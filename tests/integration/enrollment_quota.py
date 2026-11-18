#!/usr/bin/env python3
"""Actual enrollment issuance quota survives expired-request cleanup and API restart."""
import tempfile
import uuid
from pathlib import Path

import delivery as d
from recovery import compose, scalar


def denied(token):
    try:
        response = d.request('/v1/devices/enrollment', {}, token=token, expected=429)
    except AssertionError:
        # Do not print an unexpectedly issued enrollment nonce/payload.
        raise AssertionError('ENROLLMENT_QUOTA_BYPASSED_OR_WRONG_STATUS') from None
    assert response == {'code': 'ENROLLMENT_LIMIT'}, 'Quota must be enforced by persistent issuance, not the generic IP limiter'


def main():
    d.BASE = 'https://127.0.0.1:5094'
    database = 'securemesh_quota_' + uuid.uuid4().hex[:12]
    compose('exec', '-T', 'db', 'createdb', '-U', 'securemesh', database)
    try:
        with d.Server(database=database, legacy_bootstrap=False) as server, tempfile.TemporaryDirectory(prefix='securemesh-quota-', dir=d.ROOT / '.local') as tmp:
            owner = d.account(Path(tmp)); candidate = d.Device(Path(tmp))
            session = d.login(owner['username'], owner['password'], candidate)
            assert session['trustState'] == 'DEVICE_PENDING_TRUST'
            token = session['accessToken']
            identities = set()
            for index in range(32):
                request = d.request('/v1/devices/enrollment', {}, token=token)
                identity = str(uuid.UUID(request['id']))
                assert identity not in identities
                identities.add(identity)
                if index == 0:
                    assert d.request('/v1/devices/enrollment', {}, token=token)['id'] == identity
                # Simulate elapsed request lifetime in the owned isolated DB;
                # every new issuance still goes through the real API.
                scalar(f"UPDATE device_enrollments SET expires_at=now()-interval '1 second' WHERE id='{identity}'", database)
            denied(token)
            device = str(uuid.UUID(candidate.identity))
            assert scalar(f"SELECT count(*) FROM device_enrollment_issuance WHERE device_id='{device}'", database) == '32'
            assert scalar(f"SELECT count(*) FROM device_enrollments WHERE device_id='{device}'", database) == '1'
            server.restart()
            denied(token)
            scalar(f"UPDATE device_enrollment_issuance SET created_at=now()-interval '1 day'-interval '1 second' WHERE device_id='{device}'", database)
            next_request = d.request('/v1/devices/enrollment', {}, token=token)
            assert next_request['id'] not in identities
            assert scalar(f"SELECT count(*) FROM device_enrollment_issuance WHERE device_id='{device}'", database) == '33'
            d.request('/v1/conversations', token=token, expected=403)
            print('PASS: 32 real new enrollment issuances across expired-row cleanup; same pending request retry does not consume quota; 33rd denied by ENROLLMENT_LIMIT, including after API restart; next rolling-day window allows issuance; candidate stays pending. Expiry/window timestamps advanced only in an owned isolated DB; no mocked API/crypto.')
    finally:
        compose('exec', '-T', 'db', 'dropdb', '-U', 'securemesh', database)


if __name__ == '__main__':
    main()
