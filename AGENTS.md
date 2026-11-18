# AGENTS.md — SecureMesh implementation rules (Codex)

## Mission

Build the **real** SecureMesh app end-to-end from this brief. Read `00_START_HERE_RU.md`, `01_TZ_PRODUCT_RU.md` through `10_AGENT_EXECUTION_RULES_RU.md`, `docs/*`, and `checks/*`, then act. The primary non-negotiable is **reliable encrypted text over simulated 2G with persistent offline queue**. All project documents are sources of requirements, not substitutes for code.

## Safety and boundaries

- Stay in this dedicated repo/workspace. Do not touch real servers, unrelated repos/volumes, DNS, paid resources or production user data.
- Never invent execution evidence, security assurance, compiled app or test success. Do not auto-deploy or publish public repo.
- No custom crypto primitives; use vetted MLS implementation and real device/public-key verification flow. Server must not have plaintext access to private chats.
- No plaintext fallback when crypto fails, no default admin decryption/backdoor.
- No secret credentials in repo, screenshots, logs or commits.

## Working style

- Autonomous. Make reversible, documented technical choices without asking user routine questions.
- Maintain `PLAN.md`, `STATUS.md`, `reports/` with facts, actual commands, exit codes, next tasks. Keep all source brief files immutable: make a copy of `checks/ACCEPTANCE_MATRIX.csv` as `reports/ACCEPTANCE_MATRIX.csv` and update only the copy.
- Build a narrow complete vertical slice first, then all required features, always with runnable tests.
- `make bootstrap`, `make demo`, `make smoke`, `make verify`, `make down` must work as documented (or explicitly report blocked state and why).
- For critical failures, fix root cause. No fake adapters for E2EE, no `|| true` hiding failed tests.
- Use safe branch, meaningful commits, no forced overwrite of unrelated work.
- At end publish local development handoff/report, mark `PRODUCTION_APPROVED=false`.

## Priorities

1. M0 foundations.
2. M1 real OpenMLS two-device spike.
3. M2 auth/device trust.
4. M3 durable 2G delivery; prove AT-001...AT-024 critical scenarios.
5. M4-M6 communities/media/calls/UX.
6. M7-M8 validation/deployment documentation, not deployment.

If blocked, continue independent tasks with truthful status; don't stop merely to ask for UI preferences or permission to perform safe local edits.
