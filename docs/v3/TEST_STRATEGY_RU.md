# SecureMesh V3 — стратегия TDD/XP, E2E и сравнительной приёмки

Статус: предписание по разработке/валидации, **не свидетельство выполненных испытаний**. Совместить с неприкосновенными исходными AT-001..040, docs/v2/04_ACCEPTANCE_ROADMAP_RU.md и reports/TEST_RESULTS.md. Рабочая V3 матрица: docs/v3/ACCEPTANCE_MATRIX.csv (шаблон), копировать в reports/V3_ACCEPTANCE_MATRIX.csv, по умолчанию NOT_RUN. Для каждого прохода нужны реальное действие, независимая проверка и сырой evidence.

## 1. Метод, а не новая архитектура приложения

**Рекомендация: TDD + XP engineering practices + contract tests + selective whole-stack E2E + adversarial/security testing + deterministic network chaos.**
- Red/Green/Refactor для каждого изменяемого функционального модуля, приписывая тест к публичному наблюдаемому поведению, не к классу/внутреннему SQL.
- Небольшие вертикальные инкременты: schema/API/Rust/Dart/native UI + negative tests + migrations/docs. Нельзя написать только UI и объявить фичу завершённой.
- CI как постоянно воспроизводимое доказательство, быстрое tier-0 на каждый коммит, более тяжёлое tier-1/2 по расписанию/перед merge, security/fault/real-device отдельно по релизным гейтам.
- Pair review/второй агент для architectural/security code review; **не** подменяет независимый внешний аудит. Избегать двух автономных агентов, редактирующих один crypto/DB файл без интегратора.
- Тестовые сценарии stateful/happy/negative. Там, где E2E слишком медленный, передвинуть edge cases в property-based/unit/integration, оставить несколько главных настоящих пользовательских путей.

## 2. Пирамида

Tier 0 — fast (<resource-defined budget; измерить): .NET tests, cargo tests, dart tests/format/analyze, static types, code generation check, pure authorization state machine, deterministic crypto vectors, RFC/protocol bounded parsers, serializers, UI widget accessibility, schema compatibility. Жёсткие assertion, отсутствие test skip без письменного blocked evidence.

Tier 1 — real integration: Testcontainers/Compose PostgreSQL migrations + API TLS + email Mailpit + independent OpenMLS/SQLCipher native processes + Flutter Rust bridge, direct negative auth, alternate KeyPackages, timeouts, restart/restore, push mocked transport but real payload policy. Никаких «mocked messages» или plaintext projection вместо E2EE.

Tier 2 — **true whole-stack E2E**: сборки Android, iOS, Linux, Windows запускают UI automation against actual isolated API/PG/MLS. Account signup, verify, login, device approval, chats and media/calls; backend проверяется independent DB queries/other native device, а не видимостью пузырька у отправителя. Синтетические email и deterministic test transport, без обращения к живым людям или prod. Flutter integration_test + per-platform harness; Android emulator/physical; iOS simulator/physical on Mac; Linux GTK/Xvfb; Windows UI runner. Пасс на Linux не значит Android/iOS/Windows PASS.

Tier 3 — extended reliability/security: property tests, fuzz, malicious server, key substitution/MITM, decryption negative, file parser/resource quotas, memory/secret scans, dependency audits, multiple devices and group epoch races, deterministic chaos/cpu/battery/load. Независимые security audits — отдельная внешняя release обязанность; local tools не заменяют её.

## 3. True user journeys: acceptance scenario definitions

J-01 **Создать учётку**: install clean client -> язык -> signup -> email verification in Mailpit -> login -> local store unlock initialized -> confirm no server URL/no second manual passphrase on supported keystore -> check server identity bound to account/device; wrong code and retries negative.

J-02 **Зайти и удалить**: logout/reopen/login -> account security settings -> delete own account with confirmation -> verify sessions/device grants revoked, user no longer searchable/authorizable, queued messages not delivered, storage deletion/tombstones per policy; others' local plaintext copies explicitly out of scope. Isolated fixtures only.

J-03 **Переписка 1:1**: independent A1/B1 accounts -> username request/consent -> verify fingerprints independent channel -> text Unicode, multi-line, emoji, offline send -> durable ACK (server), device receipt, optional read correct; same ID double-submit once; changed ciphertext 409; unauthorized C cannot read/chat.

J-04 **Низкая скорость**: J-03 with netem GPRS20kbit/s RTT1.5s loss3% and severe10kbit/s RTT3s loss10%; all 200 each direction for seeds7/19/41; GPRS p95 <=15s gate, severe eventual delivery; raw unique IDs and actual decrypt/inbox COMMIT; no hidden decrement of load. Compare with retained six-trial baseline 4b003dd. Additional combined 60s blackout+lostACK+halfopen+SIGKILL+DB failure+competing encrypted media: zero logical losses/dupes, text priority and eventual recovery. New code must re-run gates, not rely only on old binary.

J-05 **Сети 3G/4G/5G/Wi-Fi**: define documented bandwidth/RTT/jitter/loss/reorder profiles based on transparent source/measurements, no made-up universal carrier SLA. Run J-03 on each with reconnect, roaming/handovers, WiFi<->cellular, 0 network, high latency/no buffer, offline/cold-start. Capture frame/layer bytes, CPU/memory, battery proxy, peak memory, p50/p95/p99, loss, duplication, reconnect. At least one real device/carrier per supported platform where feasible; lab profile ≠ real radio qualification.

J-06 **Привязать устройство**: A1 trusted; A2 login account-only and cannot private fetch; displays signed QR bound to fingerprint/origin/device/nonce/expiry; A1 independently verifies and approves; A2 verifies grant and activates; assert A2 new separate MLS leaf and future private messages from B1 arrive and decrypt both A1/A2; A1 offline/restart, lost replies/duplicates do not double add; wrong QR, copied grant, server injection, unknown member, timeout reject.

J-07 **Старая история и recovery**: A2 newly joined sees no old history by password/passkey alone; authenticated E2EE transfer from A1 -> eligible old messages restored with matching authenticated manifest, no live ratchet clone; backup from user-held secret restores with integrity/anti-rollback; lost devices+no key -> no old plaintext and explicit security reset notice. Wrong passphrase/key, modified chunks, old snapshot, revoked device fail.

J-08 **Отозвать и скомпрометировать**: A1 revokes A2 -> pending private auth denied immediately, group epochs committed/remove/rekey, B1 sees device change, A2 cannot decrypt future messages; pre-revoke snapshots can't be remotely erased. Concurrent send/add/revoke/race/epoch conflicts tested.

J-09 **Группы**: create private A/B/C devices (>=3 humans) -> invite, join, add/remove, role permissions, key rotation, asynchronous offline reconnect, replay/tamper rejection, wrong-key and stale epoch; exact recipient set+membership no server plaintext. Run with A1/A2 and B1 at least.

J-10 **Каналы/посты**: public vs invite-only channel -> owner creates/publishes, edits, schedules, pins, reacts, comments, subscribes, finds public, leaves, deletes; unauthorized/moderator ACL negative; public content always labelled readable to server, private chat never global searchable.

J-11 **Файлы и фотографии**: send client-side E2EE small/large file and photo A->B, compare independent hash after decrypt, test resumes, chunk corruption/replay, duplicate upload, unauthorized URL, cancellation/retry, orphan cleanup, EXIF removal for public preview, private thumbnail still encrypted.

J-12 **Голосовые и кружочки**: actual microphone/camera permissions, record voice -> Opus encode -> send -> decrypt -> recipient plays/seek; record circle video -> preview/cancel/encode -> send -> decrypt -> circle play with orientation; denied permission, background, SIGKILL, 2G media deferral. Encoder/codec must be exercised in production path, not just UI screenshots.

J-13 **Звонки**: A1->B1 outgoing incoming/accept/reject/cancel and hangup, WebRTC real ICE/STUN/TURN relay mode, authenticated DTLS identity binding vs malicious signaling, mute/camera switch/reconnect, NAT/timeout, 2G graceful unavailability without stalling text. End-to-end call privacy claims require explicit peer verification.

J-14 **Уведомления и фон**: Android Doze/AppStandby, iOS background APNs caveats, app closed/reopened, no plaintext in FCM/APNs payload/logs, deferred fetch after app is resumed, eventual message decryption correct; must distinguish push delivery/notification from actual app E2EE inbox acknowledgement.

J-15 **Безопасное упрощение входа**: existing Linux encrypted profile migrates exactly once to OS-bound DEK wrapper and reopens with same device keys/MLS history; break/power loss before/after COMMIT, hardware unavailable, wrong biometric/PIN, keychain wiped, credential enrolled/removed, OS upgrade, locked device, multi-user machine. No silent insecure fallback. Password reset never grants old E2EE.

J-16 **Аутентификация и админ**: Argon2id, lockout/rate limiting, malicious challenge swap/invalid TLS, CSRF/CORS/authz, admin MFA, IDOR on all private/public/media/call endpoints, banned/blocked/unknown user behavior, recovery/admin cannot E2EE decrypt.

J-17 **Кросс-OS и обновление**: for each Android/iOS/Linux/Windows: install, upgrade existing DB, signed/known source binary, registration/DM/revoke/media/test after app version upgrade, running without developer SDK, OS keystore and permission policy; test from clean and upgraded versions separately.

J-18 **Полный отказ**: fresh/upgrade schema, DB + object/backup restore and keyring scope, 60s blackout and 1000 ordered IDs with persisted cursor+server receipt, server reboot/multiple workers, resource pressure; confirm no unacked false-success, no private leak, recoverable consistent state.

J-19 **UX acceptance**: independent testers can find new chat, see trust warning, link device, send voice/circle, distinguish public channel from E2EE, locate security/privacy without server settings, not required to understand KeyPackage/SQLCipher. Screen readers and 320dp/desktop keyboard; security warning comprehension and destructive action confirmations checked. No screenshot/golden alone counts as end-to-end.

## 4. Network lab: reproducibility contract

Each run records app/platform OS+version, hardware/device kind, Flutter/Dart/Rust/.NET versions, commit, actual binary SHA, actual FFI linked package versions, seed, netem configuration, sample size, actual child exit, total payload sizes (app and TLS/network accounted separately), success/error/timeout, percentile definition and measurement boundaries.

Profiles (reference, not promises):
- GPRS historical gate: each direction 20 kbit/s, RTT 1500 ms, packet loss 3%, 200 msgs per direction, seeds7/19/41, p95 <=15s.
- Severe historical gate: each direction 10 kbit/s, RTT 3000 ms, loss10%, same 200 × 2 × 3, eventual delivery. No latency p95 SLA.
- OFFLINE: blocked WSS and HTTPS 60s, no false delivery ACK; after restore 1000 distinct decrypted IDs, no loss/duplicate and persisted cursor.
- 3G/4G/5G: **parameterized profiles derived from measured traces/declared scenario**, include RTT/jitter/loss/reorder/bandwidth and radio handover; do not label arbitrary netem numbers «real 5G».
- MIXED: low bandwidth + large media upload + control Commit + 100-character text + outbox recovery + process kill/restart + server DB interruption. Text/ACK priority protected; crypto-bound/auth denied fail closed.

Use isolated disposable netns/containers and locks for impairment; do not alter host NIC, VPN, production network. No heuristic pass by lowering sample counts or ignoring pending child exit. Failure raw logs retained and regression minimization uses the original seed plus randomized seeds.

**Performance nonregression**: baseline commit/binary/platform/hardware/profile and candidate run paired, equivalent hot/cold, compare exact p50/p95/p99, CPU/mem/energy proxy, UI frame jank, message overhead/bytes. Existing absolute GPRS gate non-negotiable; candidate vs baseline degradation triggers investigation. New quantitative budgets fixed from baseline and risk assessment before feature rollout; no ungrounded zero-percent guaranteed across all hardware. Separate benchmarks for auth/unlock cold start, MLS add/rekey scaling to devices and group size, media fairness, account deletion latency.

## 5. Security/security-negative library

Red team simulations:
- malicious operator with DB, media store, backups, admin/root, crash logs, push logs cannot recover private plaintext, session and recovery keys (scope explicit).
- swap key package/identity/device grant/Welcome/group epoch, replay/counter rollback, invalid signature/nonce/expiry, truncated/oversized protobuf/MLS, TLS invalid cert/hostname, MITM no plaintext fallback.
- unknown/blocked/revoked third party, abusive rate/IDOR; public/private cross-scope leakage in search, media URL, notifications and admin UI.
- password/local keystore migration and recovery tamper test; no secret in preference files, platform backups, local logs, copied clipboard, crash reports.
- file bombs (size/codec/mime, malformed chunks, EXIF), resource limits, voice/video call signaling impersonation, background/OS lock auth changes.
- supply chain RustSec/Cargo, NuGet, Pub/OSV, license/SBOM, pinned dependencies, reproducible build provenance, artifact scan.

OWASP MASVS/MASWE coverage mapping in reports; scans are evidence only for tested dependencies; independent cryptographic and mobile application assessment separate public gate.

## 6. CI delivery matrix and infrastructure dependencies

| Scope | Local fast | Actual host |
|---|---|---|
| .NET/Rust/Dart unit/property | Linux + CI | Linux runner |
| API/PG/MLS integration, chaos | isolated Compose netns | Linux runner |
| Flutter Linux UI and upgrade | Xvfb + real TLS | Linux runner |
| Android compile and UI automation | Android SDK/emulator + ADB | Linux Android runner; device farm for physical |
| Windows compile/native UI | cannot assert via Linux only | Windows runner |
| iOS compile/native UI | cannot assert via Linux | macOS/Xcode runner, iOS simulator, physical iPhone for device gate |
| Store/distribution signing | NOT_RUN until owner approval | dedicated secrets/authorized platform accounts |
| Independent security audit | BLOCKED pending external specialists | audit evidence from third party |

CI badge is only valid if workflows actually ran. GitHub Actions billing/spending limits can block runner before steps: mark BLOCKED, run local gates, record actual error; never call this cloud PASS. Avoid treating iOS blocked as an optional exclusion from final product.

Suggested orchestration interfaces (to implement, not currently claimed): make test-unit; make test-contract; make e2e-linux; make e2e-android; make e2e-windows; make e2e-ios; make e2e-net-gprs; make e2e-net-severe; make e2e-net-3g; make e2e-net-4g; make e2e-net-5g; make e2e-security; make verify-v3; make report-v3. Names may be adapted to existing Makefile but must be documented and stable.

## 7. Report schema, reproducibility and status

Working acceptance CSV in reports: ID, title, priority, status PASS|FAIL|NOT_RUN|BLOCKED, commit, artifact/runner/device, evidence path+sha, seed, environment, command, exit, notes. A photo, compile log, written plan, unit-only PASS or mock server receipt does not mark multi-device E2E PASS. Retain raw FAIL and follow-up evidence; do not overwrite. Expose original AT, V2 and V3 matrices simultaneously.

For each PR/feature: spec link -> fail-first test -> actual implementation -> exact commands/logs -> safety/perf diff -> peer review -> matrix updated. Keep explicit false for PRODUCTION_APPROVED until separate user authorization after independent audits, backup/restore/load/ops review. No automatic production deploy or real user data.

Sources: Flutter integration test docs https://docs.flutter.dev/testing/integration-tests ; MLS protocol https://www.rfc-editor.org/rfc/rfc9420.html ; MLS architecture https://www.rfc-editor.org/rfc/rfc9750.html ; OWASP MASVS https://mas.owasp.org/MASVS/03-Using_the_MASVS/ ; Test pyramid https://martinfowler.com/articles/practical-test-pyramid.html ; Android power/background https://developer.android.com/training/monitoring-device-state/doze-standby ; Apple push constraints https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app .
