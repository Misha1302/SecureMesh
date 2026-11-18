#!/usr/bin/env python3
import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def main():
    subprocess.run(['dotnet','build','src/SecureMesh.Api','--no-restore'],cwd=ROOT,check=True)
    subprocess.run(['docker','compose','up','-d','--wait','db'],cwd=ROOT,check=True)
    password=dict(line.split('=',1) for line in (ROOT/'.env').read_text().splitlines())['SECUREMESH_DB_PASSWORD']
    env=dict(os.environ, ASPNETCORE_ENVIRONMENT='Development',
             ConnectionStrings__Database=f'Host=127.0.0.1;Port=55438;Database=securemesh;Username=securemesh;Password={password}')
    # Restart validates migration idempotence against the same persistent database.
    for _ in range(2):
        with (ROOT/'.local/api-smoke.log').open('w') as log:
            p=subprocess.Popen(['dotnet','src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll','--urls','http://127.0.0.1:5089'],cwd=ROOT,env=env,stdout=log,stderr=log)
            try:
                for attempt in range(100):
                    if p.poll() is not None: raise RuntimeError('API stopped; inspect .local/api-smoke.log')
                    try:
                        with urllib.request.urlopen('http://127.0.0.1:5089/health/ready',timeout=1) as r:
                            assert json.load(r)['status']=='ready'
                        break
                    except OSError: time.sleep(.1)
                else: raise RuntimeError('readiness timeout')
            finally:
                p.terminate(); p.wait(timeout=10)
    print('PASS: API build; real PostgreSQL readiness; EF migration; restart and migration idempotence.')

if __name__=='__main__': main()
