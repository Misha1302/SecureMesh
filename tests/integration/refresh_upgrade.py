#!/usr/bin/env python3
"""Real EF 6→7 with legacy sessions/MLS data; isolated PG and refresh-key restore."""
import json
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
import delivery as d
from directory import establish


def pg(database, statement):
    result=subprocess.run(['docker','compose','exec','-T','db','psql','-U','securemesh','-d',database,'-v','ON_ERROR_STOP=1','-Atc',statement],cwd=d.ROOT,capture_output=True)
    assert result.returncode==0,'Owned SQL operation failed'
    return result.stdout


def main():
    os.umask(0o077)
    d.BASE='https://127.0.0.1:5092'
    databases=[]
    try:
        with tempfile.TemporaryDirectory(prefix='securemesh-refresh-upgrade-',dir=d.ROOT/'.local') as tmp, d.Server(legacy_bootstrap=False) as server:
            root=Path(tmp); state=root/'source-state';state.mkdir()
            server.env['StateDirectory']=str(state);server.restart()
            a,b=[d.account(root) for _ in range(2)]
            a['device'].pin(b['device']);b['device'].pin(a['device']);group=establish(a,b)
            message=a['device'].call('queue',group=group,id=str(uuid.uuid4()),text='Legacy schema survives refresh upgrade and restore')
            d.request('/v1/messages',d.envelope(message,group),token=a['session']['accessToken'])
            user_ids=[d.request('/v1/users/me',token=x['session']['accessToken'])['userId'] for x in (a,b)]
            target='securemesh_refresh_upgrade_'+uuid.uuid4().hex[:12]
            subprocess.run(['docker','compose','exec','-T','db','createdb','-U','securemesh',target],cwd=d.ROOT,check=True);databases.append(target)
            connection=server.env['ConnectionStrings__Database'].replace('Database=securemesh;','Database='+target+';')
            subprocess.run(['dotnet','tests/migration_runner/bin/Debug/net10.0/MigrationRunner.dll'],cwd=d.ROOT,env={**os.environ,'SECUREMESH_TEST_DATABASE':connection},check=True,timeout=45,stdout=subprocess.DEVNULL)
            assert pg(target,'SELECT count(*) FROM "__EFMigrationsHistory"').strip()==b'6'
            devices=','.join("'"+x['device'].identity+"'" for x in (a,b));users=','.join("'"+x+"'" for x in user_ids)
            tables=[('users',f'id IN ({users})'),('devices',f'id IN ({devices})'),('sessions',f'device_id IN ({devices})'),('conversations',f"id='{group}'"),('members',f"conversation_id='{group}'"),('chat_requests',f'sender_device IN ({devices})'),('key_packages',f'device_id IN ({devices})'),('conversation_bootstraps',f"conversation_id='{group}'"),('messages',f"conversation_id='{group}'"),('outbox',f"message_id IN (SELECT id FROM messages WHERE conversation_id='{group}')"),('cursors',f"conversation_id='{group}'")]
            assert pg('securemesh',f'SELECT count(*) FROM sessions WHERE device_id IN ({devices}) AND device_bound_refresh').strip()==b'0'
            for table,where in tables:
                columns=pg(target,"SELECT string_agg(quote_ident(column_name),',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='"+table+"'").decode().strip()
                raw=pg('securemesh',f'COPY (SELECT {columns} FROM {table} WHERE {where}) TO STDOUT (FORMAT binary)')
                result=subprocess.run(['docker','compose','exec','-T','db','psql','-U','securemesh','-d',target,'-v','ON_ERROR_STOP=1','-c',f'COPY {table} ({columns}) FROM STDIN (FORMAT binary)'],cwd=d.ROOT,input=raw,capture_output=True)
                assert result.returncode==0,'Owned legacy fixture copy failed'
            server.stop();server.env['ConnectionStrings__Database']=connection;server.start()
            assert pg(target,'SELECT count(*) FROM "__EFMigrationsHistory"').strip()==b'7'
            assert d.request('/v1/users/me',token=a['session']['accessToken'])['userId']==user_ids[0]
            a['device'].call('profile_put',profile={**a['session'],'endpoint':d.BASE,'userId':user_ids[0],'username':a['username']})
            request=a['device'].call('refresh_prepare',endpoint=d.BASE)['request']
            rotated=d.request('/v1/auth/refresh/device',request)
            assert rotated['refreshBinding']=='device-signature-v1'
            backup=root/'backup.dump'
            with backup.open('wb') as output:subprocess.run(['docker','compose','exec','-T','db','pg_dump','-U','securemesh','-d',target,'-Fc'],cwd=d.ROOT,stdout=output,check=True)
            restored=target+'_restored'
            subprocess.run(['docker','compose','exec','-T','db','createdb','-U','securemesh',restored],cwd=d.ROOT,check=True);databases.append(restored)
            with backup.open('rb') as source:subprocess.run(['docker','compose','exec','-T','db','pg_restore','-U','securemesh','-d',restored,'--no-owner','--exit-on-error'],cwd=d.ROOT,stdin=source,check=True)
            restored_state=root/'restored-state';shutil.copytree(state/'refresh-keys',restored_state/'refresh-keys')
            server.stop();server.env['ConnectionStrings__Database']=connection.replace('Database='+target+';','Database='+restored+';');server.env['StateDirectory']=str(restored_state);server.start()
            replay=d.request('/v1/auth/refresh/device',request)
            assert replay['accessToken']==rotated['accessToken'] and replay['refreshToken']==rotated['refreshToken']
            a['device'].call('refresh_complete',response=replay)
            assert a['device'].call('outbox')['messages']==[message]
            d.sync(b['device'],b['session']['accessToken'],group)
            events=b['device'].call('history',group=group)['events']
            assert len(events)==1 and events[0]['text']=='Legacy schema survives refresh upgrade and restore'
            assert pg(restored,'SELECT count(*) FROM refresh_rotations').strip()==b'1'
            print('PASS: real EF previous six-migration schema populated with owned legacy users/device keys/sessions, consented DM/bootstrap, ciphertext and outbox; additive migration seven preserves auth and MLS; actual pg_dump/isolated pg_restore plus separate refresh-key directory restore recovers exact signed refresh response and original recipient decrypts once. Media/full-system restore not covered.')
    finally:
        for name in reversed(databases):subprocess.run(['docker','compose','exec','-T','db','dropdb','-U','securemesh',name],cwd=d.ROOT,check=True)

if __name__=='__main__':main()
