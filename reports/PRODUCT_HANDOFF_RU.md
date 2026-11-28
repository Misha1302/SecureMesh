# Передача продукта SecureMesh — 28 ноября 2026

## Решение и база

Текущая база кандидата — `origin/modernization-integration` (`00084b8`, 28.11.2026). Аудитная ветка `audit/modernization-20261127` (`e653e18`) добавляет один коммит поверх кандидата; её отдельный прогон удаления аккаунта в изолированном Linux keyring не следует считать частью candidate. Главная ветка GitHub проверена через API: `main` = `59d5e752c980c612943c0863d3d47cb788cb9f87`. PR #3 открыт (head совпадает с `00084b8`). PR #4 закрыт; это отдельный документальный PR `ТЗ на Key Transparency и проверку получателей MLS` (head `ca5ed54`), не часть candidate. Локальные `main`/`origin/main` и checkout-копии могут быть устаревшими — при интеграции ориентироваться на API и актуальный remote.

В delivery checkout одновременно ведётся незакоммиченная работа: Flutter onboarding; публичный Caddy config и profile UI сайта; API Identity/VerificationEmailQueue и EmailTokenOwner migration. Точный `git status` менялся во время проверки. Эти изменения не входят в подтверждённый candidate SHA и не считаются проверенными этой передачей.

## Короткий статус

**Не готово к production.** Актуальный агрегат `reports/TEST_RESULTS.md` сообщает `PARTIAL / NOT_READY`, `PRODUCTION_APPROVED=false`: P0 — 14 PASS, 1 FAIL, 11 NOT_RUN; P1 — 2 PASS, 11 NOT_RUN, 1 BLOCKED. Последний полный `make verify` завершился с кодом 2: 24/27 групп прошли, RustSec и оба acceptance gate не прошли. Более поздние точечные проверки onboarding/localization и Android media не заменяют новый полный агрегатный прогон.

## Матрица платформ

Статусы ниже — узкие проверенные сценарии, не общая сертификация платформы. Источник: `reports/PLATFORM_MATRIX.csv` плюс более поздние candidate evidence.

| Платформа | Статус на candidate | Доказательство / предел |
|---|---|---|
| Linux | PASS | `reports/evidence/linux-build-v5.txt`, `native-dart-ffi.txt`, `ui-linux-final.png`; полноценный локальный GUI/FFI сценарий. |
| Android | INTEROP + частично реальные устройства | API 28 установленный APK обменялся MLS-сообщениями с Linux; API 35 UI, камера/аудио проверены на эмуляторе в последнем candidate workflow; физический Xiaomi Android 15 подтверждает регистрацию и текст, но не завершённый медиасценарий. `reports/evidence/android-linux-recheck-20261127/interop.json`, `reports/evidence/native-ui-20261127/`, `reports/evidence/xiaomi-android15-20261127/`; `tests/android/video_capture.py`. Камера/аудио физического устройства и полная platform acceptance ещё нужны. |
| Web / PWA | WEB artifact + Safari simulator SUCCESS; production private chat DISABLED | Текущие Flutter web app содержит WASM MLS lab/probe; это исследовательская интеграция, не включённый production private chat. Приложение прямо отключает private chats до проверки browser crypto. См. `apps/client_flutter/lib/public_web.dart`, `reports/evidence/wasm-probe.txt`, `tests/pwa/`; hosted package run 46085427987 и Safari simulator 46085428014 прошли на SHA 00084b8. Публичный сайт отдельно публикуется workflow `.github/workflows/pages.yml` только при push в `main`; это не PWA deployment. |
| iOS | UNSIGNED_BUILD | Есть unsigned bundle; подпись, установка и acceptance на устройстве остаются незавершёнными. `docs/PLATFORM_RELEASE_RU.md`, `.github/workflows/ios.yml`. |
| Windows | CANDIDATE_BUILD | Native library упакована; полная приёмка сообщений на Windows не выполнена. `.github/workflows/desktop-bundles.yml`. |
| macOS | BLOCKED_NO_MACOS | Нет доступного macOS/Xcode runner, успешная сборка не заявлена. |

## Сеть, безопасность и зависимости

- Native GPRS/severe результаты в `reports/NATIVE_2G_REPORT.md`, `reports/evidence/v2-native-network-report.txt` и `reports/evidence/native-network-report.txt` ограничены измеренным runtime `4b003dd`; шесть удержанных прогонов дали 2400 уникальных ID без потерь/дубликатов. Текущая более новая journal-сборка не переизмерена; смешанный сценарий crash + DB + ACK loss + media остаётся NOT_RUN. Не переносить старую PASS на новый бинарник.
- P0 AT-023 остаётся FAIL: `reports/evidence/rustsec-current.txt` перечисляет четыре RustSec advisories и предупреждение о неподдерживаемом crate. Совместимое обновление не найдено; игнорирований нет. Это release blocker.
- Dart Pub: OSV-запрос охватил 55 lock versions с положительным контролем; 55 license texts сохранены (`reports/evidence/v2-pub-osv.txt`, `reports/PUB_LICENSE_INVENTORY.json`). SPDX/legal review не выполнен. Полная multi-ecosystem SBOM, контейнерный аудит и reachability review также остаются открытыми (`docs/SECURITY_LIMITATIONS.md`).


## Свежая проверка hosted CI

По GitHub Actions API для candidate SHA `00084b8002e3ac554963169c91fcf366129d7fd1` (workflow run set от 27.11.2026, run IDs `46085427975`–`46085428024`) на момент чтения:

| Код | Проверка | Статус | Что именно подтверждает |
|---|---|---|---|
| A | Local checks `46085427975` | IN_PROGRESS | Итоговую проверку candidate ещё нельзя считать завершённой. |
| B | iPhone alpha `46085428024` | IN_PROGRESS | Job `profile-unlock-simulator` ещё выполнялся; не объявлять iOS run успешным целиком. |
| C | Desktop release candidates `46085427986` | SUCCESS | Сборка desktop artifacts прошла; это не полная Windows messaging acceptance. |
| D | Android release-mode `46085428011` | SUCCESS | `verified-apk`, `android-linux-interop` успешно; package-and-launch skipped. Это не доказательство физического устройства. |
| E | Package SecureMesh web app `46085427987` | SUCCESS | Web artifact packaged. |
| F | PWA iPhone Safari simulator `46085428014` | SUCCESS | Jobs `package` и `safari` прошли на candidate SHA. Simulator run, не физический iPhone. |
| G | Native severe netem seed 7 | SUCCESS | Один hosted severe-network seed. |
| H | Native severe netem seed 19 | SUCCESS | Один hosted severe-network seed. |
| I | Native severe netem seed 41 | SUCCESS | Один hosted severe-network seed. |
| J | Native GPRS seeds 7/19/41 | IN_PROGRESS | Все три jobs были ещё в работе; aggregate network result не завершён. |
| K | Cargo audit в локальной среде | NOT RUN | `cargo audit --version` сообщает, что cargo subcommand не установлен. Свежий advisory scan этим запуском не получен. |

Это моментальный readback, а не окончательный статус CI: повторить API query перед merge и связать результат с точным SHA.

## Что осталось сделать

1. Устранить или обосновать/эскалировать RustSec находки через совместимое обновление; затем повторить полный dependency, SBOM и license review без подавления advisories.
2. После изменений candidate выполнить свежий полный `make verify` и оба acceptance gate, сохранить hash исходников/бинарников и заменить устаревшие агрегатные статусы только подтверждёнными результатами.
3. Завершить Android физическое media acceptance; подписать и проверить iOS на устройстве; завершить Windows messaging acceptance; получить macOS runner. Для PWA сохранить результаты прошедших hosted package и Safari simulator runs вместе с точным SHA; production private chat остаётся отключён.
4. Провести смешанный сетевой fault schedule на том же runtime, который собирается к релизу; добавить media fairness, crash/platform и восстановление object storage/keyring/media.
5. Закрыть остающиеся P0/P1 сценарии из `reports/TEST_RESULTS.md`: password recovery, полные RBAC/operator-dump проверки, группы и multi-device MLS membership/rekey/history, QR enrollment, attachments, channels/search/moderation, voice/video/WebRTC, admin MFA/audit и assistive-tech acceptance.
6. Разобрать текущие uncommitted API/email/onboarding/site изменения отдельными изменениями с тестами и собственной проверкой; не путать их со SHA candidate и не включать автоматически в документальный коммит.

## Источники истины

Матрицы и подробные пределы: `reports/TEST_RESULTS.md`, `reports/PLATFORM_MATRIX.csv`, `reports/ACCEPTANCE_MATRIX.csv`, `reports/V2_ACCEPTANCE_MATRIX.csv`, `reports/V3_ACCEPTANCE_MATRIX.csv`. Свежие candidate evidence — `reports/evidence/`; старые baseline/previous captures сохранять как историю, не использовать как доказательство свежего candidate. CI workflow definitions — `.github/workflows/`. Для состояния GitHub main/PR использовать API readback непосредственно перед merge: проверка main в этой передаче вернула `59d5e752c980c612943c0863d3d47cb788cb9f87`.
