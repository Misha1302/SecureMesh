# SecureMesh V2 — обязательная дорожная карта и приёмка

## Базовые invariants
Оригинальные AT-001...AT-040 неизменны. Дополнительная рабочая `reports/V2_ACCEPTANCE_MATRIX.csv` должна содержать ID, scenario, priority, status PASS/FAIL/NOT_RUN/BLOCKED, evidence path/commit/env/date; не «покрыт частично => PASS». `PRODUCTION_APPROVED=false` до независимого аудита и явного отдельного разрешения владельца.

## Этапы (в порядке выполнения)
S0 [P0] Провести audit HEAD/build; устранить все release-blocking RustSec findings совместимым поддерживаемым provider/storage обновлением и negative tests; довести real KeyPackage directory/Welcome/trust binding, Flutter registration UX, WSS-first+HTTPS fallback, текущие P0. Без новых фич во вред фундаменту.

S1 [P0] Trusted QR new-device approval, account/auth trust boundary, per-device MLS leaves/sync, revoke+rekey, user-owned E2EE history transfer, recoverable encrypted backup with random user key + integrity/anti-rollback, lost-all-devices rules, trust/key transparency design and server-malicious tests.

S2 [P1] Полные личные и групповые чаты и UX, блокировки, реакции/replies/edit/delete/disappearing; публичные группы, Telegram-like channels/posts/feed/subscriptions/search/comments/topics/invites/roles/admin moderation and MFA with mode separation. Интеграционные тесты backend/client/public ACL.

S3 [P1] S3/MinIO media + E2EE client chunks, capture+play of voice Opus, Telegram-like video circles, photos/videos/files/GIF/stickers, resumable multipart, TTL/view-once; text over competing media on 2G; push; 1:1 WebRTC/TURN calls with authenticated signaling.

S4 [P1] Full Flutter UX and platform CI, Android real app and Linux E2E, Windows builds, iOS/macOS verified on macOS or BLOCKED, browser public-only if E2EE unavailable; RU/EN/accessibility, rate/abuse/security, production-like staging, backup/restore of DB+objects, migrations and rollback, load/chaos/low battery/network testing.

S5 [P2] Stories/polls/community features/bots/advanced topics/analytics/group calls after all essential gates; do not mark S4 complete because P2 remains future.

## Additional acceptance scenarios
- V2-01 [P0]: ordinary account login on new device leads only to PENDING_TRUST; old E2EE data inaccessible by password/passkey alone.
- V2-02 [P0]: real signed QR trust enrollment with replay/expiry/MITM/race/unauthorized device rejection.
- V2-03 [P0]: two devices per account independently receive/sync MLS E2EE, offline/reconnect/kill/restart, no lost durable ACK/no logical dup.
- V2-04 [P0]: new device old history via mutually authenticated E2EE transfer; not via server-held keys or cloning old MLS secrets.
- V2-05 [P0]: zero-device restore with user recovery key decrypts eligible history; wrong/no key fails; new MLS trust re-established, peer-visible reset if necessary.
- V2-06 [P0]: malicious server admin root DB+all backups cannot decrypt private message/media/backup; directory key injection/split-view and impersonation detected.
- V2-07 [P0]: revoke member/device => no future epoch decryption; past copies not falsely promised deleted.
- V2-08 [P0]: mixed 2G: three seeds, 200 both directions, GPRS and severe, 60s blackout, lost ACK, half-open, SIGKILL, DB interruption, concurrent media starvation; preserve original warm p95 gate; record raw evidence.
- V2-09 [P0]: backup integrity/corruption/rollback/TTL/view-once and no exposed keys/server logs, confirmed on real data fixtures.
- V2-10 [P1]: invite/message by username, user blocks, replies/edit/delete/reactions/search/chats list and accurate status in true UI.
- V2-11 [P1]: three-user private MLS group with add/remove/rekey/role/epoch conflict/multi-device.
- V2-12 [P1]: create/join/public and invite-only channels, publish/edit/schedule/pin/react/comment/search/subscribe/views/rights and explicit **not-E2EE** label.
- V2-13 [P1]: public groups/topics/moderation/anti-spam with negative permission/IDOR tests; private chats excluded from global search.
- V2-14 [P1]: private photo/video/document GIF upload cancel/retry/checksum/resume and E2EE recipient download/decrypt; denied unauthorized link.
- V2-15 [P1]: microphone capture/encode/voice send, playback/seek; camera capture/round video message preview/send/play; permissions/offline/crashes.
- V2-16 [P1]: disappearing/view-once events, TTL/cache/backup exclusion; user-visible limitations.
- V2-17 [P1]: actual WebRTC/TURN calls with identity verification and denial unauthorized signaling; safety state on weak network.
- V2-18 [P1]: notifications background and no plaintext in push; Android+Linux actual builds/E2E; Apple/Windows independently verified or honestly BLOCKED.
- V2-19 [P0]: full fresh bootstrap, upgrade migration, real DB+object backup restore, secret/security scans, verify gates, 100-character TLS byte accounting, safe-load figures and rollback dry run.
- V2-20 [P0]: external crypto/mobile/infra security audit and explicit owner launch approval are gates to **public production**, not things to fake in CI.

## Process
For each stage inspect actual source and tests; code backend+data+crypto+UI+negative/E2E cases, run relevant tests and commit with evidence. Keep `PLAN.md`, `STATUS.md`, `reports/TEST_RESULTS.md` and the V2 matrix current. Fail closed and leave unfinished rows NOT_RUN. At toolchain/permission blocker continue next independent useful task, record exact error. Do not weaken tests, add `|| true`, invent evidence, hide RustSec or bypass production guard. Use safe working branch, never force push user changes.

## Definition of done
- FUNCTION_VERIFIED: actual backend+client+schema+E2E, auth/cryptographic negative tests, platform tested, evidence.
- FULL_LOCAL_CANDIDATE: original P0 and all V2 P0/P1 functional gates objectively passed, plus clear platform blockers and working deliverable; outstanding external audit separately labeled.
- READY_TO_DEPLOY: no release-blocking security issues, full ops/backup/load/observability, signed provenance, independently reviewed crypto/mobile/infra, designated host/domain, owner explicit permission. Until then production remains disabled.
- PUBLIC_LAUNCH: separate authorized action after READY_TO_DEPLOY, staging dry run, real smoke/rollback, monitoring and legal/privacy checklist. Never claim the prompt itself constitutes production authorization.
