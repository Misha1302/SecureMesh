# Подготовка к развертыванию ПОЗЖЕ — без реальных production-действий

## 1. Граница полномочий в текущем задании

Сейчас Codex может создавать код, Dockerfile/Compose, шаблоны infra, runbooks, локально поднимать тестовые контейнеры, делать *dry-run* развертывания в изолированной тестовой сети и собирать артефакты. Запрещено изменять реальные серверы, домены, DNS, firewall, registrar, Cloudflare, платёжные аккаунты, реальные почтовые и push-сервисы, опубликованные приложения, выдавать настоящий production CA certificate или заливать секреты без явной будущей команды владельца.

**Локальная разработка не должна зависеть от доступа к существующему серверу владельца.** Не искать и не использовать его IP/SSH-ключи из других репозиториев.

## 2. Требуемые артефакты от Codex

- `deploy/compose.staging.yaml` или эквивалент; production-like configuration при injected secrets, без hardcoded credentials.
- `deploy/reverse-proxy.conf.template`: TLS/WSS/HSTS/auth security headers, upgrade, limits, streaming media, timeouts appropriate for 2G.
- `deploy/.env.production.example`: полный inventory настроек, но только placeholders; секреты через secret files/KMS.
- `deploy/README.md`: host requirements, architecture, sizing assumptions, ports, DNS, cert, monitoring, migrations, rollback steps.
- `deploy/backups/`: scripts for backup and **restore drill** executed on local test dataset only.
- `docs/OPERATIONS_RUNBOOK.md`: start/stop/rotate secrets, incident handling, data restore, rollout/rollback, disable unsafe features, test post-deploy.
- `reports/FINAL_HANDOFF_RU.md`: SHA/commit, commands, tested OS, AT summary, failures, security limitations and missing prerequisites.
- `deploy/check-prerequisites.sh`: read-only/dry-run audit, without modifying remote host.

## 3. Что владелец предоставит позднее

Сервер/хостинг и целевая юрисдикция; домен и DNS; SSL issuance/renewal; email relay, abuse contact; FCM/APNs credentials and Apple/Google developer accounts; object storage and backup provider; secure admin bootstrap and MFA recovery; legal/privacy policy; monitoring and operational support; formal security review. **Не требовать это сейчас** — использовать локальные substitutes и документировать TODO.

## 4. Минимальная безопасная конфигурация production

- Cloud TLS edge 443; WSS and HTTPS; protected admin origin; internal DB/cache/object networks not publicly exposed.
- DB unique constraints, PITR/backups; restore rehearsed, encrypted backup+key management and retention.
- Object storage scoped tokens, expiry, per-user quotas; S3 server-side encryption **дополняет**, но не заменяет E2EE private media.
- App containers non-root, pinned images and SBOM, read-only filesystem where feasible, minimum capabilities.
- Admin MFA, forced logout/device revoke, signing key rotation with graceful validation windows, audit append-only.
- Dedicated antiflood/rate limiting, IP reputation privacy-conscious, monitoring, alerting, resource budgets, log redaction.
- Deployment rollout using canary/staging; health probes and rollback path; never `docker compose down -v` on production.

## 5. Ресурсы и расчёт мощности

Сделать калькулятор/таблицу в runbook: registered users, concurrent connections, messages/day, average ciphertext bytes, media GB/day, retention, replication factor, bandwidth egress, TURN relay share. **Не выдумывать** capacity numbers, производительность измеряется `tests/load/`. 2G support depends primarily on latency/backpressure/queue semantics, а не на выборе самого дорогого VPS.

## 6. Приёмка после будущего развёртывания

1. DNS/TLS/headers, closed ports, firewall, WSS fallback verified from public internet.
2. User1→User2 crypto identity sanity and no plaintext server side.
3. Offline reconnect and 2G simulation from external device; real EDGE field test separately.
4. Media uploads and TURN calls, push notifications with FCM/APNs in background conditions.
5. Backup + restore in staging; security scans, pen test, admin log and MFA.
6. Observability, incident runbook, budget alerts, legal/privacy and independent crypto audit signoff.

**Release flag:** `PRODUCTION_APPROVED=false` по умолчанию. Codex обязан оставить его false. Запуск реальной публикации — отдельное решение владельца.
