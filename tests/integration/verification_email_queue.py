#!/usr/bin/env python3
"""Verify durable registration and bounded transactional mail using local PostgreSQL and Mailpit."""
import base64
import concurrent.futures
import json
import os
import secrets
import socket
import subprocess
import time
import urllib.parse
import urllib.request
import uuid

import delivery as test


def main():
    test.BASE = 'https://127.0.0.1:5197'
    database = 'mailqueue_' + uuid.uuid4().hex
    password = dict(line.split('=', 1) for line in
                    (test.ROOT / '.env').read_text().splitlines())['SECUREMESH_DB_PASSWORD']
    pg = dict(os.environ, PGHOST='127.0.0.1', PGPORT='55438', PGUSER='securemesh', PGPASSWORD=password)

    def sql(statement):
        return subprocess.check_output(['psql', '-XAtq', '-v', 'ON_ERROR_STOP=1',
                                        '-d', database, '-c', statement], env=pg, text=True).strip()

    def wait_for(statement, expected):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if sql(statement) == expected:
                return
            time.sleep(.1)
        raise AssertionError(f'Expected database result {expected} for {statement}')

    subprocess.run(['createdb', database], env=pg, check=True)
    try:
        # Reserve a loopback port with no listener so SMTP gets a connection failure.
        with socket.socket() as offline:
            offline.bind(('127.0.0.1', 0))
            os.environ['VerificationEmail__MailpitPort'] = str(offline.getsockname()[1])
            os.environ['VerificationEmail__Provider'] = 'Mailpit'
            os.environ['VerificationEmail__MaxAttemptsPerUtcHour'] = '60'
            with test.Server(database) as api:
                username = 'mail_' + uuid.uuid4().hex[:16]
                email = username + '@securemesh.test'
                registration = dict(username=username, email=email, password=secrets.token_urlsafe(24))
                assert test.request('/v1/auth/register', registration, expected=202) is None
                assert test.request('/v1/auth/register', registration, expected=202) is None
                assert sql('SELECT count(*) FROM users') == '1'
                assert sql('SELECT count(*) FROM email_tokens') == '1'
                wait_for('SELECT attempts FROM verification_email_queue', '1')
                assert sql('SELECT attempts FROM verification_email_budget') == '1'
                assert sql("SELECT payload LIKE '%securemesh.test%' FROM verification_email_queue") == 'f'

                # The same pending delivery must survive stopping the process.
                api.stop()
                sql('UPDATE verification_email_queue SET next_attempt_at=now()')
                api.env['VerificationEmail__MailpitPort'] = '51028'
                api.start()
                token = test.verification_token(email)
                wait_for('SELECT count(*) FROM verification_email_queue', '0')
                test.request('/v1/auth/verify-email', dict(token=token), expected=204)
                test.request('/v1/auth/verify-email', dict(token=token), expected=400)

                api.stop()
                api.env['VerificationEmail__MailpitPort'] = os.environ['VerificationEmail__MailpitPort']
                api.start()
                second = 'mail_' + uuid.uuid4().hex[:16]
                second_email = second + '@securemesh.test'
                credential = base64.b64encode(secrets.token_bytes(32)).decode()
                test.request('/v2/auth/register',
                             dict(username=second, email=second_email,
                                  credential=credential, displayName='Queue test'),
                             expected=202)
                for attempt in range(1, 6):
                    wait_for('SELECT attempts FROM verification_email_queue', str(attempt))
                    # Advance the retry schedule without waiting through operational backoff.
                    sql('UPDATE verification_email_queue SET next_attempt_at=now()')
                wait_for('SELECT count(*) FROM verification_email_queue', '0')
                resend_path = '/v2/auth/resend-verification'
                resend = dict(username=second, credential=credential)
                original_hash = sql("SELECT encode(hash,'hex') FROM email_tokens")
                assert test.request(resend_path, resend, expected=202) is None
                assert sql('SELECT count(*) FROM verification_email_queue') == '0'
                assert sql("SELECT encode(hash,'hex') FROM email_tokens") == original_hash
                sql("UPDATE email_tokens SET expires_at=now()-interval '1 second'")
                wrong = base64.b64encode(secrets.token_bytes(32)).decode()
                assert test.request(resend_path, {**resend, 'credential': wrong}, expected=202) is None
                assert test.request(resend_path, {**resend, 'username': username + '_x'}, expected=202) is None
                assert sql('SELECT count(*) FROM verification_email_queue') == '0'
                sql("UPDATE users SET verification_resends=5,verification_resend_window=now() WHERE NOT verified")
                assert test.request(resend_path, resend, expected=202) is None
                assert sql('SELECT count(*) FROM verification_email_queue') == '0'
                sql("UPDATE users SET verification_resend_window=now()-interval '25 hours' WHERE NOT verified")
                api.stop()
                api.env['VerificationEmail__MailpitPort'] = '51028'
                api.start()
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    futures = [pool.submit(test.request, resend_path, resend, expected=202) for _ in range(2)]
                    assert [future.result() for future in futures] == [None, None]
                replacement = test.verification_token(second_email)
                assert sql('SELECT verification_resends FROM users WHERE NOT verified') == '1'
                assert sql('SELECT count(*) FROM email_tokens') == '1'
                assert sql("SELECT encode(hash,'hex') FROM email_tokens") != original_hash
                test.request('/v1/auth/verify-email', dict(token=replacement), expected=204)
                assert test.request(resend_path, resend, expected=202) is None
                assert sql('SELECT count(*) FROM email_tokens') == '0'
        verify_hourly_budget(database, sql, wait_for)
    finally:
        subprocess.run(['dropdb', database], env=pg, check=True)

    print('Passed local verification email outage, restart, retry, token, resend and shared hourly budget checks.')


def verify_hourly_budget(database, sql, wait_for):
    def mail_count(email):
        query = urllib.parse.urlencode({'query': 'to:' + email})
        with urllib.request.urlopen(f'http://127.0.0.1:58028/api/v1/search?{query}', timeout=3) as result:
            return len(json.load(result)['messages'])

    def register():
        username = 'mail_' + uuid.uuid4().hex[:16]
        email = username + '@securemesh.test'
        password = secrets.token_urlsafe(24)
        test.request('/v1/auth/register', dict(username=username, email=email, password=password), expected=202)
        return username, email, password

    def simulate_new_utc_hour():
        # The next lease sees a budget from a previous UTC hour.
        sql("UPDATE verification_email_budget SET hour_started_at=date_trunc('hour',now(),'UTC')-interval '1 hour'")

    os.environ['VerificationEmail__MailpitPort'] = '51028'
    os.environ['VerificationEmail__MaxAttemptsPerUtcHour'] = '1'
    simulate_new_utc_hour()
    with test.Server(database) as first:
        username, resend_recipient, password = register()
        test.verification_token(resend_recipient)
        wait_for('SELECT count(*) FROM verification_email_queue', '0')
        assert sql('SELECT attempts FROM verification_email_budget') == '1'

        first_origin = test.BASE
        test.BASE = 'https://127.0.0.1:5196'
        try:
            with test.Server(database):
                # Make the existing token eligible for resend without waiting five minutes.
                sql("UPDATE email_tokens SET expires_at=now()-interval '1 second'")
                test.request('/v1/auth/resend-verification', dict(username=username, password=password), expected=202)
                _, initial_recipient, _ = register()
                expired_user, expired_recipient, _ = register()
                untouched = sql("""
                    SELECT bool_and(q.attempts=0 AND q.expires_at=t.expires_at AND q.expires_at>now())
                    FROM verification_email_queue q JOIN email_tokens t ON t.hash=q.token_hash
                    """)
                assert untouched == 't'
                assert sql('SELECT count(*) FROM verification_email_queue') == '3'
                first.stop()
                test.BASE = first_origin
                first.start()
                test.BASE = 'https://127.0.0.1:5196'

                duration = 1.5
                time.sleep(duration)
                assert mail_count(resend_recipient) == 1
                assert mail_count(initial_recipient) == 0
                assert mail_count(expired_recipient) == 0
                assert sql('SELECT attempts FROM verification_email_budget') == '1'
                assert sql('SELECT count(*) FROM verification_email_queue WHERE attempts=0') == '3'

                # This message's verification window ends before there is more capacity.
                sql(f"""
                    WITH expired AS (
                        UPDATE email_tokens SET expires_at=now()-interval '1 second'
                        WHERE user_id=(SELECT id FROM users WHERE username='{expired_user}') RETURNING hash
                    )
                    UPDATE verification_email_queue q SET expires_at=now()-interval '1 second'
                    FROM expired WHERE q.token_hash=expired.hash
                    """)
                wait_for('SELECT count(*) FROM verification_email_queue', '2')
                simulate_new_utc_hour()
                wait_for('SELECT count(*) FROM verification_email_queue', '1')
                assert mail_count(resend_recipient) + mail_count(initial_recipient) == 2
                assert mail_count(expired_recipient) == 0
                assert sql('SELECT attempts FROM verification_email_budget') == '1'
                simulate_new_utc_hour()
                wait_for('SELECT count(*) FROM verification_email_queue', '0')
                assert mail_count(resend_recipient) == 2
                assert mail_count(initial_recipient) == 1
                assert mail_count(expired_recipient) == 0
        finally:
            test.BASE = first_origin


if __name__ == '__main__':
    main()
