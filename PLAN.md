# SecureMesh — execution plan

Source brief remains immutable. Implementation work used `codex/securemesh-build`, which is retained. At the user's explicit request on 2026-11-18, `main` was created from that branch for synchronization with the private repository https://github.com/Misha1302/SecureMesh. Runtime resources remain local; no deployment.

1. M0: pin available SDK, API, PostgreSQL migrations, isolated Compose, health, Make/CI.
2. M1: real OpenMLS independent processes, Welcome, add/remove/rekey, encrypted durable state, restart, replay and pinned identity rejection. Probe Flutter/native/WASM tooling.
3. M2: Argon2id accounts, local email verification, rotating sessions, device identity/trust.
4. M3: transactional opaque message/outbox, idempotence/digest conflicts, bounded sync/cursors, encrypted client outbox, WSS/protobuf and HTTPS fallback. Exercise crashes before claiming reliability.
5. Run specified 2G profiles with raw measurements; preserve all original gates (200 each direction, three seeds).
6. M4–M6 only after foundations: groups/public spaces, media, native UX, calls.
7. M7–M8: security/restore tests, deployment templates, truthful local handoff. No deployment.

Every verified increment gets a commit. `make verify` must fail if required acceptance gates remain incomplete. Unsupported or unrun checks remain NOT_RUN/BLOCKED, never PASS.


## Checkpoint / next execution order

Verified components and known failures are in STATUS.md and reports. No M0–M8 milestone is declared fully complete.

- [x] Immutable brief integrity; safe local branch; real API/PG health/migrations.
- [x] OpenMLS/SQLCipher process spike and Linux Dart/FRB test.
- [x] Core auth/device possession/refresh and durable text/cursor/epoch tests.
- [x] GPRS and severe steady baselines: 200 each direction, three seeds each.
- [x] Native Linux build/launch, real two-GUI messaging, offline kill/reopen, body RU/EN/themes, layout tests.
- [x] Execute security scans and record failures; raw evidence preserved.
- [ ] Remediate four RustSec findings through compatible upstream/provider/storage versions; no suppressions/custom primitives.
- [ ] Complete actual directory/KeyPackage/Welcome/enrollment/recovery and registration/trust UX.
- [ ] Native WSS-first reconnect/HTTPS fallback; mixed blackout/crash/half-open/media fault schedule; all remaining P0.
- [ ] M4 groups/public channels/moderation, M5 all media, M6 calls/full native UX/platforms.
- [ ] M7 complete security/resource/load/backup/retention/supply-chain matrix; independent audit remains future external gate.
- [ ] M8 full local delivery candidate and approved future-deployment documentation; current handoff is a partial checkpoint.

Continue from existing code, not a new skeleton. make verify must remain nonzero while RustSec or required acceptance rows are red. Current source checkpoint is recorded in reports/FINAL_HANDOFF_RU.md; git rev-parse HEAD is authoritative for the checkout.
