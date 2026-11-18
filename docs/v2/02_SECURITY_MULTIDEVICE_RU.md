# SecureMesh V2 — шифрование, доверие и многодевайсное восстановление

## Проверяемые свойства и ограничения
Желаемая модель: полный доступ злоумышленника к VPS/БД/server backups/root/admin credentials **не** даёт ключей приватных сообщений и приватных файлов. Private chats/closed groups — клиентское MLS E2EE; нет master key/escrow/admin decrypt/backdoor или plaintext fallback. Это не защищает автоматически от захвата endpoint, раскрытого пользовательского recovery key, будущего злонамеренного клиентского обновления, сетевых IP/time/size метаданных и публичных постов. Все заявления ограничивать угрозмоделью и реальными тестами.

## Состояния авторизации и устройств
Состояния нового устройства: `SIGNED_OUT -> ACCOUNT_AUTHENTICATED -> DEVICE_PENDING_TRUST -> DEVICE_TRUSTED -> MLS_JOINED -> HISTORY_SYNC -> READY`. Знание пароля/passkey, password reset, possession of email или доступ к админке **не** дают старых E2EE-ключей/истории и не позволяют скрыто добавить device.

Каждое устройство локально создаёт независимые device identity/signing и MLS keys. Хранить их внутри защищённого локального SQLCipher/системного Keystore/Keychain (при доступности), с явной платформенной оценкой. Использовать стандартный OpenMLS, подписанные/привязанные к identity KeyPackages, одноразовое lease, expiry, replay protection и server Welcome routing. Все device-join/leave/revoke и MLS epoch commitments должны быть проверяемыми и атомарными для клиентского состояния. Сервер — недоверенный транспорт, не authority на незаметную смену ключей.

### Подключение нового устройства
1. Новый клиент создаёт подписанный challenge с device ID, nonce, ограничением времени, отображаемым fingerprint/QR и channel-bound transcript.
2. Существующее доверенное устройство показывает новый device ID/fingerprint, получает явное подтверждение владельца и подписывает одноразовый enrollment grant.
3. Проверка обеими сторонами, сервером и другими клиентами: owner binding, authenticity, expiry, anti-MITM, anti-replay, revocation, proof of possession; server key substitution вызывает hard failure/visible warning.
4. Новый per-device MLS leaf добавляется в нужные чаты, Welcome/epoch упорядочены. Trust/key change видны пользователям.
5. **История до присоединения** переносится отдельным E2EE client-to-client snapshot либо из личного зашифрованного backup. Не копировать исторические MLS traffic secrets ради удобства синхронизации: сохранять forward secrecy будущих событий.
6. Отзыв/revoke исключает устройство из будущих эпох; прошлые сообщения, уже скопированные на него, физически не отозвать.

### Полная потеря всех устройств
Восстановление аккаунта и E2EE истории разные операции. Пользователь может восстановить доступ к аккаунту по политике, но старую историю — только если ранее создан user-held backup/recovery secret. Клиент генерирует криптографически случайный 256-битный backup root, показывает пригодный для хранения recovery key и проверяет, что пользователь его сохранил. Backup root НЕ равен паролю/refresh token/MLS secret. Если пользователь потерял устройства+recovery key, никакого административного восстановления истории нет.

Обязательно отдельно решить возвращение права получать **будущие** E2EE-сообщения: account-recovery delegation, проверяемый новым клиентом и наблюдаемый собеседниками, либо новая identity с явным trust reset и безопасной реинициализацией MLS. Backup decrypt сам по себе не делает новое устройство trusted participant.

### Зашифрованные бэкапы
Стандартный audited AEAD; manifest с version, sequence/snapshot, account binding, integrity/authenticity, anti-rollback/freshness; nonce uniqueness, independent per-snapshot/per-chunk keys, bounded memory, resumable upload, corrupted-chunk rejection. Сервер получает только ciphertext и необходимые минимальные метаданные. Не загружать в backup живые MLS ratchet/secrets для будущих эпох. Ротация backup root, экспорт, удаление backup, retention. Исторический архив при потере секретности recovery key может раскрыть старые сообщения — явно описать. Exclude/view-once/expired disappearing content из новых backup; не обещать уничтожение уже экспортированных/скопированных данных.

### Защита от злонамеренного сервера
Key Transparency: append-only commitment/inclusion+consistency proofs, независимые monitors/witnesses и client pinning. Журнал, который контролирует единственный оператор, может допускать split-view; его недостаточно для абсолютной гарантии. Подмена identity/KeyPackage/Welcome, rogue device, rollback/downgrade = reject+user-visible state, никогда silently accept.

Reproducible signed builds, transparency of versions, independent review and 2-person/threshold release controls уменьшают риск вредоносного обновления; не дают математической гарантии против целенаправленной компрометации будущих клиентов. Защищать signing keys и build provenance, независимые проверки бинарников.

### Privacy и анонимность
Username — псевдоним, не анонимность. Сетевые адреса, время, граф связей и размеры могут быть наблюдаемыми. Минимизировать IP/TLS logs, retention, адресную книгу, telemetry и push content. Номер не требовать; email — optional после корректной антиспам/восстановительной миграции. Privacy-safe moderation, user-selected disclosure; admin audit не содержит plaintext. Отдельно документировать противника ISP/сервер/endpoint/operator update.

## Обязательные отрицательные кейсы
SEC-V2-01: оператор имеет полный DB+storage+root+backup dump — private plaintext и recovery secret недоступны.
SEC-V2-02: malicious directory подменяет ключ, устройство, Welcome, commit, supply-chain; fail-closed.
SEC-V2-03: one password login не даёт E2EE истории; trusted QR transfer даёт; recovery secret backup даёт; без обоих не даёт.
SEC-V2-04: two accounts multiple devices sync without duplicates/secret cloning; revoke future-only.
SEC-V2-05: backup wrong key/corruption/rollback/replay/incomplete write/downgrade rejected или явно предупреждён.
SEC-V2-06: disappearing/view-once/TTL не возвращается из нового backup/cache после истечения; честно ограничено ранее сохранёнными копиями.
SEC-V2-07: никаких secret/message/keys в логах/крашах/telemetry/push/server, server authorization negative tests и rate limits.
SEC-V2-08: закончен RustSec remediation + независимый внешний crypto/mobile/infra аудит до публичного релиза.
