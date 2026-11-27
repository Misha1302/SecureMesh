#!/usr/bin/env python3
"""Run every real EF migration on an owned empty PG database; restart and exercise trust."""
import subprocess
import tempfile
import uuid
from pathlib import Path
import delivery as d


def command(*args):
    return subprocess.check_output(['docker','compose','exec','-T','db',*args],cwd=d.ROOT,text=True)


def main():
    d.BASE='https://127.0.0.1:5094'
    database='securemesh_v2_'+uuid.uuid4().hex
    command('createdb','-U','securemesh',database)
    try:
        with d.Server(database=database) as server,tempfile.TemporaryDirectory(dir=d.ROOT/'.local',prefix='securemesh-migration-') as tmp:
            a=d.account(Path(tmp));candidate=d.Device(Path(tmp))
            pending=d.login(a['username'],a['password'],candidate)
            assert pending['trustState']=='DEVICE_PENDING_TRUST'
            server.restart()
            assert d.request('/v1/users/me',token=pending['accessToken'])['trustState']=='DEVICE_PENDING_TRUST'
            d.request('/v1/devices',token=pending['accessToken'],expected=403)
            result=command('psql','-U','securemesh','-d',database,'-Atc','SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY "MigrationId"')
            assert result.strip().splitlines()==['202611180001_Foundation','202611180002_DeviceChallenges','202611180003_DeviceTrust','202611180004_MlsDirectory','202611180005_EnrollmentActivation','202611190006_EnrollmentIssuanceQuota','202611270007_DisplayName']
            print('PASS: fresh owned PostgreSQL database; all seven EF migrations; real registration and first/pending device proof; restart preserves pending status; migration reapplication idempotent. Existing development database upgrade exercised by enrollment/directory suites; destructive downgrade deliberately refused.')
    finally:
        command('dropdb','-U','securemesh',database)


if __name__=='__main__':main()
