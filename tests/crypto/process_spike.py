#!/usr/bin/env python3
"""Real OpenMLS + SQLCipher. Each call is a fresh OS process and DB connection."""
import base64
import json
import secrets
import subprocess
import tempfile
import uuid
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / 'src/crypto_core/target/debug/securemesh-crypto'

class Device:
    def __init__(self, root, identity=None):
        self.path = root / (str(uuid.uuid4())+'.db')
        self.password = secrets.token_urlsafe(32)
        self.identity = identity or str(uuid.uuid4())
        self.public = self.call('init', identity=self.identity)['public_key']

    def call(self, op, reject=False, **args):
        request = dict(op=op, passphrase=self.password, **args)
        p = subprocess.run([str(BIN), str(self.path)], input=json.dumps(request), text=True, capture_output=True)
        if reject:
            assert p.returncode != 0, f'{op} unexpectedly accepted'
            return None
        assert p.returncode == 0, f'{op}: {p.stderr}'
        return json.loads(p.stdout)

    def pin(self, other):
        self.call('pin', identity=other.identity, public_key=other.public, confirmed=True)

class PersistentDevice(Device):
    @classmethod
    def wrap(cls,device):
        self=cls.__new__(cls)
        self.__dict__.update(device.__dict__)
        self.lock=threading.Lock()
        self.process=subprocess.Popen([str(BIN),'--serve',str(self.path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.process.stdin.write(json.dumps(dict(passphrase=self.password))+'\n'); self.process.stdin.flush()
        assert json.loads(self.process.stdout.readline())['unlocked']
        return self

    def call(self,op,reject=False,**args):
        with self.lock:
            self.process.stdin.write(json.dumps(dict(op=op,**args))+'\n'); self.process.stdin.flush()
            raw=self.process.stdout.readline()
            assert raw,'client process stopped'
            result=json.loads(raw)
            if reject: assert 'error' in result; return None
            assert 'error' not in result,f'{op} rejected'
            return result

    def close(self):
        self.process.stdin.close(); self.process.wait(timeout=10)

def main():
    with tempfile.TemporaryDirectory(prefix='securemesh-crypto-', dir=ROOT/'.local') as tmp:
        root=Path(tmp)
        a,b,c,attacker=[Device(root) for _ in range(4)]
        assert len({a.public,b.public,c.public,attacker.public})==4
        for x in (a,b,c):
            for y in (a,b,c): x.pin(y)
        group=str(uuid.uuid4())
        a.call('create',group=group)
        welcome=a.call('add',group=group,keypackage=b.call('keypackage')['keypackage'])
        b.call('join',group=group,welcome=welcome['welcome'])
        msg=a.call('queue',group=group,id=str(uuid.uuid4()),text='Привет 🛰️ — private test sentinel')
        assert b.call('process',group=group,ciphertext=msg['ciphertext'])['text']=='Привет 🛰️ — private test sentinel'
        b.call('process',reject=True,group=group,ciphertext=msg['ciphertext'])
        assert a.call('outbox')['messages']==[msg]
        assert a.call('queue',group=group,id=msg['id'],text='retry must keep immutable ciphertext')==msg
        welcome=a.call('add',group=group,keypackage=c.call('keypackage')['keypackage'])
        b.call('process',group=group,ciphertext=welcome['commit'])
        c.call('join',group=group,welcome=welcome['welcome'])
        msg=b.call('queue',group=group,id=str(uuid.uuid4()),text='three members')
        assert a.call('process',group=group,ciphertext=msg['ciphertext'])['text']=='three members'
        assert c.call('process',group=group,ciphertext=msg['ciphertext'])['text']=='three members'
        removal=a.call('remove',group=group,identity=c.identity)
        b.call('process',group=group,ciphertext=removal['commit'])
        c.call('process',group=group,ciphertext=removal['commit'])
        msg=a.call('queue',group=group,id=str(uuid.uuid4()),text='after revocation')
        b.call('process',group=group,ciphertext=msg['ciphertext'])
        c.call('process',reject=True,group=group,ciphertext=msg['ciphertext'])
        a.call('add',reject=True,group=group,keypackage=attacker.call('keypackage')['keypackage'])
        a.call('pin',reject=True,identity=b.identity,public_key=attacker.public,confirmed=True)
        # Wrong passphrase must not silently create a new state or expose plaintext.
        password=b.password
        b.password=secrets.token_urlsafe(32)
        b.call('history',reject=True,group=group)
        b.password=password
        assert len(b.call('history',group=group)['events'])==2
        # Process dies after encrypt/SQL writes, before transaction commit: ratchet + outbox rollback together.
        crash_id=str(uuid.uuid4())
        a.call('queue',reject=True,group=group,id=crash_id,text='crash consistency',crash_before_commit=True)
        assert all(x['id']!=crash_id for x in a.call('outbox')['messages'])
        retry=a.call('queue',group=group,id=crash_id,text='crash consistency')
        assert b.call('process',group=group,ciphertext=retry['ciphertext'])['text']=='crash consistency'
        for d in (a,b,c):
            assert not d.path.read_bytes().startswith(b'SQLite format')
            assert b'private test sentinel' not in d.path.read_bytes()
        print('PASS: independent keys; Welcome; two-process Unicode message; add/remove/rekey; revoked member denied; replay rejected; pinned key substitution rejected; SQLCipher wrong key denied; durable immutable outbox; process abort rollback; restart decrypt.')

if __name__=='__main__': main()
