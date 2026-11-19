# SecureMesh — проверяемое продолжение V2

**PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.**

Рабочий каталог: /home/micodiy/SecureMesh. Код продолжения: 1c08659 (журнал/привязки challenge), 5cbdb01 (перевод сохранённой ошибки). Ветка разработки codex/securemesh-v2; git rev-parse HEAD определяет checkout, отчётные коммиты могут быть новее. Сохранены предыдущие реализации и неизменяемые исходные ТЗ/checks/docs/v2. Production, DNS, платные ресурсы и реальные пользовательские данные не затронуты.

## Реально добавлено

Прерванный native sign-in продолжает тот же SQLCipher/OpenMLS-профиль и ключ. До login журналируются identity/origin/username и неопределённость результата, после ответа — allowlisted session до account fetch. Полный профиль и удаление журнала коммитятся вместе. Пароли в журнал не записываются. Клиент отклоняет challenge с чужим назначением/ID/device/username до подписи и login POST.

Linux UI выбирает сохранённый файл, исправляет неверный локальный пароль, продолжает prepared/cached/expired session и сохраняет введённый пароль при смене RU/EN. При cached session повторный login не выполняется; после истечения нужен пароль аккаунта. Pending private-data gate сохраняется. Это не восстановление потерянного файла/пароля, не перенос истории и не мультиустройственный MLS join.

Подробный компонентный отчёт: [ONBOARDING_RESUME_REPORT.md](ONBOARDING_RESUME_REPORT.md). Протокол/ограничения: [ONBOARDING_RESUME.md](../docs/ONBOARDING_RESUME.md).

Существующий рабочий слой сохранён: verified email/Argon2id/device proof, rotating sessions, signed manual enrollment/activation и durable quota; consented KeyPackage/Welcome DM, независимые pin-проверки, OpenMLS/SQLCipher, durable outbox/inbox/cursor, WSS/protobuf с HTTPS fallback, Linux signup/chat и offline/SIGKILL/reopen. Это не завершает все требования соответствующих этапов.

## Проверки и ограничения доказательств

Последний широкий make verify: exit2, 24/27 групп PASS. Красные — RustSec и обе acceptance matrices. После него финальные challenge/locale изменения прошли адресные controller/GUI/analyzer/build проверки; повтор полного aggregate не заявляется.

- evidence/v2-onboarding-challenge-recovery.txt: exit0, реальные API/PG/OpenMLS/SQLCipher, SIGKILL/lost reply/saved/expired/foreign bindings/wrong key и четыре подмены challenge без login POST/session.
- evidence/v2-onboarding-gui-locale-fix.txt: exit0, три настоящих GTK/Xvfb UI-пути, один и тот же ключ/device, server sessions2/1/2, pending private API403, все сохранённые сегменты логов проверены на тестовые пароли/токены. GUI fixtures — настоящие accepted API logins; crash boundaries отдельно исполнены production Dart controller.
- evidence/v2-resume-locale-analyze.txt и v2-resume-locale-linux-build.txt: exit0. Три widget-теста с новыми navigation/username regression assertions прошли в широком прогоне.
- Independent UI reviewer: sole P2 translation fix resolved, scoped ship; отдельный documenter сохранил design-файлы. Это Linux light/default-scale evidence, не mobile/a11y/security approval. Снимки1280×720/320×844, не Android/iOS.
- Схема сервера по-прежнему содержит шесть миграций; migrations/restore/доставка/enrollment/directory/epochs/session/native faults повторены широким прогоном. Journal использует существующую encrypted app_meta, новой серверной миграции нет.

Raw FAIL/диагностика сохранены: initial registration timeout; proxy не читал chunked body; неправильный page context; GUI assertion до click/wait; первая review-находка RU error на EN форме. Никакие assertion, timeout или security gate не ослаблялись. Предыдущие26 aggregate logs сохранены побайтно под baseline-6b2aefc-* с проверенными SHA; старая сводка v2-final-summary-0343.json, текущая v2-final-summary.json.

Шесть прежних native transport trials — runtime4b003dd, совпадающие measured controller/transport hashes, один набор бинарников, child exit0, 2400 IDs без потерь/дублей. GPRS20kbit/s/RTT1.5s/loss3% p95=4.672/4.928/4.742s; severe10kbit/s/RTT3s/loss10% p95=42.772/56.869/66.886s, без latency SLA. Это сохранённые измерения, не новый прогон crypto binary с журналом. Separate60s/1000-event blackout recovery и GUI chat kill/reopen остаются отдельными доказательствами, не полным combined schedule.

## Что блокирует продукт

Четыре RustSec: crypto-bigint0.5.5 / RUSTSEC-2026-0387; libcrux-kem0.0.9 /0330,0331; libsqlite3-sys0.35.0 /0459. Advisory DB472a4c9a785030434f15d7da84964d60fbe789ab; proc-macro-error2 unmaintained. Provider/storage stable versions в registry readback прежние; один libsqlite3-sys readback UNAVAILABLE. Новые metadata bigint/SQLCipher не равны совместимому исправлению. Игнорирований/самописной криптографии/plaintext fallback нет, независимого аудита нет.

Остаются registration/email interruption до создания журнала, refresh lost-reply/crash qualification, keyring/keystore, QR, multi-device MLS leaf/revoke/rekey, history transfer/recovery/transparency, полный combined2G/ACK/SIGKILL/DB/media schedule, остальные authorization/retention/resource/load/fuzz/backup/platform/supply-chain проверки. Группы/каналы/посты, media/files/voice/video circles, disappearing/view-once, WebRTC/calls/push/admin/moderation в основном отсутствуют. Browser private chat выключен, Android/Apple artifacts не проверены.

Матрицы не повышены за частичную работу: P0 14PASS/1FAIL/11NOT_RUN; P1 2PASS/11NOT_RUN/1BLOCKED. V2 1PASS/18NOT_RUN/1BLOCKED. Ни один M0–M8/S0–S4 этап не объявлен завершённым.

## Запуск и продолжение

```bash
make bootstrap
make demo
# В другом терминале:
make build-linux
make client
```

API:https://127.0.0.1:5088; локальное письмо:http://127.0.0.1:58028. Для нового DM создайте два аккаунта, подтвердите почту, примите username-заявку и независимо сравните ключи. Профили make client хранит в ignored .local/profiles. Folder action выбирает прежний файл для resume, не заменяет потерянный пароль.

Адресные команды:

```bash
make onboarding-recovery
make gui-onboarding-recovery
make gui-smoke
make gui-pending-smoke
make native-cursor-recovery
make restore-v2
make native-network-gprs
make native-network-severe
make verify
make down
```

Перед GUI нужен make build-linux. Network suites выполняются последовательно с общим lock. make down завершился0, securemesh_db сохранён; тестовые API/GUI fixtures закрыты, стенд остановлен. Не трогать чужие сервисы/интерфейсы.

Следующий порядок: совместимое upstream security remediation; оставшиеся pre-journal/refresh crash edges; полный mixed-fault schedule; multi-device MLS/history/recovery; затем остальные S2–S4/M4–M8 функции. Продолжать существующие модули, не пересоздавать приложение.

GitHub origin: существующий приватный https://github.com/Misha1302/SecureMesh. Atomic push завершился0; remote Git readback подтвердил dfda7ca в main и codex/securemesh-v2. Доказательства — evidence/v2-resume-github-push.txt и v2-resume-github-readback.json. Следующий документационный коммит сохраняет их; git rev-parse HEAD определяет более новый итоговый checkout. REST/Actions readback после push завершился TLS timeout: cloud CI этого checkpoint NOT_CONFIRMED. Прежние Actions44419726144/44419726028 не запустили шаги из-за billing/spending limits; платёжные настройки не менялись. Source synchronization — не deployment. Публичный запуск требует завершённых gates, независимого аудита и отдельного разрешения.
