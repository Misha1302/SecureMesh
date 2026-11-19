# SecureMesh V3 — уточнённое техническое задание (19.11.2026)

Статус: NORMATIVE PRODUCT REQUIREMENTS, цель полного продукта, **НЕ отчёт об реализации**. Применяется совместно с оригинальными 01_TZ_PRODUCT_RU.md, 04_SECURITY_E2EE_RU.md, 07_TESTING_ACCEPTANCE_RU.md, docs/v2/*, STATUS.md и reports/*. Исходные брифы, checks и V2 остаются неизменными. Существующие требования к E2EE, 2G, аудиту, секретам и P0 **не ослабляются**. В случае конфликта новых продуктовых приоритетов/поддерживаемых платформ с прежним роадмапом приоритет имеет V3; требования безопасности, подтверждённые отрицательными тестами и release gates суммируются.

## 0. Принятые решения по запросу владельца

1. Целевые полноценные клиенты: **Android, iOS/iPhone, Linux, Windows**. Это четыре платформы, включая **две настольные версии: Linux и Windows**. Ни один клиент нельзя объявлять готовым без собственного собираемого артефакта и реальных проверок. iOS обязателен в финальном скоупе, но macOS/Xcode и signing/TestFlight требуют отдельной среды; при отсутствии этой среды статус BLOCKED, а не DONE и не «выкинули iOS». macOS desktop — дополнение при наличии среды, не замена iOS.
2. Flutter + существующий Rust OpenMLS/SQLCipher + .NET API сохраняются, если эксперимент не докажет непреодолимого platform blocker; не переписывать стек ради моды.
3. UX по моделям взаимодействия максимально знаком пользователю Telegram: список чатов, создание/поиск диалога, свайпы/контекстные действия, ответ/реакции/редактирование, группы/каналы/посты, прикрепление/камера/микрофон, звонки, список устройств и настройки приватности. **Не копировать чужой код, бренд, иконки, ресурсы или пиксель-в-пиксель дизайн.** Криптографические гарантии SecureMesh отличны от облачных чатов Telegram и не должны подменяться привычным видом.
4. В обычном приложении не показывать ввод адреса сервера, TLS настройки, URL API, KeyPackage, epoch, SQLCipher, сетевые параметры. Нужные серверные endpoint и trust anchors определяются проверяемой конфигурацией официальной сборки. Self-host и диагностика — отдельно обозначенная Advanced/Developer секция; никогда не отключать TLS validation, pinning/identity verification, E2EE, не делать переключение на злоумышленный сервер незаметным.
5. Один понятный ежедневный вход. По возможности passkey/FIDO2 для **аутентификации аккаунта**, OS biometric/PIN для **локальной разблокировки** ключа хранилища; сильный пароль аккаунта — поддерживаемый fallback; отдельный высокоэнтропийный recovery secret для E2EE-архива. Важно: passkey, email, пароль аккаунта, biometrics и refresh-токен **не** дают автоматически доверие новому MLS-устройству и не восстанавливают переписки. Для отказа платформы от безопасного keystore нужен честный fallback с локальным секретом, а не постоянный открытый ключ или небезопасный автологин.
6. Настоящие дополнительные устройства P0: быстрый QR + подтверждение на действующем доверенном устройстве, отдельные device keys и MLS leaves, синхронизация будущих сообщений, отзыв/rekey; перенос прошлой истории — только end-to-end transfer или recovery key, без владения сервером расшифровкой.
7. Группы, каналы, посты, файлы, фото, голосовые, видеокружочки, 1:1 аудио-/видеозвонки и корректные уведомления — **обязательная функциональность полного продукта**, а не необязательная витрина. Зависимости реализации определяют фазы; никакой release FULL_PRODUCT_DONE без завершения и E2E подтверждения.
8. Web не обязателен. При отсутствии отдельно квалифицированной безопасной browser E2EE интеграции приватный web chat отключён; допускается отдельная публичная страница/справка/каналы с явной маркировкой и серверной модерацией. Нативные Linux и Windows не подменяются web wrapper.
9. Процесс — risk-driven TDD + CI + contract/integration + E2E на реальных компонентах + property/fuzz + fault-injection. «TDD» — подход к разработке, **не** архитектура шифрования и не доказательство защищённости.
10. Ни один шаг UX не имеет права ухудшить уровень E2EE, защиту ключей, корректность доставки, недопущение потерь/дублей или ранее измеренную 2G латентность. Регрессы оцениваются в эквивалентных условиях, с одинаковыми версиями и профилями; без измерений «не замедлилось» не заявлять.

## 1. Полный набор требований V3 с ID

### Платформы — PL

- PL-01 [P0] Android: installable signed-by-dev/CI debug/release candidate APK/AAB, ABI arm64 минимум, реальные регистрации, crypto native, SQLCipher, push, background, камера/микрофон, медиа, сети, минимум emulator + физическое устройство для mobile acceptance; артефакт содержит проверенную Rust библиотеку. Не объявлять Store-ready без оформления.
- PL-02 [P0] iOS/iPhone: реальный Xcode build на macOS, simulator + device/подписанный test artifact, Keychain, local auth, APNs, background, crypto bridge, камера/микрофон, тесты; без Mac и Apple setup подготовить исходники/CI, поставить BLOCKED и указать конкретные действия владельца. Никаких фиктивных IPA.
- PL-03 [P0] Linux: уже имеющийся GTK клиент, Xvfb + real interactive E2E; стандартное пакетирование, secrets через доступный системный secret service, fallback при отсутствии — без ослабления защиты.
- PL-04 [P0] Windows: отдельная Windows сборка/runner и настоящий native E2E, пакетирование, Windows credential protection/Hello where possible, проверенная FFI/SQLCipher/Rust. Linux-кросс-сборка не является Windows PASS.
- PL-05 [P1] Общие Flutter экраны/состояния и transport/crypto contracts должны быть одинаковы. Специфические OS permissions, background policies, protected storage и accessibility тестируются на платформе, не предполагаются автоматически.
- PL-06 [CONDITIONAL] Web: отдельный security decision/gate, public-only допустим; private web only после независимого browser threat model, устойчивого identity/key storage, supply-chain/XSS/extension/update attack review и end-to-end tests. Не делать plaintext fallback.

### UX — UX

- UX-01 [P0] Первый запуск: язык -> приветствие -> создать аккаунт/войти; адрес сервера скрыт, никакого технического жаргона, предсказуемые разрешения только по необходимости.
- UX-02 [P0] Onboarding: username/email/password или passkey при поддержке, подтверждение email; по успешной авторизации ключи создаются/открываются безопасно без ручного ввода двух паролей в штатном сценарии. Существующие профили мигрируются без потери истории; миграция атомарна/обратима и протестирована на краш.
- UX-03 [P0] Главная: чаты (персональные, закрытые группы, публичные группы, каналы), поиск, непрочитанные, непрерывная прокрутка, закрепления, mute, ясные статусы доставлено/ожидает/прочитано. Mobile навигация с привычными жестами, desktop горячие клавиши/drag-drop.
- UX-04 [P0] Создание чата по username, запрос/согласие и понятная проверка идентичности с отдельным предупреждением о смене ключей. Нельзя скрыть/автоподтвердить unsafe trust action ради UX.
- UX-05 [P0] Настройки по умолчанию: профиль, уведомления, приватность и безопасность, устройства, хранение и сеть, помощь; серверная/разработческая конфигурация доступна только явно и защищённо. Разрешено скрывать сложность, **запрещено** скрывать значимую для безопасности информацию.
- UX-06 [P0] Device management: «Подключить устройство» -> QR на новом -> скан/сравнение и подтверждение на доверенном -> видимое «Подключено» после локальной активации -> история отдельно; «Завершить сеанс» запускает revoke и MLS rekey, уведомляет участника. В случае потери всех устройств отдельный recovery wizard.
- UX-07 [P0] Стабильные 320dp/крупный текст, RU+EN, dark/light, контраст, TalkBack/VoiceOver/desktop keyboard, нет скрытых опасных действий.
- UX-08 [P1] Полный Telegram-подобный UX функций — reply/forward/edit/delete/react, drafts, archive, pinned, mute, поиск по локальному plaintext только на клиенте, attachments, drag/drop, voice playback, круглая видеокарточка, звонки, каналы/публикации. Различать private E2EE и public server-readable режим видимым бейджем/пояснением, не вводя пользователя в заблуждение.
- UX-09 [P0] Метрики UX без содержимого сообщений: доля завершённых registration/first DM/device linking, время и ошибки по сценариям; UX-критерии измеряются на реальных тестах, не по скриншотам.

### Account / local unlock — AU

- AU-01 [P0] Три границы доверия: account authentication, device trust/MLS membership, local storage unlock. У них независимые ключи и права; password-reset не расшифровывает E2EE историю.
- AU-02 [P0] Предпочтительна безопасная OS-bound оболочка случайного database-unlock key с user-presence/authentication, с обработкой смены биометрии, потери lockscreen, backup/migration. На iOS device-only Keychain policy (проверить mode), на Android Keystore+BiometricPrompt; на Windows защищённая локальная связка; на Linux libsecret или равнозначный слой. Не утверждать, что Secure Enclave/Keystore непосредственно поддерживает любые MLS/Ed25519 ключи.
- AU-03 [P0] Безопасный fallback для недоступного аппаратного хранилища: локальная сильная фраза/KDF, отсутствие секретов в настройках, логах, clipboard и в telemetry. Не сохранять пароль аккаунта как plaintext; не превращать PIN из 4 цифр в офлайновый decrypt key без hardware throttling.
- AU-04 [P0] Passkeys/FIDO2 как удобная опция аккаунта после сервера challenge validation/domain binding/attestation policy; пароль+Argon2id допустим. Ни passkeys, ни синхронизированный Apple/Google credential не являются trusted device grant.
- AU-05 [P0] Recovery: offline recoverable secret, пользователь явно сохраняет/подтверждает; zero-devices сценарий отдельно показывает утрату истории при потере recovery key. Не предоставлять оператору escrow/backdoor.
- AU-06 [P0] Account deletion: подтверждение личности, удаление токенов, account keys/device grants, серверных данных согласно политики, требуемые tombstones и storage object cleanup, запрет дальнейшей доставки; не обещать удаление уже расшифрованных копий у других пользователей. E2E должен создавать и удалять реальный тестовый аккаунт.

### Trust and multi-device — MD

- MD-01 [P0] Вход на новую машину всегда даёт PENDING_TRUST, private API denied; старое trusted устройство явно одобряет подписанный challenge с nonce, account/device/origin/expiry, подтверждая проверенный QR/SAS. Replay/MITM/expired/race/revocation fail-closed; device grant нельзя подделать сервером.
- MD-02 [P0] После grant — локальная activation, отдельная identity и **отдельный MLS leaf для каждого устройства**; список участников и peer safety controls показывают изменения. Не копировать MLS ratchet/keypair всех участников на новый аппарат.
- MD-03 [P0] Добавление листа во все активные 1:1/закрытые групповые MLS беседы по управляемому rekey/Commit/Welcome pipeline с учётом offline, race, outbox, epoch conflict/rebase, independent per-device cursor. Устройство получает будущие сообщения после подтверждённого join; при частичных сбоях честная pending-индикация и repair.
- MD-04 [P0] История до join: отдельный authenticated E2EE device-to-device transfer или user-owned encrypted backup с high-entropy recovery key; snapshot integrity, anti-rollback, expiry/view-once exclusions. «Подключён» и «История загружена» — разные статусы.
- MD-05 [P0] Logout/revoke/компрометация: остановить выдачу private messages и rotate session, MLS leaf removal/rekey в беседах, peer-visible alerts и локальная очистка в пределах OS; revoked не дешифрует **будущие** эпохи, старые копии нельзя гарантированно удалить.
- MD-06 [P0] Против malicious server: независимый device/key pin, KeyPackage/Welcome validation, transparency план с клиентским enforcement/monitoring до абсолютных заявлений, negative tests на подмену, rollback, split view, unauthorized member.

### Сообщения / сообщества / медиа / звонки — FEAT

- FEAT-01 [P0] Настоящий 1:1 E2EE chat с реакциями/ответами/редактированием/удалением, drafts, локальным поиском, доставкой и отзывом устройств. Без plaintext fallback.
- FEAT-02 [P0] Закрытые E2EE группы с несколькими людьми и устройствами, приглашениями, ролями, add/remove/rekey, атомарной серверной авторизацией membership и negative tests.
- FEAT-03 [P0 full product] Public и invite-only каналы/посты, подписка, публикация/редактирование/удаление, комментарии, реакции, темы, поиск, moderator/admin ACL и публичные метки. Invite-only НЕ означает E2EE.
- FEAT-04 [P0 full product] Фото, файлы, GIF/видео и **приватные** клиентски зашифрованные thumbnails/chunks/manifests, upload/download с resume, квотами, integrity, denial при unauthorized; server no private transcode.
- FEAT-05 [P0 full product] Voice notes: microphone -> capture/encoding -> send -> playback/seek. Video circles: camera -> record -> preview -> encode -> send -> circular playback. Никаких fake кнопок.
- FEAT-06 [P0 full product] 1:1 аудио/видео звонки через WebRTC + TURN, media peer identity binding к проверенным device credentials, authorised signalling; на 2G fail soft без приоритета звонка над текстом.
- FEAT-07 [P0] Фоновые уведомления на Android/iOS без private plaintext/personal secrets в APNs/FCM payload; при ограничениях OS отсроченная синхронизация и честная семантика; background delivery нельзя гарантировать.
- FEAT-08 [P0] Удаление аккаунта, экспорт, приватность и abuse/moderation ACL; E2EE доступен только адресатам, public moderation видит только публичное или добровольно раскрытое.

### Reliability / performance / security — NFR3

- NFR3-01 [P0] Существующие 2G gates неизменны: 20 kbit/s RTT 1.5s loss 3% p95 <=15s, seeds 7/19/41 и 200 сообщений в каждом направлении; severe 10 kbit/s RTT3s loss10% — eventually no loss/duplicates, без выдуманного latency SLA. Full combined crash/blackout/ACK/DB/media обязательный отдельный gate.
- NFR3-02 [P0] 3G/4G/5G/Wi-Fi/смена сетей: lab profile + реальные устройства, throughput/RTT/jitter/loss/reorder/transition/background, реальные сетевые профили калибруются и явно маркируются. Моделирование 5G через tc не доказывает работу в любой 5G сети.
- NFR3-03 [P0] Для любой UX/multi-device/media доработки: comparable pre/post p50/p95 delivery, throughput, byte overhead, CPU/mem/battery, startup, Flutter frame jank на одинаковом оборудовании/профиле. Регрессии расследовать и исправлять. Новые количественные budgets фиксировать до тестов, не подгонять; сохранённый 2G baseline запрещено ухудшать.
- NFR3-04 [P0] Текст, MLS commits и ACK планируются с приоритетом над media upload; большие вложения не должны блокировать короткие encrypted texts даже при 2G. Background policy не держит постоянный CPU/Wakelock обходами ОС.
- NFR3-05 [P0] RustSec все release-blocking advisories устранены совместимо без custom crypto/unsafe overrides; mobile/infra/supply-chain audits, MASVS-based checklist, TLS/identity, secret scanning, signed artifact provenance, rollback; do not waive gates.
- NFR3-06 [P0] TDD + реальные negative/integration/E2E/chaos тесты, обязательные из docs/v3/TEST_STRATEGY_RU.md. Build passes ≠ platform acceptance passes.
- NFR3-07 [P0] Разработка/демонстрации только на изолированных локальных стендах и синтетических учётках. Публикация в Stores, production, смена DNS, платежи, SMS/e-mail реальным людям, реальные пользователи — отдельная явная авторизация. PRODUCTION_APPROVED=false до независимого аудита и решения владельца.

## 2. Definition of Done без скрытого снижения объёма

- **FEATURE_VERIFIED**: production-код в backend+client+crypto+storage и доказательства живой happy-path + security negative case и platform-specific UI.
- **PLATFORM_VERIFIED**: реальная сборка, установка/запуск, реальные E2E/crypto/storage/background/permissions и отчёты на соответствующей ОС. Android emulator-only не окончательная мобильная квалификация; iOS без Mac/Xcode BLOCKED; Windows без Windows runner BLOCKED.
- **CORE_ALPHA_VERIFIED**: защищённый 1:1 + native OS, multi-device/recovery, offline/2G, безопасный UX и security gates; НЕ равно полному продукту.
- **FULL_PRODUCT_DONE**: все обязательные FR/FEAT/PL/MD/AU/UX, группы, каналы, файлы, voice/video circles, calls, E2E на всех четырёх платформах; все acceptance rows подтверждены, все security blockers устранены. Любая отсутствующая обязательная функция оставляет статус PARTIAL.
- **PUBLIC_PRODUCTION_APPROVED**: независимые внешние crypto/mobile/infra аудиты, ops/load/restore/backup, signed provenance, юридическое и security review и отдельное одобрение владельца. Даже FULL_PRODUCT_DONE не даёт разрешения деплоить.

См.: docs/v3/ARCHITECTURE_RESEARCH_RU.md, docs/v3/TEST_STRATEGY_RU.md, docs/v3/CONFLICTS_AND_DECISIONS_RU.md, docs/v3/ACCEPTANCE_MATRIX.csv. Не переписывать V1/V2 историю так, будто они уже выполнены.
