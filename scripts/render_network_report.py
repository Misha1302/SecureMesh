#!/usr/bin/env python3
import json
from pathlib import Path

rows=[]
for path in sorted(Path('reports/evidence').glob('netem-v2-*-*-200.json')):
    j=json.loads(path.read_text())
    rows.append(f"| {j['profile']} | {j['seed']} | {j['messages_each_direction']} + {j['messages_each_direction']} | {j['delivery_p50']:.3f} | {j['delivery_p95']:.3f} | {j['delivery_p99']:.3f} | {j['duplicates']} | {j['losses']} | [{path.name}](evidence/{path.name}) |")
text='''# 2G measurements — local synthetic traffic

Real OpenMLS, independent persistent client processes, SQLCipher, .NET API, PostgreSQL and TLS WebSocket. One WSS per device multiplexes send/sync/processed receipts. Linux netem runs only in two disposable SecureMesh containers (NET_ADMIN inside containers); no host qdisc changes. Each device has separate upload/download HTB classes. GPRS: 20 kbit/s per direction, 750 ms per egress leg, 3% packet loss. Severe: 10 kbit/s, 1500 ms per leg, 10% loss. Raw `tc -s` counters, seeds, binary hashes, message IDs, character/UTF-8 counts and monotonic timings are in JSON evidence.

## Historical Python client full-size trials

| Profile | Seed | Messages | p50 seconds | p95 seconds | p99 seconds | Duplicates | Missing IDs | Raw evidence |
|---|---:|---:|---:|---:|---:|---:|---:|---|
'''+ '\n'.join(rows)+'''

GPRS objective stays p95 <=15 seconds. Severe has no latency acceptance threshold. Latency starts before local queue encryption/COMMIT and ends after recipient decrypt/inbox COMMIT. Unicode length is 1..400 characters; messages are offered at 1 second/device for GPRS and 1.5 seconds/device for severe with at most three sends in flight. Dedicated quiet benchmark hardware was not used; local builds ran concurrently. This is not a carrier/device/battery test.

## Failure and correction

The first full GPRS seed 7 failed p95: 25.721 seconds, while delivering 400/400 IDs without duplicates. Evidence `evidence/netem-gprs-full.txt` and `netem-gprs-7-200.json` is retained. No threshold or impairment parameters were relaxed. The initial client reopened SQLCipher and paid its password KDF for every operation; sync also echoed full ciphertext back to the sender. Fixed with a single serialized unlocked store per client (also exposed through flutter_rust_bridge), small bounded sync pages, asynchronous persisted receipts and sender echoes containing the verified SHA-256 of locally stored ciphertext. Recipient E2EE remains unchanged.

## Limits / still outstanding

The profile runs prove steady functioning-link delivery. Crash/lost-ACK/concurrency/DB-stop cases are executed separately in crypto/delivery/recovery/epoch tests. The profile driver does not yet mix all specified crashes, 60-second blackout, half-open reconnect, media competition and three network seeds in one fault schedule; AT-013 remains partial for that stronger combined criterion. Native GUI now uses WSS-first MeshTransport/NativeDelivery with tested HTTPS fallback. Its measurements are reported separately in [NATIVE_2G_REPORT.md](NATIVE_2G_REPORT.md); historical Python results do not clear a native regression. App frame statistics in these trials cover varied Unicode messages and exclude TLS record overhead. Exact 100-character TLS/network accounting, 30-minute resource/battery checks, 1000-event sync stress and real operator trials remain unverified. Media fairness cannot pass while media is absent.

No production SLA or universal 2G claim. PRODUCTION_APPROVED=false.
'''
Path('reports/2G_REPORT.md').write_text(text)
print('Rendered',len(rows),'completed full-size network trials; missing trials are not synthesized.')
