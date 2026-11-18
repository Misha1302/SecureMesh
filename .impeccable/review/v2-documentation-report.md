# V2 native documentation handoff

Scope: ordinary Material 3 Operate extension, documentation merge for finish-review finding 5. No visual-world replacement or token change. This pass changed only `DESIGN.md`, `.impeccable/design.json` and this report. It did not edit UI/crypto/server sources, run services, install dependencies, rerun the context runner or execute the product tests.

## Recorded implementation

- Shared outlined account fields, inline length validation, email verification, RU/EN and busy/retry states; account password and local-store passphrase remain distinct.
- Correction after a conclusive unauthenticated rejection, retaining unused encrypted files; ambiguous/authenticated failures preserve the prepared identity.
- Account hub, username consent/request states, explicit unchecked comparison acknowledgement and separate account-action/background-refresh errors.
- Pending, approved, locally verified and activated enrollment behavior. Local verification is an intermediate operation, not a claimed success screen. Old-device approval alone cannot open the trusted hub.
- Accurate Chat/back-arrow guidance and explicit absence of old-history transfer/recovery and full multi-device MLS enrollment/rekey.
- The incumbent conversation key dialog is documented separately from the new checkbox comparison dialog, without changing its behavior.

Source inspection covered `apps/client_flutter/lib/{native,onboarding,account_hub,http_api,local_client,session,delivery_client,transport}.dart`, plus the existing browser availability gate and widget tests. Direction remains `.impeccable/surfaces/apps-client-flutter-lib-native-dart.md`; PRODUCT.md and its brand commitments were preserved.

## Evidence checked

Opened actual Linux GTK/Xvfb renders: `desktop.png` (1280×720), `phone.png` (320×844), `v2-login.png`, `v2-email.png`, `v2-account.png`, `v2-compare.png`, `v2-conversation.png`, `v2-recovered.png`, `v2-failed-login.png` and `v2-persistent-action-error.png`. The compact filename does not establish Android/iOS execution. These are test captures, not shipping raster assets.

The following retained command logs were read, not rerun by this documenter:

| Evidence | Recorded command / result | Scope |
| --- | --- | --- |
| `reports/evidence/v2-layout.txt` | Flutter `test --no-pub test`; exit 0, three tests | 320×844 account/unlock at 1.3× text, RU/EN, empty validation and browser private-chat gate. |
| `reports/evidence/v2-flutter-analyze.txt` | Flutter `analyze --no-pub apps/client_flutter`; exit 0 | Static analyzer reports no issues at the recorded run. |
| `reports/evidence/v2-linux-build.txt` | `bash scripts/build-linux.sh`; exit 0 | Actual Linux debug bundle built. |
| `reports/evidence/v2-native-gui-review-fixes.txt` | `.local/venv/bin/python tests/gui/native_v2.py --script tests/gui/v2_scenario.json`; exit 0 | Actual GUI account/consent/MLS exchange and offline COMMIT/SIGKILL/reopen recovery. Failed-login and persistent-action-error captures were inspected alongside source recovery logic. |
| `reports/evidence/v2-device-enrollment.txt` | `.local/venv/bin/python tests/integration/enrollment.py`; exit 0 | Signed enrollment/core negative scenarios; does not establish a complete native enrollment walkthrough or MLS history access. |
| `reports/evidence/v2-native-session.txt` | `.local/venv/bin/python tests/integration/native_session.py`; exit 0 | Shared concurrent refresh rotation with SQLCipher persistence. |
| `reports/evidence/v2-rustsec-initial.txt` | Cargo audit against local advisory database; exit 1 | Four findings and the unmaintained warning remain; no clearance. |

No native design detector was run. No new account dark-flow capture, mobile build, screen-reader/keyboard/IME audit, independent security audit or complete product acceptance is claimed. The original finish disposition was `fix`; the final visual verdict remains the reviewer's responsibility.

## Preservation checks

Documentation validation used Python JSON parsing, exact frontmatter hashing and comparison against the pre-edit in-memory baseline; exit 0. `git diff --check -- DESIGN.md .impeccable/design.json .impeccable/review/v2-documentation-report.md` and `python3 -m json.tool .impeccable/design.json` also returned exit 0.

- `DESIGN.md` token frontmatter is byte-equivalent. SHA-256: `d50bcc9a66c5013deb0c3ac52cb8a4ebd604e841cdb5b3d0bea5cd0d6280b290`.
- Color metadata/tonal ramps, shadow/motion/breakpoint values and typography identities are unchanged. Only two typography purpose descriptions were expanded.
- All nine existing component preview HTML/CSS strings and token references are unchanged. Their descriptive text now records reuse by account controls; no invented web implementation was added.
- The eight canonical DESIGN.md section headings and their order remain unchanged.
- Sidecar changes are timestamp, descriptive metadata and narrative/guardrails; its schema remains version 2.

## Pre-existing drift outside this write boundary

Older recap paragraphs in `STATUS.md`, `reports/TEST_RESULTS.md`, `reports/2G_REPORT.md` and `reports/FINAL_HANDOFF_RU.md` still describe registration, WSS-first transport or routed directory/Welcome as missing, while current source and newer V2 evidence implement those components. The newer STATUS checkpoint already distinguishes some of this progress. This documentation pass reports that historical drift without repairing those files or promoting acceptance rows.

Product remains **PARTIAL / NOT_READY**. Four RustSec findings remain. Full multi-device MLS/history/recovery, groups/media/calls and remaining platform/acceptance work are incomplete. **PRODUCTION_APPROVED=false**.
