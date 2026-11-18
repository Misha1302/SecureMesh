# SecureMesh V2 — проверяемый локальный checkpoint

PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.
Рабочий каталог: /home/micodiy/SecureMesh. Разработка: codex/securemesh-v2 от dae7259. Проверенный runtime checkpoint: 4b003dd; штатный demo-path исправлен в fffe534, повтор сетевого advisory-запроса — 0819e00. Документирующие коммиты могут быть новее; git rev-parse HEAD определяет текущий checkout. Все исходные ТЗ/checks и docs/v2 сохранены. Развёртывания, DNS, платные ресурсы и production-данные не затронуты.

## Реально работает

- API/.NET10/PostgreSQL17, шесть EF-миграций, Mailpit verification, Argon2id, отдельный device proof, rotating one-use refresh. Восемь одновременных запросов используют одну сохранённую ротацию. Fresh/upgrade/restart и isolated PG restore проверены: исходный сеанс, новый login и расшифрование исходным SQLCipher/OpenMLS-клиентом работают.
- Новый вход другого устройства остаётся PENDING_TRUST. Signed request/proof/grant, независимая проверка закреплённого ключа и явная activation проверены настоящими API/клиентами. Само одобрение старым устройством доступа не активирует. Replay/expiry/race/owner/key/revocation/substitution negatives проходят. Квота 32 выдачи/скользящие сутки теперь сохраняется отдельно от истёкших заявок: старый бинарник проваливает тест, новый отклоняет 33-ю выдачу и после restart; повтор той же заявки лимит не расходует. Камеры QR, MLS leaf и старой истории это не добавляет.
- DM: username-заявка и согласие получателя, настоящий public-only OpenMLS KeyPackage validator, одноразовый lease, signed server-routed Welcome и независимое сравнение ключей. Транзакционный join проверяет ровно двух участников; повтор Welcome не откатывает ratchet. Старый прямой bootstrap выключен по умолчанию. Seed-demo использует routed flow.
- Настоящие OpenMLS/SQLCipher, атомарные ratchet+immutable outbox и decrypt+inbox+cursor, server COMMIT до durable ACK, конфликт/idempotence и epoch race/rebase. Standalone add/remove/rekey проверен; полная групповая/мультиустройственная система ещё отсутствует.
- Linux Flutter UI: регистрация/письмо/login, отдельный локальный пароль, исправление ошибочного username, account hub, consent/key comparison, DM list/create/join и Unicode. Реальный GUI переживает offline COMMIT → SIGKILL → открытие того же store → доставку того же ciphertext ровно один раз. Pending UI и настоящая signed заявка проверены, сервер отказывает кандидату в приватных чатах. Пять исходных замечаний независимого UI-review закрыты; это narrow Linux verdict, не разрешение на выпуск продукта.
- Production-controller Dart WSS/protobuf: bounded window6, три независимо пополняемые отправки, sync и coalesced receipts, HTTPS fallback/re-probe, строгие frame/ACK/Upgrade проверки. TLS socket после Upgrade имеет явного владельца и уничтожается на disconnect/close/timeout. SHA-1 здесь только стандартный RFC6455 accept challenge из vetted crypto package; TLS/MLS алгоритмы и проверка сертификата не ослаблены. Два прежних варианта close зависали и сохранены как FAIL, итоговый вариант проходит реальные fault/exit проверки.

## Измерения и точные результаты

Финальный набор: 200 сообщений в каждом направлении, seeds7/19/41, реальные TLS/API/PG/OpenMLS/SQLCipher и netem только в двух контейнерах SecureMesh. Во всех шести trials совпадают source hashes текущего controller и набор бинарников, наблюдён child_exit_code=0. Все 2400 ID доставлены без потерь/логических дублей, outboxes обработаны.

| Профиль | p95 seed7/19/41, секунды | Критерий |
|---|---|---|
| GPRS:20kbit/s, RTT1.5s, loss3% | 4.672/4.928/4.742 | <=15s в каждом полном trial, PASS |
| Severe:10kbit/s, RTT3s, loss10% | 42.772/56.869/66.886 | eventual delivery, без временного SLA, PASS |

Запуски выполнены как make native-network-gprs, отдельный severe --seeds41 (сначала проблемный case), затем severe --seeds7,19; все по200 в каждом направлении. Точные команды/exit codes: v2-native-gprs-full.txt, v2-native-severe-41-owned.txt, v2-native-severe-7-19-owned.txt в reports/evidence. Строгий renderer: v2-native-network-report.txt, exit0, 6/6. Raw IDs/timings/tc counters/source+binary SHA — native-netem-*-200.json; таблица NATIVE_2G_REPORT.md. Старые Python-результаты отдельно в 2G_REPORT.md. Первая GPRS неудача и оба severe зависания сохранены; наличие готового JSON без успешного завершения процесса не засчитывается.

Отдельный текущий native recovery: blackout WSS+HTTPS 60.000s, 1000 событий в порядке без дублей/потерь и без доставки во время blackout; после повторного открытия SQLCipher cursor=1000, реальный PostgreSQL receipt=1000. Это отдельный сценарий, а не полный combined profile/crash/DB/media schedule. Статистика WSS — application bytes; точный100-character TLS accounting, battery/resource/load и media fairness не завершены. Outer retry counter не включает внутренние transport fallback; HTTPS request counts сохранены отдельно.

- make bootstrap и make smoke: exit0 в существующем workspace; clean-room не заявляется.
- Linux debug build, analyzer,3 widget tests, native crypto/transport/session, enrollment/quota/migration/directory/restore checks: exit0.
- Финальный make verify: exit2 (underlying script1). Все реализованные группы проходят;3 красных gate: RustSec, original acceptance и V2 acceptance. reports/evidence/v2-final-verify.txt. Первый aggregate с временным OSV network FAIL сохранён отдельно, повтор scan и aggregate выполнены; недоступный feed никогда не считается clearance.
- Реальный make demo отдельно проверен через health и routed DM/decryption. Обнаруженный относительный validator-path при dotnet run исправлен абсолютной конфигурацией; negative/positive logs сохранены. make down: exit0, API/контейнеры проекта остановлены; volume securemesh_db сохранён (v2-volume-preserved.txt).
- Оригинальные24 SHA-файла проверяются tools/verify_bundle.py; это проверка документов, не аудит безопасности.

Приёмка: P0 14PASS/1FAIL/11NOT_RUN; P1 2PASS/11NOT_RUN/1BLOCKED. V2 1PASS/18NOT_RUN/1BLOCKED. Частичные сценарии не повышены до PASS. Источники: обе working CSV-матрицы и TEST_RESULTS.md.

## Блокеры и оставшийся объём

RustSec database472a4c9a785030434f15d7da84964d60fbe789ab: crypto-bigint0.5.5 (RUSTSEC-2026-0387), libcrux-kem0.0.9 (0330/0331), libsqlite3-sys0.35.0 (0459), плюс unmaintained proc-macro-error2. Совместимое обновление выбрало0 изменений; прямые версии нарушают upstream constraints. В advisory затронут также bundled SQLCipher новых wrappers — одного номера wrapper недостаточно. Ничего не проигнорировано, самописной криптографии/plaintext fallback нет. Независимого crypto/mobile/infra аудита не было. Реальные чувствительные данные использовать нельзя; production startup запрещён.

Pub OSV проверил55 hosted lock versions с настоящим известным affected positive control:0 reported package advisories. Тексты55/55 лицензий и хеши сохранены; SPDX/legal compatibility, полный SBOM/container/multi-ecosystem review не завершены. NuGet feed не сообщил известных уязвимых пакетов. Это ограниченные feed-checks, не безопасность продукта.

Не завершены: QR camera, MLS multi-device membership/revoke/rekey, history transfer/recovery/transparency и keyring/keystore. Crash между успешным onboarding login и полной записью local profile не покрыт готовым resume UI; encrypted draft не является recovery. Группы/каналы/посты, файлы/медиа/голос/кружки, disappearing/view-once, calls/push/admin/moderation и большая часть S2–S4 отсутствуют. Android SDK есть, build/licenses/bridge не проверены; Apple runner отсутствует; compact Linux не является Android evidence. Приватный web выключен. Полные clean-room/object+keyring restore/load/fuzz/platform/retention gates отсутствуют.

## Запуск и продолжение

```bash
make bootstrap
make demo
# В другом терминале:
make build-linux
make client
```

API:https://127.0.0.1:5088; локальное письмо:http://127.0.0.1:58028. В GUI создайте два аккаунта, подтвердите письмо, примите username-заявку и независимо сравните ключи. Local passphrase не отправляется API; профили в ignored .local/profiles. make seed-demo необязателен; его ignored mode600 .local/demo/profiles.json содержит синтетические unlock-значения и не является recovery. make down сохраняет DB volume.

Дополнительные проверяемые команды:

```bash
make gui-smoke
make gui-pending-smoke
make native-cursor-recovery
make enrollment-quota
make restore-v2
make native-network-gprs
make native-network-severe
make verify
```

Network suites запускаются последовательно и имеют общий exclusive lock; API fixtures не принимают чужой readiness. Порты15990/15991 вынесены из стандартного ephemeral range после реального TIME_WAIT-конфликта. Никакие host qdisc/sysctl или чужие контейнеры не менялись.

Следующий критический путь: совместимый upstream security remediation без ignore; crash-safe onboarding draft resume с сохранением той же identity; полный mixed-fault schedule; MLS device/history/recovery по V2; затем остальные M4–M8/S2–S4 функции. Новые закрытые компоненты не пересоздавать. PLAN.md и матрицы сохраняют точный остаток.

GitHub origin — существующий приватный https://github.com/Misha1302/SecureMesh. Финальная синхронизация/remote readback выполняются после локальных проверок; журнал будет в reports/evidence. Ранее Actions блокировался до запуска шагов по billing/spending limits; платёжные настройки не менялись. Локальные результаты не означают successful cloud CI. Публичный запуск требует завершённых gates, независимого аудита и отдельного разрешения владельца.
