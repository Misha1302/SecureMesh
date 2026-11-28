# Native Linux blackout trial

Run this separately from the steady-link trials, with the same local Linux fixture. It uses Docker Compose netem containers with NET_ADMIN, iproute2 with seeded netem support, the local PostgreSQL and test mail services, Debug API and Rust binaries, a TLS fixture, generated wire bindings and the Flutter Dart SDK. The Dart driver uses NativeDelivery, MeshTransport, FRB, OpenMLS and SQLCipher.

```sh
.local/venv/bin/python tests/chaos-2g/native_run.py --outage --seeds 7 --count 10
```

The default run uses seeds 7, 19 and 41. Each direction starts with three messages over the EDGE laboratory profile (100 kbit/s per direction, 600 ms RTT, 1% loss per leg). After the recipients commit all six decrypted messages and both sender outboxes drain, the harness applies 100% loss on both routes for at least 60 seconds. It then restores the same EDGE settings. The clients continue running while the new batch enters their SQLCipher outboxes. The harness checks the exact queued IDs twice, checks that the API database still contains only the baseline messages before restoration and compares its final message IDs with both recipients' records.

The criterion set before measurement is zero missing, unexpected or duplicate IDs and a recovery p95 of at most 45 seconds. The budget allows up to 30 seconds of current retry backoff plus 15 seconds of EDGE catch-up for the default seven queued messages per direction. Recovery time starts just before the first route is restored and ends after the recipient commits the decrypted message. It excludes the 60-second hold, includes network reconfiguration and is reported separately from end-to-end delivery. Each JSON result includes the qdisc settings at cutoff and restoration, minimum blackout duration, measured timestamps by message ID, build hashes and the process exit status.

Use the standard checkout's netem lock and Compose project if running from another worktree. The host ports 5090, 15990 and 15991 are shared with other network trials. The default 20-message run covers this standalone outage. The combined interruption schedule, the 1000-message offline qualification and physical radio tests remain separate.
