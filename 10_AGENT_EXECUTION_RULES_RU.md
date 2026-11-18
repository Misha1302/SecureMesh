# Правила исполнения Codex: максимальная автономность без подмены результата

## 1. Приоритеты

1. Preserve external state: no touching production, other repositories, unrelated Docker projects, real DNS, accounts, secrets.
2. Build real functional code, not prose-only plan or mocks.
3. Correctness and security gates > visual polish > feature breadth.
4. Verify with executed commands and report evidence; distinguishing `NOT_RUN` from `PASS`.
5. Keep work resumable and autonomous; do not stop to ask user to choose UI colors/variable names/dependency version. Choose and write ADR.

## 2. Сотрудничество с ограниченной средой

- If Docker/sudo/SDK unavailable, inspect, attempt non-destructive alternatives in workspace only, document verified blocker, continue independent code work. Do NOT claim tests passed when blocked.
- If external internet blocked, use caches and avoid unsupported versions; write deterministic setup and mark dependency fetch BLOCKED.
- If iOS build unavailable without macOS, add macOS CI and do not report passed iOS native build.
- If OpenMLS Flutter WASM integration unsupported after actual attempt, document exact error and build web public-only mode. No fallback to server-readable private chats.
- No infinite loops on failing dependency, no overriding tests. Save STATUS and move to highest-value independent task.
- If time/context/compute exhausted, produce the best real partial repo and recorded next actions; the next run should be able to resume.

## 3. Development discipline

- Read entire brief once, write PLAN with work packages, test dependencies, risks and stage milestones.
- Inspect actual code before editing and actual process states before making any claims.
- Incremental code/build/test; maintain committed work after verified slice. No force pushes, no deleting unrelated code/data.
- Use source of truth docs and actual runtime outputs rather than guesses or narrative optimism.
- Prefer clean APIs with explicit boundaries and straightforward data models, no huge framework scaffolding without purpose.
- Every crypto change requires negative tests and re-read of model; never implement primitives manually.
- Database schema changes tested on fresh and existing fixture; migration/rollback documented.
- Avoid production credentials or real addresses in logs/doc artifacts; no manufactured evidence.

## 4. Automated quality gates

Required command names `make bootstrap`, `make demo`, `make smoke`, `make verify`, `make down` backed by real scripts. Verify exit codes, do not use `|| true` or suppressed failures. Use CI cross-platform matrix as viable; store execution evidence in `reports/evidence/` with redaction.

CI definitions are useful but not substitutes for actual runs. When tests cannot run, state precisely why and what is needed.

## 5. Git and release hygiene

Use work branch (e.g. `codex/securemesh-build`) in an empty repo. If repository exists, avoid assumptions; inspect current HEAD/dirty state and work on a safe branch. Commit meaningful stages with test result summaries. Push branch only if remote is already configured, credentials available and no security sensitivity; never automatically force-push `main` or publish code to a new **public** repo. No production deploy.

## 6. Финальный отчёт

```
# SecureMesh — final handoff
Code HEAD: <actual sha>
Implementation status: DONE_VERIFIED / PARTIAL / BLOCKED
Production status: NOT_APPROVED
Verified platforms: ...
Missing/unverified platforms: ...
P0 tests: X pass / Y fail / Z not run (complete table)
P1 features: ...
2G measurements: p50/p95/p99 + seeds, environment
Crypto: OpenMLS versions, actual E2EE test, key-directory risks
Security: critical unresolved findings, dependency scans, external audit missing
Local run: exact commands
Server deployment later: prerequisites and commands
Next steps if incomplete: exact highest priority actions
```

**Нельзя** говорить «полностью сделано», когда есть критические провалы, тесты только в mock, и есть неизученные security assumptions. Даже успешный local candidate — не production-certified продукт.
