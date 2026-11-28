# Передача продукта SecureMesh — 28 ноября 2026

## Решение и база

Текущая база кандидата — `origin/modernization-integration` (`00084b8`, 28.11.2026). Аудитная ветка `audit/modernization-20261127` (`e653e18`) добавляет один коммит поверх кандидата; её отдельный прогон удаления аккаунта в изолированном Linux keyring не следует считать частью candidate. Главная ветка GitHub проверена через API: `main` = `59d5e752c980c612943c0863d3d47cb788cb9f87`. PR #3 открыт (head совпадает с `00084b8`). PR #4 закрыт; это отдельный документальный PR `ТЗ на Key Transparency и проверку получателей MLS` (head `ca5ed54`), не часть candidate. Локальные `main`/`origin/main` и checkout-копии могут быть устаревшими — при интеграции ориентироваться на API и актуальный remote.

Рабочая копия delivery на момент передачи уже содержит незакоммиченные изменения API и Rust directory (Identity.cs, Program.cs, directory.rs, очередь verification email и миграция). Этот handoff не подтверждает и не описывает их как прошедшие проверку. Изменять/коммитить их следует отдельной задачей; этот коммит предназначен только для отчёта.

## Короткий статус

**Не готово к production.** Актуальный агрегат `reports/TEST_RESULTS.md` сообщает `PARTIAL / NOT_READY`, `PRODUCTION_APPROVED=false`: P0 — 14 PASS, 1 FAIL, 11 NOT_RUN; P1 — 2 PASS, 11 NOT_RUN, 1 BLOCKED. Последний полный `make verify` завершился с кодом 2: 24/27 групп прошли, RustSec и оба acceptance gate не прошли. Более поздние точечные проверки onboarding/localization и Android media не заменяют новый полный агрегатный прогон.

## Матрица платформ

Статусы ниже — узкие проверенные сценарии, не общая сертификация платформы. Источник: `reports/PLATFORM_MATRIX.csv` плюс более поздние candidate evidence.

| Платформа | Статус на candidate | Доказательство / предел |
|---|---|---|
| Linux | PASS | `reports/evidence/linux-build-v5.txt`, `native-dart-ffi.txt`, `ui-linux-final.png`; полноценный локальный GUI/FFI сценарий. |
| Android | INTEROP + частично реальные устройства | API 28 установленный APK обменялся MLS-сообщениями с Linux; API 35 UI, камера/аудио проверены на эмуляторе в последнем candidate workflow; физический Xiaomi Android 15 подтверждает регистрацию и текст, но не завершённый медиасценарий. `reports/evidence/android-linux-recheck-20261127/interop.json`, `reports/evidence/native-ui-20261127/`, `reports/evidence/xiaomi-android15-20261127/`; `tests/android/video_capture.py`. Камера/аудио физического устройства и полная platform acceptance ещё нужны. |
| Web / PWA | PUBLIC_ONLY | Сборка и браузерные проверки не означают приватный чат: WASM probe не подтверждает native MLS, private chat отключён. См. `reports/evidence/wasm-probe.txt`, `tests/pwa/` и Pages workflow `.github/workflows/pages.yml`. Учитывать самый свежий candidate PWA run, а не прежние simulator notes. |
| iOS | UNSIGNED_BUILD | Есть unsigned bundle; подпись, установка и acceptance на устройстве остаются незавершёнными. `docs/PLATFORM_RELEASE_RU.md`, `.github/workflows/ios.yml`. |
| Windows | CANDIDATE_BUILD | Native library упакована; полная приёмка сообщений на Windows не выполнена. `.github/workflows/desktop-bundles.yml`. |
| macOS | BLOCKED_NO_MACOS | Нет доступного macOS/Xcode runner, успешная сборка не заявлена. |

## Сеть, безопасность и зависимости

- Native GPRS/severe результаты в `reports/NATIVE_2G_REPORT.md`, `reports/evidence/v2-native-network-report.txt` и `reports/evidence/native-network-report.txt` ограничены измеренным runtime `4b003dd`; шесть удержанных прогонов дали 2400 уникальных ID без потерь/дубликатов. Текущая более новая journal-сборка не переизмерена; смешанный сценарий crash + DB + ACK loss + media остаётся NOT_RUN. Не переносить старую PASS на новый бинарник.
- P0 AT-023 остаётся FAIL: `reports/evidence/rustsec-current.txt` перечисляет четыре RustSec advisories и предупреждение о неподдерживаемом crate. Совместимое обновление не найдено; игнорирований нет. Это release blocker.
- Dart Pub: OSV-запрос охватил 55 lock versions с положительным контролем; 55 license texts сохранены (`reports/evidence/v2-pub-osv.txt`, `reports/PUB_LICENSE_INVENTORY.json`). SPDX/legal review не выполнен. Полная multi-ecosystem SBOM, контейнерный аудит и reachability review также остаются открытыми (`docs/SECURITY_LIMITATIONS.md`).

## Что осталось сделать

1. Устранить или обосновать/эскалировать RustSec находки через совместимое обновление; затем повторить полный dependency, SBOM и license review без подавления advisories.
2. После изменений candidate выполнить свежий полный `make verify` и оба acceptance gate, сохранить hash исходников/бинарников и заменить устаревшие агрегатные статусы только подтверждёнными результатами.
3. Завершить Android физическое media acceptance; подписать и проверить iOS на устройстве; завершить Windows messaging acceptance; получить macOS runner. Для PWA зафиксировать один актуальный браузерный run с точными функциями public-only и ограничениями.
4. Провести смешанный сетевой fault schedule на том же runtime, который собирается к релизу; добавить media fairness, crash/platform и восстановление object storage/keyring/media.
5. Закрыть остающиеся P0/P1 сценарии из `reports/TEST_RESULTS.md`: password recovery, полные RBAC/operator-dump проверки, группы и multi-device MLS membership/rekey/history, QR enrollment, attachments, channels/search/moderation, voice/video/WebRTC, admin MFA/audit и assistive-tech acceptance.
6. Разобрать незакоммиченные API/verification-email/directory изменения в отдельном изменении с миграцией, тестами и собственной проверкой. Не включать их автоматически в этот документальный коммит.

## Источники истины

Матрицы и подробные пределы: `reports/TEST_RESULTS.md`, `reports/PLATFORM_MATRIX.csv`, `reports/ACCEPTANCE_MATRIX.csv`, `reports/V2_ACCEPTANCE_MATRIX.csv`, `reports/V3_ACCEPTANCE_MATRIX.csv`. Свежие candidate evidence — `reports/evidence/`; старые baseline/previous captures сохранять как историю, не использовать как доказательство свежего candidate. CI workflow definitions — `.github/workflows/`. Для состояния GitHub main/PR использовать API readback непосредственно перед merge: проверка main в этой передаче вернула `59d5e752c980c612943c0863d3d47cb788cb9f87`.
