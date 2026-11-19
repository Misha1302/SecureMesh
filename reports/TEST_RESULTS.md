# Acceptance checkpoint — not ready

PARTIAL / NOT_READY. PRODUCTION_APPROVED=false. Partial coverage remains NOT_RUN; a component PASS is limited to its stated local scope.

P0: 14 PASS / 1 FAIL / 11 NOT_RUN. P1: 2 PASS / 11 NOT_RUN / 1 BLOCKED. V2: 1 PASS / 18 NOT_RUN / 1 BLOCKED.

| ID | Priority | Status | Evidence | Notes |
|---|---|---|---|---|
| AT-001 | P0 | NOT_RUN |  | PARTIAL: warm make bootstrap and real migrations/health pass; full clean-room infrastructure not complete. |
| AT-002 | P0 | PASS | evidence/delivery-final.txt | Real verified users/login/device proof/token rotation; uniform unknown-user response tested. |
| AT-003 | P0 | PASS | evidence/m1-crypto-v2.txt | Independent client keys and public-only device registration; CLI/Linux scope. |
| AT-004 | P0 | PASS | evidence/crypto-final.txt | Independent processes, Welcome and real MLS encrypted Unicode. |
| AT-005 | P0 | PASS | evidence/crypto-final.txt | Standalone OpenMLS third-member add/remove/rekey/revoked denial; group UI/server workflow separate. |
| AT-006 | P0 | NOT_RUN |  | PARTIAL: server sees opaque messages; private media and complete operator dump/audit scenario absent. |
| AT-007 | P0 | PASS | evidence/crypto-final.txt | Pinned-key substitution and raw MLS replay rejected. |
| AT-008 | P0 | PASS | evidence/db-recovery.txt | DB stopped while send waits before COMMIT; 503/no success ACK; retry/outbox persistence. |
| AT-009 | P0 | NOT_RUN |  | PARTIAL: concurrent/lost-ACK server and local projection dedup tested; full automated native UI fault suite pending. |
| AT-010 | P0 | PASS | evidence/delivery-final.txt | Same client ID changed ciphertext or epoch gives 409. |
| AT-011 | P0 | PASS | evidence/v2-native-gui-final.txt | Actual Linux Flutter offline enqueue, encrypted COMMIT, SIGKILL, same-store reopen; identical ciphertext delivered once and both histories checked. |
| AT-012 | P0 | PASS | evidence/v2-native-cursor-recovery.txt | Actual native client, 60.000s WSS+HTTPS blackout, 1000 ordered IDs recovered; zero loss/duplicates, reopened SQLCipher cursor and PostgreSQL processed receipt=1000. Separate from combined 2G faults. |
| AT-013 | P0 | NOT_RUN |  | PARTIAL: three full baseline GPRS seeds pass; prescribed mixed crash/ACK-drop/reconnect schedule not combined with profiles. |
| AT-014 | P0 | PASS | NATIVE_2G_REPORT.md | Final 4b003dd native GPRS, 200 each direction/seeds 7/19/41: p95 4.672/4.928/4.742s; all 1200 IDs once; observed child exit=0 and equal binaries/current source hashes. Gate remains 15s; initial FAIL retained. |
| AT-015 | P0 | PASS | NATIVE_2G_REPORT.md | Final 4b003dd native severe, 10kbit/s RTT3s 10% loss, 200 each direction/seeds 7/19/41; all 1200 IDs once, outboxes drained and child exit=0. No latency SLA; p95 42.772/56.869/66.886s. Prior hangs retained as FAIL. |
| AT-016 | P0 | PASS | evidence/v2-native-owned-socket.txt | Actual production Dart/SQLCipher/MLS/TLS/PG: half-open/blocked/lost ACK fallback, wrong Upgrade and malformed frame denied, immutable retry and WSS recovery. Explicit TLS socket ownership bounds cleanup. |
| AT-017 | P0 | NOT_RUN |  | NOT_RUN: media pipeline and competing-upload fairness absent. |
| AT-018 | P0 | NOT_RUN |  | PARTIAL: chat/device negative authorization tested; complete media/admin RBAC surfaces absent. |
| AT-019 | P0 | NOT_RUN |  | NOT_RUN: password reset/recovery API and UI absent. |
| AT-020 | P0 | NOT_RUN |  | NOT_RUN: public spaces/search/moderation absent. |
| AT-021 | P0 | NOT_RUN |  | PARTIAL: API secret checks and native debug endpoint redaction tested; full crash/platform matrix pending. |
| AT-022 | P0 | NOT_RUN |  | PARTIAL: current six-migration PG isolated restore, routed DM, original session plus new login/decrypt/cursor/receipt pass; object/keyring/media restore matrix incomplete. |
| AT-023 | P0 | FAIL | evidence/rustsec-current.txt | Four current RustSec advisories plus unmaintained warning; compatible update selected zero changes. No ignores; supply-chain review partial. |
| AT-024 | P0 | PASS | evidence/delivery-final.txt | Real client processes + TLS API + PostgreSQL + reconnect; native GUI supplementary captures. |
| AT-025 | P1 | NOT_RUN |  | NOT_RUN: MLS core add/remove works; closed-group native UI and server membership workflow absent. |
| AT-026 | P1 | NOT_RUN |  | NOT_RUN: public channels/feed/search/media/moderation absent. |
| AT-027 | P1 | NOT_RUN |  | NOT_RUN: voice capture/media transfer absent. |
| AT-028 | P1 | NOT_RUN |  | NOT_RUN: video-circle capture/media transfer absent. |
| AT-029 | P1 | NOT_RUN |  | NOT_RUN: attachment pipeline absent. |
| AT-030 | P1 | NOT_RUN |  | NOT_RUN: WebRTC/TURN/native call flow absent. |
| AT-031 | P1 | NOT_RUN |  | PARTIAL: real signup/verification/login/account-hub/DM/manual-trust Linux UI, RU/EN/light-dark/layout checks; groups/media/admin and full assistive-tech/platform flows absent. |
| AT-032 | P1 | NOT_RUN |  | PARTIAL: independent device keys, signed pending-to-activated trust and revoke/session controls; MLS leaf membership/rekey across devices and old-history transfer remain incomplete. |
| AT-033 | P1 | NOT_RUN |  | NOT_RUN: moderation/admin MFA/audit workflow absent. |
| AT-034 | P1 | PASS | evidence/wasm-probe.txt | Native WASM probe fails; browser builds and explicitly disables private chat. Public features still missing. |
| AT-035 | P1 | NOT_RUN |  | NOT_VERIFIED: Android SDK36 exists with unaccepted licenses; Android crypto packaging/build not completed. |
| AT-036 | P1 | PASS | evidence/v2-resume-locale-linux-build.txt | Actual Linux debug build and three GUI resume paths; same keys/session counts/pending403, wrong-passphrase correction and RU/EN input preservation. Compact Linux is not Android evidence. |
| AT-037 | P1 | BLOCKED |  | No macOS/Xcode runner; no Apple artifact claimed. |
| AT-038 | P0 | NOT_RUN |  | PARTIAL: local handoff/checkpoint only; deployment candidate blocked. |
| AT-039 | P1 | NOT_RUN |  | PARTIAL: variable Unicode app frames measured; exact 100-character TLS/network accounting absent. |
| AT-040 | P0 | PASS | evidence/epochs-final.txt | Two real staged self-update commits race, loser rebases, both restart and resume at epoch3. |

## Executed V2 component evidence

| Component | Evidence | Scope |
|---|---|---|
| Device trust | evidence/device-enrollment.txt; evidence/v2-enrollment-quota.txt | Pending isolation; signed proof/grant/local activation; replay/expiry/race/revocation negatives; real persistent 32-issuance quota and API restart |
| Schema / restored DM | evidence/v2-migrations-m6.txt; evidence/v2-isolated-restore.txt | Six migrations; isolated PG restore, original session plus fresh login and original recipient decrypt/cursor/receipt |
| Directory | evidence/mls-directory.txt | Consented real KeyPackage validation, one-use lease, signed routed Welcome; crash-safe and replay-safe exact two-member join |
| Native transport / session | evidence/v2-native-owned-socket.txt; evidence/v2-native-session.txt | Real Dart/FRB/TLS/PG; wrong Upgrade/malformed response denied; WSS/HTTPS faults; explicit detached TLS socket destruction; one persisted refresh for eight concurrent requests |
| Native GUI | evidence/v2-native-gui-final.txt; evidence/v2-native-pending-gui.txt | Signup/verification/corrected login/DM; offline SIGKILL/reopen; pending device denied private conversations |
| Interrupted sign-in | evidence/v2-onboarding-challenge-recovery.txt; evidence/v2-onboarding-gui-locale-fix.txt | Actual same-key process-kill/lost-reply/saved/expired recovery, strict challenge bindings, wrong-passphrase correction, actual PG sessions2/1/2 and pending private403; RU/EN retains entered password |
| Cursor recovery | evidence/v2-native-cursor-recovery.txt; evidence/native-cursor-recovery.json | Actual 60s blackout, 1000 ordered IDs, durable reopen and actual PostgreSQL receipt |
| Native 2G | NATIVE_2G_REPORT.md; evidence/v2-native-network-report.txt | Six retained 4b003dd runtime trials; 2400 unique IDs; child exit=0; matching measured transport sources and one measured binary set. New journal build not remeasured. Combined crash/DB/media schedule incomplete |
| Pub supply chain | evidence/v2-pub-osv.txt; PUB_LICENSE_INVENTORY.json | 55 hosted lock versions queried with real positive control; 55 actual license texts retained, SPDX/legal review pending |
| Narrow UI review | ../.impeccable/review/v2-finish-report.md | Five original findings resolved; Linux visual review, not product/security approval |

Latest broad make verify: exit2, 24/27 groups pass; RustSec and both acceptance gates fail. Final challenge/locale changes have subsequent focused controller/GUI/analyzer/build passes; no second complete aggregate is claimed. See ONBOARDING_RESUME_REPORT.md for failed attempts and exact scope.

Historical Python metrics are separate in 2G_REPORT.md. The retained failed native GPRS and both hanging severe attempts are not counted as PASS. Measured transport runtime: 4b003dd; account-setup code: 1c08659 and 5cbdb01. Full multidevice MLS/history/recovery, QR camera, groups/channels/media/calls, remaining platforms and acceptance work are incomplete.

RustSec remains a release blocker. See ../docs/SECURITY_LIMITATIONS.md and FINAL_HANDOFF_RU.md for current aggregate verification and continuation.
