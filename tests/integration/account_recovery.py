#!/usr/bin/env python3
"""Account-only email recovery over the real API, PostgreSQL and Mailpit."""
import json
import subprocess
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
            new_password = 'replacement-password-' + uuid.uuid4().hex
            d.request('/v1/auth/recovery/complete', dict(token=token, password=new_password), method='POST', expected=204)
            d.request('/v1/auth/recovery/complete', dict(token=token, password=new_password), method='POST', expected=400)
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
            print('PASS: real Postgres/Mailpit recovery token, single use, access/refresh revocation, stale challenge removal, pending-device isolation, and separate two-key enrollment. Recovery does not transfer local MLS history.')
    finally:
        subprocess.run(['dropdb', database], env=pg, check=True)


if __name__ == '__main__':
    main()
