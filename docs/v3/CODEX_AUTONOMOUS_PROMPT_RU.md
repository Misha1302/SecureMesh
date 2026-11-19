# Полный автономный промпт Codex — SecureMesh V3 (19.11.2026)

Ты — lead architect + senior security/mobile/backend engineer + QA/SRE. Твоя задача — **самостоятельно довести существующий SecureMesh до максимально полного, работающего и тщательно протестированного продукта**, не подменяя факты намерениями и не снижая безопасность, приватность, производительность и надёжность. Работай в реальном репозитории **Misha1302/SecureMesh**. Не создавай заново Telegram-клон и не начинай новый проект вместо продолжения существующего. Этот текст — задание на реализацию, а не разрешение на публичный релиз.

## 0. Немедленно установить фактическое состояние

1. Сам выбери безопасный рабочий каталог: если уже есть checkout SecureMesh, проверь git remote/status/branch и используй его, не перезаписывая чужие изменения; иначе клонируй приватный https://github.com/Misha1302/SecureMesh через доступную авторизацию в отдельный каталог. Никогда не предполагай, что push/logs выполнены — проверяй.
2. Прочти последовательно AGENTS.md, README.md, STATUS.md, PLAN.md, original 00_START_HERE_RU.md и 01_TZ...10_AGENT..., docs/v2/*, docs/v3/PRODUCT_REQUIREMENTS_RU.md, ARCHITECTURE_RESEARCH_RU.md, TEST_STRATEGY_RU.md, CONFLICTS_AND_DECISIONS_RU.md, ACCEPTANCE_MATRIX.csv, текущие reports/*.md, cryptography/advisory/2G evidence, checks/*. Прочитай актуальный исходный код и текущие тесты. V1 brief и checks immutable; V3 расширяет продуктовые обязательства без послаблений исходных security gates.
3. Сними baseline: git HEAD, дерево с грязными файлами, toolchain availability .NET/Rust/Flutter/Android SDK/Xcode/Windows runner, actual Rust FFI/SQLCipher binaries, зависимости, все тесты, текущий make verify (известно ранее exit2, 24/27 PASS, RustSec+acceptance FAIL; не считай это свежим прогоном). Сохрани команды/exit codes/sha в reports/v3/baseline. Проверь, что secret material не попадает в evidence.
4. Составь проверяемый backlog с IDs FR/PL/UX/AU/MD/FEAT/NFR3 и V3-01..44; рабочую копию CSV размести reports/V3_ACCEPTANCE_MATRIX.csv со статусами из действительного evidence. Непройденный/непроверенный тест — FAIL/NOT_RUN/BLOCKED, не PASS. Зафиксируй dependency graph, конфликтующие документы, риски и критический путь в PLAN.md. Не замораживай выполнение из-за бумажного планирования.

## 1. Непереговорные инварианты

- Private DM/closed groups: настоящая E2EE, отдельные OpenMLS identities/leaves на устройстве, клиентская защита SQLCipher, operator/admin/DB/backups не расшифровывают plaintext. Никаких секретных backdoors, собственных crypto primitives, plaintext fallback, автоматического принятия ключей, отключения TLS/identity verification, фальсификации тестов, suppression RustSec.
- Public channels/posts могут быть server-readable, но явно видимо помечаются. Invite-only публичный канал не следует объявлять E2EE. Telegram — функциональный/UX референс; нельзя копировать код/ресурсы/бренд и нельзя переносить облачную модель его чатов на SecureMesh.
- 2G text/offline-first на реальном transport/controller; persistent outbox/inbox/dedup/cursor, accurate queued/ACK/delivered/read, MLS control/ACK не блокируются файлами и звонками; существующий GPRS p95<=15s и raw 200*2*3 испытания не ослаблять.
- Упрощение UX НЕ снижает security level. Account password/passkey, local unlock, device trust и encrypted recovery отдельны. Новый login на устройство не означает E2EE доверие, пароль не выдаёт old history.
- Полный продукт должен иметь настоящие Android, **iOS/iPhone**, Linux и Windows приложения, включая **две desktop версии Linux+Windows**, а также native E2E. iOS обязателен, даже если без macOS/Xcode временно BLOCKED; никогда не удаляй из scope. Сайт НЕ обязателен; не делай незащищённый private web chat.
- Группы, каналы, посты, файлы/фото, голосовые, видеокружочки, 1:1 голосовые/видеозвонки и уведомления — обязательны в FULL_PRODUCT_DONE; отсутствие хотя бы одной сохраняет PARTIAL.
- До завершённого внешнего независимого аудита и отдельного письменного решения владельца PRODUCTION_APPROVED=false. Не деплой на реальные сервера, не трогай DNS/Stores/платные услуги/ключи/аккаунты/другие репозитории. Никаких реальных персональных данных, массовых сообщений или секретов в git.
- Ни один пройденный ранее тест не удалить и не ослабить; если изменяешь gate, он должен оставаться эквивалентным/строже с явным доказательством и ADR. Не опускай sample size, network loss, latency, auth negatives ради PASS.

## 2. Организация максимально эффективной автономной работы

Сначала root-cause security, затем маленькие end-to-end вертикальные срезы, а не тысячи файлов-заглушек. Используй risk-driven TDD (red/green/refactor), contract/integration, property/fuzz, true UI E2E, chaos/failure injection, code review/security review. Храни атомарные коммиты и воспроизводимые evidence. Если доступна мультиагентность, параллелизуй только **независимые** участки через отдельные git worktrees/branches: (A) RustSec/provider/SQLCipher + security, (B) Android/iOS/Windows FFI/platform, (C) UX/account/local-unlock, (D) multi-device MLS/history, (E) backend groups/channels/media/ACL, (F) test harness/network/CI. Один интегратор владеет миграциями, crypto API, общими контрактами и merge; не запускай одновременно netem suites с общим lock/базой. Если агентов нет — исполняй последовательно.

При ограничении контекста/сессии запиши checkpoint в PLAN/STATUS/reports (точная ветка/commit, done, running, next, команды и результаты), чтобы следующий Codex resume продолжал без дублирования. Можно использовать existing tools/run_codex_autonomous.sh, если уместно, только с конечными лимитами и безопасными разрешениями; не обещай endless background execution или полный результат к конкретному времени.

## 3. План реализации с обязательными зависимостями

### Phase A — security blockers и измеримый baseline

Устрани текущие RustSec vulnerabilities по фактическим reachable dependency trees, включая libsqlite3-sys/SQLCipher bundled SQLite и crypto-bigint/libcrux-kem через совместимые поддерживаемые upstream packages/provider upgrades; запрещены игнорирование advisories, самописная криптоарифметика, plaintext storage и косметические изменения Cargo.lock. После каждого обновления full positive+negative crypto/MLS/SQLCipher tests, restart/restore, source/binary hashes, memory/CPU, native delivery performance. Проверь stale cert pin/KEY packages, code injections, key identity, push/log plaintext. Re-run latest make verify and note residual independent audit gate. Не блокируй параллельный Android spike при независимом коде.

### Phase B — настоящие native платформы

Сохрани Flutter + существующий Rust bridge. Доведи Android до реальной устанавливаемой сборки с Rust OpenMLS/SQLCipher, generated bindings, secure random and TLS, корректной local DB/permission/network lifecycle. Пройди хотя бы real emulator end-to-end, а device-specific проверки — на настоящем устройстве/спец runner. Сохрани screenshots+logs только без секретов. Предусмотри target ABIs, 16k page, minSdk/NDK и package compatibility.

Доведи Windows Flutter native build на Windows toolchain, bundling native DLLs, local Windows credential handling, install+real UI automation; не выдавай Linux-сборку за Windows.

Подготовь iOS build полностью (Xcode project, Rust static lib/FFI target, Keychain/LocalAuthentication, APNs, camera/microphone, onboarding UI) и реально запускай simulator/device tests **если имеется macOS/Xcode**. Если Mac или Apple dev account отсутствует: останови только зависимую фазу, отчёт BLOCKED с конкретной конфигурацией runner, стоимость/действия владельца без самовольных покупок, продолжай все независимые фичи. Нельзя создать «доказанный IPA» без Xcode.

Linux оставь рабочим, не ломай поддержку Wayland/X11/GTK, SQLCipher profiles и offline/recovery; сделай release-like desktop packaging и negative tests.

Для каждой платформы реальный fresh install, upgrade old profile, Rust crypto, local encrypted DB, identity key, signup 1:1 DM, offline/SIGKILL/reopen, background/permissions, visual/accessibility и perf baseline. Общий код не приравнивай к общему quality gate.

### Phase C — Telegram-подобный удобный UX без ослабления защиты

Создай реалистичную информационную архитектуру и компоненты по docs/v3 (не копируй дизайн буквально): чаты, строка поиска, новый чат/контакты, группы/каналы/публикации, composer, attachment sheet, быстрые ответы/реакции, статусы, медиа, настройки, звонки. RU+EN, light/dark, мобильные 320dp, клавиатура Windows/Linux, TalkBack/VoiceOver. Замерь реальные flows first message/device linking.

Полностью убери server URL, SQLCipher/KeyPackage/MLS jargon и dev settings из обычного onboarding; доверенный endpoint официальный и проверяется, self-host config только явно advanced с однозначной индикацией origin/keys и без bypass TLS.

Сделай **один удобный ежедневный unlock**: в secure platform storage держи wrapped high-entropy SQLCipher database unlock key (keystore/Keychain/Windows/Linux equivalent с verified user presence policies). Account auth может поддерживать passkeys/FIDO2 или пароль Argon2id, без смешивания с E2EE trust. В недоступном secure environment fallback сильной локальной passphrase, а не plain saved password. Атомарно мигрируй текущие профили, проверяй crash boundaries и сохранение прежних MLS keys/cursor/history. Истребуй security peer review на архитектуру key wrapping.

### Phase D — настоящее multi-device MLS, QR и история

Сделай экран «Подключить устройство» (trusted QR approval/SAS, short expiry, nonce/account/device/origin signed grant, independent fingerprint comparison). Начальный login -> PENDING_TRUST без private access; approval != active/MLS join. Добавляй новый **отдельный leaf** в каждую применимую личную/закрытую MLS-группу, корректно доставляй Commit/Welcome, сохраняй group epochs и outbox, разные device cursors. Локальная activation и честные pending/partial/error states. При отзыве: сессия/ACL отмена, удаление leaf из групп, rekey, уведомление о новых/удалённых ключах и недоступность будущих сообщений. Concurrent/replay/stale/rollback/unauthorised adversarial suite.

Отдельно реализуй mutually authenticated E2EE history transfer trusted-to-new device с integrity/resume, и encrypted user-held recoverable backup без ratchet cloning, TTL/view-once leakage и серверного key escrow. Zero-device recovery или явный trust reset и peer alerts; без recovery secret старая история недоступна. Не жертвуй защитой ради UI «в один клик».

### Phase E — закрытые группы, публичные каналы и посты

Доведи реальную private groups MLS с >2 людьми, ролями, invite/join/leave/ban, auth per MLS epoch/add/remove, синхронизацией на все доверенные устройства. Создай публичные и invite-only каналы с записями/подпиской, сообщениями/постами, комментариями, реакциями, поиском и moderation. Public server-readable режим виден в UI, private group encrypted и не индексируется сервером. SQL/postgres ACL, pagination, stable order, fanout pointers, quotas, anti-spam, IDOR tests. Реализуй account deletion/data export с честной семантикой локальных чужих копий.

### Phase F — медиа, голосовые, кружочки, звонки и фон

Добавь объектное хранилище dev MinIO и backend upload sessions; private files/photos/videos encrypted client-side via per-file AEAD key/chunks/manifests encrypted thumbnails, resumable upload/download, checksum, cancellation, cleanup, denial unauthorized object. Не делай серверного сканирования/транскодирования private plaintext. На 2G большие медиа отложены, текст/MLS/ACK приоритетны.

Запись микрофона/Opus и воспроизведение у другого клиента; запись камеры/ориентация/сжатие/круглое воспроизведение видеосообщения; разрешения ОС и действительные отправка/расшифровка/проигрывание. Не делать кнопки-заглушки.

Реальные 1:1 voice/video calls WebRTC + TURN, разрешённый signaling, authenticating DTLS fingerprint через peer/device identity, корректная отмена/mute/camera/reconnect; network failure state при 2G без блокировки отправки текста. APNs/FCM notification payload без plaintext/секретов и с честным background/resume (iOS silent push не гарантируется). Push dev adapters не считать реальным мобильным push PASS.

### Phase G — непрерывные реальные E2E и хаос

Реализуй docs/v3/TEST_STRATEGY_RU.md J-01..J-19 и docs/v3/ACCEPTANCE_MATRIX.csv V3-01..V3-44 на фактических build artifacts и настоящем API/PG/MLS/SQLCipher/TLS. Не заменяй сеть, криптографию и БД фиктивными adapters. Автотесты создают независимые test accounts, подтверждают email через Mailpit, добавляют устройства, общаются двумя/несколькими устройствами, отправляют 2G/3G/4G/5G, делают полный offline/coldstart, удаляют аккаунты, проверяют без доступа revoked/attacker, private/group/public, media/calls, keychain migration, backup corrupt, safe cleanup.

Network 2G historical gate: GPRS 20kbit/s RTT1.5s 3% loss seeds7/19/41 200 each direction p95<=15s. Severe10kbit/s RTT3s 10% loss same count and eventual full delivery. Объединённые ACK loss, 60s WSS+HTTPS outage, SIGKILL, PostgreSQL down, pending MLS Commit and media congestion — отдельный тест, стабильный cursor and no logical duplicates. 3G/4G/5G измеряй по документированным lab profiles (throughput/RTT/jitter/loss/handovers) и настоящим mobile conditions; не выдавай один netem профиль за реальную сеть оператора. Сохраняй raw per-ID logs, exit0, binary SHA и comparative p95, CPU/mem/battery/jank на одинаковом hardware/profile. Не допускай ухудшения старых gates и бездоказательных performance claims.

Собери CI matrix Linux, Android, Windows, macOS/iOS — independent compile/E2E statuses. Используй локальные и доступные runner без платежей. Если cloud Actions по billing не запускаются, фиксируй BLOCKED и local evidence отдельно, никогда CI PASS. Добавь unit/contract/property/fuzz/negative security/real app-level E2E, static analysis, secret scanner, deps/SBOM, artifacts provenance, restore/dry-run rollback, MASTG/MASVS mapping.

### Phase H — итоговый аудит и gate

Каждой фиче назначь Feature Verified только когда есть реальные backend+storage+client+crypto+negative tests и доказательства. Не маркируй FULL_PRODUCT_DONE пока не выполнены все четыре платформы и mandatory groups/channels/posts/files/voice/circles/calls; не повышай original P0/V2 matrices из-за частичных новых тестов. Отчёт статусами PASS/FAIL/NOT_RUN/BLOCKED, old FAIL retained. Публичный release всегда отдельно: независимый внешний crypto/mobile/infra audit и отдельное разрешение владельца. В отсутствие внешнего аудита оставь PRODUCTION_APPROVED=false и ясно укажи блокер, не объявляя автономную работу бесполезной.

## 4. Минимальный контракт каждой итерации

- Какая функция/ID/угроза и baseline (commit, measured perf, failing test).
- Код с реальной логикой и migration/compatibility consideration; тест fail-first, затем green без ослабления.
- Положительный и отрицательный case; реальный client/server flow, если нужен UI.
- Производительность: сравнение до/после на равных условиях; не регрессировать 2G, network/secret/energy.
- Результаты команд (exit code, environment, raw evidence, binary hashes), commit, review, docs, обновлённый working acceptance CSV.
- Если BLOCKED, докажи недостающий toolchain/runner/credential и продолжи независимую workstream. Не надо постоянно спрашивать согласия на обычные локальные безопасные изменения.

## 5. Отчёт и автономное продолжение

В конце каждой завершённой итерации и при выходе из сессии запиши:
1. HEAD/branch/коммиты и summary actual diffs.
2. Таблицу verified/partial/failed/blocked по V1, V2, V3 с точным evidence.
3. Реальные сборки и пути artefacts (не выдумывай APK/IPA/MSIX), versions/signing state.
4. Perf p95/message loss/CPU/bytes/battery и сравнительные baseline при одинаковых условиях.
5. Список оставшихся блокеров в dependency-order и точную следующую команду/файл для Codex resume.
6. Честную строку FINAL_STATUS и PRODUCTION_APPROVED=false до внешнего решения.

**Начинай прямо сейчас с анализа репозитория, составления фактической матрицы и устранения первого критического блокера, не останавливаясь на создании очередного плана.** Твоя задача — максимально много реального кода, тестов и проверенных вертикальных сценариев, а не имитация завершения. Не сокращай обязательную функциональность из-за ограничений одной сессии; оставляй продолжение в репозитории.
