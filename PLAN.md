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
- [x] Consented initial-DM directory/KeyPackage/Welcome, signed manual device activation, native signup/trust/DM UX and real Linux GUI recovery tests.
- [x] Native WSS-first reconnect/HTTPS fallback with real Dart fault and concurrent session tests.
- [ ] Complete QR camera, multi-device MLS leaf enrollment/rekey, history transfer/recovery and trust transparency.
- [ ] Full native 2G regressions and mixed blackout/crash/half-open/DB/media fault schedule; all remaining P0.
- [ ] M4 groups/public channels/moderation, M5 all media, M6 calls/full native UX/platforms.
- [ ] M7 complete security/resource/load/backup/retention/supply-chain matrix; independent audit remains future external gate.
- [ ] M8 full local delivery candidate and approved future-deployment documentation; current handoff is a partial checkpoint.

Continue from existing code, not a new skeleton. make verify must remain nonzero while RustSec or required acceptance rows are red. Current source checkpoint is recorded in reports/FINAL_HANDOFF_RU.md; git rev-parse HEAD is authoritative for the checkout.

## V2 execution — starting at dae7259 (2026-11-18)

Working branch: codex/securemesh-v2; original V1/V2 requirements stay immutable. Preserve existing implementation and tests. Source updates are not deployment; PRODUCTION_APPROVED=false.

1. S0 dependency audit: inspect current upstream constraints and actual bundled SQLCipher version; compatible dependency updates only, no ignores. Re-run crypto/persistence and RustSec; retain failures (AT-023, SEC-V2-08).
2. S0/S1 account/device boundary: pending sessions cannot access private delivery; signed, expiring, single-use enrollment with existing trusted device, owner/key binding and client verification. Test replay, substitution, race, revoked approver, cross-account and independent client keys (V2-01/02; V2-03/07 remain incomplete until MLS enrollment/rekey).
3. S0 directory: authenticated signed one-use KeyPackage publication/leasing and routed Welcome with client pin verification, bounded quotas and transaction tests. Stage MLS membership commits until durable acceptance; preserve epoch conflict behavior (AT-007/040).
4. S0 native transport: one bounded WSS protobuf connection, HTTPS fallback, timeouts/backoff and recovery with the same durable outbox/cursor. Exercise the actual Dart implementation against real API/MLS stores (AT-016).
5. S0 native registration: connect account verification/login and device states to Flutter; no seed-only registration; honest partial chat availability. Preserve 320dp/RU/EN/theme behavior.
   Current UI flow is connected and tested; remaining S0 edge: recover an encrypted onboarding draft after a crash between accepted server login and complete local profile persistence.
6. S0/S1 network: warm GPRS/severe regressions and mixed blackout/lost-ACK/SIGKILL/half-open/DB interruptions, then media competition when real media exists (V2-08). Never promote partial coverage to PASS.
7. S1 history transfer/recovery: independent user recovery secret, encrypted eligible-history snapshots, integrity/freshness/TTL exclusions; no live MLS secrets in archives. Test wrong-key/rollback and lost-all-devices trust reset (V2-04/05/06/09).
8. Only after foundations: S2 DM/groups/public modes and ACL; S3 real E2EE media/capture/calls/push; S4 platform/load/restore/release provenance; S5 optional features. Missing stages retain NOT_RUN.

Each completed component gets executed positive/negative tests, evidence, a meaningful commit and current STATUS/TEST_RESULTS/V2 matrix. Cloud billing, unavailable upstream fixes or platform runners do not justify bypassing gates; continue independent local S0 work. Exact continuation commands will be recorded at the checkpoint.

V2 current component checkpoint: signed pending-device enrollment/activation, persistent issuance quota (sixth migration), consented one-use KeyPackage/Welcome API, native registration/DM UI, WSS/HTTPS faults and session concurrency are implemented and exercised. True GUI offline/SIGKILL/reopen and current 60-second/1000-event recovery pass. NativeDelivery shares production code with the network driver. Both SDK-close attempts that leaked CLOSE_WAIT remain FAIL; explicit detached TLS socket ownership now passes all six final trials on 4b003dd (2400 IDs, normal process exit, matching source/binary provenance). GPRS p95 4.672/4.928/4.742s; severe eventual with no latency SLA. Actual make-demo DM launch is fixed/tested in fffe534.

Final aggregate: make verify exits2 from the three mandatory red groups (RustSec and both acceptance matrices); all implemented groups pass. Current hosted Pub OSV positive-control scan and 55 retained license texts do not clear the four RustSec findings or complete supply-chain review.

Next order: compatible upstream dependency/provider/storage remediation; crash-safe onboarding journal/resume using the same local identity; complete combined 2G blackout/lost-ACK/SIGKILL/half-open/DB/media schedule; then MLS multi-device leaf/rekey/history transfer/recovery and remaining S2–S4 features. No stage is complete, no production approval, no public deployment. Continue from reports/FINAL_HANDOFF_RU.md and the exact working matrices; do not recreate completed modules.
