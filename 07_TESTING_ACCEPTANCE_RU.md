# Проверяемая приёмка: что значит «Codex сделал весь проект»

## 1. Методика

Не считать screenshot, unit mocks или ответ «готово» доказательством работы. Каждый критический кейс — отдельный automated integration/E2E test в CI и воспроизводимая локальная команда с `stdout`, `exit code`, версиями toolchain и evidence. В отчёте статус `PASS | FAIL | NOT_RUN | BLOCKED` (не только галочки).

**P0** = блокирует delivery candidate. **P1** = обязательная функция продукта, не пропускать из финального scope; если окружение не позволяет проверить, отмечать NOT_VERIFIED и не выдавать full complete. **P2** = улучшение после рабочей основы.

## 2. Приёмочная таблица

| ID | P | Сценарий | Условия успешности |
|---|---|---|---|
| AT-001 | P0 | Fresh bootstrap | clean isolated workspace, compose, DB migrations, demo server health PASS |
| AT-002 | P0 | Registration and auth | create 2 ordinary users, login, password verify, credentials never logged, login enumeration resisted |
| AT-003 | P0 | Client device identity | two devices have independent private keys; server DB contains only public crypto material |
| AT-004 | P0 | OpenMLS 1:1 | real MLS across 2 processes/devices: encrypt/decrypt only recipient can read |
| AT-005 | P0 | Group MLS | add/remove member, epoch rekey, revoked device denied new ciphertext after rotation |
| AT-006 | P0 | E2EE metadata sanity | server/operator cannot read plaintext or private media key via DB/log/storage |
| AT-007 | P0 | Key substitution and replay | malicious key replacement leads to visible warning or explicit deny; replay rejected |
| AT-008 | P0 | Durable ACK | storage commit before ACK; kill DB before commit means message stays unsent |
| AT-009 | P0 | Exactly-once UI | lost ACK, resend same ID/payload -> one DB record and one UI event |
| AT-010 | P0 | Payload conflict | same id different digest -> conflict, not silent duplicate |
| AT-011 | P0 | Offline outbox | write offline, force-kill app, reconnect -> eventual delivery; no plaintext fallback |
| AT-012 | P0 | Cursor resume | disconnect 60s, client catches up missing events in order, ACK cursor after local persist |
| AT-013 | P0 | GPRS texts | 20 Kbit/s, RTT 1.5 s, 3% loss; 200 messages each direction, 3 seeds, no lost/duplicates |
| AT-014 | P0 | GPRS performance | p95 warm-session end-to-end <=15s; measured vs objective, not invented |
| AT-015 | P0 | Severe 2G | 10 Kbit/s, RTT 3s, 10% loss; eventual success when network usable, no SLA time |
| AT-016 | P0 | WSS fallback | blocked/broken WSS -> HTTPS sync/send; delivery semantics unchanged |
| AT-017 | P0 | Media starvation test | ongoing media upload on low bandwidth does not block text queue |
| AT-018 | P0 | Security authorization | cross-user chat, device, media and admin IDOR denied; RBAC consistently enforced |
| AT-019 | P0 | Account reset | password/email recovery does not decrypt old E2EE data without client backup/device |
| AT-020 | P0 | Private/public separation | search/moderation accesses public content only, user-report reveal explicitly opted in |
| AT-021 | P0 | Logging secrecy | structured logs/crashes never contain keys, password, plaintext private message or tokens |
| AT-022 | P0 | Backup restore | recovery isolated DB+objects, test checks consistency, no lost durable committed messages within backup policy |
| AT-023 | P0 | Supply chain | dependency/security scan, SBOM, no committed secrets, license inventory |
| AT-024 | P0 | True E2E demo | two real client sessions exchange 1:1 encrypted text via real server/Postgres and reconnect |
| AT-025 | P1 | Closed groups UI | create/invite/send/remove/rekey, real client E2E |
| AT-026 | P1 | Public channel/feed | create channel, publish/read/search/post/media, moderation, server-side ACL |
| AT-027 | P1 | Voice notes | capture Opus or supported codec, encrypt, upload, download, playback, interrupted resume |
| AT-028 | P1 | Video circles | record, round display, encrypt, transfer, play; secure permissions |
| AT-029 | P1 | Attachments | images/GIF/video/documents, multipart resume, size/checksums, encryption for private |
| AT-030 | P1 | One-to-one calls | real WebRTC signaling/TURN test in test network and native client, deny unauthorized call |
| AT-031 | P1 | UI/accessibility | login/chats/communities/profile/settings/admin, RU+EN, light/dark, automated UI checks |
| AT-032 | P1 | Multi-device | multiple independent keys, device revocation, per-device sync and receipts |
| AT-033 | P1 | Moderation | public reporting, admin MFA/RBAC, immutable audit trail for actions |
| AT-034 | P1 | Web crypto compatibility | real wasm OpenMLS native/wave test; otherwise web private disabled + limitation explicitly reported |
| AT-035 | P1 | Android client | Android build + emulator/device E2E if SDK/emulator available; no fabricated verification |
| AT-036 | P1 | Linux desktop client | build and launch Linux desktop through smoke or screenshot test |
| AT-037 | P1 | iOS/macOS | build/test on mac runner if available; otherwise UNVERIFIED with setup steps |
| AT-038 | P0 | Ops handoff | deploy templates/config, smoke, backups, rollback, commands documented; no real prod changes |
| AT-039 | P1 | Slow network envelope size | stats app bytes and TLS bytes for 100-byte message, compare objective <=1 KiB app payload |
| AT-040 | P0 | Reconnect and MLS ordering | concurrent epoch commit conflicts, resolve correctly, no permanent stuck clients |

## 3. Отказоустойчивость / хаос

- Crash client at (before local persist / after persist / before encrypt / after encrypt / before network / server after insert / before ACK / after ACK / before recipient local commit / after local commit); verify deterministic consistency.
- Two senders concurrently create messages, random duplicated events; verify ordering, no overwritten device cursor.
- DB restart, Redis unavailable, S3 timeout; server must not turn ephemeral state into false durable ACK.
- Backpressure: slow consumer, hundreds of queued events; bounded memory, pagination and rate limit, no unbounded array.
- JWT revoked/expired in active WSS; fail authentication and reconnect safely.

## 4. Угроза злоупотреблений

Тестировать unauthenticated registration rate limits, OTP/enumeration, untrusted avatar/media, large gzip bombs, user search enumeration, spoofed keys, sealed filename traversal, file quota bypass, unauthorized public/private data fetch. No insecure demonstration endpoints in release mode.

## 5. Отчёт о качестве

Рабочая матрица — `reports/ACCEPTANCE_MATRIX.csv` (копия исходного неизменяемого `checks/ACCEPTANCE_MATRIX.csv` с фактическими статусами). `reports/TEST_RESULTS.md` должен включать таблицу по всем AT-001...AT-040, команды, даты и platform. `reports/2G_REPORT.md`: environment, seed, profiles, distribution of delivery times (p50/p95/p99), app bytes/network bytes, duplicates, losses, notable failures and fixes. `reports/CRYPTO_REVIEW.md`: actual library version, files that handle key operations, threat model, platform limitations, list of code that was not audited.

В итоговом заключении разделять:
- Implemented and tested on real process/device;
- Implemented but unverified in this environment;
- Missing/partial;
- Blocked by credentials/device/independent audit.

Никакой отчёт не должен содержать подставные нули, моковые `PASS`, преждевременные слова «production ready», «невозможно взломать», «официально аудитировано».

## 6. Действительные критерии доставки владельцу

У Codex есть право считать **локальный delivery candidate** сформированным, если AT P0 зелёные, P1 реализованы и соответствующие platform limitations указаны, выполняются `make demo` и `make verify`, а остаточные security risks перечислены. Это всё ещё не authorisation to deploy. Если P0 не зелёные, код и отчёт всё равно передаются, но статус `PARTIAL / NOT_READY`, а не «проект готов».
