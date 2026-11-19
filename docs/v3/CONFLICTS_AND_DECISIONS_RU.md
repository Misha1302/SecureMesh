# SecureMesh V3 — аудит противоречий, решений и трассируемости ТЗ

Дата: 19 ноября 2026. Сверено по main 25b30e0: 01_TZ_PRODUCT_RU.md, 06_ROADMAP_RU.md, 07_TESTING_ACCEPTANCE_RU.md, AGENTS.md, docs/v2/01_FEATURE_CATALOG_RU.md, docs/v2/02_SECURITY_MULTIDEVICE_RU.md, docs/v2/04_ACCEPTANCE_ROADMAP_RU.md, STATUS.md и reports/TEST_RESULTS.md.

**Правило:** исходные V1/V2 документы по AGENTS.md immutable, поэтому новый требовательный слой V3 опубликован как addendum; прямые редактирования тех файлов не делаются. Старые AT-001..AT-040 и V2 тесты сохраняют силу. V3 имеет приоритет в **перечне целевых платформ, UX и полноте scope**, но не ослабляет original security, 2G, negative gates и audit. Архитектурное изменение — только с ADR/PoC. Отчёты STATUS/TEST_RESULTS фиксируют настоящую реализацию, а не «новую версию желаний».

| ID | Противоречие или пробел | Старое положение | Решение V3 | Проверка |
|---|---|---|---|---|
| C-01 | Android vs iOS | FR-U01: Android/Linux, далее iOS/Windows | Android и iOS обязательны; iOS не считать DONE без macOS/Xcode; при нет runner — BLOCKED, остаётся в scope | PL-01/02, V3-01/02 |
| C-02 | Desktop | Windows отложен в FR-U01/S4 | **Обе** настольные ОС Linux+Windows обязательны; это трактовка «два варианта» по контексту | PL-03/04, V3-03/04 |
| C-03 | «iPhone обязательно» vs «iOS как получится» | Неоднозначное пожелание | Финальная обязательная платформа, но честный временный platform blocker без релизного обмана | V3-02 |
| C-04 | Простота vs безопасность | Два самостоятельных пароля (account/store) в текущем Linux alpha | Нормальная работа с OS-bound unlock и минимум действий, но local secret/store, account auth, trusted device grant, E2EE recovery остаются разными границами | AU-01..05, V3-05..08 |
| C-05 | Telegram-like cloud UX vs E2EE приватность | Telegram default cloud chats не являются моделью E2EE, только UX референс | Cross-device sync через independent MLS device leaves, trusted onboarding, end-to-end history transfer, recovery key; нет серверной дешифрации | MD-01..06, V3-09..14 |
| C-06 | Скрыть сервер vs прозрачная безопасность | Local alpha показывает dev endpoint; config важна для TLS | Сервер не вводится обычным пользователем; официально доверенный origin управляется проверяемо, advanced custom server только явно и без отключения проверки identity/TLS | UX-01/05, V3-15 |
| C-07 | «Как Telegram» vs копирование | Оригинал уже запрещает копирование кода/бренда/визуала | Функциональные паттерны/сценарии с оригинальным дизайном и видимым режимом E2EE/public; не копировать интерфейс pixel-by-pixel | UX-03/08, V3-16/17 |
| C-08 | Доп.устройства частично работают | V2 approval + pending trust реализовано, но MLS leaf/history нет | Full multi-device стал обязательным P0; server session activation не является MLS join и не означает историю | V3-09..14 |
| C-09 | Важные медиа/каналы были P1 | V2 S2/S3 и FEAT P1 | Обязательны для FULL_PRODUCT_DONE, но после crypto/2G инфраструктуры; последовательные dependency milestones допустимы, «optional later» — нет | V3-18..24 |
| C-10 | 2G vs media/calls | Текст — P0, media/calls — другие режимы | Приоритет текст/ACK/MLS при 2G; calls не обещать на 2G, медиа deferred/resumable, не ухудшать SLI | V3-25..29 |
| C-11 | «без уменьшения скорости» | Текущие замеры только старой Linux-сборки | Nonregression на одинаковых binary/hardware/profile; не обещать абсолютное неухудшение без испытаний и budget. Нельзя снижать 15s p95 gate/sample size | V3-25..30 |
| C-12 | TDD или XP как «архитектура» | Tests есть, но E2E coverage неполная | Это метод разработки, не замена криптоархитектуры. Risk-driven TDD + contract + E2E per OS + fuzz + chaos + audit | V3-31..37 |
| C-13 | Web vs безопасная E2EE | ADR-008 conditional, WASM probe failed | Необязательный browser; public-only допустим, private E2EE запрещён до отдельной приемки; Linux/Windows native остаются | V3-38 |
| C-14 | Публичный канал vs private group | Public content server-readable, closed E2EE | В UI строго различать modes; invite-only public channel server-readable, нельзя обещать E2EE везде | V3-21/22 |
| C-15 | План «полный продукт» vs milestones | Ни один M0..M8/S0..S4 не complete; acceptance P0 14 PASS/1 FAIL/11 NOT_RUN; P1 2 PASS/11 NOT_RUN/1 BLOCKED; V2 1 PASS/18 NOT_RUN/1 BLOCKED | Никакие статус/процент готовности не повышаются из-за появления нового ТЗ. Реализация и аудит остаются отдельными шагами | STATUS.md; acceptance |
| C-16 | Автономность vs контроль владельца | AGENTS запрещает prod/deploy/real users | Codex автономно редактирует, тестирует и публикует в development branch; production, Stores, реальные credentials, платные ресурсы требуют явной авторизации | V3 gates |
| C-17 | iOS background / mobile tests vs отсутствие runner | Linux Xvfb не равно phone; cloud CI billing blocked | iOS/macOS/Windows/Android получают независимые platform states; background push best-effort, приоритет encrypted queue/recovery | V3-01..04, V3-32 |

## Соответствие текущей реализации (факты на момент фиксации)

Готово **лишь частично**: .NET API/PG, verified accounts/rotating sessions, OpenMLS/SQLCipher DM, WSS/HTTPS 2G native Linux, offline queue/dedup, Linux signup/chat, signed pending device grant, interrupted sign-in journal. См. STATUS.md.

Не завершено и **не может быть повышено** из-за документа: four RustSec findings, independent audit, device MLS leaf/old history/recovery, keyring integration, Android/iOS/Windows builds/E2E, combined chaos, groups/channels, files/voice/video/calls, account deletion, web E2EE. Последний общий make verify exit2, 24/27 groups pass; проверки V3 пока NOT_RUN.

## Принятие V3 как authoritative execution baseline

1. В безопасной ветке хранить пять артефактов: PRODUCT_REQUIREMENTS_RU.md, ARCHITECTURE_RESEARCH_RU.md, TEST_STRATEGY_RU.md, ACCEPTANCE_MATRIX.csv, CODEX_AUTONOMOUS_PROMPT_RU.md.
2. Добавить указатель в README/AGENTS только после проверки, что V3 не уменьшает V1/V2 safety gates. Исходные брифы и checks не переписывать.
3. Создать working reports/V3_ACCEPTANCE_MATRIX.csv и backlog по ID; status сначала NOT_RUN. Не «подсвечивать зеленым» требование, лишь потому что в предыдущем проекте была похожая функция.
4. Код/сервер/секреты не менялись при создании этого addendum. Документальный PR не означает завершение фич и не разрешает production.
5. Если для одной функции неизбежен tradeoff между удобством и безопасностью, сохранять безопасность и предоставить честное UI-пояснение/безопасный fallback; не «выбирать» удобство ослаблением E2EE. Если платформа технически недоступна, требование остаётся обязательным со статусом BLOCKED.

## Внешние основания

- Flutter target platforms: https://docs.flutter.dev/reference/supported-platforms
- Flutter iOS Xcode/macOS: https://docs.flutter.dev/deployment/ios
- Apple iOS Keychain ThisDeviceOnly: https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
- Android Keystore: https://developer.android.com/privacy-and-security/keystore
- MLS RFC 9420 and 9750: https://www.rfc-editor.org/rfc/rfc9420.html ; https://www.rfc-editor.org/rfc/rfc9750.html
- NIST SP 800-63B: https://pages.nist.gov/800-63-4/sp800-63b.html
- OWASP MASVS: https://mas.owasp.org/MASVS/03-Using_the_MASVS/
- Flutter actual integration tests: https://docs.flutter.dev/testing/integration-tests
- Telegram UX/cloud/secret-chat difference: https://telegram.org/faq
