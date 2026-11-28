#!/usr/bin/env python3
"""Verify durable registration and bounded transactional mail using local PostgreSQL and Mailpit."""
import base64
import os
import secrets
import socket
import subprocess
import time
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
            with test.Server(database) as api:
                username = 'mail_' + uuid.uuid4().hex[:16]
                email = username + '@securemesh.test'
                registration = dict(username=username, email=email, password=secrets.token_urlsafe(24))
                assert test.request('/v1/auth/register', registration, expected=202) is None
                assert test.request('/v1/auth/register', registration, expected=202) is None
                assert sql('SELECT count(*) FROM users') == '1'
                assert sql('SELECT count(*) FROM email_tokens') == '1'
                wait_for('SELECT attempts FROM verification_email_queue', '1')
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
                test.request('/v2/auth/register',
                             dict(username=second, email=second + '@securemesh.test',
                                  credential=base64.b64encode(secrets.token_bytes(32)).decode(), displayName='Queue test'),
                             expected=202)
                for attempt in range(1, 6):
                    wait_for('SELECT attempts FROM verification_email_queue', str(attempt))
                    # Advance the retry schedule without waiting through operational backoff.
                    sql('UPDATE verification_email_queue SET next_attempt_at=now()')
                wait_for('SELECT count(*) FROM verification_email_queue', '0')
    finally:
        subprocess.run(['dropdb', database], env=pg, check=True)

    print('Passed local verification email outage, restart, duplicate, token, and retry-bound checks.')


if __name__ == '__main__':
    main()
