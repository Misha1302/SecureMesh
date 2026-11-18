#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path
import delivery as d


def sql(statement):
    return subprocess.check_output(['docker','compose','exec','-T','db','psql','-U','securemesh','-d','securemesh','-v','ON_ERROR_STOP=1','-Atc',statement],cwd=d.ROOT,text=True).strip()


def main():
    d.BASE='https://127.0.0.1:5097'
    with d.Server(legacy_bootstrap=False),tempfile.TemporaryDirectory(prefix='securemesh-native-session-',dir=d.ROOT/'.local') as tmp:
        root=Path(tmp);account=d.account(root);device=account['device'];id=str(uuid.UUID(device.identity))
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{id}'")=='1'
        sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{id}'")
        fixture=root/'fixture.json';fixture.write_text(json.dumps(dict(endpoint=d.BASE,path=str(device.path),passphrase=device.password,device=device.identity,session=account['session'],cert=str(d.ROOT/'.local/tls.pem'),library=str(d.ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'))));fixture.chmod(0o600)
        subprocess.run([str(d.ROOT/'.local/flutter/bin/dart'),'run','tool/session_smoke.dart',str(fixture)],cwd=d.ROOT/'apps/client_flutter',env={**os.environ,'PUB_CACHE':str(d.ROOT/'.local/pub-cache')},check=True,timeout=60)
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{id}'")=='2'
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{id}' AND revoked")=='0'
        assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{id}' AND NOT used AND NOT revoked AND expires_at>now()")=='1'
        print('PostgreSQL confirms one rotation and no refresh-family reuse revocation.')


if __name__=='__main__':main()
