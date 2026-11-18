# SecureMesh V2 — архитектура и транспорт

## Сохранять существующий стек
ASP.NET Core/.NET 10 modular monolith, PostgreSQL (текущая 17), Rust OpenMLS/SQLCipher, Flutter/Rust bridge, protobuf WSS and HTTPS. Не переписывать работающий delivery или crypto core с нуля. Migration-only schema changes с реальным test upgrade старой БД. Слои: account/auth, device trust/MLS directory, delivery+sync+cursors, encrypted history backup, media object broker, public channels/feed/search, moderation/admin, signaling/calls, push, ops. Ключи приватных чатов и файлов остаются исключительно у клиентов.

### Data model (проектное расширение)
users/credentials/passkeys/sessions; device identities/proofs/trust grants/revocation/transparency; conversations/memberships/MLS epoch envelopes; message ciphertext/immutable client ID/digest/sequences; per-device cursor and receipts; backup encrypted manifests+snapshots; channels/posts/subscriptions/comments/topics/reactions/permissions; public groups; upload sessions/chunk refs/media manifests/quotas; moderation reports/admin audit; notifications/abuse/calls. Для каждой сущности обязательны ACL, индексы, TTL, пагинация, quota и тест на IDOR. Клиентские приватные search indexes — только encrypted on-device.

## P0 — сохранить и завершить 2G/GPRS критерии
Исходные 40 AT и 2G критерии не снижать. GPRS: 20 kbit/s **per direction**, RTT 1.5s, loss 3%, seeds 7/19/41, **200 messages each direction per seed**, no missing IDs/logical duplicates, p95<=15s при warm session. Severe: 10 kbit/s, RTT 3s, loss 10%, same volume, eventual delivery без обязательной latency границы. Тесты реальные OpenMLS+TLS+Postgres/SQLCipher, а не моки; сырые logs IDs/tc, p50/p95/p99, binary SHA и версия окружения.

- Durable local encrypted outbox before send; immutable ciphertext/clientMessageId. Server stores envelope+outbox in one DB transaction; durable ACK after COMMIT. Lost ACK => resend same byte payload; idempotent dedup. Never silently reencrypt with same ID или сказать «отправлено» до коммита.
- Native WebSocket binary protobuf stream WSS-first, timeout/reconnect/fallback to HTTPS on blocked/broken WSS, gradual recovery and jitter/backoff; no plaintext or loss/duplicate on transport switch. Existing Flutter HTTPS polling != complete.
- Separate bounded priority queues: critical MLS control & small text, ACK/cursor, metadata; below them media; typing/presence best effort. Text priority even during upload/call. Media never auto-download on 2G, user-controlled Wi-Fi preference and adaptive media quality.
- Cursor per device/conversation, batch/backpressure/sequence/epoch rebase, sync after 60s blackout and 1000 events, lost ACK, client SIGKILL, half-open, DB restart, concurrent sends, malicious replay; protect CPU/RAM and battery. No lost durable commitments.
- Measure exact 100-character text bytes at application and TLS network layers; <=1KiB app payload is objective unless technically justified and documented. No unsafe compression with mixed secrets/attacker input.
- GPRS p95 baseline preserving existing passing tests; combined mixed-fault run independent mandatory gate, no carrier reliability claim until actual phone/EDGE field tests.

## Media/calls/public feed
Private files encrypted client-side with independent per-file random keys and AEAD chunks; keys in MLS ciphertext. S3/MinIO only opaque ciphertext; signed short-lived URLs require ACL; resumable chunked uploads and clean abandoned uploads; safe previews on client. Public media server-visible for safe transcode/moderation and CDN; strict UI mode labels.

Public channels: one post record with fanout pointers/cursor to subscribers, paging and anti-abuse; not N individual E2EE copies. Calls via WebRTC+TURN+authenticated signaling and verified identity bindings. On 2G, calls and media disabled/deprioritized, text unaffected.

## Capacity/operations
Single VPS for first staging is a *sizing hypothesis* (2–4 vCPU, 4–8GB RAM, NVMe), **not** tested capacity. Measure concurrent 100/1000/10000 websocket sessions, buffer footprint (currently 128KiB/frame receive buffer per connection), RSS/CPU/DB IO, reconnect storms, messages/day, media egress, storage/backup growth. No invented user limits. Keep PostgreSQL authoritative; Redis optional cache, no early Kafka/K8s. Offsite encrypted DB PITR/object backups with restore drills, migrations/rollbacks, metrics without private data. Reverse proxy/TLS443, SMTP+push providers, DNS/TURN/object stores/secrets and MFA only after gates.

## Platform verification
Linux running alpha, Android true native bridge/emulator/physical test, Windows build where environment, Apple signing/build only on real macOS runner, Web private E2EE only after supported/audited WASM bridge; otherwise explicitly unavailable. Build success != end-to-end functionality. RU/EN, light/dark, 320dp, screen reader, keyboard/IME, background push, large history and low battery. Separate platform PASS/BLOCKED evidence.

## Known starting blockers
See `STATUS.md` and `docs/SECURITY_LIMITATIONS.md`: RustSec advisories (crypto-bigint, libcrux-kem, libsqlite3-sys) and unmaintained proc-macro-error2; unresolved authenticated KeyPackage leasing/Welcome/real enrollment; incomplete WSS-first Flutter; mixed-fault 2G suite; browser private E2EE disabled; no release authorization. Do not suppress scanner or replace audited crypto primitives.
