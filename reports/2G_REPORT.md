# 2G measurements — local synthetic traffic

Real OpenMLS, independent persistent client processes, SQLCipher, .NET API, PostgreSQL and TLS WebSocket. One WSS per device multiplexes send/sync/processed receipts. Linux netem runs only in two disposable SecureMesh containers (NET_ADMIN inside containers); no host qdisc changes. Each device has separate upload/download HTB classes. GPRS: 20 kbit/s per direction, 750 ms per egress leg, 3% packet loss. Severe: 10 kbit/s, 1500 ms per leg, 10% loss. Raw `tc -s` counters, seeds, binary hashes, message IDs, character/UTF-8 counts and monotonic timings are in JSON evidence.

## Executed full-size trials

| Profile | Seed | Messages | p50 seconds | p95 seconds | p99 seconds | Duplicates | Missing IDs | Raw evidence |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| gprs | 19 | 200 + 200 | 2.792 | 4.375 | 5.078 | 0 | 0 | [netem-v2-gprs-19-200.json](evidence/netem-v2-gprs-19-200.json) |
| gprs | 41 | 200 + 200 | 2.849 | 4.754 | 5.791 | 0 | 0 | [netem-v2-gprs-41-200.json](evidence/netem-v2-gprs-41-200.json) |
| gprs | 7 | 200 + 200 | 2.724 | 4.351 | 5.457 | 0 | 0 | [netem-v2-gprs-7-200.json](evidence/netem-v2-gprs-7-200.json) |
| severe | 19 | 200 + 200 | 19.315 | 58.895 | 64.625 | 0 | 0 | [netem-v2-severe-19-200.json](evidence/netem-v2-severe-19-200.json) |
| severe | 41 | 200 + 200 | 18.908 | 64.428 | 68.824 | 0 | 0 | [netem-v2-severe-41-200.json](evidence/netem-v2-severe-41-200.json) |
| severe | 7 | 200 + 200 | 21.697 | 30.325 | 36.062 | 0 | 0 | [netem-v2-severe-7-200.json](evidence/netem-v2-severe-7-200.json) |

GPRS objective stays p95 <=15 seconds. Severe has no latency acceptance threshold. Latency starts before local queue encryption/COMMIT and ends after recipient decrypt/inbox COMMIT. Unicode length is 1..400 characters; messages are offered at 1 second/device for GPRS and 1.5 seconds/device for severe with at most three sends in flight. Dedicated quiet benchmark hardware was not used; local builds ran concurrently. This is not a carrier/device/battery test.

## Failure and correction

The first full GPRS seed 7 failed p95: 25.721 seconds, while delivering 400/400 IDs without duplicates. Evidence `evidence/netem-gprs-full.txt` and `netem-gprs-7-200.json` is retained. No threshold or impairment parameters were relaxed. The initial client reopened SQLCipher and paid its password KDF for every operation; sync also echoed full ciphertext back to the sender. Fixed with a single serialized unlocked store per client (also exposed through flutter_rust_bridge), small bounded sync pages, asynchronous persisted receipts and sender echoes containing the verified SHA-256 of locally stored ciphertext. Recipient E2EE remains unchanged.

## Limits / still outstanding

The profile runs prove steady functioning-link delivery. Crash/lost-ACK/concurrency/DB-stop cases are executed separately in crypto/delivery/recovery/epoch tests. The profile driver does not yet mix all specified crashes, 60-second blackout, half-open reconnect, media competition and three network seeds in one fault schedule; AT-013 remains partial for that stronger combined criterion. Native GUI currently polls HTTPS; its automatic WSS-first connection manager is missing. App frame statistics in these trials cover varied Unicode messages and exclude TLS record overhead. Exact 100-character TLS/network accounting, 30-minute resource/battery checks, 1000-event sync stress and real operator trials remain unverified. Media fairness cannot pass while media is absent.

No production SLA or universal 2G claim. PRODUCTION_APPROVED=false.
