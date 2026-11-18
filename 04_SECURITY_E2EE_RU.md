# Модель безопасности и E2EE — без ложных обещаний

## 1. Цели, угрозы, допущения

Внешний атакующий может перехватывать пакеты, красть токены, выполнять brute-force, DoS, подбирать идентификаторы, внедрять опасные файлы. Сильный атакующий может получить read/write доступ к DB/object storage, стать оператором gateway или изменить directory/key packages. Возможны потерянные и скомпрометированные устройства. **Доверенным остаётся только корректно построенный клиент на здоровом устройстве**, а trust в credentials должен быть проверяемым.

Цели: privacy и аутентичность содержимого private chat, целостность, защита от replay/подмены ключей, ограничение компрометации старых ключей, анонимизация/минимизация server metadata где возможно. Не цели: абсолютная анонимность, доступность при отключённой сети, защита контента на уже заражённом endpoint, предотвращение скриншота/записи экрана получателем.

## 2. Криптографический протокол — единый вариант

**Выбор:** Messaging Layer Security (MLS) RFC 9420 для приватных чатов, включая 1:1 как группу из двух пользователей/их устройств, и для закрытых групп. RFC 9750 описывает Authentication Service и Delivery Service, которые проект обязан реализовать корректно. Предпочтительная реализация crypto core — Rust OpenMLS без самодельных криптографических примитивов. Для вызова из Flutter — flutter_rust_bridge (Android/Linux/iOS/Desktop) и отдельный `wasm32` bridge для web, если пройдёт реальный spike. Версию OpenMLS зафиксировать после compatibility spike, документировать конкретный commit/tag и лицензию.

Преимущества: единая модель 1:1 и групп, async join, forward secrecy/PCS при соблюдении требований протокола. Недостатки: MLS — не весь мессенджер; ordering/control handshake, credentials, key packages, conflict resolution, metadata и key transparency — ответственность приложения. Заявлять постквантовую защищённость без соответствующей согласованной ciphersuite **нельзя**.

**Важная альтернатива:** Signal PQXDH/Double Ratchet рассмотрены, но libsignal официально не поддерживает стороннюю интеграцию как стабильный SDK; не комбинировать спонтанно Signal и MLS, не писать собственный Double Ratchet на глаз. Пересмотр выбора допускается только документированным ADR с работающими тестами и равным/лучшим security posture.

## 3. Device identity / KeyPackages / transparency

- Каждое устройство генерирует identity keys **на устройстве**, локально сохраняет закрытый материал в защищённом хранилище, публикует подписанный публичный credential и KeyPackages.
- Сервер хранит связь user/device/public key, nonce, event journal. Доступ к загрузке/выделению KeyPackages — только аутентифицированным членам допустимых групп; предотвращать exhaustion/replay.
- KeyPackages по возможности одноразовые и с TTL; отсутствие свежего KeyPackage — явное состояние и retry, а не использование бесконечно старого.
- New-device enrollment: trusted existing device verifies/signs enrollment, либо доверенный recovery flow. Новое устройство не получает старую историю без защищённого user-controlled восстановления.
- Смена ключа / новое устройство -> уведомление и возможность проверки safety number/QR; не показывать «проверен» без реальной проверки.
- Добавить append-only auditable key directory/key transparency в roadmap. **Без** независимого/проверяемого лога сервер потенциально может выдавать разные view ключей разным клиентам. Минимум на local release: signed binding audit + device-change alerts; before public production: реальная проверяемая transparency architecture и independent review.

## 4. Правила формата private messages

- Не применять произвольное «своё шифрование». Использовать поддерживаемые ciphersuites OpenMLS, строгую domain separation и authenticating client_id/session; в test suite crypto known vectors, negative cases.
- Private message content (включая quotes, mentions, reactions, deleted markers, keys for attachments) должен быть в MLS payload, не в server-visible metadata.
- Два вида update: encrypted app event и MLS handshake (proposal/commit/welcome). Нельзя маршрутизировать по plaintext «тип сообщения — поздравление/ответ» при private mode.
- При смене состава групп — MLS rotation / new epoch; pre-membership messages не показываются задним числом new member без явного client-shared history.
- При потере состояния/невозможности decrypt нельзя автоматически fallback в plaintext. UI объясняет «ключи изменились/сообщение недоступно» и предлагает восстановление.
- Запрещены передача private keys на сервер в plaintext и включение их в логи/Crashlytics.

## 5. Локальное хранилище и web constraints

Для Android/iOS использовать аппаратно поддержанные системы защиты ключей, где доступны; DB encryption key sealed in Android Keystore/Apple Keychain; приложению нужен secure lock/privacy controls, clipboard expiring, screenshot preview redaction где применимо. Linux desktop — доступные secure keyrings, при отсутствии лучше явный user passphrase и заблокированный store, а не hardcoded ключ.

Web browser: сервер поставляет JavaScript и теоретически может выдать вредоносное обновление; нет гарантии эквивалента hardware-backed storage. E2EE на web **не объявляется эквивалентно доверенным native-клиентам** без security review. Если Rust OpenMLS WASM bridge не прошёл integration tests — web поддерживает только public data + auth, private chat отключается с ясным сообщением; статус «частичная web-поддержка» в итоговом отчёте. Не симулировать E2EE.

## 6. Вложения

- На устройстве генерируется уникальный 256-bit key с CSPRNG на файл. Шифровать AEAD через криптобиблиотеку; для chunked upload — уникальные nonce per chunk в защищённой derivation (например nonce из random per-file prefix и строгого индекса при фиксированном safe design), full integrity and authenticated chunk order/manifest.
- В encrypted MLS event передавать key, algorithm/version, chunk manifest encrypted or protected, digest/ciphertext reference. Не отправлять ключ медиа в публичную signed URL или header.
- Server-visible file id / размер / приблизительное время доступны серверу; это metadata leakage, пользователь должен знать.
- Публичные файлы: content scanning, MIME sniffing, transcoding, quotas. Приватные файлы на стороне сервера нельзя сканировать по plaintext; компенсировать sandboxed parsers на клиентах, size quotas, explicit media rendering.
- Temporary object URLs short TTL, server-side access control and anti-enumeration; authenticated access even if IDs guessed; prevent SSRF via media import.

## 7. Авторизация и безопасность аккаунта

- Для паролей Argon2id + уникальная соль и современные memory-cost параметры по OWASP; защитить от timing/user enumeration, rate-limit, настраивать параметры с нагрузочными тестами.
- Email verification token — одноразовый hashed token с TTL. Tokens stored hashed/server-side; refresh token rotation/revocation, secure cookies if web, CSRF protection.
- Админ требует MFA и reauth для критических действий. Роль выдается только через заранее защищённый bootstrap, не публичной регистрацией.
- Account recovery через email reset **не** расшифровывает E2EE chats. Для истории — отдельно защищённый recovery key/backup или trust device.
- Локальные тестовые аккаунты допустимы только в dev с explicit dev mode; production config fail-closed.

## 8. Модерация совместно с E2EE

Admin видит аккаунты, статистику, метаданные (по минимальному перечню), публичные публикации, жалобы и **добровольно раскрытые пользователем** фрагменты private ciphertext/plaintext с доказуемым источником контекста. Сообщения вне жалоб не расшифровываются админом. Нельзя скрытно регистрировать административное устройство как участника MLS.

Для закрытых групп локальные администраторы контролируют membership, а не глобальный администратор через серверный decrypt. Распространение явно опасного контента ограничивать server policies, user reports, rate limits and public moderation.

## 9. Логи и observability

Запретить логировать: passwords, JWT/refresh, E2EE keys, private message text, email verification codes, signed URLs, raw push payload if sensitive. Audit хранит identity/time/role/action/reason, замаскированные targets, immutability/append-only constraints. Crash reports по умолчанию не собирают message bodies.

## 10. Атаки — обязательные тесты

1. Operator читает DB/object store: приватный plaintext не извлекается; публичный контент ожидаемо доступен.
2. Server substitutes KeyPackage: client не должен незаметно принять неподтверждённую смену binding; adversarial test, blocked/key warning.
3. Same `client_message_id` с другим payload -> explicit conflict, не невидимая подмена.
4. Replay MLS ciphertext и старые commits -> отклонение/без дублей.
5. Device revoke -> новые сообщения недоступны удалённому устройству после согласованного rekey, но ранее полученные plaintext нельзя удалить гарантированно.
6. Unauthorized group join / media fetch / admin endpoint / object IDOR -> deny.
7. Password reset + old device access -> E2EE protection persists.
8. Spoofed receipts/typing/presence -> identity validated.
9. Attachments with malicious filename/MIME, huge chunk, decompression bomb, path traversal -> bounded safe error.
10. SQL injection/XSS/CSRF/SSRF/open redirect/DoS -> automated tests and security checklist.
11. App reinstall/offline restored -> no silent key loss, explicit safe recovery behavior.
12. Backup restoration → DB data restored, still not enough to decrypt private messages without client keys.

## 11. Production security gate

Перед публичным использованием: независимый криптоаудит integration, review key directory and device onboarding, mobile/web pentest, infrastructure pen-test, key management and backup drill. Baseline OWASP ASVS 5.0 + Mobile MASVS; оформленный threat model и data protection impact review. До этого маркировать систему `LOCAL_BETA_UNAUDITED`.
