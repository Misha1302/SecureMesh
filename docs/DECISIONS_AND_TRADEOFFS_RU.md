# Архитектурные решения (ADR) и альтернативы

Каждое решение ниже — стартовая инженерная гипотеза для реализации. Изменять её можно только с работающим proof-of-concept и новым ADR, не из личного вкуса Codex.

## ADR-001: .NET 10 LTS вместо 11 STS, Go или Node

**Выбор:** ASP.NET Core .NET 10 LTS. Нагрузка: небольшие binary messages, много async connections, Postgres transactions. Плюсы: знакомый стек, mature tools, LTS support. 11 STS более новая, но 10 LTS предпочтительна по циклу поддержки. Go также подходит для gateway, но нет достаточно оснований умножать языки backend. **Не** вводить Rust backend ради OpenMLS — он нужен как native client crypto core.

## ADR-002: Flutter + OpenMLS/Rust bridge

**Выбор:** Flutter UI / Rust OpenMLS as crypto module. Один cross-platform клиент уменьшает расход на UI, а библиотека Rust позволяет не писать криптографию на Dart. **Риск:** native bindings и web WASM, iOS compiling. Митигировать M1 spike перед разработкой остального. **Альтернатива:** Kotlin+Swift native если bridge безнадёжен, но это двукратная клиентская работа; не переключаться без evidence.

## ADR-003: MLS for 1:1 and private groups

**Выбор:** RFC 9420 MLS для всех E2EE чатов, в том числе 1:1 с несколькими device participants. **Плюсы:** единая security architecture для groups. **Минусы:** commitments/epochs, AS/DS implementation, key verification, cannot claim built-in key transparency. **Альтернатива:** libsignal/PQXDH+Double Ratchet для 1:1 и MLS groups, но две независимые системы с увеличением maintenance и официально unsupported external libsignal SDK. Не писать primitive самостоятельно.

## ADR-004: Modular monolith + PostgreSQL authoritative outbox

**Выбор:** один backend с отдельными clean modules, Postgres as source of truth. Redis only optional. **Плюсы:** атомарная запись message+outbox, просто локально и на первом VPS, меньше distributed transactions. **Минус:** высшее масштабирование требует отделения gateway/worker, но это делается после измерений. К Kafka/NATS переходить только при подтверждённом bottleneck.

## ADR-005: WSS + Proto, HTTPS fallback

**Выбор:** binary WSS persistent connection; HTTPS for degraded networks/blocked proxies. **Плюсы:** reduces request overhead, simple broker independent. **Минус:** WebSocket buffering/backpressure, mobile background restrictions, Web clients may be throttled. Нужно outbox/cursor/restore вне транспорта.

## ADR-006: E2EE private content, server-readable public

**Выбор:** split by content scope, visible in UI. **Плюсы:** E2EE promises can be honest, public search/moderation possible. **Минусы:** E2EE private content cannot be scanned/transcoded by server, server may see group membership metadata. Moderation private via user opt-in report only; public moderation server-side.

## ADR-007: One server owner cannot decrypt private chats

**Выбор:** full admin control over policies, accounts, moderation but **no silent plaintext access**. Conflicting requests resolved in favor of user privacy. Security invalidated if server masquerades as new MLS device; trust verification and key transparency are essential.

## ADR-008: Browser private chat conditional

Web crypto maturity/ABI key storage has different risks than native. Require crypto spike and actual cross-platform tests. Failure -> documented **partial** browser experience, not plaintext fallback. Final release claim must clearly report coverage.

## ADR-009: No true 2G guarantee without live network

`tc netem` 10–100 Kbit/s models are useful and repeatable, **not a substitute** for physical GPRS/EDGE on multiple carriers. Performance claims can say "passed deterministic GPRS simulation" after evidence, not "guaranteed on all 2G networks".

## ADR-010: Local-first automatic coding but human-governed deployment

Autonomous agent creates, tests, commits and documents. Real internet publication, acquiring infrastructure, remote SSH, issuance of production credentials and independent cryptographic signoff require separate owner decision. This prevents unintended impact and protects other projects on same host.
