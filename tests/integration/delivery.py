#!/usr/bin/env python3
"""Live HTTPS/WSS API + PostgreSQL + separate SQLCipher/OpenMLS client processes."""
import base64
import concurrent.futures
import importlib.util
import json
import os
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/crypto'))
sys.path.insert(0,str(ROOT/'.local'))
from process_spike import Device
import wire_pb2 as wire
from google.protobuf.internal.encoder import _VarintBytes
from google.protobuf.internal.decoder import _DecodeVarint
from websockets.sync.client import connect

TLS=ssl.create_default_context(cafile=str(ROOT/'.local/tls.pem'))
BASE='https://127.0.0.1:5090'

def request(path,data=None,token=None,method=None,expected=200):
    body=None if data is None else json.dumps(data).encode()
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,data=body,headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,context=TLS,timeout=10) as r:
            status=r.status; raw=r.read()
    except urllib.error.HTTPError as e: status=e.code; raw=e.read()
    assert status==expected, f'{path}: expected {expected}, got {status}: {raw[:300]!r}'
    return json.loads(raw) if raw else None

def login(username,password,device,expected=200):
    challenge=request('/v1/auth/challenge',dict(username=username,deviceId=device.identity))
    proof=device.call('sign',payload=challenge['payload'])['signature']
    return request('/v1/auth/login',dict(username=username,password=password,deviceId=device.identity,publicKey=device.public,challengeId=challenge['challengeId'],signature=proof),expected=expected)

def account(root):
    username='u_'+uuid.uuid4().hex[:20]; email=username+'@securemesh.test'; password=secrets.token_urlsafe(24)
    device=Device(root)
    request('/v1/auth/register',dict(username=username,email=email,password=password),expected=202)
    search='http://127.0.0.1:58028/api/v1/search?query='+urllib.parse.quote('to:'+email)
    with urllib.request.urlopen(search) as r: messages=json.load(r)['messages']
    assert len(messages)==1
    with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/message/'+messages[0]['ID']) as r: email_body=json.load(r)
    verification=email_body['Text'].strip()
    login(username,password,device,expected=401)
    request('/v1/auth/verify-email',dict(token=verification),expected=204)
    request('/v1/auth/verify-email',dict(token=verification),expected=400)
    session=login(username,password,device)
    return dict(username=username,password=password,device=device,session=session)

def envelope(message,group):
    return dict(conversationId=group,clientMessageId=message['id'],mlsEpoch=message['epoch'],envelopeKind=message['kind'],ciphertext=message['ciphertext'])

class Stream:
    def __init__(self,token,device):
        self.ws=connect(BASE.replace('https:','wss:')+'/v1/stream',ssl=TLS,additional_headers={'Authorization':'Bearer '+token},open_timeout=10,max_size=131077)
        f=wire.Frame(protocol_version=1,kind=wire.HELLO)
        f.hello.supported_versions.append(1); f.hello.client_device_id=uuid.UUID(device.identity).bytes
        assert self.exchange(f).kind==wire.HELLO
    def exchange(self,f):
        f.request_id=uuid.uuid4().bytes
        raw=f.SerializeToString(); self.ws.send(_VarintBytes(len(raw))+raw)
        raw=self.ws.recv(timeout=10); length,offset=_DecodeVarint(raw,0)
        assert len(raw)-offset==length
        result=wire.Frame.FromString(raw[offset:]); assert result.request_id==f.request_id
        return result
    def send(self,message,group):
        f=wire.Frame(protocol_version=1,kind=wire.SEND_ENCRYPTED)
        e=f.encrypted; e.conversation_id=uuid.UUID(group).bytes; e.client_message_id=uuid.UUID(message['id']).bytes
        e.mls_epoch=message['epoch']; e.envelope_kind=message['kind']; e.opaque_ciphertext=base64.b64decode(message['ciphertext'])
        return self.exchange(f)
    def close(self): self.ws.close()

def sync(device,token,group,limit=100):
    cursor=device.call('cursor',group=group)['cursor']
    while True:
        path='/v1/sync?'+urllib.parse.urlencode(dict(conversationId=group,cursor=cursor,limit=limit))
        page=request(path,token=token)
        for index,m in enumerate(page['messages']):
            device.call('ingest',group=group,id=m['clientMessageId'],sender=m['senderDeviceId'],seq=m['serverSequence'],epoch=m['mlsEpoch'],kind=m['envelopeKind'],ciphertext=m['ciphertext'],digest=m['ciphertextSha256'],cursor=page['nextCursor'] if index==len(page['messages'])-1 else '')
        cursor=page['nextCursor']
        if not page['hasMore']: break
    sequence=device.call('cursor',group=group)['seq']
    request('/v1/acks',dict(conversationId=group,sequence=sequence),token=token,expected=204)

class Server:
    def __enter__(self):
        password=dict(line.split('=',1) for line in (ROOT/'.env').read_text().splitlines())['SECUREMESH_DB_PASSWORD']
        self.env=dict(os.environ,ASPNETCORE_ENVIRONMENT='Development',ConnectionStrings__Database=f'Host=127.0.0.1;Port=55438;Database=securemesh;Username=securemesh;Password={password}',Kestrel__Certificates__Default__Path=str(ROOT/'.local/tls.pem'),Kestrel__Certificates__Default__KeyPath=str(ROOT/'.local/tls.key'))
        self.log=(ROOT/'.local/api-delivery.log').open('w')
        self.start()
        return self
    def start(self):
        self.p=subprocess.Popen(['dotnet','src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll','--urls',os.environ.get('SECUREMESH_TEST_URLS',BASE)],cwd=ROOT,env=self.env,stdout=self.log,stderr=self.log)
        for _ in range(150):
            if self.p.poll() is not None: raise RuntimeError('API died; inspect .local/api-delivery.log')
            try: request('/health/ready'); break
            except OSError: time.sleep(.1)
        else: raise RuntimeError('API readiness timeout')
    def stop(self): self.p.terminate(); self.p.wait(timeout=10)
    def restart(self): self.stop(); self.start()
    def __exit__(self,*_):
        self.stop(); self.log.close()

def main():
    with Server() as server, tempfile.TemporaryDirectory(prefix='securemesh-delivery-',dir=ROOT/'.local') as tmp:
        root=Path(tmp); a,b,outsider=[account(root) for _ in range(3)]
        da,db=a['device'],b['device']; at=a['session']['accessToken']; bt=b['session']['accessToken']; ot=outsider['session']['accessToken']
        da.pin(db); db.pin(da)
        login(a['username'],'incorrect password',da,expected=401)
        replacement=Device(root)
        login(a['username'],a['password'],replacement,expected=403)
        rotated=request('/v1/auth/refresh',dict(token=a['session']['refreshToken']))
        request('/v1/users/me',token=at,expected=401)
        request('/v1/auth/refresh',dict(token=a['session']['refreshToken']),expected=401)
        request('/v1/users/me',token=rotated['accessToken'],expected=401)
        at=login(a['username'],a['password'],da)['accessToken']
        group=str(uuid.uuid4()); da.call('create',group=group)
        joined=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage'])
        db.call('join',group=group,welcome=joined['welcome'])
        request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=joined['epoch']),token=at,expected=201)
        first=da.call('queue',group=group,id=str(uuid.uuid4()),text='Только устройства читают это 🛰️')
        # Network was unavailable when queued; this fresh process sees the committed immutable outbox.
        assert first in da.call('outbox')['messages']
        stream=Stream(at,da); saved=stream.send(first,group)
        assert saved.kind==wire.DURABLE_ACK and saved.durable_ack.server_sequence==1
        stream.close() # Simulate ACK lost before sender local save.
        retry=request('/v1/messages',envelope(first,group),token=at)
        assert retry['alreadyCommitted'] and retry['serverSequence']==1 and retry['durable']
        bad=envelope(first,group); bad['ciphertext']=base64.b64encode(b'changed ciphertext').decode()
        request('/v1/messages',bad,token=at,expected=409)
        bad=envelope(first,group); bad['mlsEpoch']+=1
        request('/v1/messages',bad,token=at,expected=409)
        request('/v1/sync?conversationId='+group,token=ot,expected=403)
        request('/v1/messages',envelope(first,group),token=ot,expected=403)
        request('/v1/devices/'+da.identity,token=bt,method='DELETE',expected=404)
        page=request('/v1/sync?conversationId='+group,token=bt)
        m=page['messages'][0]
        ingest=dict(group=group,id=m['clientMessageId'],sender=m['senderDeviceId'],seq=m['serverSequence'],epoch=m['mlsEpoch'],kind=m['envelopeKind'],ciphertext=m['ciphertext'],cursor=page['nextCursor'])
        db.call('ingest',reject=True,**ingest,crash_before_commit=True)
        assert db.call('cursor',group=group)['seq']==0
        db.call('ingest',**ingest)
        assert db.call('ingest',**ingest)['duplicate']
        assert len(db.call('history',group=group)['events'])==1
        request('/v1/sync?'+urllib.parse.urlencode(dict(conversationId=group,cursor=page['nextCursor'])),token=at,expected=400)
        request('/v1/sync?'+urllib.parse.urlencode(dict(conversationId=group,cursor=page['nextCursor']+'tampered')),token=bt,expected=400)
        server.restart() # Durable data and cursor signing keys survive API restart.
        retry=request('/v1/messages',envelope(first,group),token=at)
        assert retry['alreadyCommitted'] and retry['serverSequence']==1
        reply=db.call('queue',group=group,id=str(uuid.uuid4()),text='Ответ после перезапуска')
        request('/v1/messages',envelope(reply,group),token=bt) # HTTPS fallback after WSS closed.
        sync(da,at,group,limit=1); sync(db,bt,group,limit=1)
        assert da.call('cursor',group=group)['seq']==db.call('cursor',group=group)['seq']==2
        assert len(da.call('history',group=group)['events'])==len(db.call('history',group=group)['events'])==1
        # Concurrent identical writes serialize to the same durable record, including its outbox event.
        third=da.call('queue',group=group,id=str(uuid.uuid4()),text='concurrent retries')
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results=list(pool.map(lambda _:request('/v1/messages',envelope(third,group),token=at),range(6)))
        assert {r['serverSequence'] for r in results}=={3}
        assert len({r['serverMessageId'] for r in results})==1
        sync(db,bt,group); assert len(db.call('history',group=group)['events'])==2
        stream=Stream(bt,db)
        request('/v1/devices/'+db.identity,token=bt,method='DELETE',expected=204)
        result=stream.exchange(wire.Frame(protocol_version=1,kind=wire.PING))
        assert result.kind==wire.SERVER_ERROR and result.server_error.code==401
        stream.close()
        logs=(ROOT/'.local/api-delivery.log').read_text()
        for secret in [a['password'],at,bt,first['ciphertext'],'Только устройства читают это']:
            assert secret not in logs
        sql="SELECT count(*),count(DISTINCT seq),(SELECT count(*) FROM outbox o JOIN messages m ON m.id=o.message_id WHERE m.conversation_id='"+group+"') FROM messages WHERE conversation_id='"+group+"'"
        check=subprocess.run(['docker','compose','exec','-T','db','psql','-U','securemesh','-d','securemesh','-Atc',sql],cwd=ROOT,text=True,capture_output=True,check=True)
        assert check.stdout.strip()=='3|3|3',check.stdout
        print('PASS: verified email + one-use token; Argon2 login; independent Ed25519 device proof; untrusted device denied; refresh rotation/reuse; real MLS HTTPS/WSS exchange; persistent offline queue; lost ACK/idempotent concurrent retries; digest/epoch conflict; encrypted receiver crash recovery; paginated scoped cursors; API restart; device revocation on active WSS; membership/IDOR denial; log secret checks; atomic message/outbox counts.')

if __name__=='__main__': main()
