#!/usr/bin/env python3
"""Actual production Dart delivery cycle over project-only Linux netem, real MLS/SQLCipher/API/PG/TLS."""
import argparse
import fcntl
import hashlib
import json
import os
import selectors
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/integration'))
import delivery as d
from directory import establish

COMPOSE=['docker','compose','-f','docker-compose.yml','-f','compose.chaos.yml']
def docker(*args):return subprocess.check_output(COMPOSE+list(args),cwd=ROOT,text=True)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--profile',choices=['gprs','severe'],required=True);parser.add_argument('--count',type=int,default=200);parser.add_argument('--seeds',default='7,19,41');args=parser.parse_args()
    suite_lock=(ROOT/'.local/netem-suite.lock').open('w')
    try:fcntl.flock(suite_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise RuntimeError('SECUREMESH_NETEM_SUITE_ALREADY_RUNNING') from None
    d.BASE='https://127.0.0.1:5090';os.environ['SECUREMESH_TEST_URLS']='https://127.0.0.1:5090;https://10.239.238.1:5090'
    try:
        docker('up','-d','netem-a','netem-b')
        for seed in map(int,args.seeds.split(',')):
            for i,name in enumerate(('netem-a','netem-b')):docker('exec','-T',name,'sh','/netem/configure.sh','10000','0','0',str(seed+i))
            with d.Server(legacy_bootstrap=False),tempfile.TemporaryDirectory(prefix='securemesh-native-netem-',dir=ROOT/'.local') as tmp:
                root=Path(tmp);a,b=[d.account(root) for _ in range(2)];a['device'].pin(b['device']);b['device'].pin(a['device']);group=establish(a,b)
                output=ROOT/f'reports/evidence/native-netem-{args.profile}-{seed}-{args.count}.json'
                fixture=root/'fixture.json';fixture.write_text(json.dumps(dict(profile=args.profile,seed=seed,count=args.count,group=group,output=str(output),progress=str(ROOT/'.local/native-network-progress.json'),cert=str(ROOT/'.local/tls.pem'),library=str(ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'),devices=[dict(id=who['device'].identity,path=str(who['device'].path),passphrase=who['device'].password,session=who['session'],endpoint=f'https://127.0.0.1:{15990+i}') for i,who in enumerate((a,b))])));fixture.chmod(0o600)
                source_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
                binary_hashes={str(p.relative_to(ROOT)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in [ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so',ROOT/'src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll']}
                source_hashes={str(p.relative_to(ROOT)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in [ROOT/'apps/client_flutter/lib/delivery_client.dart',ROOT/'apps/client_flutter/lib/transport.dart',ROOT/'apps/client_flutter/lib/session.dart',ROOT/'apps/client_flutter/tool/network_trial.dart']}
                with (root/'dart.stderr').open('w') as errors:
                    process=subprocess.Popen([str(ROOT/'.local/flutter/bin/dart'),'run','tool/network_trial.dart',str(fixture)],cwd=ROOT/'apps/client_flutter',env={**os.environ,'PUB_CACHE':str(ROOT/'.local/pub-cache')},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,text=True)
                    try:
                        ready=selectors.DefaultSelector();ready.register(process.stdout,selectors.EVENT_READ)
                        if not ready.select(timeout=60):raise TimeoutError('Dart warm startup timed out')
                        if process.stdout.readline().strip()!='WARM_READY':raise RuntimeError((root/'dart.stderr').read_text())
                        rate,rtt,loss=(20,1500,3) if args.profile=='gprs' else (10,3000,10)
                        setup={}
                        for i,name in enumerate(('netem-a','netem-b')):setup[name]=docker('exec','-T',name,'sh','/netem/configure.sh',str(rate),str(rtt),str(loss),str(seed+i*100))
                        process.stdin.write('RUN\n');process.stdin.flush()
                        stdout,_=process.communicate(timeout=1300)
                        if stdout:print(stdout.strip(),flush=True)
                        if output.exists():
                            result=json.loads(output.read_text());result.update(rate_kbps_each_direction=rate,rtt_ms=rtt,packet_loss_percent=loss,setup=setup,source_head_at_start=source_head,binary_sha256=binary_hashes,source_sha256=source_hashes)
                            for name in ('netem-a','netem-b'):result[name+'_tc_stats']=docker('exec','-T',name,'tc','-s','qdisc','show','dev','eth0')
                            output.write_text(json.dumps(result,indent=2)+'\n')
                        if process.returncode!=0:raise RuntimeError(f'Dart native network trial exited {process.returncode}: '+(root/'dart.stderr').read_text())
                    finally:
                        if process.poll() is None:process.terminate();process.wait(timeout=10)
    finally:docker('stop','netem-a','netem-b')


if __name__=='__main__':main()
