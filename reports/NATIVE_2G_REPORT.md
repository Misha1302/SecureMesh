# Native Linux 2G measurements — component gate

The executable Dart driver uses the same NativeDelivery, MeshTransport, AccountSession and Rust bridge as Flutter, with real OpenMLS/SQLCipher, TLS API and PostgreSQL. Initial DM setup uses the consented KeyPackage/Welcome API. This is not a GUI timing benchmark or an Android/carrier/battery test.

Each trial offers 200 Unicode messages in each direction (400 distinct IDs), one per second/device for GPRS and every 1.5 seconds/device for severe. Time starts before local encryption/outbox COMMIT and ends after recipient decryption/inbox COMMIT. TLS/WSS sessions are warmed before impairments. Owned disposable netem containers apply 20 kbit/s per direction / RTT 1.5s / 3% loss for GPRS and 10 kbit/s / RTT 3s / 10% loss for severe. No host network interface is changed. Raw records, counters, exact source/binary hashes and source HEAD at each launch are retained. Builds/GUI tests may run concurrently; this is shared development hardware.

| Profile | Seed | Result | p50 seconds | p95 seconds | p99 seconds | Raw evidence |
|---|---:|---|---:|---:|---:|---|
| gprs | 7 | PASS | 3.000 | 4.672 | 5.475 | [native-netem-gprs-7-200.json](evidence/native-netem-gprs-7-200.json) |
| gprs | 19 | PASS | 3.047 | 4.928 | 5.831 | [native-netem-gprs-19-200.json](evidence/native-netem-gprs-19-200.json) |
| gprs | 41 | PASS | 2.990 | 4.742 | 5.998 | [native-netem-gprs-41-200.json](evidence/native-netem-gprs-41-200.json) |
| severe | 7 | PASS | 15.375 | 42.772 | 44.931 | [native-netem-severe-7-200.json](evidence/native-netem-severe-7-200.json) |
| severe | 19 | PASS | 23.634 | 56.869 | 79.053 | [native-netem-severe-19-200.json](evidence/native-netem-severe-19-200.json) |
| severe | 41 | PASS | 32.741 | 66.886 | 69.057 | [native-netem-severe-41-200.json](evidence/native-netem-severe-41-200.json) |

GPRS gate remains p95 <=15 seconds in every full trial. Severe requires eventual delivery, with a bounded 1200-second harness watchdog and no claimed latency SLA. The raw failure from the first native seed 19 (p95 18.559 seconds) is preserved in v2-native-gprs-initial-fail.txt and native-netem-gprs-initial-19-200.json. No impairment, count or threshold was reduced. The fix removes batch-wide ACK/sync waiting: bounded writes refill independently from sync, immutable ciphertext remains in SQLCipher until durable ACK, and MLS control commits remain serial barriers.

A separate earlier severe trial delivered 400 IDs but failed to terminate with a CLOSE_WAIT socket. Both unsuccessful SDK-close variants remain FAIL; see [WEBSOCKET_CLOSE_FIX.md](WEBSOCKET_CLOSE_FIX.md). The measured fix explicitly owns and destroys the detached TLS socket after a validated Upgrade. Printed measurements from a hanging child are insufficient: the parent requires successful process exit. The gate also checks current measured transport/controller source hashes, equal binary sets across all six trials and actual raw ID/percentile consistency. It does not assert that a later rebuilt crypto binary equals the measured binary; the six trials qualify the retained 4b003dd runtime baseline. Later account-setup journal changes have separate recovery tests, not a newly claimed six-trial network run.

WSS byte counters cover application framing, not TLS/network overhead or an exact 100-character envelope. Historical Python-client figures are separate in 2G_REPORT.md. These steady-link measurements do not complete the combined 60-second blackout, lost-ACK, SIGKILL, half-open, DB interruption and competing-media schedule. AT-013 and V2-08 remain partial. No universal 2G or production claim. PRODUCTION_APPROVED=false.
