#!/usr/bin/env python3
"""Render only observed production-native measurements; missing/failed trials fail the gate."""
import hashlib
import json
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[1]
rows = []
failures = []
binary_set = None
for profile, rate, rtt, loss in [('gprs', 20, 1500, 3), ('severe', 10, 3000, 10)]:
    for seed in (7, 19, 41):
        path = root / f'reports/evidence/native-netem-{profile}-{seed}-200.json'
        if not path.exists():
            failures.append(f'{profile}/{seed}: NOT_RUN')
            rows.append(f'| {profile} | {seed} | NOT_RUN | — | — | — | — |')
            continue
        data = json.loads(path.read_text())
        records = data['records']
        counts = Counter(r['sender'] for r in records)
        reasons = []
        if (data['profile'], data['seed'], data['messages_each_direction'], data['rate_kbps_each_direction'], data['rtt_ms'], data['packet_loss_percent']) != (profile, seed, 200, rate, rtt, loss):
            reasons.append('profile/count mismatch')
        if len(records) != 400 or len({r['id'] for r in records}) != 400 or sorted(counts.values()) != [200, 200] or data['duplicates'] or data['missing_ids']:
            reasons.append('missing/duplicate/direction mismatch')
        measured = sorted(r['delivery_seconds'] for r in records)[379]
        if abs(measured - data['delivery_p95']) > 1e-8 or measured < 0:
            reasons.append('inconsistent measured percentile')
        if profile == 'gprs' and measured > 15:
            reasons.append('p95 exceeds unchanged 15-second gate')
        if not data['source_sha256'] or not data['binary_sha256'] or not all(data[n + '_tc_stats'] for n in ('netem-a', 'netem-b')):
            reasons.append('provenance/counters missing')
        if any(hashlib.sha256((root / name).read_bytes()).hexdigest() != digest for name, digest in data['source_sha256'].items()):
            reasons.append('measured native sources differ from current sources')
        if binary_set is None:
            binary_set = data['binary_sha256']
        elif binary_set != data['binary_sha256']:
            reasons.append('binary set differs between trials')
        status = 'FAIL' if reasons else 'PASS'
        if reasons:
            failures.append(f'{profile}/{seed}: ' + ', '.join(reasons))
        rows.append(f"| {profile} | {seed} | {status} | {data['delivery_p50']:.3f} | {measured:.3f} | {data['delivery_p99']:.3f} | [{path.name}](evidence/{path.name}) |")

text = '''# Native Linux 2G measurements — component gate

The executable Dart driver uses the same NativeDelivery, MeshTransport, AccountSession and Rust bridge as Flutter, with real OpenMLS/SQLCipher, TLS API and PostgreSQL. Initial DM setup uses the consented KeyPackage/Welcome API. This is not a GUI timing benchmark or an Android/carrier/battery test.

Each trial offers 200 Unicode messages in each direction (400 distinct IDs), one per second/device for GPRS and every 1.5 seconds/device for severe. Time starts before local encryption/outbox COMMIT and ends after recipient decryption/inbox COMMIT. TLS/WSS sessions are warmed before impairments. Owned disposable netem containers apply 20 kbit/s per direction / RTT 1.5s / 3% loss for GPRS and 10 kbit/s / RTT 3s / 10% loss for severe. No host network interface is changed. Raw records, counters, exact source/binary hashes and source HEAD at each launch are retained. Builds/GUI tests may run concurrently; this is shared development hardware.

| Profile | Seed | Result | p50 seconds | p95 seconds | p99 seconds | Raw evidence |
|---|---:|---|---:|---:|---:|---|
''' + '\n'.join(rows) + '''

GPRS gate remains p95 <=15 seconds in every full trial. Severe requires eventual delivery, with a bounded 1200-second harness watchdog and no claimed latency SLA. The raw failure from the first native seed 19 (p95 18.559 seconds) is preserved in v2-native-gprs-initial-fail.txt and native-netem-gprs-initial-19-200.json. No impairment, count or threshold was reduced. The fix removes batch-wide ACK/sync waiting: bounded writes refill independently from sync, immutable ciphertext remains in SQLCipher until durable ACK, and MLS control commits remain serial barriers.

WSS byte counters cover application framing, not TLS/network overhead or an exact 100-character envelope. Historical Python-client figures are separate in 2G_REPORT.md. These steady-link measurements do not complete the combined 60-second blackout, lost-ACK, SIGKILL, half-open, DB interruption and competing-media schedule. AT-013 and V2-08 remain partial. No universal 2G or production claim. PRODUCTION_APPROVED=false.
'''
(root / 'reports/NATIVE_2G_REPORT.md').write_text(text)
for failure in failures:
    print(failure)
print(f'Native network gate: {6 - len(failures)}/6 observed trials pass')
raise SystemExit(bool(failures))
