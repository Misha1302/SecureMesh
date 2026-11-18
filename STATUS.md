# SecureMesh — implementation checkpoint

Implementation: PARTIAL / NOT_READY
PRODUCTION_APPROVED=false

## Environment and boundaries

2026-11-18, Fedora 43 x86_64. Bundle SHA-256: all 24 files verified, unchanged. Empty-code intake; local branch codex/securemesh-build, no remote/deployment. .NET 10.0.111 / runtime 10.0.11, Rust 1.93.1, PostgreSQL container 17 pinned by digest, Docker 29.8 / Compose 5.5.1. Flutter 3.50.0 / Dart 3.14 downloaded, SHA-256 checked, installed inside .local. GTK build toolchain isolated in project container. Android SDK 36 exists, licenses and Android bridge build unverified. No Apple builds. Workspace TMPDIR avoids host temporary-file quota failures.

## Verified components (not complete milestones)

- M0 PARTIAL: API builds; real PostgreSQL readiness and EF migration restart/idempotence pass. Own Compose subnet resolves exhausted default pools; no foreign networks/volumes changed. Full clean bootstrap/auxiliary stack not complete.
- M1 PARTIAL: OpenMLS 0.9.2 + transactional SQLCipher: independent keys, Welcome, Unicode, third-member add/remove/rekey, replay/key substitution denial, encrypted-store wrong-key failure, crash rollback and immutable outbox. Dart/FRB 2.13.0 native two-store crypto call passes. No Android/WASM private-chat verification.
- M2/M3 PARTIAL: Mailpit email, Argon2id, device proof, refresh reuse revocation, TLS WSS/HTTPS texts, lost ACK/concurrent idempotent retries, conflicts, receiver crash recovery, scoped cursor pagination, API restart, active-stream revoke. DB stop before COMMIT returns 503; pg_dump/restore into isolated DB succeeds. Concurrent epoch test stages two commits, accepts one, merges after ACK, rejects/rebases loser, resumes encrypted text. KeyPackage/Welcome routing, enrollment/recovery and native WSS-first manager remain missing.
- GPRS baseline: seeds 7/19/41, 200 messages each direction each seed; all 1200 IDs delivered exactly once, p95 4.351/4.375/4.754 seconds. Severe same count/seeds: all 1200 IDs delivered exactly once; p95 30.325/58.895/64.428 seconds, no time gate. Raw IDs/times/tc counters/binary hashes retained. Original GPRS failure p95 25.721 preserved; fixed SQLCipher reopening cost, sender echo and sync pacing. Combined blackout/crash/half-open/media schedules remain incomplete.
- Native Flutter Linux debug binary built and launched in Xvfb. Two actual GUI sessions exchanged encrypted text, compared keys, queued offline, survived SIGKILL, reopened and saved queued text. RU/EN, light/dark, compact layout, encrypted cached history. Registration UI is not connected; make seed-demo creates real local accounts/profiles. UI review found draft lock/reentrant send/error-state issues; fixes implemented and targeted reviewer pass completed. Latest actual native window captured after final build. Browser builds with private chat explicitly disabled.
- Layout tests at 320 dp / 1.3 text scale pass. Full screen-reader/mobile/accessibility validation not done.

## Security release blockers

RustSec executed, exit 1: four advisories in Cargo.lock (crypto-bigint, libcrux-kem twice, libsqlite3-sys), plus unmaintained proc-macro-error2. No advisory ignored. Compatibility probes executed and failed current upstream version constraints. NuGet vulnerability query exits 0. OSV unreachable; RustSec fallback succeeded as an executed scan, not clearance. Cargo license metadata/SBOM recorded; allo-isolate metadata lacks a license expression, and its supplied Apache 2.0 LICENSE is retained under third_party. Independent audit absent. Do not use this alpha with real private data.

## Missing scope

M4–M6 social/groups UI/media/calls/admin largely absent. Device directory and real Welcome delivery, multi-device enrollment, password reset, native connection manager, combined 2G faults, storage/resource checks and dependency remediation precede expansion. M7/M8 remain partial validation/handoff. No local delivery candidate and no production approval.

## Current verification / next

make bootstrap and make smoke: exit 0. make verify: exit 2 from make (underlying script exit 1): implemented checks pass, RustSec and acceptance gate fail. Linux final analyzer/layout/build: exit 0. Staging syntax only: exit 0; readiness: exit 1. make demo TLS readiness and make down verified; only project containers/processes stopped and DB volume retained. All original bundle hashes still pass.

Acceptance: P0 11 PASS / 1 FAIL / 14 NOT_RUN; P1 2 PASS / 11 NOT_RUN / 1 BLOCKED. Partial coverage stays NOT_RUN. Compatibility probes failed upstream version constraints; no vulnerability ignored.

Next: dependency remediation, real directory/KeyPackage/Welcome/enrollment, native WSS-first manager, mixed 2G fault schedule and remaining P0, then all M4–M6 features. See reports/FINAL_HANDOFF_RU.md, PLAN.md and reports/ACCEPTANCE_MATRIX.csv. Do not recreate completed modules. Source checkpoint c1dfffb8870d56c23d2ad7988657c0f2ef072104; checkout HEAD: git rev-parse HEAD.
