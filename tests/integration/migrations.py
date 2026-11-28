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
            session=d.login(a['username'],a['password'],a['device'],client_os='linux')
            token=session['accessToken']
            d.request('/v1/devices/me/name',{'name':'Ноутбук'},method='PUT',token=token,expected=204)
            d.request('/v1/devices/me/name',{'name':'forbidden'},method='PUT',token=pending['accessToken'],expected=403)
            rows=d.request('/v1/devices',token=token)
            own,other=rows
            assert own['isCurrent'] and own['id']==a['device'].identity
            assert own['clientOs']=='linux' and own['name']=='Ноутбук' and own['createdAt'] and own['lastLoginAt']
            assert own['hasRefreshableSession'] and not other['isCurrent']
            assert other['id']==candidate.identity and other['name'] is None and other['clientOs'] is None
            assert other['trustState']=='DEVICE_PENDING_TRUST'
            refreshed=d.request('/v1/auth/refresh',{'token':session['refreshToken']})
            refreshed_rows=d.request('/v1/devices',token=refreshed['accessToken'])
            assert refreshed_rows[0]['lastLoginAt']==own['lastLoginAt']
            legacy=d.login(a['username'],a['password'],a['device'])
            assert d.request('/v1/devices',token=legacy['accessToken'])[0]['clientOs']=='linux'
            # Same device-level endpoint used for each confirmed bulk action.
            d.request('/v1/devices/'+candidate.identity,method='DELETE',token=legacy['accessToken'],expected=204)
            d.request('/v1/users/me',token=pending['accessToken'],expected=401)
            final=d.request('/v1/devices',token=legacy['accessToken'])
            assert final[0]['isCurrent'] and final[0]['hasRefreshableSession']
            assert final[1]['revoked'] and not final[1]['hasRefreshableSession']
            result=command('psql','-U','securemesh','-d',database,'-Atc','SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY "MigrationId"')
            expected = [
                '202611180001_Foundation',
                '202611180002_DeviceChallenges',
                '202611180003_DeviceTrust',
                '202611180004_MlsDirectory',
                '202611180005_EnrollmentActivation',
                '202611190006_EnrollmentIssuanceQuota',
                '202611270007_DisplayName',
                '202611270008_ProfilePhotos',
                '202611270009_PublicChannels',
                '202611270010_PrivateBlobs',
                '202611270011_ChannelInvitations',
                '202611270012_ResumableBlobs',
                '202611270013_DeviceRoster',
                '202611270014_AccountRemoval',
                '202611270015_ProfileText',
                '202611270016_DeviceClientMetadata',
                '202611270017_UnicodeDisplayName',
                '202611270018_SessionInactivity',
                '202611280101_VerificationEmailQueue',
                '202611280102_EmailTokenOwner',
                '202611280103_VerificationEmailBudget',
                '202611280104_DirectoryPackageOffer',
                '202611280105_ContactBlocks',
                '202611280106_AccountRecovery',
                '202611280107_SecurityEmail',
                '202611280108_ChannelReactions',
                '202611280109_ChannelPostEditedAt',
            ]
            assert result.strip().splitlines() == expected
            print(f'PASS: {len(expected)} EF migrations on a fresh PostgreSQL database; idempotent restart preserves trust and device metadata.')
    finally:
        command('dropdb','-U','securemesh',database)


if __name__=='__main__':main()
