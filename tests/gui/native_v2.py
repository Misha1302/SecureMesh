#!/usr/bin/env python3
"""Owned Xvfb/container native GUI driver. Secrets are generated in memory and typed from mode-600 files."""
import argparse
import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/integration'))
import delivery as d


class NativeGui:
    def __enter__(self):
        os.umask(0o077)
        self.temp=tempfile.TemporaryDirectory(prefix='securemesh-ui-v2-',dir=ROOT/'.local')
        self.root=Path(self.temp.name);(self.root/'profiles').mkdir()
        self.name='securemesh-ui-v2-'+uuid.uuid4().hex[:12]
        d.BASE='https://127.0.0.1:5098'
        os.environ['SECUREMESH_TEST_URLS']='https://127.0.0.1:5098;https://10.239.238.1:5098'
        self.server=d.Server(legacy_bootstrap=False).__enter__()
        username='gui_'+uuid.uuid4().hex[:16]
        self.values=dict(badusername=username+'_x',invalidcontact='x',username=username,email=username+'@securemesh.test',password=secrets.token_urlsafe(24),localpass=secrets.token_urlsafe(24),endpoint='https://127.0.0.1:5088',text='Настоящий GUI: регистрация, Welcome и шифрование',reply='Ответ второго независимого клиента',queued='Очередь GUI переживает SIGKILL без сети')
        command=['docker','run','-d','--rm','--name',self.name,'--network','securemesh_default','--security-opt','label=disable','--user',f'{os.getuid()}:{os.getgid()}','-v',f'{ROOT}:{ROOT}','-w',str(ROOT),'-e','DISPLAY=:98','-e','SECUREMESH_API_ORIGIN=https://127.0.0.1:5088','-e','GDK_BACKEND=x11','-e','LIBGL_ALWAYS_SOFTWARE=1','-e','UPSTREAM_HOST=10.239.238.1','-e',f'SECUREMESH_CRYPTO_LIB={ROOT}/src/crypto_core/target/debug/libsecuremesh_crypto.so','-e',f'SECUREMESH_CERT_FILE={ROOT}/.local/tls.pem','-e',f'SECUREMESH_PROFILE_DIRECTORY={self.root}/profiles','securemesh-linux-builder:local','bash','-c',f'ulimit -c 0; umask 077; Xvfb :98 -screen 0 1280x900x24 -nolisten tcp > {self.root}/xvfb.log 2>&1 & python3 tests/gui/forward.py & exec apps/client_flutter/build/linux/x64/debug/bundle/securemesh_client > >(python3 tests/redact_ui_log.py > {self.root}/app.log) 2>&1']
        subprocess.run(command,check=True,stdout=subprocess.DEVNULL)
        self.command=command
        self.run('bash','-c','clang tests/gui/clipboard.c -o .local/gui-clipboard $(pkg-config --cflags --libs gtk+-3.0)')
        self.window=None
        for _ in range(100):
            found=self.run('xdotool','search','--onlyvisible','--name','^securemesh_client$',check=False).stdout.strip()
            if found:self.window=found.splitlines()[0];break
            time.sleep(.2)
        if not self.window:
            self.__exit__();raise RuntimeError('Native visible window not found')
        self.run('xdotool','windowfocus','--sync',self.window)
        return self

    def run(self,*args,check=True):
        return subprocess.run(['docker','exec','-e','DISPLAY=:98',self.name,*map(str,args)],text=True,capture_output=True,check=check)

    def capture(self,path):
        target=(ROOT/path).resolve();target.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True)
        time.sleep(.4);self.run('import','-window',self.window,str(target))

    def type(self,value):
        target=self.root/'type.txt';target.write_text(value);target.chmod(0o600)
        try:
            if value.isascii():self.run('xdotool','type','--clearmodifiers','--delay','2','--file',str(target))
            else:
                process=subprocess.Popen(['docker','exec','-e','DISPLAY=:98',self.name,str(ROOT/'.local/gui-clipboard'),str(target)],stdout=subprocess.PIPE,text=True)
                assert process.stdout.readline().strip()=='ready'
                self.run('xdotool','key','--clearmodifiers','ctrl+v');assert process.wait(timeout=5)==0
        finally:target.write_text('')

    def account(self):
        paths=list((self.root/'profiles').glob('*.db'))
        matches=[]
        for path in paths:
            device=d.Device.__new__(d.Device);device.path=path;device.password=self.values['localpass']
            try:
                me=device.call('identity');profile=device.call('profile')
            except AssertionError:continue
            if profile.get('username')==self.values['username']:
                device.identity=me['identity'];device.public=me['public_key'];matches.append((device,profile))
        assert len(matches)==1,'Expected one authenticated GUI profile; rejected drafts must stay unused'
        return matches[0]

    def execute(self,command):
        if command.get('prepare_pending'):
            self.approver=d.account(self.root)
            self.values.update(username=self.approver['username'],password=self.approver['password'])
            print('Existing verified account has its own trusted device; GUI will enroll an independent candidate.',flush=True)
        if 'resize' in command:
            self.run('xdotool','windowsize',self.window,*command['resize'])
            time.sleep(.5)
            geometry=self.run('xdotool','getwindowgeometry','--shell',self.window).stdout
            actual=dict(line.split('=',1) for line in geometry.splitlines() if '=' in line)
            assert (int(actual['WIDTH']),int(actual['HEIGHT']))==tuple(command['resize']),'Native resize did not take effect'
        if 'click' in command:self.run('xdotool','mousemove','--window',self.window,*command['click'],'click','1')
        if 'key' in command:self.run('xdotool','key','--clearmodifiers',command['key'])
        if 'fill' in command:
            field=command['fill']
            if field=='verification':
                url='http://127.0.0.1:58028/api/v1/search?query='+urllib.parse.quote('to:'+self.values['email'])
                with urllib.request.urlopen(url) as r:messages=json.load(r)['messages']
                assert len(messages)==1
                with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/message/'+messages[0]['ID']) as r:value=json.load(r)['Text'].strip()
            elif field=='path':value=str(self.account()[0].path)
            else:value=self.values[field]
            self.type(value)
        if 'wait' in command:time.sleep(min(15,command['wait']))
        if command.get('verify_account'):
            self.device,self.profile=self.account()
            d.request('/v1/users/me',token=self.profile['accessToken'])
            self.peer=d.account(self.root);self.values['peer']=self.peer['username']
            print('Real GUI account and independent peer ready.',flush=True)
        if command.get('verify_pending'):
            self.device,self.profile=self.account()
            me=d.request('/v1/users/me',token=self.profile['accessToken'])
            assert me['trustState']=='DEVICE_PENDING_TRUST'
            assert self.device.identity!=self.approver['device'].identity
            d.request('/v1/conversations',token=self.profile['accessToken'],expected=403)
            assert not self.device.call('outbox')['messages']
            print('PASS: real GUI password login creates independent PENDING_TRUST device; server denies private conversations.',flush=True)
        if command.get('verify_enrollment_request'):
            _,profile=self.account()
            request=d.request('/v1/devices/enrollment/'+profile['enrollmentId'],token=profile['accessToken'])
            payload=base64.b64decode(request['payload']).decode().splitlines()
            assert payload[2]==self.device.identity and request['candidateSignature'] and not request['approved']
            print('PASS: GUI created a real signed pending enrollment request; no approval or history access implied.',flush=True)
        if command.get('accept_peer'):
            requests=d.request('/v1/chat-requests',token=self.peer['session']['accessToken'])
            request=next(r for r in requests if r['senderDevice']==self.device.identity)
            self.peer['device'].pin(self.device)
            kp=self.peer['device'].call('keypackage')['keypackage']
            d.request('/v1/crypto/keypackages',dict(payload=kp),token=self.peer['session']['accessToken'],expected=201)
            d.request(f"/v1/chat-requests/{request['id']}/accept",{},token=self.peer['session']['accessToken'],expected=204)
            print('Peer independently pinned GUI device, published real KeyPackage and accepted request.',flush=True)
        if command.get('join_peer'):
            welcome=d.request('/v1/crypto/welcomes',token=self.peer['session']['accessToken'])
            assert len(welcome)==1
            self.group=welcome[0]['group']
            self.peer['device'].call('directory_join',**welcome[0])
            d.request(f'/v1/crypto/welcomes/{self.group}/ack',{},token=self.peer['session']['accessToken'],expected=204)
            print('Peer joined MLS via signed server-routed Welcome.',flush=True)
        if command.get('verify_message'):
            d.sync(self.peer['device'],self.peer['session']['accessToken'],self.group)
            events=self.peer['device'].call('history',group=self.group)['events']
            assert len(events)==1 and events[0]['text']==self.values['text']
            message=self.peer['device'].call('queue',group=self.group,id=str(uuid.uuid4()),text=self.values['reply'])
            d.request('/v1/messages',d.envelope(message,self.group),token=self.peer['session']['accessToken'])
            print('Real GUI message decrypted by independent recipient; encrypted reply saved.',flush=True)
        if command.get('verify_reply'):
            events=self.device.call('history',group=self.group)['events']
            assert len(events)==1 and events[0]['text']==self.values['reply']
            for value in (self.values['password'],self.values['localpass'],self.values['text'],self.profile['accessToken']):
                assert value not in (self.root/'app.log').read_text(errors='replace')
                assert value not in (ROOT/'.local/api-5098.log').read_text(errors='replace')
            print('PASS: actual Flutter GUI registration/email verification/login, independent key, username consent/key comparison, routed Welcome, two-way encrypted text, local encrypted persistence and log-secret checks.',flush=True)
        if command.get('offline'):
            self.server.stop()
            print('Owned API stopped; GUI remains running offline.',flush=True)
        if command.get('crash_reopen'):
            queued=self.device.call('outbox')['messages']
            assert len(queued)==1 and queued[0]['group']==self.group,'GUI did not persist offline outbox'
            self.queued=queued[0]
            subprocess.run(['docker','kill',self.name],check=True,stdout=subprocess.DEVNULL)
            for _ in range(50):
                if subprocess.run(['docker','container','inspect',self.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0:break
                time.sleep(.1)
            self.server.start()
            launch=self.command.copy();index=launch.index('securemesh-linux-builder:local');launch[index:index]=['-e',f'SECUREMESH_PROFILE={self.device.path}']
            subprocess.run(launch,check=True,stdout=subprocess.DEVNULL)
            self.window=None
            for _ in range(100):
                found=self.run('xdotool','search','--onlyvisible','--name','^securemesh_client$',check=False).stdout.strip()
                if found:self.window=found.splitlines()[0];break
                time.sleep(.2)
            assert self.window,'Restarted native window not visible'
            self.run('xdotool','windowfocus','--sync',self.window)
            print('SIGKILL applied to owned native container after durable queue; API and GUI restarted with the same encrypted profile.',flush=True)
        if command.get('verify_recovered'):
            deadline=time.monotonic()+30
            while self.device.call('outbox')['messages']:
                if time.monotonic()>deadline:raise TimeoutError('Reopened GUI did not drain durable outbox')
                time.sleep(.5)
            d.sync(self.peer['device'],self.peer['session']['accessToken'],self.group)
            events=self.peer['device'].call('history',group=self.group)['events']
            assert len(events)==2 and len({m['id'] for m in events})==2
            assert next(m for m in events if m['id']==self.queued['id'])['text']==self.values['queued']
            page=d.request('/v1/sync?conversationId='+self.group,token=self.peer['session']['accessToken'])
            saved=[m for m in page['messages'] if m['clientMessageId']==self.queued['id']]
            assert len(saved)==1 and saved[0]['ciphertext']==self.queued['ciphertext']
            timeline=self.device.call('timeline',group=self.group)['messages']
            assert len(timeline)==3 and len({m['id'] for m in timeline})==3
            print('PASS: actual GUI offline enqueue; encrypted local COMMIT verified; native SIGKILL; reopen same store; exact immutable ciphertext delivered once; both histories and cursor persisted.',flush=True)
        if 'capture' in command:self.capture(command['capture'])
        return {'completed':list(command)}

    def __exit__(self,*_):
        subprocess.run(['docker','stop','-t','2',self.name],check=True,stdout=subprocess.DEVNULL)
        self.server.__exit__();self.temp.cleanup()


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--interactive',action='store_true');parser.add_argument('--script');args=parser.parse_args()
    with NativeGui() as gui:
        print('Owned native GUI ready.',flush=True)
        if args.script:
            for command in json.loads(Path(args.script).read_text()):print(json.dumps(gui.execute(command)),flush=True)
        else:
            for line in sys.stdin:
                command=json.loads(line)
                if command.get('stop'):break
                try:print(json.dumps(gui.execute(command)),flush=True)
                except Exception as error:print(json.dumps({'error':type(error).__name__}),flush=True)


if __name__=='__main__':main()
