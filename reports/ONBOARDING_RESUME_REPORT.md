# Продолжение SecureMesh — незавершённый вход

2026-11-19. **PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.**

Код: `1c08659` — зашифрованный журнал и проверка challenge; `5cbdb01` — перевод уже показанной ошибки при смене языка. Это законченный локальный компонент, не готовность всего приложения и не восстановление потерянных устройств/истории.

## Что изменилось

До login POST идентичность OpenMLS и привязанный к origin/username журнал записываются одной транзакцией SQLCipher. До сетевой попытки сохраняется признак неопределённого результата; потерянный ответ и следующий неверный пароль не заменяют потенциально зарегистрированный ключ. Успешный session сохраняется до `/v1/users/me`; создание полного профиля и удаление журнала коммитятся вместе. Пароли аккаунта/хранилища в журнал не записываются. Новых криптопримитивов и plaintext fallback нет.

Перед подписью клиент проверяет назначение challenge, challenge ID, device ID, username, nonce и размер. Подмена этих привязок отклоняется до подписи/login POST. Session/account другого устройства не завершает профиль.

В Linux UI можно выбрать сохранённый файл и открыть его исходным локальным паролем. Незавершённый вход использует тот же ключ; сохранённый valid session не требует повторного login, истёкший просит пароль аккаунта. Pending-устройство остаётся без доступа к приватным чатам. RU/EN переключает и существующую ошибку, сохраняя введённый пароль. Детали: [ONBOARDING_RESUME.md](../docs/ONBOARDING_RESUME.md).

## Фактически выполнено

| Проверка | Результат | Доказательство |
|---|---|---|
| Rust build и прежние crypto/persistence/rekey negatives | exit 0 | evidence/v2-resume-crypto-build.txt; v2-resume-crypto.txt |
| Полный `make verify` | exit 2, 24/27 PASS | evidence/v2-resume-final-verify.txt |
| Финальный production Dart controller, API/PG/SQLCipher | exit 0, пять групп сценариев | evidence/v2-onboarding-challenge-recovery.txt; v2-onboarding-recovery.json |
| Analyzer после последней UI-правки | exit 0 | evidence/v2-resume-locale-analyze.txt |
| Linux debug build после последней UI-правки | exit 0 | evidence/v2-resume-locale-linux-build.txt |
| Настоящий GTK/Xvfb GUI, prepared/cached/expired | exit 0, 3/3 | evidence/v2-onboarding-gui-locale-fix.txt; v2-onboarding-gui.json |
| Независимый UI verdict | ship только по единственному scored fix | ../.impeccable/review/v2-onboarding-finish-report.md |
| Документирование и сохранение design tokens | выполнено в пределах отчёта | ../.impeccable/review/v2-onboarding-documentation-report.md |
| `make down` | exit 0, DB volume сохранён | evidence/v2-resume-down.txt |

Широкий прогон завершился до финальных challenge/locale изменений. После них выполнены адресные проверки выше; повтор всего aggregate не заявляется. Три красные группы — RustSec, original acceptance, V2 acceptance. Число незакрытых требований не уменьшалось за счёт ослабления матриц.

Controller-тест задерживает реальные HTTPS-ответы после серверного COMMIT и посылает SIGKILL собственным Dart process groups. Проверены lost reply, следующий неверный пароль, session до account fetch, истёкший session, abort до локального COMMIT, kill после COMMIT, чужие bindings и неверный локальный ключ. Повтор сохраняет устройство/ключ. Повтор login после потерянного ответа может создать второй session того же устройства; exactly-once выдача session не заявляется.

GUI использует реальные accepted API logins как fixtures и проверяет продолжение через интерфейс, а не выдаёт эти fixtures за GUI-исполнение crash boundaries. Число server sessions: prepared=2, cached=1, expired=2; приватный API возвращает 403 для pending. Пароли/токены проверены во всех сохранённых сегментах UI-log и API-log. Снимки — Linux 1280×720 и 320×844, light/default scale; это не Android/iOS, не screen-reader audit и не полный accessibility verdict.

## Неудачи сохранены

- Первый параллельный registration превысил старый 10s fixture timeout; отдельно тот же endpoint вернул 202 за 1.927s. Лимит не менялся: `v2-onboarding-recovery-initial-timeout.txt`, `v2-resume-register-diagnostic.txt`.
- Тестовый proxy не декодировал настоящий chunked POST и пересылал пустое тело; API правильно вернул `INVALID_REQUEST`. Исправлен только bounded decoder fixture; исходные FAIL/diagnostic logs сохранены.
- Новый chooser сначала получил context выше MaterialApp. Исправлен page context, добавлена widget-регрессия перехода; снимок `v2-resume-picker-context-fail.png` сохранён.
- Exploratory GUI-driver проверял завершение до click/wait. Исправлен порядок, assert не ослаблялся: `v2-onboarding-gui-initial-fail.json`.
- Первая успешная UI-регрессия имела одну review-находку: русская ошибка оставалась на EN-форме. Pre-fix лог/11 снимков/хеши сохранены как `v2-onboarding-gui-before-locale-fix.*` и `before-locale-fix-*`; повтор сохранил пароль при переключении и прошёл.

Предыдущие 26 aggregate logs восстановлены побайтно из коммита `6b2aefc`, SHA-256 проверены и сохранены под `baseline-6b2aefc-*`; прежняя сводка — `v2-final-summary-0343.json`. Текущая сводка отдельно описывает широкий прогон и последующие адресные проверки.

## Оставшиеся обязательные блокеры

Те же четыре RustSec findings: crypto-bigint 0.5.5 / RUSTSEC-2026-0387; libcrux-kem 0.0.9 / 0330, 0331; libsqlite3-sys 0.35.0 / 0459. DB advisory commit `472a4c9a785030434f15d7da84964d60fbe789ab`; предупреждение proc-macro-error2 также сохранено. Registry readback provider/storage не показал новых stable versions; один libsqlite3-sys запрос был недоступен. Появление более новых bigint/SQLCipher metadata не является проверенным совместимым remediation: `v2-resume-upstream-readback.json`. Ничего не проигнорировано.

Остаются pre-journal registration/email interruption, отдельная qualification refresh lost-reply/crash, keyring/keystore, QR, MLS multi-device membership/revoke/rekey, history transfer/recovery/transparency; полный mixed 2G/ACK/SIGKILL/DB/media schedule; группы/каналы/медиа/звонки и остальные M4–M8. Независимого security-аудита нет.

Шесть 2G-trials/2400 IDs остаются измерениями runtime `4b003dd` с совпадающими transport/controller source hashes и одним набором измеренных бинарников. После journal-изменения они не объявляются новым прогоном текущего crypto binary. Схема API остаётся с шестью миграциями; новый журнал использует существующую encrypted app_meta, серверная миграция не требовалась. Исходные ТЗ/checks/docs/v2 неизменны. Production не развёрнут.
