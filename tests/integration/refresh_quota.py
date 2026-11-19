#!/usr/bin/env python3
"""512 real signed refreshes; no fake ledger rows or lowered server limit."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

import delivery as d
from native_session import sql


def main():
    os.umask(0o077)
    d.BASE='https://127.0.0.1:5093'
    with d.Server(legacy_bootstrap=False),tempfile.TemporaryDirectory(prefix='securemesh-refresh-quota-',dir=d.ROOT/'.local') as tmp:
        root=Path(tmp);account=d.account(root);device=account['device']
        device.call('profile_put',profile={**account['session'],'endpoint':d.BASE})
        fixture=root/'fixture.json'
        data=dict(path=str(device.path),passphrase=device.password,endpoint=d.BASE,
                  library=str(d.ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'),
                  cert=str(d.ROOT/'.local/tls.pem'))
        def run(count):
            fixture.write_text(json.dumps(data|{'count':count}));fixture.chmod(0o600)
            result=subprocess.run([str(d.ROOT/'.local/flutter/bin/dart'),'run','tool/refresh_quota.dart',str(fixture)],cwd=d.ROOT/'apps/client_flutter',env={**os.environ,'PUB_CACHE':str(d.ROOT/'.local/pub-cache')},text=True,capture_output=True,timeout=260)
            assert result.returncode==0,'Actual refresh quota runner failed'
            for secret in [account['password'],device.password,account['session']['refreshToken']]:
                assert secret not in result.stdout+result.stderr
            return json.loads(result.stdout.strip())
        first=run(513)
        assert first['accepted']==512 and first['limited']
        assert sql(f"SELECT count(*) FROM refresh_rotations WHERE device_id='{device.identity}'")=='512'
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'")=='513'
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}' AND revoked")=='0'
        pending=device.call('refresh_status')['pending']
        assert pending is not None
        sql(f"UPDATE refresh_rotations SET created_at=created_at-interval '2 days',expires_at=expires_at-interval '2 days' WHERE device_id='{device.identity}'")
        second=run(1)
        assert second['accepted']==1 and not second['limited']
        assert device.call('refresh_status')['pending'] is None
        assert sql(f"SELECT count(*) FROM refresh_rotations WHERE device_id='{device.identity}'")=='1'
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'")=='514'
        print(f"PASS: 512 actual signed rotations; 513th denied without token/family loss; observed global-rate waits={first['throttles']}; owned ledger timestamps advance next window and same pending request succeeds. No seeded quota rows/lowered limit.")


if __name__=='__main__':main()
