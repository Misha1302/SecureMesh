#!/usr/bin/env python3
"""Native session recovery after actual refresh COMMIT and owned SIGKILL."""
import argparse
import base64
import hashlib
import urllib.error
import urllib.request
import uuid
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

import delivery as d
from native_session import sql
from onboarding_recovery import GateProxy
from directory import establish


def post(path, data=None, token=None, expected=200, method=None):
    headers={"Content-Type":"application/json"}
    if token: headers["Authorization"]="Bearer "+token
    request=urllib.request.Request(d.BASE+path,data=json.dumps(data).encode() if data is not None else None,headers=headers,method=method)
    try:
        response=urllib.request.urlopen(request,context=d.TLS,timeout=10)
    except urllib.error.HTTPError as error:
        response=error
    with response:
        status, raw=response.status,response.read()
    assert status==expected, "HTTP status mismatch: "+str(status)
    return json.loads(raw) if raw else None


def signed(device, request):
    payload=("SecureMesh/refresh/v1\n"+request["requestId"]+"\n"+request["deviceId"]+"\n"+hashlib.sha256(request["token"].encode()).hexdigest()).encode()
    return {**request,"signature":device.call("sign",payload=base64.b64encode(payload).decode())["signature"]}


def sql_input(statement):
    result=subprocess.run(["docker","compose","exec","-T","db","psql","-U","securemesh","-d","securemesh","-v","ON_ERROR_STOP=1","-f","-"],input=statement,text=True,capture_output=True)
    assert result.returncode==0,"Owned SQL fixture write failed"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-baseline', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    d.BASE = 'https://127.0.0.1:5094'
    children = []
    with d.Server(legacy_bootstrap=False) as server, GateProxy() as proxy, tempfile.TemporaryDirectory(
            prefix='securemesh-refresh-', dir=d.ROOT / '.local') as tmp:
        try:
            root = Path(tmp)
            account = d.account(root)
            device = account['device']
            me = d.request('/v1/users/me', token=account['session']['accessToken'])
            original = device.call('identity')
            peer = d.account(root) if not args.legacy_baseline else None
            group = None
            queued = None
            if peer:
                device.pin(peer['device']); peer['device'].pin(device)
                group = establish(account,peer)
                queued = device.call('queue',group=group,id=str(uuid.uuid4()),text='Durable queue across lost refresh: Привет')
            device.call('profile_put', profile={
                **account['session'], 'endpoint': proxy.endpoint,
                'username': account['username'], 'userId': me['userId'],
                'requiresEnrollment': False, 'enrollmentVerified': True, 'group':group,
                'marker':'preserve-profile-fields',
            })
            sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{device.identity}'")
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps(dict(path=str(device.path), passphrase=device.password,
                                              device=device.identity,
                                              cert=str(d.ROOT / '.local/tls.pem'),
                                              library=str(d.ROOT / 'src/crypto_core/target/debug/libsecuremesh_crypto.so'))))
            fixture.chmod(0o600)

            base_fixture=json.loads(fixture.read_text())

            def start(**options):
                fixture.write_text(json.dumps(base_fixture | options));fixture.chmod(0o600)
                child = subprocess.Popen(
                    [str(d.ROOT / '.local/flutter/bin/dart'), 'run', 'tool/session_recovery.dart', str(fixture)],
                    cwd=d.ROOT / 'apps/client_flutter', env={**os.environ, 'PUB_CACHE': str(d.ROOT / '.local/pub-cache')},
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                children.append(child)
                return child

            proxy.arm('/v1/auth/refresh' if args.legacy_baseline else '/v1/auth/refresh/device')
            first = start()
            deadline = time.monotonic() + 35
            while not proxy.hit.wait(.1) and first.poll() is None and time.monotonic() < deadline:
                pass
            if not proxy.hit.is_set():
                raise AssertionError('Actual refresh COMMIT gate not reached')
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'") == '2'
            os.killpg(first.pid, signal.SIGKILL)
            first.communicate(timeout=10)
            assert first.returncode == -signal.SIGKILL
            proxy.release.set()
            assert device.call('profile')['refreshToken'] == account['session']['refreshToken']
            request = device.call('refresh_status')['pending']['request'] if not args.legacy_baseline else None
            if request:
                assert device.call('refresh_prepare',endpoint=proxy.endpoint)['request']==request
                device.call('refresh_prepare',endpoint='https://invalid.securemesh.test',reject=True)
                device.call('refresh_complete',response={'requestId':str(uuid.uuid4())},reject=True)
                server.env['StateDirectory']=str(d.ROOT/'.local')
                server.env['ASPNETCORE_CONTENTROOT']=str(d.ROOT/'src/SecureMesh.Api')
            server.restart()
            second = start()
            output, errors = second.communicate(timeout=45)
            for secret in (account['password'], device.password, account['session']['accessToken'], account['session']['refreshToken']):
                assert secret not in output + errors
            result = json.loads(output.strip().splitlines()[-1]) if output.strip() else {}
            assert second.returncode == 0 and result.get('ok'), 'Recovery rejected: ' + str(result.get('code', 'native failure'))
            assert device.call('identity') == original
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'") == '2'
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}' AND revoked") == '0'
            assert not proxy.errors, proxy.errors
            print('PASS: actual refresh COMMIT, lost reply, owned SIGKILL, API restart and same-key native recovery without another rotation or family revocation.',flush=True)
            if args.legacy_baseline:
                return
            profile=device.call('profile')
            assert profile['marker']=='preserve-profile-fields' and profile['enrollmentVerified']
            assert device.call('outbox')['messages']==[queued]
            replay=post('/v1/auth/refresh/device',request)
            assert replay['refreshToken']==profile['refreshToken'] and replay['accessToken']==profile['accessToken']
            device.call('refresh_complete',response=replay)  # same local receipt is idempotent
            assert device.call('refresh_status')['pending'] is None
            post('/v1/auth/refresh',{'token':profile['refreshToken']},expected=401)
            bad={**request,'signature':base64.b64encode(bytes(64)).decode()}
            post('/v1/auth/refresh/device',bad,expected=401)
            post('/v1/auth/refresh/device',signed(peer['device'],request),expected=401)
            post('/v1/auth/refresh/device',{**request,'deviceId':peer['device'].identity},expected=401)
            assert sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}' AND revoked")=='0'
            raw=sql(f"SELECT protected_response FROM refresh_rotations WHERE device_id='{device.identity}'")
            for secret in [request['token'],profile['accessToken'],profile['refreshToken']]:
                assert secret not in raw
            sql(f"UPDATE refresh_rotations SET protected_response='corrupted' WHERE device_id='{device.identity}'")
            post('/v1/auth/refresh/device',request,expected=503)
            assert device.call('profile')==profile
            sql_input("UPDATE refresh_rotations SET protected_response='"+raw.replace("'","''")+"' WHERE device_id='"+device.identity+"';")
            post('/v1/auth/refresh/device',request)
            print('PASS: stable replay tokens; device-bound sessions reject bearer downgrade, forged/foreign proof; no family revocation from unauthenticated input; response encrypted in PG.',flush=True)

            def crash_rotation(expire_successor=False):
                before=int(sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'"))
                sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{device.identity}' AND NOT used")
                proxy.arm('/v1/auth/refresh/device')
                child=start()
                assert proxy.hit.wait(35),'Refresh COMMIT barrier not reached'
                pending=device.call('refresh_status')['pending']['request']
                os.killpg(child.pid,signal.SIGKILL);child.communicate(timeout=10)
                assert child.returncode==-signal.SIGKILL
                proxy.release.set()
                assert int(sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}'"))==before+1
                if expire_successor:
                    sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{device.identity}' AND NOT used")
                return pending

            # Recovered access can already have expired after a long blackout;
            # the saved next refresh is committed first, then rotates once.
            second_request=crash_rotation(expire_successor=True)
            response=post('/v1/auth/refresh/device',second_request)
            assert response['expiresIn']==0
            snapshot=device.call('profile')
            device.call('refresh_complete',response=response,crash_before_commit=True,reject=True)
            assert device.call('profile')==snapshot
            assert device.call('refresh_status')['pending']['request']==second_request
            resumed=start();output,errors=resumed.communicate(timeout=45)
            assert resumed.returncode==0,'Expired recovered access failed'
            assert device.call('identity')==original
            assert device.call('outbox')['messages']==[queued]
            print('PASS: expired recovered access deadline is not extended; real local pre-COMMIT abort preserves journal; native client commits recovery then rotates once.',flush=True)

            expired_request=crash_rotation()
            # Timestamp fixtures only, on this owned device's ledger; no host clock change.
            sql(f"UPDATE refresh_rotations SET created_at=created_at-interval '2 days',expires_at=expires_at-interval '2 days' WHERE device_id='{device.identity}' AND request_id='{expired_request['requestId']}'")
            denied=start();output,errors=denied.communicate(timeout=45)
            assert denied.returncode==2 and json.loads(output.strip())['code']=='REFRESH_RECOVERY_EXPIRED'
            assert device.call('outbox')['messages']==[queued]
            # Authenticated, different retry still triggers reuse revocation.
            changed=signed(device,{**expired_request,'requestId':str(uuid.uuid4())})
            post('/v1/auth/refresh/device',changed,expected=401)
            post('/v1/auth/refresh/device',expired_request,expected=401)
            assert int(sql(f"SELECT count(*) FROM sessions WHERE device_id='{device.identity}' AND NOT revoked"))==0
            print('PASS: replay window expires; different authenticated reuse revokes family; exact replay cannot resurrect it; encrypted queue retained.',flush=True)

            signed_in=start(reauthenticate=True,password=account['password'],deliver=True)
            output,errors=signed_in.communicate(timeout=60)
            assert signed_in.returncode==0,'Same-key reauthentication or queue recovery failed'
            restored=device.call('profile')
            assert restored['deviceId']==device.identity and restored['marker']==profile['marker']
            assert restored['requiresEnrollment']==profile['requiresEnrollment'] and restored['enrollmentVerified']==profile['enrollmentVerified']
            assert device.call('identity')==original and device.call('outbox')['messages']==[]
            device.call('refresh_complete',response=replay,reject=True)
            assert device.call('profile')==restored
            d.sync(peer['device'],peer['session']['accessToken'],group)
            history=peer['device'].call('history',group=group)['events']
            assert len(history)==1 and history[0]['id']==queued['id']
            assert history[0]['text']=='Durable queue across lost refresh: Привет'
            page=d.request('/v1/sync?conversationId='+group,token=peer['session']['accessToken'])
            assert len(page['messages'])==1 and page['messages'][0]['ciphertext']==queued['ciphertext']
            print('PASS: password + original key reauthentication coalesces eight waiting calls; preserves profile/MLS/trust; actual native transport drains the identical queued ciphertext once to independent MLS recipient.',flush=True)

            post('/v1/devices/'+device.identity,token=restored['accessToken'],method='DELETE',expected=204)
            revoked=start(reauthenticate=True,password=account['password'])
            output,errors=revoked.communicate(timeout=45)
            assert revoked.returncode==2 and json.loads(output.strip())['code']=='DEVICE_KEY_CHANGED'
            assert device.call('profile')==restored and device.call('identity')==original
            assert sql(f"SELECT count(*) FROM devices WHERE user_id='{me['userId']}'")=='1'
            for path in root.glob(device.path.name+'*'):
                content=path.read_bytes()
                for secret in [account['password'],device.password,restored['accessToken'],restored['refreshToken'],history[0]['text']]:
                    assert secret.encode() not in content
            logs=(d.ROOT/'.local/api-5094.log').read_text()
            for secret in [account['password'],device.password,restored['accessToken'],restored['refreshToken'],history[0]['text']]:
                assert secret not in logs
            assert not proxy.errors,proxy.errors
            print('PASS: revoked device cannot reauthenticate even with password/key; no replacement device or trust reset; local store/WAL and API logs contain no tested secrets/plaintext.',flush=True)

            # Legacy demo profiles omitted username/userId. The existing key's
            # server ownership must bind adoption; another valid account fails.
            legacy=d.account(root);ld=legacy['device'];lid=ld.call('identity')
            ld.call('profile_put',profile={**legacy['session'],'endpoint':proxy.endpoint,'marker':'legacy-profile'})
            post('/v1/auth/refresh',{'token':legacy['session']['refreshToken']})
            post('/v1/auth/refresh',{'token':legacy['session']['refreshToken']},expected=401)
            common=dict(path=str(ld.path),passphrase=ld.password,device=ld.identity,reauthenticate=True)
            wrong=start(**common,username=peer['username'],password=peer['password'])
            output,errors=wrong.communicate(timeout=45)
            assert wrong.returncode==2 and json.loads(output.strip())['code']=='DEVICE_KEY_CHANGED'
            assert 'username' not in ld.call('profile')
            correct=start(**common,username=legacy['username'],password=legacy['password'])
            output,errors=correct.communicate(timeout=45)
            assert correct.returncode==0
            adopted=ld.call('profile')
            assert adopted['username']==legacy['username'] and adopted['marker']=='legacy-profile'
            assert ld.call('identity')==lid
            assert sql(f"SELECT count(*) FROM devices WHERE user_id='{adopted['userId']}'")=='1'
            print('PASS: legacy completed profile adopts missing account labels only after same-key ownership/login; another valid account rejected; no replacement identity.',flush=True)
        finally:
            proxy.release.set()
            for child in children:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.communicate(timeout=10)


if __name__ == '__main__':
    main()
