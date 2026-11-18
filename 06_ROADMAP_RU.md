# Roadmap автономной реализации

## Подход

Работать **вертикальными срезами**, а не «30 тысяч строк infrastructure до первого сообщения». Каждый этап имеет реальный вход/выход, tests, demo, commit и STATUS. Никаких фиктивных завершений. Зафиксировать исходное состояние репозитория и не перезаписывать чужую работу.

### M0 — Init / environment / foundations [P0]

**Сделать:** изучить весь bundle; инвентаризация SDK/Docker; создать git repo/branch при необходимости; `PLAN.md` с приоритетами, `STATUS.md`; .NET API, Docker compose PostgreSQL/MinIO/Mailpit/Redis optional, здоровье backend, migrations, CI skeleton, Makefile. Не трогать сторонние сервисы.

**Gate:** чистая установка, `make bootstrap`, `make smoke`, health 200, migration idempotence, no secrets.

### M1 — Crypto feasibility + threat model [P0]

**Сделать:** реальный OpenMLS Rust proof-of-concept: 2 устройства, приглашение, message, third member add/remove, rekey, state persisted and recovered; Dart/Flutter bridge Linux/Android, web WASM spike. Keypackage/credential binding, negative replay tests; README с конкретной ciphersuite/ограничениями.

**Gate:** 2 independently simulated devices encrypted/decrypted real MLS after restart; серверный процесс не содержит private keys; explicit web status; security tests green. Это обязательный критический путь.

### M2 — Identity / devices / basic secure UX [P0]

**Сделать:** registration/login, username/email, Argon2id, verified email dev, token rotation, user/profile, device directory, trust/device change UX, Flutter screens and encrypted DB. Admin MFA scaffold. Интеграция с M1 через реальные устройства.

**Gate:** два аккаунта создаются, входят, получают независимые device keys; reset не выдаёт старые keys, negative IDOR tests.

### M3 — Reliable 2G text delivery [P0 — главная веха]

**Сделать:** Protobuf WSS framing + HTTPS fallback, durable idempotent server write, per-device cursor and ACK, local SQLite outbox, reconnect, resume, multi-device, private 1:1 MLS, minimal chat UI. Separate MLS commit ordering.

**Gate:** успешный A↔B text with offline/cold restart, 2G deterministic test suite P0, zero logical duplicates/data loss after durable ack; logs and p95. **Не переходить к тяжёлым медиа, если фундамент доставки сломан.**

### M4 — Closed groups + public spaces [P0/P1]

**Сделать:** MLS group add/remove/roles/epoch, 1:1 multiple devices, public channels, posts, feed, search public, moderation public, group invites/ban; distinct UI privacy state.

**Gate:** e2e group membership/epoch/rekey after revoke; public feed works without private message leakage; authorization negative tests.

### M5 — Media pipeline [P1]

**Сделать:** S3 multipart/resume, client-side E2EE, uploads, files, image, GIF/video, voice Opus, round video; server public transcode worker; quotas, safe parsers, bandwidth-aware queues.

**Gate:** cross-device E2EE media decrypt; interrupted upload resumes; private keys never server visible; media paused and text prioritized on 2G; media display/playback on platforms claimed.

### M6 — Calls + polished UI [P1]

**Сделать:** 1:1 WebRTC audio/video calls with local TURN, reconnect; adaptivity themes, accessibility RU/EN, registration/chat/feed/profile/settings/admin flows, media capture UX; design-system snapshots.

**Gate:** call tests on supported devices, route failure behavior, no false «group E2EE video calls» promise. UI regression tests, responsive layouts.

### M7 — Security/reliability hardening [P0 for release]

**Сделать:** OWASP ASVS checklist, threat model, fuzz/parsing limits, secret scans, dependency/containers scans, race/chaos/load test, backups/recovery drill, observability; data retention and account deletion. Indep. audit required post-handoff for production.

**Gate:** security P0 automated suite passes; no plaintext private message logs; `make verify` all available gates; if unverified list explicit blockers.

### M8 — Autonomous delivery package, NO deployment [P0]

**Сделать:** end-to-end `make demo`, `make verify`, verified evidence under reports, CLI demo flows, cleaned docs/runbooks, schema migrations, `deploy/compose.staging.yaml`, `deploy/README.md`, configuration templates, basic backup/restore scripts tested only in isolated test env. Commits on safe branch. Owner handoff includes only commands, not secrets.

**Gate:** explain what works, what tests passed and where, source commit SHA, supported platform artifacts, unreleased security risks, future server prerequisites and `DEPLOYMENT_READY = yes/no`, with independent audit explicitly incomplete.

## Строгий порядок при дефиците времени/контекста

1. Сохранить реальное состояние и следующий шаг (`STATUS.md`, `PLAN.md`).
2. Довести текущий вертикальный срез до проходящих тестов.
3. Не ставить `DONE`, если тесты не прошли/не запускались; статусы: `DONE_VERIFIED`, `IMPLEMENTED_UNVERIFIED`, `PARTIAL`, `BLOCKED`.
4. Если ограничение окружения (нет macOS/credentials/internet) — зафиксировать и продолжить независимые задачи; не зависать на внешнем ресурсe.
5. Не заменять настоящие модули фейками и не ослаблять требования ради зелёной CI.

## Продуктовые приоритеты

Релиз **Local Alpha**: M0–M3 + базовая регистрация/E2EE/2G; **Local Beta**: M4–M6; **Delivery Candidate (unaudited)**: M7–M8. Public launch — после отдельного независимого security and ops approval, **вне автономного задания**.

## Working checkpoints в каждом коммите

```
STATUS.md
  HEAD: <sha>
  last_verified_step: <M# and test name>
  done: [ids]
  failed: [ids + true diagnostic]
  environment blockers: [exact text]
  next: [concrete commands]
reports/evidence/<YYYY-MM-DD>_<phase>.txt
  commands, stdout/stderr redacted, exit codes, environment versions
```

## Декомпозиция задач для Codex (пример границ)

- `task/01` crypto core standalone tests; `task/02` device registry/auth; `task/03` durable message store; `task/04` framed transport; `task/05` Flutter offline store; `task/06` integration reconnect; `task/07` group MLS; `task/08` public channels; `task/09` media; `task/10` calls; `task/11` admin; `task/12` hardening.
- Мердж делать после компиляции и tests, без конфликтов и silent loss; предпочтительно работать в одной ветке последовательно, если нет независимых рабочих деревьев.
