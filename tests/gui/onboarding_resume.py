#!/usr/bin/env python3
"""Real GTK UI opens/resumes existing encrypted account-setup journals.

Crash boundaries of the shared production controller are tested separately in
onboarding_recovery.py; these GUI fixtures use real accepted API logins.
"""
import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

from native_v2 import NativeGui, ROOT, d


class ResumeGui(NativeGui):
    def execute(self, command):
        if not hasattr(self, 'log_segments'):
            self.log_segments, self.secret_values = [], set()
        if 'prepare_draft' in command:
            if not hasattr(self, 'approver'):
                self.approver = d.account(self.root)
            self.values.update(username=self.approver['username'], password=self.approver['password'])
            self.values['wronglocalpass'] = self.values['localpass'] + '_wrong'
            self.secret_values.update([self.values['password'], self.values['localpass'], self.values['wronglocalpass']])
            device = d.Device.__new__(d.Device)
            device.identity = str(uuid.uuid4())
            device.path = self.root / 'profiles' / (device.identity + '.db')
            device.password = self.values['localpass']
            me = device.call('init', identity=device.identity, onboarding=dict(
                endpoint=self.values['endpoint'], username=self.values['username'], registeredHere=False))
            device.public = me['public_key']
            device.call('onboarding_attempt')
            session = d.login(self.values['username'], self.values['password'], device)
            self.secret_values.update([session['accessToken'], session['refreshToken']])
            assert session['trustState'] == 'DEVICE_PENDING_TRUST'
            if command['prepare_draft'] != 'prepared':
                device.call('onboarding_session', session=session)
            if command['prepare_draft'] == 'expired':
                statement = f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{device.identity}'"
                subprocess.run(['docker','compose','exec','-T','db','psql','-U','securemesh','-d','securemesh','-v','ON_ERROR_STOP=1','-c',statement],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
            self.candidate, self.original = device, device.call('identity')
            self.expected_sessions = 1 if command['prepare_draft'] == 'authenticated' else 2
            print('Prepared real accepted login in encrypted journal:', command['prepare_draft'], flush=True)
        if command.get('restart_gui'):
            self.log_segments.append((self.root/'app.log').read_text(errors='replace'))
            subprocess.run(['docker','kill',self.name],check=True,stdout=subprocess.DEVNULL)
            for _ in range(50):
                if subprocess.run(['docker','container','inspect',self.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0:
                    break
                time.sleep(.1)
            subprocess.run(self.command,check=True,stdout=subprocess.DEVNULL)
            self.window = None
            for _ in range(100):
                found = self.run('xdotool','search','--onlyvisible','--name','^securemesh_client$',check=False).stdout.strip()
                if found:
                    self.window = found.splitlines()[0]
                    break
                time.sleep(.2)
            assert self.window
            self.run('xdotool','windowfocus','--sync',self.window)
            print('Owned GUI restarted with no profile environment pointer.',flush=True)
        super().execute({key: value for key, value in command.items() if key != "capture"})
        if 'verify_journal' in command:
            assert self.candidate.call('onboarding_state')['stage'] == command['verify_journal']
        if command.get('verify_resume'):
            state = self.candidate.call('onboarding_state')
            if state != {'stage': 'complete'}:
                self.capture('.impeccable/review/v2-resume-incomplete-fail.png')
                print('Incomplete native state:', state['stage'], 'uncertain:', state.get('draft',{}).get('loginUncertain'),flush=True)
            assert state == {'stage': 'complete'}, 'GUI did not complete the interrupted profile'
            profile = self.candidate.call('profile')
            assert profile['deviceId'] == self.candidate.identity
            assert self.candidate.call('identity') == self.original
            assert profile['requiresEnrollment'] and not profile['enrollmentVerified']
            d.request('/v1/conversations', token=profile['accessToken'], expected=403)
            statement = f"SELECT count(*) FROM sessions WHERE device_id='{self.candidate.identity}'"
            count = subprocess.check_output(['docker','compose','exec','-T','db','psql','-U','securemesh','-d','securemesh','-v','ON_ERROR_STOP=1','-Atc',statement],cwd=ROOT,text=True).strip()
            assert int(count) == self.expected_sessions, 'GUI unexpectedly created another session'
            self.secret_values.update([profile['accessToken'], profile['refreshToken']])
            logs = self.log_segments + [(self.root/'app.log').read_text(errors='replace')]
            for value in self.secret_values:
                assert all(value not in log for log in logs)
                assert value not in (ROOT/'.local/api-5098.log').read_text(errors='replace')
            print('PASS: actual native GUI completed the same device/profile; pending access stayed gated; no credential/token logs.',flush=True)
        if "capture" in command:
            self.capture(command["capture"])
        return {"completed": list(command)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--script')
    args = parser.parse_args()
    with ResumeGui() as gui:
        print('Resume GUI ready.',flush=True)
        if args.script:
            for command in json.loads(Path(args.script).read_text()):
                print(json.dumps(gui.execute(command)),flush=True)
        else:
            for line in sys.stdin:
                command = json.loads(line)
                if command.get('stop'):
                    break
                print(json.dumps(gui.execute(command)),flush=True)


if __name__ == '__main__':
    main()
