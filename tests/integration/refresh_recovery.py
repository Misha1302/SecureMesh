#!/usr/bin/env python3
"""Native session recovery after actual refresh COMMIT and owned SIGKILL."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

import delivery as d
from native_session import sql
from onboarding_recovery import GateProxy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-baseline', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    d.BASE = 'https://127.0.0.1:5094'
    children = []
    with d.Server(legacy_bootstrap=False) as server, GateProxy() as proxy, tempfile.TemporaryDirectory(
            prefix='securemesh-refresh-', dir=d.ROOT / '.local') as tmp:
        try:
            root = Path(tmp)
            account = d.account(root)
            device = account['device']
            me = d.request('/v1/users/me', token=account['session']['accessToken'])
            original = device.call('identity')
            device.call('profile_put', profile={
                **account['session'], 'endpoint': proxy.endpoint,
                'username': account['username'], 'userId': me['userId'],
                'requiresEnrollment': False, 'enrollmentVerified': True,
            })
            sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{device.identity}'")
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps(dict(path=str(device.path), passphrase=device.password,
                                              device=device.identity,
                                              cert=str(d.ROOT / '.local/tls.pem'),
                                              library=str(d.ROOT / 'src/crypto_core/target/debug/libsecuremesh_crypto.so'))))
            fixture.chmod(0o600)

            def start():
                child = subprocess.Popen(
                    [str(d.ROOT / '.local/flutter/bin/dart'), 'run', 'tool/session_recovery.dart', str(fixture)],
                    cwd=d.ROOT / 'apps/client_flutter', env={**os.environ, 'PUB_CACHE': str(d.ROOT / '.local/pub-cache')},
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                children.append(child)
                return child

            proxy.arm('/v1/auth/refresh' if args.legacy_baseline else '/v1/auth/refresh/device')
            first = start()
            deadline = time.monotonic() + 35
            while not proxy.hit.wait(.1) and first.poll() is None and time.monotonic() < deadline:
                pass
            if not proxy.hit.is_set():
                raise AssertionError('Actual refresh COMMIT gate not reached')
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'") == '2'
            os.killpg(first.pid, signal.SIGKILL)
            first.communicate(timeout=10)
            assert first.returncode == -signal.SIGKILL
            proxy.release.set()
            assert device.call('profile')['refreshToken'] == account['session']['refreshToken']
            server.restart()
            second = start()
            output, errors = second.communicate(timeout=45)
            for secret in (account['password'], device.password, account['session']['accessToken'], account['session']['refreshToken']):
                assert secret not in output + errors
            result = json.loads(output.strip().splitlines()[-1]) if output.strip() else {}
            assert second.returncode == 0 and result.get('ok'), 'Recovery rejected: ' + str(result.get('code', 'native failure'))
            assert device.call('identity') == original
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'") == '2'
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}' AND revoked") == '0'
            assert not proxy.errors, proxy.errors
            print('PASS: actual refresh COMMIT, lost reply, owned SIGKILL, API restart and same-key native recovery without another rotation or family revocation.')
        finally:
            proxy.release.set()
            for child in children:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.communicate(timeout=10)


if __name__ == '__main__':
    main()
