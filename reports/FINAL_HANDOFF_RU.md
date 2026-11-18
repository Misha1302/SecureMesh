# SecureMesh — локальный checkpoint, полный продукт не завершён

Статус: PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.
Репозиторий: /home/micodiy/SecureMesh.
Ветка: codex/securemesh-build; remote не создавался, push/публикации не было.
Проверенный исходный code checkpoint: c1dfffb8870d56c23d2ad7988657c0f2ef072104.
Финальный checkout HEAD определяется командой git rev-parse HEAD (документирующий коммит может быть новее исходного checkpoint).

## Реально реализовано и выполнено

.NET 10 API, PostgreSQL и EF-миграции; Mailpit; Argon2id; подтверждение владения ключом устройства; одноразовые email-токены, refresh rotation/reuse revocation. Настоящий OpenMLS 0.9.2, отдельные клиентские процессы, Welcome, добавление/исключение третьего участника и rekey, отрицательные replay/key-substitution проверки. SQLCipher с общей транзакцией для MLS state и outbox/inbox/cursor. Серверный COMMIT message+outbox до durable ACK, idempotence/conflict, cursor pagination, protobuf WSS и HTTPS. Гонка MLS self-update коммитов с reject/rebase проверена.

Flutter 3.50.0 Linux debug собран и запущен в изолированном Xvfb. Два GUI-процесса действительно обменялись текстом через TLS API/PostgreSQL; публичные ключи сравнены; offline очередь пережила SIGKILL и повторное открытие. Есть чат/настройки, RU/EN строки, light/dark, компактная компоновка. UI ещё использует HTTPS polling; WSS-first manager отсутствует. Регистрация в UI не подключена; make seed-demo создаёт реальные локальные тестовые аккаунты/профили. Браузерная сборка отключает приватные чаты явно.

## Команды и фактические результаты

- python3 tools/verify_bundle.py: exit 0, 24 SHA-256 исходных файла неизменны.
- make bootstrap: exit 0 в существующем локальном workspace (не полный clean-room прогон).
- make smoke: exit 0, настоящие API/PostgreSQL/OpenMLS, аутентификация, WSS/HTTPS и повторная доставка.
- make verify: exit 2 от make, underlying script exit 1. Build/crypto/API/epochs/format/secret-pattern/Flutter checks проходят; RustSec и acceptance gate остаются красными. reports/evidence/verify.txt.
- tests/crypto/process_spike.py, tests/integration/delivery.py, epochs.py: exit 0.
- tests/integration/recovery.py: exit 0; остановка БД до COMMIT =>503 без ACK; изолированный pg_dump/pg_restore и расшифрование оригинальным клиентом. Объектное хранилище не проверено.
- Dart/FRB native crypto smoke, Flutter analyzer и два layout-теста: exit 0.
- Linux build: exit 0; последние исходники/бинарник отдельно проверены. Android/iOS/macOS артефактов нет.
- NuGet scan exit 0; RustSec exit 1, четыре advisory. Secret-pattern scan exit 0 с ограниченным набором паттернов, не обещание отсутствия всех секретов.
- make down: exit 0; только контейнеры/процессы SecureMesh остановлены, DB volume сохранён.
- staging Compose config syntax: exit 0, без запуска. Deployment prerequisite gate: exit 1, NOT_READY.

## 2G evidence

GPRS 20 kbit/s на направление / RTT 1.5 s / loss3%: seed7/19/41, по200 сообщений A→B и B→A; все1200 ID доставлены, дублей нет; p95 4.351 / 4.375 / 4.754 s. Первоначальный FAIL p95 25.721 s сохранён; критерий не снижался.

Severe 10 kbit/s / RTT3s / loss10%, тот же объём и seeds: все1200 ID доставлены, дублей нет; p95 30.325 / 58.895 / 64.428 s; временной SLA нет. Настоящий netem только в контейнерах проекта. Raw IDs/тайминги/tc counters/хеши бинарников: reports/evidence/netem-v2-*.json; подробности reports/2G_REPORT.md.

Это functioning-link baseline, не весь комбинированный crash/60s-blackout/half-open/media schedule и не испытание реальных операторов/батареи. AT-013 поэтому оставлен частичным. TLS accounting для100символов не завершён.

## Приёмка и ограничения

P0: 11 PASS, 1 FAIL, 14 NOT_RUN. P1: 2 PASS, 11 NOT_RUN, 1 BLOCKED. Частичное покрытие намеренно не названо PASS. Полная таблица: reports/ACCEPTANCE_MATRIX.csv и TEST_RESULTS.md.

RustSec: crypto-bigint 0.5.5 (RUSTSEC-2026-0387), libcrux-kem 0.0.9 (0330/0331), libsqlite3-sys 0.35.0 (0459), плюс unmaintained proc-macro-error2. Прямые обновления до исправленных major/minor несовместимы с текущими upstream constraints; реальные ошибки resolver сохранены. Ничего не проигнорировано и собственных криптопримитивов не добавлено. Независимого аудита нет; реальные чувствительные данные использовать нельзя. docs/SECURITY_LIMITATIONS.md.

Нет готового AS directory/одноразового leasing KeyPackages/серверной доставки Welcome, trusted enrollment/recovery, native WSS manager, полного mixed-fault набора. Основные M4–M6 отсутствуют: группы UI/социальные публичные пространства/медиа/голос/кружки/звонки/admin MFA/moderation. Не закрыты все hardening/load/storage/backup/platform checks. Android SDK36 существует, но лицензии/сборка bridge не проверены. Apple runner отсутствует. Полной framework-локализации и screen-reader проверки нет. Полный delivery candidate не заявляется.

## Локальный запуск

make bootstrap; затем make demo в отдельном терминале.
Для GUI: bash scripts/install-flutter.sh; make build-linux; make seed-demo; make client (два окна, разные профили из .local/demo/profiles.json). Файл содержит только синтетические локальные unlock-значения, ignored/mode600; не публиковать. make down останавливает только проект и сохраняет volume БД.

## Продолжение

1. Исправить dependency/provider/storage advisories через поддерживаемые upstream версии; повторить отрицательные crypto/persistence tests и RustSec без ignore.
2. Подключить реальный KeyPackage/Welcome/device-trust flow и регистрацию к UI.
3. Реализовать native WSS-first reconnect/fallback и смешанный воспроизводимый 2G fault schedule; не ослаблять AT-001..AT-024.
4. Затем M4–M6, M7/M8 по исходному ТЗ. PLAN.md/STATUS.md и evidence позволяют продолжить без пересоздания реализованного.

## Только позже для деплоя

После завершения функций/gates: независимый crypto/mobile/infra аудит, хост/юрисдикция, домен/DNS/TLS, SMTP/abuse, push/store signing, object/backup provider, admin MFA/bootstrap, мониторинг, retention/legal и операционное одобрение владельца. Сейчас удалённых действий, платных ресурсов и публикации нет. Шаблоны deploy не являются готовой инфраструктурой.
