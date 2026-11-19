#!/usr/bin/env python3
"""Actual existing-profile password repair in the Linux GTK application."""
import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path
from native_v2 import NativeGui, ROOT, d
sys.path.insert(0, str(ROOT/'tests/integration'))
from directory import establish
from native_session import sql

class ReauthenticationGui(NativeGui):
    def execute(self, command):
        if command.get('prepare_profile'):
            account=d.account(self.root); self.device=account['device']; self.peer=d.account(self.root)
            self.device.pin(self.peer['device']); self.peer['device'].pin(self.device)
            self.group=establish(account,self.peer)
            self.original=self.device.call('identity')
            self.values.update(username=account['username'],password=account['password'],localpass=self.device.password,wrongpassword='incorrect_account_password')
            me=d.request('/v1/users/me',token=account['session']['accessToken'])
            self.profile={**account['session'],'endpoint':self.values['endpoint'],'username':account['username'],'userId':me['userId'],'group':self.group,'peerDevice':self.peer['device'].identity,'peerName':self.peer['username'],'peerKey':self.peer['device'].public,'trustConfirmed':True,'requiresEnrollment':False,'enrollmentVerified':True}
            self.device.call('profile_put',profile=self.profile)
            self.queued=self.device.call('queue',group=self.group,id=str(uuid.uuid4()),text=self.values['queued'])
            sql(f"UPDATE sessions SET revoked=true WHERE device_id='{self.device.identity}'")
            self.log_segments=[(self.root/'app.log').read_text(errors='replace')]
            subprocess.run(['docker','kill',self.name],check=True,stdout=subprocess.DEVNULL)
            for _ in range(50):
                if subprocess.run(['docker','container','inspect',self.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0:break
                time.sleep(.1)
            launch=self.command.copy();index=launch.index('securemesh-linux-builder:local');launch[index:index]=['-e',f'SECUREMESH_PROFILE={self.device.path}']
            subprocess.run(launch,check=True,stdout=subprocess.DEVNULL)
            self.window=None
            for _ in range(100):
                found=self.run('xdotool','search','--onlyvisible','--name','^securemesh_client$',check=False).stdout.strip()
                if found:self.window=found.splitlines()[0];break
                time.sleep(.2)
            assert self.window
            self.run('xdotool','windowfocus','--sync',self.window)
            print('Prepared same-key profile with real consented DM, immutable queued ciphertext and revoked sessions; owned GUI restarted.',flush=True)
        super().execute({k:v for k,v in command.items() if k!='capture'})
        if command.get('verify_preserved'):
            assert self.device.call('identity')==self.original
            assert self.device.call('outbox')['messages']==[self.queued]
            assert self.device.call('profile')['accessToken']==self.profile['accessToken']
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{self.device.identity}'")=='1'
            print('PASS: failed real GUI password login preserved identity, original profile and exact ciphertext; no additional session.',flush=True)
        if command.get('verify_signed_in'):
            deadline=time.monotonic()+35
            while self.device.call('outbox')['messages']:
                if time.monotonic()>deadline:
                    self.capture('.impeccable/review/v2-reauth-delivery-fail.png')
                    raise TimeoutError('GUI reauthentication did not resume queued delivery')
                time.sleep(.5)
            current=self.device.call('profile')
            assert current['refreshBinding']=='device-signature-v1'
            assert current['deviceId']==self.device.identity and current['username']==self.values['username']
            assert self.device.call('identity')==self.original
            assert sql(f"SELECT count(*) FROM devices WHERE user_id='{current['userId']}'")=='1'
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{self.device.identity}'")=='2'
            d.sync(self.peer['device'],self.peer['session']['accessToken'],self.group)
            events=self.peer['device'].call('history',group=self.group)['events']
            assert len(events)==1 and events[0]['id']==self.queued['id'] and events[0]['text']==self.values['queued']
            page=d.request('/v1/sync?conversationId='+self.group,token=self.peer['session']['accessToken'])
            assert len(page['messages'])==1 and page['messages'][0]['ciphertext']==self.queued['ciphertext']
            logs='\n'.join(self.log_segments+[(self.root/'app.log').read_text(errors='replace'),(ROOT/'.local/api-5098.log').read_text(errors='replace')])
            for secret in [self.values['password'],self.values['wrongpassword'],self.device.password,current['accessToken'],current['refreshToken'],self.profile['accessToken']]:
                assert secret not in logs
            print('PASS: actual GTK password repair uses same device and MLS keys; exactly one new bound session; original ciphertext delivered/decrypted once; log secrets absent.',flush=True)
        if 'capture' in command:self.capture(command['capture'])
        return {'completed':list(command)}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--script');args=parser.parse_args()
    with ReauthenticationGui() as gui:
        print('Reauthentication GUI ready.',flush=True)
        commands=json.loads(Path(args.script).read_text()) if args.script else (json.loads(line) for line in sys.stdin)
        for command in commands:
            if command.get('stop'):break
            print(json.dumps(gui.execute(command)),flush=True)

if __name__=='__main__':main()
