# SecureMesh — execution plan

Source brief remains immutable. Work on `codex/securemesh-build`, local resources only.

1. M0: pin available SDK, API, PostgreSQL migrations, isolated Compose, health, Make/CI.
2. M1: real OpenMLS independent processes, Welcome, add/remove/rekey, encrypted durable state, restart, replay and pinned identity rejection. Probe Flutter/native/WASM tooling.
3. M2: Argon2id accounts, local email verification, rotating sessions, device identity/trust.
4. M3: transactional opaque message/outbox, idempotence/digest conflicts, bounded sync/cursors, encrypted client outbox, WSS/protobuf and HTTPS fallback. Exercise crashes before claiming reliability.
5. Run specified 2G profiles with raw measurements; preserve all original gates (200 each direction, three seeds).
6. M4–M6 only after foundations: groups/public spaces, media, native UX, calls.
7. M7–M8: security/restore tests, deployment templates, truthful local handoff. No deployment.

Every verified increment gets a commit. `make verify` must fail if required acceptance gates remain incomplete. Unsupported or unrun checks remain NOT_RUN/BLOCKED, never PASS.
