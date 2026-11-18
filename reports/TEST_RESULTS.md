# Acceptance checkpoint — not ready

Statuses are conservative; PARTIAL coverage stays NOT_RUN. PASS applies to the stated scenario and supported local scope, not a complete milestone.

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
| AT-011 | P0 | NOT_RUN |  | PARTIAL: native offline/SIGKILL/reopen manually exercised with screenshots; complete automated app crash schedule pending. |
| AT-012 | P0 | NOT_RUN |  | NOT_RUN: exact 60-second blackout and 1000-event recovery not run. |
| AT-013 | P0 | NOT_RUN |  | PARTIAL: three full baseline GPRS seeds pass; prescribed mixed crash/ACK-drop/reconnect schedule not combined with profiles. |
| AT-014 | P0 | PASS | 2G_REPORT.md | Full GPRS steady warm-session p95 4.351/4.375/4.754 seconds; threshold unchanged. |
| AT-015 | P0 | PASS | 2G_REPORT.md | Severe 10kbit/s RTT3s 10% loss, 200 each direction and three seeds, all IDs delivered. |
| AT-016 | P0 | NOT_RUN |  | PARTIAL: WSS and HTTPS services tested; native UI is HTTPS-only, automatic WSS-first fallback missing. |
| AT-017 | P0 | NOT_RUN |  | NOT_RUN: media pipeline and competing-upload fairness absent. |
| AT-018 | P0 | NOT_RUN |  | PARTIAL: chat/device negative authorization tested; complete media/admin RBAC surfaces absent. |
| AT-019 | P0 | NOT_RUN |  | NOT_RUN: password reset/recovery API and UI absent. |
| AT-020 | P0 | NOT_RUN |  | NOT_RUN: public spaces/search/moderation absent. |
| AT-021 | P0 | NOT_RUN |  | PARTIAL: API secret checks and native debug endpoint redaction tested; full crash/platform matrix pending. |
| AT-022 | P0 | NOT_RUN |  | PARTIAL: isolated PostgreSQL restore/decrypt drill passes; object/media backup missing. |
| AT-023 | P0 | FAIL | evidence/cargo-rustsec-audit.txt | Four RustSec advisories and unmaintained warning; no ignores. SBOM/license inventory partial; no clearance. |
| AT-024 | P0 | PASS | evidence/delivery-final.txt | Real client processes + TLS API + PostgreSQL + reconnect; native GUI supplementary captures. |
| AT-025 | P1 | NOT_RUN |  | NOT_RUN: MLS core add/remove works; closed-group native UI and server membership workflow absent. |
| AT-026 | P1 | NOT_RUN |  | NOT_RUN: public channels/feed/search/media/moderation absent. |
| AT-027 | P1 | NOT_RUN |  | NOT_RUN: voice capture/media transfer absent. |
| AT-028 | P1 | NOT_RUN |  | NOT_RUN: video-circle capture/media transfer absent. |
| AT-029 | P1 | NOT_RUN |  | NOT_RUN: attachment pipeline absent. |
| AT-030 | P1 | NOT_RUN |  | NOT_RUN: WebRTC/TURN/native call flow absent. |
| AT-031 | P1 | NOT_RUN |  | PARTIAL: native chat/settings RU/EN/light-dark/layout test; full flows and assistive-tech checks absent. |
| AT-032 | P1 | NOT_RUN |  | PARTIAL: revoke/session identity exists; trusted enrollment/multi-device history not implemented. |
| AT-033 | P1 | NOT_RUN |  | NOT_RUN: moderation/admin MFA/audit workflow absent. |
| AT-034 | P1 | PASS | evidence/wasm-probe.txt | Native WASM probe fails; browser builds and explicitly disables private chat. Public features still missing. |
| AT-035 | P1 | NOT_RUN |  | NOT_VERIFIED: Android SDK36 exists with unaccepted licenses; Android crypto packaging/build not completed. |
| AT-036 | P1 | PASS | evidence/linux-build-v3.txt | Linux build via isolated GTK toolchain and actual Xvfb launch; compact Linux is not Android evidence. |
| AT-037 | P1 | BLOCKED |  | No macOS/Xcode runner; no Apple artifact claimed. |
| AT-038 | P0 | NOT_RUN |  | PARTIAL: local handoff/checkpoint only; deployment candidate blocked. |
| AT-039 | P1 | NOT_RUN |  | PARTIAL: variable Unicode app frames measured; exact 100-character TLS/network accounting absent. |
| AT-040 | P0 | PASS | evidence/epochs-final.txt | Two real staged self-update commits race, loser rebases, both restart and resume at epoch3. |

PRODUCTION_APPROVED=false. See 2G_REPORT.md and SECURITY_LIMITATIONS.md in docs.
