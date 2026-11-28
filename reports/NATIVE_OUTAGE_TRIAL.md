# Native Linux blackout trial

Run this separately from the steady-link trials, with the same local Linux fixture. It uses Docker Compose netem containers with NET_ADMIN, iproute2 with seeded netem support, the local PostgreSQL and test mail services, Debug API and Rust binaries, a TLS fixture, generated wire bindings and the Flutter Dart SDK. The Dart driver uses NativeDelivery, MeshTransport, FRB, OpenMLS and SQLCipher.

```sh
.local/venv/bin/python tests/chaos-2g/native_run.py --outage --seeds 7 --count 10
```

The default run uses seeds 7, 19 and 41. Each direction starts with three messages over the EDGE laboratory profile (100 kbit/s per direction, 600 ms RTT, 1% loss per leg). After the recipients commit all six decrypted messages and both sender outboxes drain, the harness applies 100% loss on both routes for at least 60 seconds. It then restores the same EDGE settings. The clients continue running while the new batch enters their SQLCipher outboxes. The harness checks the exact queued IDs twice, checks that the API database still contains only the baseline messages before restoration and compares its final message IDs with both recipients' records.

The criterion set before measurement is zero missing, unexpected or duplicate IDs and a recovery p95 of at most 45 seconds. The budget allows up to 30 seconds of current retry backoff plus 15 seconds of EDGE catch-up for the default seven queued messages per direction. Recovery time starts just before the first route is restored and ends after the recipient commits the decrypted message. It excludes the 60-second hold, includes network reconfiguration and is reported separately from end-to-end delivery. Each JSON result includes the qdisc settings at cutoff and restoration, minimum blackout duration, measured timestamps by message ID, build hashes and the process exit status.

Use the standard checkout's netem lock and Compose project if running from another worktree. The host ports 5090, 15990 and 15991 are shared with other network trials. The default 20-message run covers this standalone outage. The combined interruption schedule, the offline sender backlog trial below and physical radio tests remain separate.

## Observed results

All three seeds passed with 10 messages per direction on implementation `4b2a73d`, which includes the active polling change `b274d89`. Source, executable and library hashes match across all three trials. Each cutoff dropped packets on both routes. PostgreSQL held six baseline rows before restoration and each sender retained seven offline messages. After restoration the server and recipients accounted for all 20 unique message IDs, with zero missing, duplicate or unexpected IDs in each trial.

| Seed | Minimum concurrent blackout (s) | Recovery p50 (s) | Recovery p95 (s) | Recovery p99 (s) | Raw evidence |
|---:|---:|---:|---:|---:|--- |
| 7 | 60.81 | 14.61 | 15.51 | 15.51 | [JSON](evidence/native-netem-edge-outage-7-10.json) |
| 19 | 60.41 | 6.63 | 10.11 | 10.11 | [JSON](evidence/native-netem-edge-outage-19-10.json) |
| 41 | 60.48 | 10.08 | 13.88 | 13.88 | [JSON](evidence/native-netem-edge-outage-41-10.json) |

## Offline sender backlog qualification

The native backlog trial measures queue recovery after a sender process dies
with 1,000 unsent messages. It uses a functioning local TLS link to a real API
and isolated PostgreSQL database. The producer queues without a transport, then
is killed after the 1,000th SQLCipher write returns. Fresh native Dart transport
instances reopen the two SQLCipher stores and use the ordinary delivery pump.

Before running, the gates are zero missing, unexpected or duplicate IDs in the
server and recipient stores, matching decrypted Unicode content and application
epoch, an empty sender outbox, and local and server-side processed cursors at
the end of the backlog. The API must have zero conversation messages before
replay. Replay must cross at least two recipient sync pages and finish within
180 seconds. Recovery p50, p95 and p99 are measured from native replay start to
the first durable recipient ingest of each ID. The 180-second limit is a
loopback qualification budget for the complete batch, including retries.
The trial uses one established MLS epoch. Traffic shaping, a live epoch
transition during recovery and device or operator performance are separate.

Run with the local API and native Rust Debug artifacts, Dart package resolution,
TLS fixture, test mail service and PostgreSQL running:

```sh
.local/venv/bin/python tests/integration/native_offline_backlog.py
```

The coordinator uses a dedicated database and TLS API port 5295, configurable
via `SECUREMESH_TEST_URLS`. Use the established Compose project name when
running from another worktree. The driver validates live cursor-paged ingestion.
The coordinator then reopens the SQLCipher stores independently, checks exact
recipient order against the PostgreSQL sequence, and retransmits three original
envelopes to verify stable durable ACKs and an unchanged server row set.
