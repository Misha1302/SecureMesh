# Crash-safe device-bound refresh and same-profile sign-in

PARTIAL / NOT_READY. PRODUCTION_APPROVED=false. This is one completed local component, not the whole SecureMesh product or independent security assurance.

## Reproduced failure and implementation

The previous production AccountSession lost its only usable refresh token if the server committed a rotation but its reply was lost before local persistence. Real Dart/TLS/PostgreSQL execution then killed the owned native process and restarted API: `v2-refresh-before-fix.txt` exited1 with `REFRESH_REUSE`. Regression commit: 19908f8. This was not a mocked response or an invented failure.

6831208 adds the device-signed refresh endpoint, PostgreSQL migration seven, SQLCipher request journal/atomic completion, protected exact-response replay and coalesced native controller. Native login now opts into a session that cannot use bearer refresh. A fixed-purpose Ed25519 proof uses the device's existing key. The server verifies it before consulting recovery state or applying authenticated reuse revocation. A 24-hour exact replay returns identical tokens only while the successor is live and unrevoked; its access deadline is not extended. Invalid proof cannot retrieve tokens or revoke the family. A corrupt protection blob fails closed. New rotations are bounded to 512/device/rolling day; exact replays are not charged. Expired inactive-device physical cleanup remains outside this change.

9d70fff connects **Sign in again** to chat/settings/account hub. Password repair proves the same local key, updates only authentication/account labels and resumes the existing queue. Local history, MLS identity/ratchets, pins and enrollment flags remain. Missing legacy labels require successful same-key account ownership. A revoked device cannot create a replacement identity through this flow. This is not lost-store/passphrase/history recovery, and an interrupted password login is not exactly-once server login. The form preserves input, translates errors/validation on RU/EN switching, distinguishes account and store passwords, and fits compact Linux windows. The independent Impeccable finish verdict is `ship` for the supplied light Linux surface; the documenter preserved incumbent design files.

3851e26 adds the previous-schema EF fixture, scoped upgrade/restore check, concurrency/pending negatives, reproducible commands and retained baseline evidence. Historical 12-digit migration IDs are resolved using EF's own `IMigrationsIdGenerator.GetName`; no migrations are renamed or manually removed. Full protocol, backup paths and limits: [SESSION_RECOVERY.md](../docs/SESSION_RECOVERY.md).

## Actual checks already completed

| Evidence under reports/evidence | Observed result and boundary |
|---|---|
| v2-refresh-before-fix.txt | exit1: original lost-reply/SIGKILL bug. |
| v2-refresh-regression-legacy.txt | exit0: actual server COMMIT/lost reply/native SIGKILL/API and content-root restart, exact recovery, forged/foreign proof, encrypted PG response, corruption503, remaining expiry, local pre-COMMIT abort, replay-window fixture, authenticated reuse revocation, same-key repair and original ciphertext delivery once, revoked denial, legacy-label ownership. |
| v2-refresh-pending-regression.txt | exit0: preceding cases plus native bound login rejects bearer downgrade and six concurrent signed HTTP retries create exactly one successor/ledger; pending private conversations403. Later logout assertions are present in the final source and await the broad run. |
| v2-refresh-quota.txt | exit0: 512 actual signed rotations; next denied; 513 sessions, none revoked; owned timestamp-window shift permits the saved request and prunes that device's expired ledger. No seeded quota counters, lowered limits or fake sessions. The numeric global-throttle counter was added to output after this run and is not claimed from this log. |
| v2-refresh-upgrade.txt | exit1: initial test runner could not resolve the historical migration ID. Retained; corrected with EF name resolution. |
| v2-refresh-upgrade-fixed.txt | exit0: real previous six-migration schema populated with owned legacy users, device keys, sessions, consented DM/bootstrap, ciphertext/outbox; additive7 preserves access; isolated PG dump/restore plus copied refresh-key directory recovers identical tokens and original recipient decrypts once. No media/full-system claim. |
| v2-refresh-gui.txt | exit0: actual GTK wrong password leaves exact profile/key/outbox and session count; compact RU/EN errors; correct password same key, one new bound session, original ciphertext received once; tested secrets absent from retained UI/API logs. |
| v2-refresh-final-analyze.txt, v2-refresh-layout.txt, v2-refresh-final-linux-build.txt | exit0: no analyzer issues, four widget tests including 320×844/1.3× validation/locale regression, actual Linux debug bundle. Earlier lint failures remain retained. |
| v2-refresh-gui-regressions.txt | exit2: first old signup/DM scenario had no recipient chat request. No successful execution is inferred from this attempt. |
| v2-refresh-gui-request-diagnostic.txt | exit0: diagnostic replay completed registration/email/device proof, consent/Welcome/two-way Unicode, offline queue/SIGKILL/reopen and exact ciphertext once. The first missed request was not reproduced; its cause is unconfirmed, so driver/UI timing flakiness remains a limitation. Missing-request diagnostic capture now fails explicitly. |
| v2-refresh-native-cursor.txt | exit0: current refresh-capable native client, actual60s WSS+HTTPS blackout,1000 ordered IDs, no blackout delivery, reopened SQLCipher and real PG cursor/receipt1000. Separate from combined 2G/DB/media faults. |
| v2-refresh-demo.txt | exit0: actual make-demo process, real consented/routed MLS and original recipient decrypt; owned demo stopped. |

Network severe series, old pending/resume GUI regression and the broad aggregate are still running at the drafting checkpoint. Final recorded statuses belong in the handoff and machine-readable summary; do not infer success from an unfinished log. Six current full network trials are mandatory after AccountSession changes, with original count/impairment/latency/child-exit/source gates unchanged. Prior canonical results were archived before replacement. Existing 27 aggregate evidence files were copied byte-for-byte to `baseline-4ef8207-*`, verifying every original SHA; their relocated summary is `v2-final-summary-4ef8207.json`.

## Release limits and continuation

No acceptance row or roadmap milestone is promoted for this scoped feature. Four retained RustSec advisories, independent audit, OS keyring, QR/multi-device MLS join/revocation/rekey, history/recovery/transparency, the full mixed-fault schedule, platform/security/resource/retention and remaining groups/channels/media/calls/admin functionality still block release. Production startup remains disabled outside Development. No production, DNS, paid resource, public-repository publication or unrelated service mutation occurred.

Run `make bootstrap`, `make demo` and `make build-linux` / `make client` as documented. A locked store needs its existing local passphrase first; a completed profile can then use **Sign in again** without replacing its key. Preserve PostgreSQL, `.local/refresh-keys`, incumbent cursor keys and local client stores through their protected workflow; never commit them. `make down` preserves volumes. Continue from STATUS.md, PLAN.md and FINAL_HANDOFF_RU.md, preserving all original brief/checks/docs/v2 files.
