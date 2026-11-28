#!/usr/bin/env python3
"""Account-only opt-in security notices through real PostgreSQL and local Mailpit."""
import json
import os
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from unittest.mock import patch

import delivery as d
from delivery_recovery_serialization import scalar
from private_blobs import database

PREFERENCE = '/v1/users/me/security-email'
DEVICE = 'SecureMesh: подключено устройство'
REUSE = 'SecureMesh: проверьте сеансы'


def messages(email):
    query = urllib.parse.urlencode({'query': 'to:' + email})
    with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/search?' + query, timeout=3) as response:
        return json.load(response)['messages']


def reuse(account):
    session = d.login(account['username'], account['password'], account['device'])
    token = dict(token=session['refreshToken'])
    d.request('/v1/auth/refresh', token)
    for _ in range(2):
        assert d.request('/v1/auth/refresh', token, expected=401)['code'] == 'REFRESH_REUSE'


def activate(account, root):
    candidate = d.Device(root)
    pending = d.login(account['username'], account['password'], candidate)['accessToken']
    d.request(PREFERENCE, dict(enabled=True), token=pending, method='PUT', expected=403)
    row = d.request('/v1/devices/enrollment', {}, token=pending)
    owner = d.request('/v1/users/me', token=pending)['userId']
    route = f"/v1/devices/enrollment/{row['id']}"
    proof = candidate.call('enrollment_proof', payload=row['payload'], account=owner)['signature']
    d.request(route + '/proof', dict(signature=proof), token=pending, expected=204)
    trusted = account['device']
    grant = trusted.call('enrollment_approve', payload=row['payload'], account=owner,
                         candidate_signature=proof, confirmed=True)['signature']
    d.request(route + '/approve', dict(signature=grant), token=account['session']['accessToken'], expected=204)
    candidate.pin(trusted)
    accepted = candidate.call('enrollment_accept', payload=row['payload'], account=owner,
                              candidate_signature=proof, approver=trusted.identity, grant_signature=grant)
    for _ in range(2):
        d.request(route + '/activate', dict(signature=accepted['activation_signature']), token=pending, expected=204)


def run(db, root, server):
    account = d.account(root)
    email = account['username'] + '@securemesh.test'
    access = account['session']['accessToken']
    owner = uuid.UUID(d.request('/v1/users/me', token=access)['userId'])
    def pref(enabled):
        assert d.request(PREFERENCE, dict(enabled=enabled), token=access, method='PUT') == {'enabled': enabled}
    def queued():
        return int(scalar(db, f"SELECT count(*) FROM verification_email_queue WHERE security_owner='{owner}'"))

    d.request(PREFERENCE, expected=401)
    assert d.request(PREFERENCE, token=access) == {'enabled': False}
    reuse(account)
    activate(account, root)
    assert queued() == 0
    assert scalar(db, f"SELECT device_email_at IS NULL AND refresh_reuse_email_at IS NULL FROM users WHERE id='{owner}'") == 't'
    assert all(s['Subject'] not in (DEVICE, REUSE) for s in messages(email))
    d.request(PREFERENCE, dict(enabled=True), method='PUT', expected=401)
    pref(True)
    # Hold the existing shared provider budget at its cap. No SMTP delivery can race inspection.
    scalar(db, "UPDATE verification_email_budget SET attempts=60,hour_started_at=date_trunc('hour',now(),'UTC')")
    activate(account, root)
    reuse(account)
    reuse(account)  # separate family, same per-account event cooldown
    assert queued() == 2
    assert scalar(db, f"""SELECT bool_and(credential_hash IS NULL AND position('{email}' in payload)=0)
        FROM verification_email_queue WHERE security_owner='{owner}'""") == 't'
    assert scalar(db, f"SELECT count(*) FROM email_tokens WHERE user_id='{owner}'") == '0'
    server.restart()
    assert queued() == 2
    scalar(db, "UPDATE verification_email_budget SET attempts=1")
    deadline = time.monotonic() + 10
    while queued() and time.monotonic() < deadline:
        time.sleep(.1)
    notices = [m for m in messages(email) if m['Subject'] in (DEVICE, REUSE)]
    assert sorted(m['Subject'] for m in notices) == sorted([DEVICE, REUSE])
    for m in notices:
        with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/message/' + m['ID'], timeout=3) as response:
            mail = json.load(response)
        assert [r['Address'] for r in mail['To']] == [email]
        assert not mail['HTML'] and not mail['Attachments']
        assert 'Откройте SecureMesh' in mail['Text'] or 'откройте SecureMesh' in mail['Text']
        assert 'http' not in mail['Text'] and account['username'] not in mail['Text']
        assert str(account['device'].identity) not in mail['Text']
    assert scalar(db, 'SELECT attempts FROM verification_email_budget') == '3'
    # Cancel an unclaimed notice without deleting verification or recovery credentials.
    scalar(db, "UPDATE verification_email_budget SET attempts=60")
    scalar(db, f"UPDATE users SET refresh_reuse_email_at=now()-interval '2 hours' WHERE id='{owner}'")
    reuse(account)
    assert queued() == 1
    d.request('/v1/auth/recovery/request', dict(email=email), expected=202)
    pref(False)
    assert queued() == 0
    recovery = f"SELECT hash FROM email_tokens WHERE user_id='{owner}' AND purpose='account_recovery'"
    assert scalar(db, f"SELECT count(*) FROM verification_email_queue WHERE credential_hash IN ({recovery})") == '1'
    scalar(db, f"DELETE FROM email_tokens WHERE hash IN ({recovery})")
    assert scalar(db, "SELECT count(*) FROM verification_email_queue") == '0'


def main():
    d.BASE = 'https://127.0.0.1:5192'
    settings = {'VerificationEmail__Provider':'Mailpit', 'VerificationEmail__MailpitPort':'51028',
                'VerificationEmail__MaxAttemptsPerUtcHour':'60'}
    with patch.dict(os.environ,settings), database() as db:
        with d.Server(database=db,legacy_bootstrap=False) as server, tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as temp:
            run(db, Path(temp), server)
    print('PASS local Mailpit security notices, trusted opt-in, atomic queue, cooldown, provider cap and cancellation.')


if __name__ == '__main__':
    main()
