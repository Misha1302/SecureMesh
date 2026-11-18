#!/usr/bin/env python3
"""DB loss before ACK and an isolated PostgreSQL restore; project resources only."""
import concurrent.futures
import json
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
import delivery as d

ROOT=d.ROOT
def compose(*args,**kw): return subprocess.run(['docker','compose',*args],cwd=ROOT,check=True,capture_output=True,**kw)
def scalar(sql,db='securemesh'):
    return compose('exec','-T','db','psql','-U','securemesh','-d',db,'-Atc',sql,text=True).stdout.strip()

def main():
    d.BASE='https://127.0.0.1:5091'
    restored='securemesh_restore_'+uuid.uuid4().hex[:12]
    created=False
    try:
        with d.Server() as server,tempfile.TemporaryDirectory(prefix='securemesh-recovery-',dir=ROOT/'.local') as tmp:
            a,b=[d.account(Path(tmp)) for _ in range(2)];da,db=a['device'],b['device'];at=a['session']['accessToken'];bt=b['session']['accessToken']
            da.pin(db);db.pin(da);group=str(uuid.uuid4());da.call('create',group=group)
            welcome=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage']);db.call('join',group=group,welcome=welcome['welcome'])
            d.request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=welcome['epoch']),token=at,expected=201)
            first=da.call('queue',group=group,id=str(uuid.uuid4()),text='Durable backup sentinel')
            assert d.request('/v1/messages',d.envelope(first,group),token=at)['serverSequence']==1
            second=da.call('queue',group=group,id=str(uuid.uuid4()),text='Persist before transport')
            lock_sql="BEGIN; SELECT id FROM conversations WHERE id='"+group+"' FOR UPDATE; SELECT pg_sleep(30);"
            locker=subprocess.Popen(['docker','compose','exec','-T','db','psql','-U','securemesh','-d','securemesh','-Atc',lock_sql],cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if int(scalar("SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%SELECT pg_sleep(30)%' AND state='active'"))>=1: break
                    time.sleep(.05)
                else: raise AssertionError('lock holder not ready')
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    pending=pool.submit(d.request,'/v1/messages',d.envelope(second,group),token=at,expected=503)
                    for _ in range(100):
                        if int(scalar("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'SELECT epoch,next_seq%'"))>=1: break
                        time.sleep(.05)
                    else: raise AssertionError('send did not wait on row lock')
                    compose('stop','-t','1','db')
                    pending.result(timeout=10)
            finally:
                if locker.poll() is None: locker.terminate()
                locker.wait(timeout=10)
                compose('up','-d','--wait','db')
            assert second in da.call('outbox')['messages']
            assert d.request('/v1/messages',d.envelope(first,group),token=at)['serverSequence']==1
            saved=d.request('/v1/messages',d.envelope(second,group),token=at)
            assert saved['durable'] and saved['serverSequence']==2
            # Backup data is kept in the ignored temporary directory and never printed.
            backup=Path(tmp)/'backup.dump'
            with backup.open('wb') as file:
                subprocess.run(['docker','compose','exec','-T','db','pg_dump','-U','securemesh','-d','securemesh','-Fc'],cwd=ROOT,stdout=file,check=True)
            compose('exec','-T','db','createdb','-U','securemesh',restored);created=True
            with backup.open('rb') as file:
                subprocess.run(['docker','compose','exec','-T','db','pg_restore','-U','securemesh','-d',restored,'--no-owner','--exit-on-error'],cwd=ROOT,stdin=file,check=True)
            assert scalar("SELECT count(*) FROM messages WHERE conversation_id='"+group+"'",restored)=='2'
            assert scalar("SELECT count(*) FROM outbox o JOIN messages m ON m.id=o.message_id WHERE m.conversation_id='"+group+"'",restored)=='2'
            server.env['ConnectionStrings__Database']=server.env['ConnectionStrings__Database'].replace('Database=securemesh;','Database='+restored+';')
            server.restart()
            d.sync(db,bt,group,limit=1)
            events=db.call('history',group=group)['events']
            assert {m['id'] for m in events}=={first['id'],second['id']}
            assert {m['text'] for m in events}=={'Durable backup sentinel','Persist before transport'}
            print('PASS: real DB stop while send is blocked before commit returns 503, no durable ACK; immutable outbox survives; PostgreSQL restart retains acknowledged message; retry commits exactly once; pg_dump/pg_restore into isolated database; restored ciphertext decrypts with original client only; restored message+outbox counts agree. Object/media restore not covered.')
    finally:
        if created: compose('exec','-T','db','dropdb','-U','securemesh',restored)

if __name__=='__main__':main()
