#!/usr/bin/env python3
"""Exercise native recovery against disposable HTTPS, PostgreSQL, Mailpit and the native Rust core."""
import hashlib
import os
import secrets
import subprocess
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch

import delivery as d
from private_blobs import database


def login(device, username, credential, expected=200):
    challenge = d.request('/v1/auth/challenge', dict(username=username, deviceId=device.identity))
    signature = device.call('sign', payload=challenge['payload'])['signature']
    return d.request('/v2/auth/login', dict(
        username=username, credential=credential, deviceId=device.identity, publicKey=device.public,
        challengeId=challenge['challengeId'], signature=signature,
    ), expected=expected)


def run(scratch):
    name = 'recover_' + uuid.uuid4().hex[:16]
    email = name + '@securemesh.test'
    old_password, new_password = [secrets.token_urlsafe(24) for _ in range(2)]
    device = d.Device(scratch)

    def credential(password):
        return device.call('derive_server_credential_v2', endpoint=d.BASE, username=name, password=password)['credential']

    old, new = credential(old_password), credential(new_password)
    d.request('/v2/auth/register', dict(username=name, email=email, displayName='Native recovery', credential=old), expected=202)
    d.request('/v1/auth/verify-email', {'token': d.verification_token(email)}, expected=204)
    initial = login(device, name, old)
    assert initial['trustState'] == 'DEVICE_TRUSTED'
    before = hashlib.sha256(device.path.read_bytes()).digest()
    files_before = set(scratch.iterdir())
    flutter = os.environ.get('SECUREMESH_TEST_FLUTTER', 'flutter')
    env = dict(os.environ, SECUREMESH_API_ORIGIN=d.BASE, SECUREMESH_PROFILE_DIRECTORY=str(scratch),
               SECUREMESH_CERT_FILE=str(d.ROOT/'.local/tls.pem'),
               SECUREMESH_CRYPTO_LIB=str(d.ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'),
               SECUREMESH_TEST_RECOVERY_USER=name, SECUREMESH_TEST_RECOVERY_EMAIL=email,
               SECUREMESH_TEST_RECOVERY_PASSWORD=new_password)
    subprocess.run([flutter, 'test', '--no-pub', 'integration/account_recovery_hosted_test.dart'],
                   cwd=d.ROOT/'apps/client_flutter', env=env, check=True, timeout=75)

    assert set(scratch.iterdir()) == files_before
    assert hashlib.sha256(device.path.read_bytes()).digest() == before
    d.request('/v1/users/me', token=initial['accessToken'], expected=401)
    login(device, name, old, expected=401)
    assert login(device, name, new)['trustState'] == 'DEVICE_TRUSTED'
    assert login(d.Device(scratch), name, new)['trustState'] == 'DEVICE_PENDING_TRUST'


def main():
    d.BASE = 'https://127.0.0.1:5191'
    mail = {'VerificationEmail__Provider': 'Mailpit', 'VerificationEmail__MailpitPort': '51028'}
    with patch.dict(os.environ, mail), database() as db:
        with d.Server(database=db, legacy_bootstrap=False), tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as scratch:
            run(Path(scratch))
    print('PASS native recovery UI, original profile bytes, old session rejection, and unchanged device trust rules.')


if __name__ == '__main__':
    main()
