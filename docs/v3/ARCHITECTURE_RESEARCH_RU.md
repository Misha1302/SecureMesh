# SecureMesh V3 — исследование архитектуры и решений, 19.11.2026

Вид документа: evidence-based design research + архитектурные рекомендации, не реализация. Фактическая отправная точка: main 25b30e0: Flutter Linux + .NET 10/PostgreSQL 17 + OpenMLS 0.9.2/SQLCipher; native WSS/protobuf + HTTPS fallback, key pinning, DM, partial device trust. STATUS.md: 4 RustSec release-blockers, нет true multi-device MLS/history, Android/iOS/Windows не квалифицированы; production запрещён. Никаких заявлений о том, что перечисленные решения уже реализованы.

## A. Исследование мультиплатформенного стека

| Вариант | Плюсы | Риски и цена смены | Решение |
|---|---|---|---|
| Flutter + существующий Rust OpenMLS/SQLCipher + .NET 10 | Общий UI Android/iOS/Linux/Windows, уже есть рабочий Linux vertical slice, один crypto core | Rust FFI/SQLCipher packaging, native SDK, background, platform keychain plugins; iOS нуждается в Mac | **Оставить; пройти отдельный spike каждой ОС** |
| Kotlin Multiplatform + Compose/SwiftUI | Более нативные platform APIs, сильная Android интеграция | Полная переделка текущего Flutter UI и integration harness, SwiftUI на iOS, Linux/Windows больше работы | Fallback только если документирован невосстановимый blocker |
| Нативно Kotlin + Swift + Desktop stack | Максимальная интеграция с OS | Четыре UI и дублирование поведения/тестов, очень высокая стоимость поддержки | Не выбирать сейчас |
| React Native/Electron/Web | Быстрые привычные web паттерны | Переписывание, увеличенная web/XSS/update поверхность; Electron не эквивалент проверенного native E2EE | Не использовать как shortcut безопасности |

Flutter официально поддерживает указанные deployment platforms, но это **не** доказательство работоспособности конкретных OpenMLS/SQLCipher/native plugins на них: https://docs.flutter.dev/reference/supported-platforms .
На iOS требуется macOS и Xcode: https://docs.flutter.dev/deployment/ios .
На Windows требуется отдельный Windows build toolchain: https://docs.flutter.dev/platform-integration/windows/setup .
Rust/Dart bridge имеет cross-platform инструменты, но именно версия/ABI реального репозитория должна пройти compile+integration+negative tests: https://github.com/fzyzcjy/flutter_rust_bridge .

### Platform spikes (до полной UI-полировки)

Android: pin Flutter/Rust/NDK/SDK versions -> build arm64 with SQLCipher/MLS -> secure random/AEAD/identity -> local encrypted store -> real TLS remote API -> two account DM -> SIGKILL/reopen -> permissions/background/push -> signed debug artifact. Проверить 16KB page size, TLS cert chain, ABI, plugin lifecycle, release stripping и dependency advisories по фактическим платформам.

iOS: macOS/Xcode runner + versions -> compile Rust static library/FFI -> simulator and physical iPhone crypto/SQLCipher/Keychain -> app lifecycle and APNs -> signed development build. Без машины/Apple доступа подготовить build scripts/CI/spec и оставить BLOCKED. Нельзя объявлять iOS DONE из Linux.

Windows: Windows runner + Visual Studio toolchain + FFI/DLL bundling, DPAPI/Hello storage where supported -> installation + real tests -> MSI/MSIX/installer options. Windows не заменяется Flutter web.

Linux: сохранив existing GTK/Xvfb, проверить libsecret lifecycle, permission/fallback, Wayland/X11, migration и упаковку. Гарантии keystore и biometrics не симметричны между платформами.

## B. Единый дизайн простого, но безопасного входа

**Четыре раздельных секрета/границы**, не смешивать:
1. Account credential: пароль+Argon2id, позднее passkey/WebAuthn. Разрешает вход в учётку, но не MLS trust.
2. Уникальная identity/device key pair: подтверждённое право нового устройства участвовать в MLS. Trusted device approval отдельно от успешного login.
3. Локальный data-encryption key (DEK) SQLCipher: случайный 256-битный ключ, защищаемый отдельным KEK через OS keystore/user-presence. Не высчитывать DEK из короткого PIN без memory-hard KDF или hardware retry protection.
4. User-held recovery secret: высокоэнтропийный ключ encrypted backup, **не** пароль аккаунта, passkey или refresh token.

Рекомендованный путь обычного пользователя:
- Первая регистрация/вход — email+password или проверенный passkey; ключи создаются один раз внутри native crypto module; DEK генерируется на устройстве и оборачивается platform-secure KEK; пользователь задаёт опциональный app lock и отдельно сохраняет recovery code.
- Последующие открытия: разблокировка устройством (Face ID/Touch ID/Android biometric/системный PIN на подходящей hardware-backed политике), без второго введённого пароля. Это **не** дополнительный серверный логин.
- Если OS secure store не отвечает требованиям или аппаратная политика недоступна: требовать надёжную отдельную локальную passphrase и объяснить причину; нельзя silently store SQLCipher key в preferences/SharedPreferences/Keychain с transferable policy без оценки риска.
- Действующий Linux профиль с локальной passphrase переносить атомарной, обратимой миграцией: сначала validate old -> создать защищённый новый DEK wrapper/сохранить ключи -> test decrypt and crash recovery -> commit state -> only then cleanup old envelope. Потерянная старая passphrase не восстанавливается через аккаунт.

Платформенные ограничения:
- Android Keystore поддерживает keys with user authentication, а BiometricPrompt может gate crypto operations: https://developer.android.com/privacy-and-security/keystore .
- iOS Keychain accessibility ThisDeviceOnly не переносит item на другой аппарат, требует отдельного trusted pairing/recovery: https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly .
- Apple Secure Enclave предоставляет аппаратно защищённые операции для **поддерживаемых** key types; нельзя утверждать, что все Ed25519/X25519/MLS secrets аппаратно неэкспортируемы: https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave .
- User presence/biometric authorization должна выполняться реально через платформу; не достаточно UI «приложить палец». Нельзя обещать off-device anti-extraction при root/jailbreak/malicious OS.
- Passkeys FIDO2 улучшают устойчивость входа к фишингу, но synced passkey может быть доступен на другом аппарате: это account credential, **не** E2EE grant, recovery и device pin. Требования account auth: https://pages.nist.gov/800-63-4/sp800-63b.html .

### Безопасный UX доверия без перегрузки

Экран нового устройства: «Войти» -> account verified -> «Подтвердите это устройство на другом устройстве» -> QR и короткий сравниваемый код. Trusted device: список/название/ожидаемый origin, QR/SAS, подтверждение; reviewer видит какие учётка, device fingerprint, expiry. Активировать только после проверки подписанного challenge, trusted proof, peer identity и local activation. В chat menu доступен понятный «Проверить безопасность» и список устройств, не MLs-термины.

Потеря всех устройств: отдельный wizard «У меня нет доступных устройств», encrypted recovery (если сохранён отдельный secret) или явный security reset с предупреждениями собеседникам. Ни email, ни пароль, ни техподдержка не выдают старую E2EE историю. QR short-lived, signed, nonce/account/device/origin/transcript binding, single-use, rate limits, clock skew bounded, replay/MITM/spoof/revocation negatives.

## C. MLS multi-device: это протокол, а не логин в аккаунт

RFC 9420 и RFC 9750 определяют клиент/устройство как криптографически отдельного участника MLS; услуга доставки не заменяет аутентификации участников. Ссылки: https://www.rfc-editor.org/rfc/rfc9420.html ; https://www.rfc-editor.org/rfc/rfc9750.html .

Выбор: **independent leaf per approved device**; не клонировать ratchet состояние для всех устройств, поскольку независимые состояния, компрометация и отзыв должны проверяться.

Контрольный pipeline:
1. New device генерирует собственные identity, MLS credentials/key packages, локальное шифрованное хранилище, создаёт PENDING_TRUST account-only session.
2. Trusted device проверяет challenge и signed grant. Сервер не может подменить contents без fail-closed; new device локально верифицирует и активирует. Реестр devices/keys содержит immutable revision и предупреждения.
3. Trusted participant добавляет новый MLS leaf в **каждую** применимую беседу, через signed Add/Commit/Welcome (всегда по политике group authorization); epoch serial-barrier и durable outbox; остальные члены получают commit и peer device event.
4. Onboarding принимает, что некоторые беседы ещё не синхронизированы; не показывает «всё готово», пока leaf не присоединён/проекция не догнала серверный cursor. Переподключение и конфликт эпохи rebase безопасны.
5. Старую историю передают отдельным end-to-end encrypted channel или snapshot backup с independent per-snapshot keys и checksum/AEAD/anti-rollback. **Не** выдавать old ratchet live secrets; не выдавать исчезающие/View Once данные сверх политики.
6. Revoke: остановить private auth и доставку на сервере; committed removal/rekey во всех беседах; соседние клиенты видят key/device change. Старые ранее прочитанные копии остаются вне контроля сервиса.
7. Identity/trust transparency не отождествлять с единственным серверным журналом. Продумать append-only proofs, independent witnesses/monitors, pin consistency, split-view alerts, restore-rollback checks. До внедрения формулировать ограниченное доверие.

Риски: 2 accounts × 3 devices означает больше MLS leaves, fanout, control traffic и проверок. Сначала замерить actual byte-size/keypackage/epoch changes и latency, затем ограничить background repair и дать control priority. Не молча пропускать устройство при проблемном upgrade.

## D. Text first / 2G performance и масштабирование

Сохраняем WSS-first protobuf, HTTPS fallback, SQLCipher outbox/inbox/cursors, bounded independent pipelining, server PG transaction boundaries; менять транспорт только при конкретных benchmark gains с сохранением negative tests. Crypto latency/serialization измеряется на самом слабом поддерживаемом телефоне.

Очереди приоритета: security-critical MLS commits, message/ACK и небольшие encrypted texts, background sync, thumbnails, voice/video/file chunks. Блокировать media starvation через лимиты, per-stream budgeting, bounded chunks/resumable; 2G автоматически откладывает autoplay/download/large upload. Не заглушать cryptographic control в пользу UI анимаций.

Baseline actual native 4b003dd: GPRS 20kbit/s/RTT1.5s/loss3%, p95 4.672/4.928/4.742s <=15s; severe 10kbit/s/RTT3s/loss10%, p95 42.772/56.869/66.886s, eventual 1200/1200 unique per class. Это Linux lab, **не Android/iOS и не оператор 2G**. Новые тесты с 3G/4G/5G должны документировать фактические RTT, jitter, loss, bandwidth, handover, power/background; speed-name alone не гарантирует radio behavior. Replay tests/zero logical duplicate/durable ACK correctness неизменны.

При UX улучшении profile mode Flutter budgets for frame build/render and real frame jank. Контроль latency до/после на одном hardware/profile/seed/commit, не сравнивать debug vs release или cold vs warm. Flutter perf guidance: https://docs.flutter.dev/perf/best-practices .

## E. Медиа, звонки и push

- Private attachment: random per-object key, authenticated chunked encryption with unique nonce policy, authenticated content manifest (sizes/digests/type), key delivered in MLS application message, encrypted private thumbnail, filesystem quarantine and atomically resumed uploads. Server checks size/ownership/id/permissions without private plaintext.
- Public attachment: server-readable by design, public conversion/search/moderation allowed with EXIF stripping and ACL.
- Voice: microphone permission at capture, supported codecs/Opus capability verified end-to-end, pause/seek, notifications/permissions, foreground/background behavior. Video circle: camera orientation/framerate/codecs measured per platform, privacy-safe thumbnails encrypted privately, real playback. No «видео работает» без recipient decryption and play.
- Voice/video calls 1:1: WebRTC with real TURN relay tests, signed authenticated signaling and binding DTLS peer fingerprint/media identity to independently authenticated device credentials, replay/reinvite and call takeover negatives; avoid casual claim that transport encryption alone gives end-to-end trust vs malicious SFU. Group calls/SFU with media E2EE have separate security gate. Fail-soft on 2G.
- Android: Doze/App Standby restrict network; use scoped privacy-safe FCM wake and sync, avoid permanent wakelocks. https://developer.android.com/training/monitoring-device-state/doze-standby .
- iOS: APNs background updates are low priority and **not guaranteed**. Use encrypted local queue + eventual sync after app wake, do not claim instantaneous background delivery. https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app .
- Push payload no private message plaintext, E2EE key, device recovery secret or sensitive membership; local display after unlock as permitted by OS and user policy.

## F. Web: решение по сравнению вариантов

1. **No web**: минимум дополнительной поверхности атаки; Linux+Windows desktop уже покрывают PC use. Рекомендованный default.
2. **Public-only site**: новости, справка, downloads, public channels/posts with correct server-readable notice. Полезно для discoverability, не создаёт опасную иллюзию E2EE.
3. **Private browser client**: потенциально возможен, **но не автоматически равен native** из-за XSS, extension injection, JS/WASM supply chain, service workers, long-lived key storage, malicious origin updates. Текущий project wasm-probe отказал, private browser disabled. Только после отдельного threat model/secure element & platform keystore compatibility analysis, independent audit, no rollback/update attacks, tests. Никакого silent downgrade до server-decryptable.

## G. Процесс разработки: TDD, XP и E2E — сравнение

- Чистое TDD для всех слоёв: помогает unit/component design, но само по себе не ловит отсутствие native library в iOS IPA или ошибочную MLS authorization в живом API. **Недостаточно**.
- XP/pair programming, continuous integration, small batches, collective ownership/refactoring: сильная дисциплина обратной связи, особенно при автономной разработке, но не заменяет независимого crypto review и mixed-network failure injection.
- Только E2E («создали аккаунт и переписываются»): наиболее близко к пользовательскому поведению, но дорого/нестабильно, сложно локализует fault.
- **Рекомендация:** risk-driven TDD at component boundary + deterministic contract/integration across .NET/Rust/Dart/SQLCipher/PG/TLS + a deliberately small set of true critical E2E journeys on every OS + property-based fuzzing + performance regression + threat-driven fault-injection + independent audit. Так получают и fast feedback, и реальную проверку пользователя; status per environment обязательный.

Flutter официальные integration tests на device/emulator и Firebase Test Lab: https://docs.flutter.dev/testing/integration-tests .
Тестовая пирамида и стоимость UI E2E: https://martinfowler.com/articles/practical-test-pyramid.html .
Мобильный security baseline: https://mas.owasp.org/MASVS/03-Using_the_MASVS/ .

## H. Безопасность / supply chain и реальные внешние зависимости

Перед любой production:
- Четыре актуальных RustSec findings (crypto-bigint, libcrux-kem, libsqlite3-sys/SQLCipher; отдельная unmaintained warning) **не игнорировать**; заменить/обновить поддерживаемым provider/storage с доказательством сохранения криптографических гарантий, тестами и actual linked versions. Cargo.lock alone не доказательство.
- CI matrix Linux/Windows/Android/macOS/iOS с independent artifacts and negative suites, explicit local vs cloud. GitHub Actions billing/spending block ранее наблюдался: не выдавать отсутствие CI за PASS.
- Threat model: malicious server admin/root+DB/object/logs, spoofed device grant, stale pinned keys, mobile backups, OS permission leak, background refresh, push metadata, file parser bombs, user deletion/tombstone, backup rollback, supply-chain malicious update.
- Device/OS compromise остаётся ограничением безопасности; открытый исходный код и воспроизводимые артефакты необходимы для доверия, но не сами по себе security certification.
- Текущая цель не разрешает deploy, Stores, DNS/secret/token changes, реальные push/email пользователям, платные runner без отдельного разрешения.

## I. Инженерные решения, требующие дополнительных измерений

1. Passkey first vs password first (влияние платформ и доступности credential managers): выбрать только после UX and threat tests.
2. Реальная политика auto-unlock и timeout на каждом OS: защищённость hardware-backed vs доступность при offline/background; явно задокументировать tradeoff.
3. Видимый интерфейс QR/SAS и room/device identity при множестве девайсов: usability tests без пропуска key verification.
4. Web private client только через gated architecture decision.
5. iOS App Store distribution и real FCM/APNs требуют учётных записей и отдельного consent; в sandbox использовать local adapters и не считать их production verified.
6. Реальные 2G carrier trials, 4G/5G radio handover и device-specific power measurements не заменяются tc/netem.
7. Коэффициенты приоритета текстового транспорта, media chunk size и concurrency не подгонять без baseline и resource study.

Заключение: переписывание проекта не нужно. Наиболее выгодная траектория — устранение security blockers, завершение per-device MLS/history и OS secure unlock, затем Android/Windows/iOS platform acceptance, после чего полнофункциональные группы/социальные функции и медиа с continuous true E2E. Этапы могут исполняться параллельно агентами **только** при независимых worktrees/interfaces, без одновременного редактирования одних и тех же critical crypto/DB schema файлов.


## J. Проверка фактических точек входа в существующем коде (GitHub main d5362d9, 19.11.2026)

Проведена инспекция **файлов репозитория**, а не сборка/запуск на этих платформах. Это карта первых конкретных изменений для Codex, не утверждение об исчерпывающем аудите.

| Файл | Подтверждённое состояние | Следующая инженерная задача |
|---|---|---|
| apps/client_flutter/android/app/build.gradle.kts | Android Flutter scaffold с placeholder applicationId com.example.securemesh_client и **debug signing в release build type** | Свой идентификатор/конфигурация, separate secure signing для будущего релиза, actual native Rust/SQLCipher packaging; debug-signed release не публиковать |
| apps/client_flutter/ios и apps/client_flutter/windows | В текущем Git tree **отсутствуют каталоги** | Сгенерировать platform runners совместимой закреплённой версией Flutter; реально собрать на macOS/Xcode и Windows toolchain; source existence ≠ platform PASS |
| apps/client_flutter/lib/local_client.dart | RustLib.init вручную открывает по умолчанию Linux libsecuremesh_crypto.so из src/crypto_core/target/debug, допускает путь через environment variable | Platform-specific verified library loading: Android .so ABI, Windows DLL, iOS static-linked symbols/framework. No fallback that skips Rust MLS. Validate signed/bundled library and release loader, without unsafe global search path |
| apps/client_flutter/pubspec.yaml | Flutter Rust bridge 2.13.0, path_provider и crypto; нет platform-local authentication/secure storage integrations в перечисленных dependencies | Evaluate native Keychain/Keystore/Hello/libsecret bridge/plugin and test security policies. Не добавлять плагин без анализа возможностей/типов ключей и fallback |
| apps/client_flutter/lib/onboarding.dart | Видимый endpoint field по умолчанию https://127.0.0.1:5088, поля account password и localPassword; на create NativeClient.open с localPassword; stateful crash recovery | Заменить видимый server config на trusted official/dev config per build, встроить secure unlock envelope и атомарную миграцию, сохранить сохранённые onboarding journal и проверку purpose/device challenges |
| apps/client_flutter/lib/native.dart | Экран open профиля по pathname+passphrase; NativeClient.open; реальный Flutter UI delivery | Default secure profile chooser/unlock и app lock, старые профили мигрировать без смены ключей; проверить offline/reopen и без plaintext/session leakage |
| src/crypto_core/src/api.rs | NativeClient.open требует строку passphrase, DB wrapped mutex; errors redacted | Изменить contract лишь после design of DEK wrapping, key lifetime, OS-bound unlock, secure zeroization и binary ABI tests на каждой ОС |
| src/crypto_core/Cargo.toml | openmls =0.9.2, rust_crypto =0.6.0, sqlite_storage=0.3.0, rusqlite bundled-sqlcipher, flutter_rust_bridge=2.13.0 | Совместимый security remediation по real transitive tree, actual bundled SQLite patch level, cross-platform link, native regression tests; не просто поменять lock |
| src/SecureMesh.Api/DeviceTrust.cs | Есть подписанные enrollment request/proof/grant/activation с pending и trusted state | Расширить QR/SAS UI и привязку identity; после grant — actual per-device MLS membership/rekey и history transfer; approval != MLS join |
| src/SecureMesh.Api/MlsDirectory.cs | Initial accepted DM via KeyPackage/Welcome, список conversations ограничен ровно двумя members (count(*)=2) | Обобщить нормализованную group/device membership модель и политики ACL/epochs с независимыми листьями устройства; отладить 1:1 multi-device/3+ member group, не ломая существующий DM |
| src/SecureMesh.Api/Program.cs | Startup явно Development only; routes identity/trust/directory/delivery/stream, migrations PG. Нет подключённых routes media/channels/calls из обязательного полного scope | Добавлять модули в modular monolith с собственными ACL, migrations, object storage и tests; не устранять production guard ради удобства демонстрации |
| Makefile; tests/gui/native_v2.py; tests/chaos-2g/* | Рабочие target'ы Linux GUI, real native network испытаний, cursor recovery, enrollment, onboarding; нет заявленных реальных Android/iOS/Windows target'ов | Переиспользовать существующие harness и добавить per-platform runners, true E2E, network trace metadata/exit/shas; нельзя подменить E2E Flutter widget-only tests |

**Непосредственный минимальный actionable patch-set для Codex:** (1) исправить RustSec без регрессии; (2) вынести Linux-only FFI loading, создать Android secure native build/test; (3) безопасная схема account/local unlock с сохранением journal; (4) QR+signed approval и MLS leaf sync; (5) Windows/iOS platform builds/CI; (6) группы/каналы/media/voice/circles/calls; (7) platform E2E. Работы могут частично идти параллельно, но общие crypto/API contracts и migrations интегрировать последовательно.

**Критически важное различие:** наличие Android scaffold — **не** готовое Android-приложение; отсутствие iOS/Windows runner — **не** основание исключать их из обязательного scope. Указанные в документе source paths и версии подтверждены чтением GitHub на этом checkpoint, но тестовые результаты берутся только из STATUS.md/reports, не из этого текстового анализа.
