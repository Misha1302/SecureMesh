#!/usr/bin/env python3
"""Account-only email recovery over the real API, PostgreSQL and Mailpit."""
import json
import subprocess
import concurrent.futures
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
import delivery as d


def mail_token(email):
    query = urllib.parse.urlencode({'query': 'to:' + email})
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        with urllib.request.urlopen(f'http://127.0.0.1:58028/api/v1/search?{query}', timeout=3) as response:
            messages = json.load(response)['messages']
        recovery = [m for m in messages if 'recovery' in m.get('Subject', '').lower()]
        if recovery:
            with urllib.request.urlopen(f"http://127.0.0.1:58028/api/v1/message/{recovery[0]['ID']}", timeout=3) as response:
                return json.load(response)['Text'].strip()
        time.sleep(.1)
    raise AssertionError('Account recovery email did not arrive')


def recovery_lock_race(database, pg, username, account, replacement):
    def sql(statement):
        return subprocess.check_output(['docker', 'compose', 'exec', '-T', 'db', 'psql', '-XAtq',
            '-U', 'securemesh', '-d', database, '-v', 'ON_ERROR_STOP=1', '-c', statement],
            cwd=d.ROOT, text=True).strip()

    challenge = d.request('/v1/auth/challenge', dict(username=username, deviceId=replacement.identity))
    signature = replacement.call('sign', payload=challenge['payload'])['signature']
    login = dict(username=username, password=account['password'], deviceId=replacement.identity,
        publicKey=replacement.public, challengeId=challenge['challengeId'], signature=signature)
    blocker = subprocess.Popen(['docker', 'compose', 'exec', '-T', 'db', 'psql', '-Xq',
        '-U', 'securemesh', '-d', database, '-v', 'ON_ERROR_STOP=1'], cwd=d.ROOT,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    blocker.stdin.write(f"BEGIN; SELECT id FROM users WHERE username='{username}' FOR UPDATE;\n")
    blocker.stdin.flush()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{database}' AND state='idle in transaction' AND query LIKE 'SELECT id FROM users WHERE username=%'") == '1':
            break
        time.sleep(.05)
    else:
        blocker.kill()
        raise AssertionError('Could not establish deterministic account-row lock')

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        sign_in = pool.submit(d.request, '/v1/auth/login', login, None, None, 401)
        refresh = pool.submit(d.request, '/v1/auth/refresh', dict(token=account['session']['refreshToken']), None, None, 401)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            count = sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{database}' AND wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=%FOR UPDATE%'")
            if count == '2':
                break
            time.sleep(.05)
        else:
            blocker.stdin.write('ROLLBACK;\\q\n')
            blocker.stdin.flush()
            raise AssertionError(f'Sign-in and refresh did not both wait on the account lock (observed {count})')
        blocker.stdin.write(f"UPDATE users SET password_hash='reset-race-fixture' WHERE username='{username}';\n"
                            f"UPDATE sessions SET revoked=true WHERE device_id IN (SELECT id FROM devices WHERE user_id=(SELECT id FROM users WHERE username='{username}'));\n"
                            f"DELETE FROM auth_challenges WHERE username='{username}'; COMMIT;\\q\n")
        blocker.stdin.flush()
        assert sign_in.result(timeout=10)['code'] == 'INVALID_CREDENTIALS'
        assert refresh.result(timeout=10)['code'] in ('REFRESH_REUSE', 'INVALID_REFRESH')
    blocker.wait(timeout=10)
    assert blocker.returncode == 0, blocker.stderr.read()


def main():
    d.BASE = 'https://127.0.0.1:5197'
    database = 'securemesh_recovery_' + uuid.uuid4().hex
    password = dict(line.split('=', 1) for line in (d.ROOT / '.env').read_text().splitlines())['SECUREMESH_DB_PASSWORD']
    pg = dict(__import__('os').environ, PGHOST='127.0.0.1', PGPORT='55438', PGUSER='securemesh', PGPASSWORD=password)
    subprocess.run(['createdb', database], env=pg, check=True)
    try:
        with d.Server(database=database), tempfile.TemporaryDirectory(prefix='securemesh-recovery-', dir=d.ROOT / '.local') as tmp:
            root = Path(tmp)
            account = d.account(root)
            username = account['username']
            email = username + '@securemesh.test'
            old_device = account['device']
            old_session = account['session']
            replacement = d.Device(root)

            # A pre-recovery one-time challenge is invalidated together with bearer grants.
            stale = d.request('/v1/auth/challenge', dict(username=username, deviceId=replacement.identity))
            stale_signature = replacement.call('sign', payload=stale['payload'])['signature']
            d.request('/v1/users/me', token=old_session['accessToken'])
            d.request('/v1/auth/recovery/request', dict(email=email), expected=202)
            token = mail_token(email)
            assert len(token) == 64
            recovery_lock_race(database, pg, username, account, replacement)
            new_password = 'replacement-password-' + uuid.uuid4().hex
            d.request('/v1/auth/recovery/complete', dict(token=token, username=username, password=new_password), method='POST', expected=204)
            d.request('/v1/auth/recovery/complete', dict(token=token, username=username, password=new_password), method='POST', expected=400)
            d.request('/v1/users/me', token=old_session['accessToken'], expected=401)
            d.request('/v1/auth/refresh', dict(token=old_session['refreshToken']), expected=401)

            # Recovery grants account authentication only. Existing device key proof remains required.
            d.request('/v1/auth/login', dict(username=username, password=new_password,
                deviceId=replacement.identity, publicKey=replacement.public, challengeId=stale['challengeId'],
                signature=stale_signature), expected=401)
            pending = d.login(username, new_password, replacement)
            assert pending['trustState'] == 'DEVICE_PENDING_TRUST'
            d.request('/v1/users/me', token=pending['accessToken'])
            d.request('/v1/devices', token=pending['accessToken'], expected=403)

            # An already enrolled device can prove its key and independently approve a replacement.
            trusted = d.login(username, new_password, old_device)
            enroll = d.request('/v1/devices/enrollment', {}, token=pending['accessToken'])
            user_id = d.request('/v1/users/me', token=pending['accessToken'])['userId']
            candidate_proof = replacement.call('enrollment_proof', payload=enroll['payload'], account=user_id)['signature']
            d.request(f"/v1/devices/enrollment/{enroll['id']}/proof", dict(signature=candidate_proof),
                      token=pending['accessToken'], expected=204)
            grant = old_device.call('enrollment_approve', payload=enroll['payload'], account=user_id,
                                    candidate_signature=candidate_proof, confirmed=True)['signature']
            d.request(f"/v1/devices/enrollment/{enroll['id']}/approve", dict(signature=grant),
                      token=trusted['accessToken'], expected=204)
            replacement.pin(old_device)
            accepted = replacement.call('enrollment_accept', payload=enroll['payload'], account=user_id,
                                        candidate_signature=candidate_proof, approver=old_device.identity,
                                        grant_signature=grant)
            d.request(f"/v1/devices/enrollment/{enroll['id']}/activate",
                      dict(signature=accepted['activation_signature']), token=pending['accessToken'], expected=204)
            assert d.request('/v1/users/me', token=pending['accessToken'])['trustState'] == 'DEVICE_TRUSTED'

            # Exercise the browser's opaque v2 credential route and token purpose separation.
            v2_name = 'recover_' + uuid.uuid4().hex[:16]
            v2_email = v2_name + '@securemesh.test'
            v2_old = __import__('base64').b64encode(__import__('secrets').token_bytes(32)).decode()
            v2_device = d.Device(root)
            d.request('/v2/auth/register', dict(username=v2_name, email=v2_email,
                displayName='Recovery integration', credential=v2_old), expected=202)
            verification = d.verification_token(v2_email)
            d.request('/v1/auth/verify-email', dict(token=verification), expected=204)
            challenge = d.request('/v1/auth/challenge', dict(username=v2_name, deviceId=v2_device.identity))
            signature = v2_device.call('sign', payload=challenge['payload'])['signature']
            old_v2 = d.request('/v2/auth/login', dict(username=v2_name, credential=v2_old,
                deviceId=v2_device.identity, publicKey=v2_device.public,
                challengeId=challenge['challengeId'], signature=signature))
            v2_user = d.request('/v1/users/me', token=old_v2['accessToken'])['userId']
            d.request('/v1/auth/recovery/request', dict(email=v2_email), expected=202)
            v2_token = mail_token(v2_email)
            d.request('/v1/auth/verify-email', dict(token=v2_token), expected=400)
            v2_new = __import__('base64').b64encode(__import__('secrets').token_bytes(32)).decode()
            d.request('/v2/auth/recovery/complete', dict(token=v2_token, username=v2_name + '_wrong', credential=v2_new), expected=400)
            d.request('/v2/auth/recovery/complete', dict(token=v2_token, username=v2_name, credential=v2_new), expected=204)
            d.request('/v1/users/me', token=old_v2['accessToken'], expected=401)
            d.request('/v1/auth/refresh', dict(token=old_v2['refreshToken']), expected=401)
            replacement_v2 = d.Device(root)
            challenge = d.request('/v1/auth/challenge', dict(username=v2_name, deviceId=replacement_v2.identity))
            signature = replacement_v2.call('sign', payload=challenge['payload'])['signature']
            pending_v2 = d.request('/v2/auth/login', dict(username=v2_name, credential=v2_new,
                deviceId=replacement_v2.identity, publicKey=replacement_v2.public,
                challengeId=challenge['challengeId'], signature=signature))
            assert pending_v2['trustState'] == 'DEVICE_PENDING_TRUST'
            assert d.request('/v1/users/me', token=pending_v2['accessToken'])['userId'] == v2_user
            d.request('/v1/devices', token=pending_v2['accessToken'], expected=403)
            print('PASS: real Postgres/Mailpit recovery token, single use, access/refresh revocation, stale challenge removal, pending-device isolation, and separate two-key enrollment. Recovery does not transfer local MLS history.')
    finally:
        subprocess.run(['dropdb', database], env=pg, check=True)


if __name__ == '__main__':
    main()
