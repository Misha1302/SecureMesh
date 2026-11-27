# SecureMesh — local development checkpoint

Для первого изменения в проекте см. [руководство участника](CONTRIBUTING.md).

## SecureMesh V3: обязательные требования (19.11.2026)

Нормативное дополнение к неизменяемым исходным ТЗ/V2: [платформы, UX и полный функционал](docs/v3/PRODUCT_REQUIREMENTS_RU.md), [архитектурное исследование](docs/v3/ARCHITECTURE_RESEARCH_RU.md), [TDD/E2E стратегия](docs/v3/TEST_STRATEGY_RU.md), [матрица из 44 сценариев](docs/v3/ACCEPTANCE_MATRIX.csv), [аудит противоречий](docs/v3/CONFLICTS_AND_DECISIONS_RU.md), [полный автономный промпт Codex](docs/v3/CODEX_AUTONOMOUS_PROMPT_RU.md).

Целевые native приложения **Android, iOS, Linux и Windows** (оба desktop варианта Linux+Windows обязательны); простой Telegram-подобный UX с безопасным локальным unlock и скрытыми серверными настройками; настоящий trusted multi-device MLS/history/recovery; группы, каналы, посты, приватные файлы, голосовые, кружочки и звонки; реальные E2E/chaos/performance проверки. Web private chat только после отдельного E2EE security gate, иначе disabled. Появление требований не значит их реализацию: см. STATUS.md и reports/TEST_RESULTS.md. **PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.**


**PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.** A real encrypted-text vertical slice, not the complete product in the immutable Russian brief. The patched native dependency candidate uses prerelease OpenMLS crates and still needs platform acceptance and independent review. See [security limitations](docs/SECURITY_LIMITATIONS.md). Do not use this alpha with real sensitive data.

Early qualitative user feedback, product positioning and the proposed 10–20-person pilot are documented in [USER_FEEDBACK_AND_PILOT_2026-11-19_RU.md](docs/USER_FEEDBACK_AND_PILOT_2026-11-19_RU.md). This is a research hypothesis, not evidence of market fit, security certification, or permission for a public launch.

Implemented/exercised: .NET 10 API/PostgreSQL migrations; Mailpit verification; Argon2id/device proof/rotating sessions; OpenMLS 0.9.2 and SQLCipher; durable message/outbox and scoped cursors. Native Flutter now has registration/verification/login, consented DM requests by username, independently compared device keys and server-routed signed Welcome. WSS-first protobuf delivery has bounded pipelining, HTTPS fallback and recovery. Additional-device login stays pending until a trusted-device grant is verified locally and activated. Full multi-device MLS/history recovery remains incomplete.

```sh
make bootstrap
make demo                 # foreground TLS API, Ctrl-C to stop
# another terminal:
make smoke
make verify               # nonzero for known security/incomplete gates
make down                 # only SecureMesh, preserves DB volume
```

Requirements: Linux, Docker/Compose, Python 3, OpenSSL, .NET SDK 10.0.111, Rust 1.94.1. Credentials are generated into ignored .env; SDKs/stores/runtime files live in ignored .local. Test clients explicitly trust the local certificate; verification is never disabled. API: https://127.0.0.1:5088. Mailpit: http://127.0.0.1:58028. Production startup is disabled.

For the actual Linux UI:

```sh
bash scripts/install-flutter.sh   # pinned 3.50.0, ~1.5 GB archive, SHA-256 checked
make build-linux                 # GTK toolchain in project-only container
# keep make demo running, then:
make client
```

Choose “Создать аккаунт или войти”, register and retrieve the development verification code from Mailpit at http://127.0.0.1:58028. The local-store passphrase is separate and never sent to the API. New Linux profiles are kept under ignored .local/profiles by make client. Use a second account/device to accept a username request and independently compare public keys before messaging. Approval alone does not import old history: transfer/recovery is still unavailable.

If sign-in is interrupted after the device keys are prepared, use the folder action on the unlock screen and the original store passphrase. Continue the same device instead of creating another one; a saved valid session finishes directly, an expired session asks for the account password. This does not recover a lost store/passphrase or another device's history. See [resume behavior and limits](docs/ONBOARDING_RESUME.md).

Optional synthetic two-account setup: make seed-demo, then open make client twice with the two paths/unlock values in ignored mode-600 .local/demo/profiles.json. The seed now uses the actual accepted-request/KeyPackage/Welcome API; no chat messages are prewritten. Never use that file as real recovery. Groups, channels, media, calls and admin UI remain incomplete.

The original Python suites are make network-gprs and make network-severe; their historical 2400-ID baseline is in the [2G report](reports/2G_REPORT.md). The actual production Dart delivery controller has separate make native-network-gprs and make native-network-severe suites, each with 200 messages per direction and seeds 7/19/41: [native results and limits](reports/NATIVE_2G_REPORT.md). Network suites share an exclusive lock and must run sequentially. Raw failures are retained; the GPRS p95 gate stays 15 seconds. Steady-link measurements do not complete the combined crash/blackout/DB/media schedule or prove carrier performance.

After make build-linux, make gui-smoke exercises real signup/DM/offline/SIGKILL/reopen in an owned GTK/Xvfb container; make gui-pending-smoke checks pending-device UI and server denial. make native-cursor-recovery runs a real 60-second WSS/HTTPS blackout and 1000-event ordered recovery. make restore-v2 restores the current six-migration database into an isolated local DB and verifies a routed DM, fresh login and original-client decryption.

make onboarding-recovery tests the production Dart setup controller with real API/SQLCipher, malicious challenge bindings, lost replies and SIGKILL boundaries. After make build-linux, make gui-onboarding-recovery drives the saved-profile chooser and prepared/cached/expired resume, wrong-passphrase correction and RU/EN feedback in the actual Linux UI.

make verify aggregates implemented build/crypto/API/trust/directory/restore/epoch/secret-pattern/format/widget/native checks, RustSec and both acceptance gates. It also validates native measurement provenance and metrics from retained full-size trials; long live network/GUI/blackout and disruptive DB checks have separate commands. Missing tools or failed/incomplete required gates remain failures. A component pass does not complete an unfinished acceptance row. See [STATUS](STATUS.md), [matrix](reports/TEST_RESULTS.md), [handoff](reports/FINAL_HANDOFF_RU.md).

Linux was built/launched in Xvfb, including real GUI signup, routed DM, Unicode exchange and offline/SIGKILL/reopen delivery. Compact Linux is layout evidence, not Android verification. Android and Apple artifacts remain unverified. Browser private chat stays disabled pending a distinct WASM integration. No production deployment. V2 work is on codex/securemesh-v2; git status/log and STATUS.md are authoritative.
