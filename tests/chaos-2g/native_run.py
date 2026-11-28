#!/usr/bin/env python3
"""Actual production Dart delivery cycle over project-only Linux netem, real MLS/SQLCipher/API/PG/TLS."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

COMPOSE=['docker','compose','-f','docker-compose.yml','-f','compose.chaos.yml']
# Per-direction kbit/s, round-trip ms, per-leg loss %, per-leg jitter ms.
PROFILES = {
    'gprs': (20, 1500, 3, 0),
    'severe': (10, 3000, 10, 0),
    '3g': (384, 250, 1, 30),
    '4g': (8000, 80, 0.2, 10),
    '5g': (50000, 30, 0.1, 3),
}

def docker(*args):return subprocess.check_output(COMPOSE+list(args),cwd=ROOT,text=True)


def link_counts(name):
    info, = json.loads(docker('exec', '-T', name, 'ip', '-j', '-s', 'link', 'show', 'dev', 'eth0'))
    return {direction: info['stats64'][direction]['bytes'] for direction in ('rx', 'tx')}


def qdisc_stats(name):
    return docker('exec', '-T', name, 'tc', '-s', 'qdisc', 'show', 'dev', 'eth0')


def configure(name, rate, rtt, loss, seed, jitter=0):
    # Run the checked-out profile definition even when reusing a cached proxy image.
    script = (ROOT / 'tests/chaos-2g/configure.sh').read_text()
    args = [str(value) for value in (rate, rtt, loss, seed, jitter)]
    return subprocess.check_output(
        [*COMPOSE, 'exec', '-T', name, 'sh', '-s', '--', *args],
        cwd=ROOT, input=script, text=True)


OUTAGE_SECONDS = 60
OUTAGE_BASELINE = 3
OUTAGE_P95_LIMIT = 45
EDGE = (100, 600, 1, 0)


def await_marker(path, process, seconds):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if process.poll() is not None:
            raise RuntimeError(f'Dart exited before {path.name}')
        if time.monotonic() >= deadline:
            raise TimeoutError(f'Dart did not reach {path.name}')
        time.sleep(0.05)


def server_deliveries(postgres, database, group):
    sql = ("SELECT coalesce(json_agg(json_build_array(device_id,client_id)), '[]') "
           f"FROM messages WHERE conversation_id = '{uuid.UUID(group)}' AND kind=1")
    result = postgres('psql', '-U', 'securemesh', '-d', database,
                      '-v', 'ON_ERROR_STOP=1', '-Atc', sql, capture_output=True, text=True)
    return json.loads(result.stdout)


def simulate_outage(root, process, setup, seed, check_server):
    await_marker(root / 'baseline-ready', process, 120)
    blocked = {name: configure(name, EDGE[0], 0, 100, seed + i * 100)
               for i, name in enumerate(setup)}
    started = time.monotonic()
    (root / 'outage-active').touch()
    await_marker(root / 'offline-queued', process, 45)
    time.sleep(max(0, started + OUTAGE_SECONDS - time.monotonic()))
    before_restore = {name: qdisc_stats(name) for name in setup}
    during = check_server()
    if len(during) != 2 * OUTAGE_BASELINE or len({tuple(row) for row in during}) != len(during):
        raise RuntimeError('Server accepted messages during blackout or baseline is invalid')
    (root / 'restore-starting').touch()
    await_marker(root / 'restore-timer-ready', process, 5)
    restore_at = time.monotonic()
    restored = {name: configure(name, *EDGE[:3], seed + i * 100, EDGE[3])
                for i, name in enumerate(setup)}
    return dict(blocked_qdiscs=blocked, blocked_qdisc_stats_before_restore=before_restore,
                restored_qdiscs=restored, server_rows_before_restore=len(during),
                minimum_blackout_seconds=restore_at - started,
                reconfiguration_seconds=time.monotonic() - restore_at)


def main():
    parser = argparse.ArgumentParser()
    scenario = parser.add_mutually_exclusive_group(required=True)
    scenario.add_argument('--profile', choices=PROFILES)
    scenario.add_argument('--outage', action='store_true', help='60-second total blackout then EDGE')
    parser.add_argument('--count', type=int)
    parser.add_argument('--seeds', default='7,19,41')
    args = parser.parse_args()
    if args.count is None:
        args.count = 10 if args.outage else 200
    if args.outage and not OUTAGE_BASELINE < args.count <= OUTAGE_BASELINE + 100:
        parser.error('--outage requires 4–103 messages per direction (at most 100 queued offline)')
    profile = 'edge-outage' if args.outage else args.profile
    rate, rtt, loss, jitter = EDGE if args.outage else PROFILES[profile]
    sys.path.insert(0, str(ROOT / 'tests/integration'))
    import delivery as d
    from directory import establish
    from private_blobs import database, postgres

    suite_lock = (ROOT / '.local/netem-suite.lock').open('w')
    try:fcntl.flock(suite_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise RuntimeError('SECUREMESH_NETEM_SUITE_ALREADY_RUNNING') from None
    d.BASE='https://127.0.0.1:5090';os.environ['SECUREMESH_TEST_URLS']='https://127.0.0.1:5090;https://10.239.238.1:5090'
    try:
        docker('up','-d','netem-a','netem-b')
        for seed in map(int,args.seeds.split(',')):
            for i,name in enumerate(('netem-a','netem-b')):configure(name,10000,0,0,seed+i)
            with database() as test_db, d.Server(test_db, legacy_bootstrap=False), tempfile.TemporaryDirectory(prefix='securemesh-native-netem-',dir=ROOT/'.local') as tmp:
                root=Path(tmp);a,b=[d.account(root) for _ in range(2)];a['device'].pin(b['device']);b['device'].pin(a['device']);group=establish(a,b)
                output=ROOT/f'reports/evidence/native-netem-{profile}-{seed}-{args.count}.json'
                if output.exists():
                    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%f')
                    output.rename(output.with_name(output.stem+'.previous-'+stamp+'.json'))
                fixture=root/'fixture.json';fixture.write_text(json.dumps(dict(clock_ticks_per_second=os.sysconf("SC_CLK_TCK"),profile=profile,seed=seed,count=args.count,group=group,output=str(output),progress=str(ROOT/'.local/native-network-progress.json'),cert=str(ROOT/'.local/tls.pem'),library=str(ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'),devices=[dict(id=who['device'].identity,path=str(who['device'].path),passphrase=who['device'].password,session=who['session'],endpoint=f'https://127.0.0.1:{15990+i}') for i,who in enumerate((a,b))])));fixture.chmod(0o600)
                if args.outage:
                    data = json.loads(fixture.read_text())
                    data['outage'] = dict(control=str(root), baseline=OUTAGE_BASELINE,
                                          seconds=OUTAGE_SECONDS, p95_limit=OUTAGE_P95_LIMIT)
                    fixture.write_text(json.dumps(data))
                source_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
                binary_hashes={str(p.relative_to(ROOT)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in [ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so',ROOT/'src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll']}
                source_hashes={str(p.relative_to(ROOT)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in [ROOT/'apps/client_flutter/lib/delivery_client.dart',ROOT/'apps/client_flutter/lib/transport.dart',ROOT/'apps/client_flutter/lib/session.dart',ROOT/'apps/client_flutter/lib/tls_client.dart',ROOT/'apps/client_flutter/tool/network_trial.dart']}
                with (root/'dart.stderr').open('w') as errors:
                    process=subprocess.Popen([str(ROOT/'.local/flutter/bin/dart'),'run','tool/network_trial.dart',str(fixture)],cwd=ROOT/'apps/client_flutter',env={**os.environ,'PUB_CACHE':str(ROOT/'.local/pub-cache')},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,text=True)
                    try:
                        ready=selectors.DefaultSelector();ready.register(process.stdout,selectors.EVENT_READ)
                        if not ready.select(timeout=60):raise TimeoutError('Dart warm startup timed out')
                        if process.stdout.readline().strip()!='WARM_READY':raise RuntimeError((root/'dart.stderr').read_text())
                        setup={}
                        for i,name in enumerate(('netem-a','netem-b')):setup[name]=configure(name,rate,rtt,loss,seed+i*100,jitter)
                        progress_path = ROOT / '.local/native-network-progress.json'
                        progress_path.unlink(missing_ok=True)
                        initial_links = {name: link_counts(name) for name in setup}
                        process.stdin.write('RUN\n');process.stdin.flush()
                        outage = None
                        coordination_error = None
                        if args.outage:
                            try:
                                outage = simulate_outage(root, process, setup, seed,
                                    lambda: server_deliveries(postgres, test_db, group))
                            except (RuntimeError, TimeoutError, subprocess.CalledProcessError) as error:
                                coordination_error = str(error)
                                if process.poll() is None:
                                    process.terminate()
                        timed_out = False
                        try:
                            stdout,_ = process.communicate(timeout=1300)
                        except subprocess.TimeoutExpired:
                            timed_out = True
                            if shutil.which('ss'):
                                sockets = subprocess.run(['ss', '-ntp'], capture_output=True, text=True)
                                for line in sockets.stdout.splitlines():
                                    if f'pid={process.pid},' in line:
                                        print('Timed out child socket:', line, flush=True)
                            process.terminate()
                            try:
                                stdout,_ = process.communicate(timeout=10)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                stdout,_ = process.communicate()

                        if stdout:print(stdout.strip(),flush=True)
                        if output.exists():
                            result = json.loads(output.read_text())
                        else:
                            result = dict(profile=profile, seed=seed, messages_each_direction=args.count,
                                          outcome="incomplete", last_progress=None)
                            if progress_path.exists():
                                try:
                                    result["last_progress"] = json.loads(progress_path.read_text())
                                except json.JSONDecodeError:
                                    pass  # The worker may have stopped while writing progress.
                        result.update(child_exit_code=process.returncode, timed_out=timed_out,
                                      rate_kbps_each_direction=rate, rtt_ms=rtt, packet_loss_percent=loss,
                                      jitter_ms_each_direction=jitter, setup=setup, source_head_at_start=source_head,
                                      binary_sha256=binary_hashes, source_sha256=source_hashes)
                        if args.outage:
                            result['outage_network'] = outage
                            result['outage_coordination_error'] = coordination_error
                            if outage is not None and 'records' in result:
                                rows = server_deliveries(postgres, test_db, group)
                                expected = {(row['sender'], row['id']) for row in result['records']}
                                accepted = {tuple(row) for row in rows}
                                outage['server_rows_after_restore'] = len(rows)
                                outage['server_missing_ids'] = len(expected - accepted)
                                outage['server_unexpected_ids'] = len(accepted - expected)
                                outage['server_duplicates'] = len(rows) - len(accepted)
                        result['proxy_eth0_bytes'] = {}
                        for name, before in initial_links.items():
                            after = link_counts(name)
                            result['proxy_eth0_bytes'][name] = {k: after[k] - before[k] for k in before}
                            result[name + '_tc_stats'] = qdisc_stats(name)
                        output.write_text(json.dumps(result,indent=2)+'\n')
                        if coordination_error is not None:
                            raise RuntimeError(coordination_error)
                        if result.get("outcome") == "incomplete" and process.returncode == 0:
                            raise RuntimeError("Trial exited without delivery measurements")
                        if outage is not None and any(outage.get(key) for key in
                                  ('server_missing_ids', 'server_unexpected_ids', 'server_duplicates')):
                            raise RuntimeError('PostgreSQL accepted a different message set than the native recipients')
                        if timed_out:
                            raise TimeoutError(f'{profile}/{seed}: Dart did not exit within the 1300s watchdog')
                        if process.returncode!=0:raise RuntimeError(f'Dart native network trial exited {process.returncode}: '+(root/'dart.stderr').read_text())
                    finally:
                        if process.poll() is None:process.terminate();process.wait(timeout=10)
    finally:docker('stop','netem-a','netem-b')


if __name__=='__main__':main()
