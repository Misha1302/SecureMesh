#!/usr/bin/env python3
"""Measured TLS/OpenMLS traffic over actual Linux netem in project-only containers."""
import argparse
import hashlib
import asyncio
import base64
import json
import math
import os
import random
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/integration'))
from delivery import Device,Server,account,request,wire,TLS,_VarintBytes,_DecodeVarint
from process_spike import PersistentDevice
from websockets.asyncio.client import connect

COMPOSE=['docker','compose','-f','docker-compose.yml','-f','compose.chaos.yml']
def docker(*args): return subprocess.run(COMPOSE+list(args),cwd=ROOT,text=True,capture_output=True,check=True).stdout

def percentile(values,p): return sorted(values)[max(0,math.ceil(len(values)*p)-1)]

class Duplex:
    async def start(self,port,device,token):
        self.device=device; self.token=token; self.port=port
        self.ws=await connect(f'wss://127.0.0.1:{port}/v1/stream',ssl=TLS,additional_headers={'Authorization':'Bearer '+token},open_timeout=30,max_size=131077,ping_interval=None)
        self.pending={}; self.reader=asyncio.create_task(self.read()); self.app_bytes=0
        hello=wire.Frame(protocol_version=1,kind=wire.HELLO)
        hello.hello.supported_versions.append(1); hello.hello.client_device_id=uuid.UUID(device.identity).bytes
        await self.exchange(hello)
        return self
    async def read(self):
        try:
            async for raw in self.ws:
                length,offset=_DecodeVarint(raw,0); assert length==len(raw)-offset
                f=wire.Frame.FromString(raw[offset:]); future=self.pending.pop(f.request_id,None)
                if future and not future.done(): future.set_result(f)
        finally:
            for future in self.pending.values():
                if not future.done(): future.set_exception(ConnectionError('stream disconnected'))
    async def exchange(self,f):
        f.request_id=uuid.uuid4().bytes
        key=f.request_id; future=asyncio.get_running_loop().create_future(); self.pending[key]=future
        raw=f.SerializeToString(); self.app_bytes+=len(raw)
        try:
            await self.ws.send(_VarintBytes(len(raw))+raw)
            result=await asyncio.wait_for(future,60)
            if result.kind==wire.SERVER_ERROR: raise RuntimeError(result.server_error.stable_code)
            return result
        finally: self.pending.pop(key,None)
    async def close(self):
        await self.ws.close(); await self.reader

async def trial(a,b,group,profile,seed,count):
    da,db=a['device'],b['device']
    x=await Duplex().start(55990,da,a['session']['accessToken'])
    y=await Duplex().start(55991,db,b['session']['accessToken'])
    rate,rtt,loss=(20,1500,3) if profile=='gprs' else (10,3000,10)
    setup={}
    for index,name in enumerate(['netem-a','netem-b']):
        setup[name]=await asyncio.to_thread(docker,'exec','-T',name,'sh','/netem/configure.sh',str(rate),str(rtt),str(loss),str(seed+index*100))
    for c in (x,y): await c.exchange(wire.Frame(protocol_version=1,kind=wire.PING))
    sent={}; received={}; acked={}; sizes=[]; completed=asyncio.Event(); receipts=[]
    interval=1.0 if profile=='gprs' else 1.5
    origin=time.monotonic()
    async def call(d,op,**kw): return await asyncio.to_thread(d.call,op,**kw)
    async def send(c,random_seed):
        rng=random.Random(random_seed)
        window=asyncio.Semaphore(3); pending=[]
        async def dispatch(m,mid):
            try:
                f=wire.Frame(protocol_version=1,kind=wire.SEND_ENCRYPTED)
                e=f.encrypted; e.conversation_id=uuid.UUID(group).bytes; e.client_message_id=uuid.UUID(mid).bytes; e.mls_epoch=m['epoch']; e.envelope_kind=1; e.opaque_ciphertext=base64.b64decode(m['ciphertext'])
                sizes.append(len(f.SerializeToString()))
                result=await c.exchange(f)
                assert result.kind==wire.DURABLE_ACK
                acked[mid]=time.monotonic()
                await call(c.device,'saved',group=group,id=mid,seq=result.durable_ack.server_sequence)
            finally: window.release()
        for i in range(count):
            await asyncio.sleep(max(0,origin+i*interval-time.monotonic()))
            await window.acquire()
            mid=str(uuid.uuid4()); text=''.join(rng.choice('abcПривет🌍') for _ in range(rng.randint(1,400)))
            started=time.monotonic()
            m=await call(c.device,'queue',group=group,id=mid,text=text)
            sent[mid]=dict(id=mid,sender=c.device.identity,start=started,utf8_bytes=len(text.encode()),characters=len(text))
            pending.append(asyncio.create_task(dispatch(m,mid)))
        await asyncio.gather(*pending)
    async def receive(c):
        cursor=b''
        while not completed.is_set():
            f=wire.Frame(protocol_version=1,kind=wire.SYNC_REQUEST)
            f.sync_request.conversation_id=uuid.UUID(group).bytes; f.sync_request.opaque_cursor=cursor; f.sync_request.limit=6
            result=await c.exchange(f); assert result.kind==wire.SYNC_RESPONSE
            page=result.sync_response
            for i,m in enumerate(page.messages):
                mid=str(uuid.UUID(bytes=m.client_message_id)); sender=str(uuid.UUID(bytes=m.sender_device_id))
                await call(c.device,'ingest',group=group,id=mid,sender=sender,seq=m.server_sequence,epoch=m.mls_epoch,kind=m.envelope_kind,ciphertext=base64.b64encode(m.opaque_ciphertext).decode(),digest=base64.b64encode(m.ciphertext_sha256).decode(),cursor=page.next_cursor.decode() if i==len(page.messages)-1 else '')
                if sender!=c.device.identity:
                    assert mid not in received,'logical duplicate'
                    received[mid]=time.monotonic()
            cursor=page.next_cursor
            if page.messages:
                ack=wire.Frame(protocol_version=1,kind=wire.PROCESSED_ACK)
                ack.processed_ack.conversation_id=uuid.UUID(group).bytes
                ack.processed_ack.highest_contiguous_persisted_sequence=page.messages[-1].server_sequence
                receipts.append(asyncio.create_task(c.exchange(ack)))
            if len(received)==count*2 and len(acked)==count*2: completed.set()
            if not page.has_more: await asyncio.sleep(.25)
    receivers=[asyncio.create_task(receive(c)) for c in (x,y)]
    try:
        await asyncio.gather(send(x,seed),send(y,seed+1))
        # Severe profile deliberately has no performance threshold; an operational watchdog reports FAIL, never PASS.
        deadline=time.monotonic()+1200
        while not completed.is_set():
            for task in receivers:
                if task.done(): task.result()
            if time.monotonic()>deadline: raise TimeoutError('eventual delivery watchdog expired')
            await asyncio.sleep(.1)
        for task in receivers: task.cancel()
        await asyncio.gather(*receivers,return_exceptions=True)
        await asyncio.gather(*receipts)
        assert set(sent)==set(received)==set(acked)
        for device in (da,db):
            history=await call(device,'history',group=group)
            assert len(history['events'])==count
            assert len({e['id'] for e in history['events']})==count
        records=[dict(**v,ack_seconds=acked[k]-v['start'],delivery_seconds=received[k]-v['start']) for k,v in sent.items()]
        delays=[r['delivery_seconds'] for r in records]
        result=dict(profile=profile,seed=seed,messages_each_direction=count,rate_kbps_each_direction=rate,rtt_ms=rtt,packet_loss_percent=loss,elapsed_seconds=time.monotonic()-origin,
                    delivery_p50=percentile(delays,.5),delivery_p95=percentile(delays,.95),delivery_p99=percentile(delays,.99),
                    application_frame_bytes_p50=percentile(sizes,.5),application_frame_bytes_p95=percentile(sizes,.95),
                    duplicates=0,losses=0,setup=setup,records=records)
        for name in ('netem-a','netem-b'): result[name+'_tc_stats']=await asyncio.to_thread(docker,'exec','-T',name,'tc','-s','qdisc','show','dev','eth0')
        return result
    finally:
        completed.set()
        for t in receivers: t.cancel()
        await asyncio.gather(*receivers,return_exceptions=True)
        await asyncio.gather(x.close(),y.close())

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--profile',choices=['gprs','severe'],required=True); parser.add_argument('--seeds',default='7,19,41'); parser.add_argument('--count',type=int,default=200)
    args=parser.parse_args()
    os.environ['SECUREMESH_TEST_URLS']='https://127.0.0.1:5090;https://10.239.238.1:5090'
    docker('up','-d','netem-a','netem-b')
    output=ROOT/'reports/evidence'
    try:
        for seed in map(int,args.seeds.split(',')):
            with Server(), tempfile.TemporaryDirectory(prefix='securemesh-netem-',dir=ROOT/'.local') as tmp:
                # Drop prior shaping before bootstrapping fresh local test accounts.
                for index,name in enumerate(('netem-a','netem-b')): docker('exec','-T',name,'sh','/netem/configure.sh','10000','0','0',str(seed+index))
                a,b=[account(Path(tmp)) for _ in range(2)]
                a['device']=PersistentDevice.wrap(a['device']); b['device']=PersistentDevice.wrap(b['device'])
                da,db=a['device'],b['device']; da.pin(db); db.pin(da)
                group=str(uuid.uuid4()); da.call('create',group=group)
                welcome=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage']); db.call('join',group=group,welcome=welcome['welcome'])
                request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=welcome['epoch']),token=a['session']['accessToken'],expected=201)
                source_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
                binaries={str(path.relative_to(ROOT)):hashlib.file_digest(path.open('rb'),'sha256').hexdigest() for path in [ROOT/'src/crypto_core/target/debug/securemesh-crypto',ROOT/'src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll']}
                try: result=asyncio.run(trial(a,b,group,args.profile,seed,args.count))
                finally: da.close(); db.close()
                result['code_head_at_start']=source_head
                result['binary_sha256']=binaries
                path=output/f'netem-v2-{args.profile}-{seed}-{args.count}.json'; path.write_text(json.dumps(result,indent=2)+'\n')
                print(json.dumps({k:v for k,v in result.items() if k not in ('records','setup') and not k.endswith('_tc_stats')}),flush=True)
                if args.profile=='gprs': assert result['delivery_p95']<=15,'GPRS p95 objective failed; raw evidence preserved'
    finally: docker('stop','netem-a','netem-b')

if __name__=='__main__': main()
