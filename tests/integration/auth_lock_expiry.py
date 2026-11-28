#!/usr/bin/env python3
"""Verify real requests recheck deadlines after waiting on the account row."""
import concurrent.futures
import os
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch

import delivery as d
from delivery_recovery_serialization import hold_row, scalar, wait_for
from private_blobs import database


def run(db, root):
    account = d.account(root)
    username, password = account['username'], account['password']
    first = account['device']
    candidate, other = d.Device(root), d.Device(root)
    token = d.login(username, password, candidate)['accessToken']
    other_token = d.login(username, password, other)['accessToken']
    owner = uuid.UUID(d.request('/v1/users/me', token=token)['userId'])
    enrollment = d.request('/v1/devices/enrollment', {}, token=token)
    eid = uuid.UUID(enrollment['id'])
    signature = candidate.call('enrollment_proof', payload=enrollment['payload'], account=str(owner))['signature']

    def prepare_enrollment(approve):
        device = d.Device(root)
        session = d.login(username, password, device)['accessToken']
        pending = d.request('/v1/devices/enrollment', {}, token=session)
        base = f"/v1/devices/enrollment/{pending['id']}"
        payload = pending['payload']
        proof = device.call('enrollment_proof', payload=payload, account=str(owner))['signature']
        d.request(base + '/proof', dict(signature=proof), token=session, expected=204)
        grant = first.call('enrollment_approve', payload=payload, account=str(owner),
                           candidate_signature=proof, confirmed=True)['signature']
        trusted = account['session']['accessToken']
        if not approve:
            return uuid.UUID(pending['id']), base + '/approve', trusted, grant
        d.request(base + '/approve', dict(signature=grant), token=trusted, expected=204)
        device.pin(first)
        accepted = device.call('enrollment_accept', payload=payload, account=str(owner), candidate_signature=proof,
                               approver=first.identity, grant_signature=grant)
        return uuid.UUID(pending['id']), base + '/activate', session, accepted['activation_signature']

    grant_id, grant_route, grant_token, grant_sig = prepare_enrollment(False)
    active_id, active_route, active_token, active_sig = prepare_enrollment(True)
    challenge = d.request('/v1/auth/challenge', dict(username=username, deviceId=first.identity))
    cid = uuid.UUID(challenge['challengeId'])
    login = dict(username=username, password=password, deviceId=first.identity, publicKey=first.public,
                 challengeId=str(cid), signature=first.call('sign', payload=challenge['payload'])['signature'])

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        with hold_row(db, f"SELECT id FROM users WHERE id='{owner}' FOR UPDATE"):
            auth = pool.submit(d.request, '/v1/devices/enrollment', {}, token=other_token, expected=401)
            proof = pool.submit(d.request, f'/v1/devices/enrollment/{eid}/proof', dict(signature=signature),
                                token=token, expected=404)
            grant = pool.submit(d.request, grant_route, dict(signature=grant_sig), token=grant_token, expected=409)
            activate = pool.submit(d.request, active_route, dict(signature=active_sig), token=active_token, expected=409)
            signin = pool.submit(d.request, '/v1/auth/login', login, expected=401)
            refresh = pool.submit(d.request, '/v1/auth/refresh', dict(token=account['session']['refreshToken']), expected=401)
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM users%FOR UPDATE%'", 6)
            # All six transactions have started. Make each deadline equal to this later
            # PostgreSQL statement time before releasing the row. No timing sleeps.
            scalar(db, f"""
                UPDATE sessions SET expires_at=statement_timestamp() WHERE device_id='{uuid.UUID(other.identity)}';
                UPDATE sessions SET refresh_expires_at=statement_timestamp() WHERE device_id='{uuid.UUID(first.identity)}';
                UPDATE device_enrollments SET expires_at=statement_timestamp() WHERE id IN ('{eid}','{grant_id}','{active_id}');
                UPDATE auth_challenges SET expires_at=statement_timestamp() WHERE id='{cid}';
            """)
        assert auth.result()['code'] == 'AUTH_REQUIRED'
        assert proof.result()['code'] == 'ENROLLMENT_NOT_PENDING'
        assert grant.result()['code'] == 'ENROLLMENT_NOT_PENDING'
        assert activate.result()['code'] == 'ACTIVATION_NOT_AVAILABLE'
        assert signin.result()['code'] == 'DEVICE_PROOF_REQUIRED'
        assert refresh.result()['code'] == 'INVALID_REFRESH'
    assert scalar(db, f"SELECT candidate_signature IS NULL FROM device_enrollments WHERE id='{eid}'") == 't'
    assert scalar(db, f"SELECT approved_at IS NULL FROM device_enrollments WHERE id='{grant_id}'") == 't'
    assert scalar(db, f"""SELECT e.activated_at IS NULL AND NOT d.trusted FROM device_enrollments e
                          JOIN devices d ON d.id=e.device_id WHERE e.id='{active_id}'""") == 't'
    assert scalar(db, f"SELECT count(*) FROM device_enrollments WHERE device_id='{uuid.UUID(other.identity)}'") == '0'
    assert scalar(db, f"SELECT count(*) FROM sessions WHERE device_id='{uuid.UUID(first.identity)}'") == '1'


def main():
    d.BASE = 'https://127.0.0.1:5193'
    mail = {'VerificationEmail__Provider': 'Mailpit', 'VerificationEmail__MailpitPort': '51028'}
    with patch.dict(os.environ, mail), database() as db:
        with d.Server(database=db, legacy_bootstrap=False), tempfile.TemporaryDirectory(dir=d.ROOT / '.local') as tmp:
            run(db, Path(tmp))
    print('PASS post-lock expiry of session, enrollment, login challenge and refresh credential.')


if __name__ == '__main__':
    main()
