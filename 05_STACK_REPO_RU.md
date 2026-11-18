# Инструменты, стек, структура и воспроизводимость

## 1. Зафиксированные архитектурные решения

| Слой | Выбор | Почему | Ограничение |
|---|---|---|---|
| Backend | C# + ASP.NET Core on **.NET 10 LTS** | Профилирование, tooling, async, зрелая инфраструктура | Pin SDK/toolchain |
| Persistence | PostgreSQL 18 или поддерживаемая версия с зафиксированным image digest | ACID, unique constraints, relational auth/data | Migration/backup required |
| ORM | EF Core 10 + Npgsql | миграции, транзакции, оптимизация запросов | Не скрывать N+1 |
| Transport | WSS + binary Protobuf + HTTPS sync fallback | низкий overhead и reconnect | bounded queues и framing |
| Client | Flutter stable (Dart) для Android, Linux, iOS, Windows, macOS, web | единая кодовая база и UI | Platform SDK/crypto bridge spike |
| E2EE | Rust `openmls` (RFC 9420) | существующий криптографический протокол | Нужно реализовать AS/DS и проверить integration |
| FFI | flutter_rust_bridge (pin version) | Dart ↔ Rust bridge | WASM-specific limitations |
| Client DB | SQLite с надёжным encryption provider | offline-first | secure key management |
| Media | MinIO dev; S3-compatible production | дешёвое object storage + chunked upload | private assets encrypted client-side |
| Ephemeral cache | Redis, **optional** | presence, rate-limit, caching | не authoritative store |
| Calls | WebRTC + coturn | NAT traversal + A/V | external endpoints later |
| Dev mail | Mailpit | тестируемый e-mail без реальной рассылки | off in production |
| Network tests | `tc netem` inside namespace + Toxiproxy | reproducible outages/latency/bandwidth | no host network changes |
| Load tests | k6 or NBomber (one selected) | measurable transport/message load | run separately from unit tests |
| Telemetry | OpenTelemetry + Prometheus/Grafana (optional local profile) | audits, observability | no private plaintext |
| CI | GitHub Actions workflows | automatic builds/tests/lint | matrix runner constraints |

Не начинать с Kafka/NATS/Kubernetes, Elasticsearch, event sourcing или federation. Это будущие оптимизации при измеренной необходимости.

## 2. Технический spike до массовой разработки

Создать Rust crypto_core с OpenMLS; два **разных реальных процесса/клиента** заводят identity, через test Delivery Service выполняют join, encrypt/decrypt 1:1, добавляют/удаляют третьего участника, сериализуют и перезапускают state. Затем Flutter native через FFI: Android + Linux; отдельный attempt web WASM bridge. Закрепить версии зависимостей, licenses, smoke integration tests и документировать ограничения. Если одна связка не работает, исправить/заменить в рамках существующих RFC и libraries с ADR; нельзя использовать fake encrypt или AES с общим серверным ключом в качестве замены E2EE.

## 3. Рекомендуемая структура создаваемого репозитория

```text
.
├── AGENTS.md
├── README.md
├── STATUS.md                        # агент обновляет по этапам
├── PLAN.md                          # живой backlog и gates
├── Makefile                         # make bootstrap, demo, verify, smoke, down
├── global.json                      # fixed .NET SDK roll-forward policy
├── pubspec.lock / Cargo.lock        # lock dependencies in proper directories
├── docker-compose.yml
├── .env.example                     # placeholders only
├── .github/workflows/
│   ├── backend.yml
│   ├── client.yml
│   └── security.yml
├── apps/
│   ├── client_flutter/
│   └── admin_web/                    # optional: integrated Flutter admin UI preferred
├── src/
│   ├── SecureMesh.Api/
│   ├── SecureMesh.Core/
│   ├── SecureMesh.Infrastructure/
│   ├── SecureMesh.Workers/
│   └── crypto_core/                  # Rust crate, OpenMLS
├── contracts/
│   ├── wire.proto
│   └── openapi.yaml
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── crypto/
│   ├── chaos-2g/
│   ├── e2e-flutter/
│   └── load/
├── deploy/
│   ├── compose.staging.yaml
│   ├── nginx-or-caddy.conf.template
│   ├── backups/
│   └── README.md
├── scripts/
│   ├── bootstrap.sh
│   ├── verify.sh
│   └── demo.sh
├── docs/
│   ├── ARCHITECTURE.md
│   ├── THREAT_MODEL.md
│   ├── ADR/
│   ├── PROTOCOL.md
│   ├── RUNBOOK.md
│   └── SECURITY_LIMITATIONS.md
└── reports/
    ├── evidence/
    ├── TEST_RESULTS.md
    ├── 2G_REPORT.md
    ├── CRYPTO_REVIEW.md
    └── FINAL_HANDOFF_RU.md
```

Codex может изменить внутренние папки, но обязан сохранить строгие boundary, Makefile/команды и прозрачную проверяемую документацию. Bundle docs переместить в `docs/brief/` или хранить в корне read-only как source requirements.

## 4. Команды завершения — интерфейс для владельца

- `make bootstrap`: проверить инструменты, поднять нужные dev containers, миграции, seed dev demo data (no real credentials).
- `make demo`: запустить backend, dev web/mobile-preview или Linux desktop client и demo аккаунты; показать явно локальный endpoint и способ начать demo.
- `make verify`: fmt/lint, все доступные unit/integration/crypto/contract/e2e/chaos tests, генерирует отчёт с кодами завершения. Не скрывать провалы `|| true`.
- `make smoke`: быстрые пользовательские сценарии на живом стеке (сборка + 2 клиента + реальная БД).
- `make down`: остановить только контейнеры/процессы этого проекта и сохранить test data, если не указано `clean`.
- `make clean-local` с явным предупреждением — удаление лишь окружения данного проекта; никогда не должно удалять сторонние Docker volumes.

## 5. Версионирование и style

- `global.json` pin .NET SDK 10.x (supported); checked NuGet lock where possible, Cargo.lock, pubspec.lock.
- Database migrations backwards compatible (expand/contract), no destructive migration without explicit opt-in.
- Strict nullable enable, lint/analyzers, formatting, no warnings from generated code treated as user-owned failures.
- Container nonroot when possible; pinned image versions/digests, `docker compose config` in CI.
- License inventory + SBOM; avoid packages with unknown licenses.
- Тестовые сертификаты только local, никакого отключения проверки TLS для production или обхода pinning.

## 6. Платформы и честный статус

На Linux environment Codex может реально проверить backend, Rust, Flutter Linux, web и Android (если SDK available). iOS/macOS нативные билды требуют macOS/Xcode — если недоступны, сохранить компилируемый проект с CI `macos-latest` без заявления, что локальный билд проверен. Если CI недоступен, статус platform `UNVERIFIED`. Для web crypto обязательна реальная WASM интеграция, иначе web private features disabled. Документировать поддержанные платформы отдельно от построенных исходников.
