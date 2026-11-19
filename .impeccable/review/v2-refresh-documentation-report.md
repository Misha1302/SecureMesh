# Same-profile session repair documentation handoff

Scope: ordinary, code-led **Operate** extension of the incumbent Material 3 native interface. This independent documenter inspected source, existing system records, retained execution logs and six current captures. This pass writes only this report. It introduces no design world, system token, comp, seed, shipping raster or implementation change; no server, build or product test was rerun.

## Direction and implemented behavior

- **THESIS:** restore server access using the open profile while preserving its device identity, keys, local history and persistent queue.
- **OWN-WORLD:** retain the existing generated green semantic theme, Material typography, standard controls and visible durable state. The source adds no palette, type scale, shadow, motion or decorative asset.
- **STORY:** the conversation reports **Sign in required** with a retained queued message; a wrong account password gives actionable feedback on the same form; correcting it signs in using the same local keys and resumes delivery.
- **FIRST VIEWPORT:** AppBar with Back and RU / EN; `SafeArea`, centered scrollable form, maximum width 440 and inset 24; one Material headline, preservation guidance, labeled username and account-password fields, local-store-passphrase clarification and one filled primary action. A known profile username is read-only. A legacy profile with no saved username can enter it, subject to the existing-key ownership check described in `docs/SESSION_RECOVERY.md`.
- **FORM:** narrow incumbent extension, with outlined fields and standard Material action shapes. No card, new surface identity, concept round or system-wide visual prohibition was added.

`ProfileReauthentication` validates the username and 12–256-character account password before calling the supplied action. The password is obscured; suggestions and autocorrect are disabled. Account authentication uses the already open store, so no local-store passphrase is requested here. Busy state disables fields, submission and language switching and prevents route departure. Failed attempts retain the form and show a semantic error-color live region. Error kinds cover credentials, device denial, challenge mismatch, rate limiting and connection failure; text and validation follow the selected RU/EN language. Successful submission clears the password and returns from the route.

`native.dart` supplies the current session's reauthentication action and commits through `session_reauthenticate`, pauses its delivery timer while the route is open, clears authentication feedback after success and calls the delivery pump when returning. Entry points exist in the conversation's authentication row, Settings and the account hub. The hub reuses `TextButton.icon` alongside refresh; Settings reuses `OutlinedButton.icon`; the conversation uses the existing tooltip-bearing Material icon-button pattern.

Implementation sources inspected: `apps/client_flutter/lib/reauthentication.dart`, the `showReauthentication`, theme, conversation status and Settings portions of `native.dart`, and the account-hub refresh/action entry points in `account_hub.dart`. `apps/client_flutter/test/layout_test.dart` and `tests/gui/v2_reauthentication_scenario.json` were read to qualify the retained test evidence. `docs/SESSION_RECOVERY.md` supplies the broader protocol, migration, backup and functional limits; this documentation pass does not independently audit that protocol.

## Captures and actual execution evidence

All six requested files under `.impeccable/review/` were opened directly:

| Capture | Observed state |
| --- | --- |
| `v2-reauth-required.png` | 1280×720 conversation; sign-in required, retained key-verification state, queue count 1 and locally queued message. |
| `v2-reauth-desktop.png` | 1280×720 initial repair form; saved username, account password and explicit store-passphrase distinction. |
| `v2-reauth-password-error.png` | 1280×720 wrong-password feedback; retained username, obscured entered password and available retry action. |
| `v2-reauth-error-compact.png` | 320×844 Russian error state; readable wrapped body/error text and visible primary action. The AppBar title uses standard ellipsis at this width. |
| `v2-reauth-error-compact-en.png` | 320×844 English error state; translated feedback and obscured entered password remain visible with the same form. |
| `v2-reauth-recovered.png` | 1280×720 connected conversation; queue count 0 and the original message now labeled saved on server. |

These are light-theme Linux GTK/Xvfb windows. The compact windows are not Android or iOS captures. They are review evidence, not shipping raster assets. No blank render or overlapping form controls were observed in the supplied captures. Screenshot labels support the visible state; the retained GUI assertions supply the device, key, ciphertext and recipient checks. No native detector was run; the HTML/CSS detector does not apply to this Flutter surface.

The following retained logs were read in full rather than rerun:

| Evidence | Recorded command and result | Supported scope |
| --- | --- | --- |
| `reports/evidence/v2-refresh-gui.txt` | `make gui-reauthentication`; exit 0 | Actual GTK wrong/correct-password scenario. Wrong password preserves identity, original profile and exact queued ciphertext without another session. Correct password retains the same device and MLS keys, creates exactly one new bound session in this scenario, and delivers/decrypts the original ciphertext once. The log also records its secret-output check passing. |
| `reports/evidence/v2-refresh-final-analyze.txt` | Flutter `analyze --no-pub apps/client_flutter`; exit 0 | No analyzer issues reported. |
| `reports/evidence/v2-refresh-layout.txt` | Flutter `test --no-pub test`; exit 0, four tests passed | Same-profile repair at 320×844 with 1.3× text, validation translated on locale switch and no invalid credential submission; incumbent account forms, unlock and browser gate checks. This is widget evidence, not a complete native accessibility walkthrough. |
| `reports/evidence/v2-refresh-final-linux-build.txt` | `bash scripts/build-linux.sh`; exit 0 | Actual Linux debug bundle built at `build/linux/x64/debug/bundle/securemesh_client`. |

The independently authored `.impeccable/review/v2-refresh-finish-report.md` was read and records **disposition: ship**, with no material fixes, for this narrow light Linux extension. That disposition is a scoped UI review, not independent security assurance, whole-product acceptance or production approval. Only the listed retained checks are reported here; no claim is made that the entire GUI regression suite passed.

## Incumbent system preserved

`DESIGN.md`, `.impeccable/design.json`, `PRODUCT.md` and `.impeccable/surfaces/apps-client-flutter-lib-native-dart.md` were read directly. Their reusable theme, type, layout and control rules remain applicable to this extension. No approved durable design-system change calls for rewriting them. `git diff --stat` for these four paths produced no changes; their inspected SHA-256 values were:

```text
DESIGN.md: e92adc9b1a869152c2e814184955df33c2552e4a8087e25996aa5405ae1b2501
.impeccable/design.json: 916b547d31ac150be0f8de0b0746dd3cdc7e02e57bb764aacc3cfb860e5e83ba
PRODUCT.md: c2cc9fdc7519babd8532915dc9e21f9bd24bbe4fe5152d468a930e13ac23ed6b
.impeccable/surfaces/apps-client-flutter-lib-native-dart.md: 810ce14d17fa1ea1648e8edb397acd231bd924d6fb36d4f733ce5e230fea12f4
```

A read-only Python documentation check exited 0: all four incumbent hashes matched, the sidecar parsed as JSON, the four listed logs ended with `Exit code: 0`, all six PNG dimensions matched their recorded sizes, and report whitespace and the production flag were valid. This was a documentation integrity check; product tests were not rerun.

Five-line system summary:

1. Palette: incumbent `#16685B` seed; generated green light/dark theme roles, semantic surface and error colors.
2. Type: inherited Material roles; headline medium 28, title large 22, body large 16, body medium 14 and label roles 14/12/11 at unscaled logical sizes.
3. Layout: existing AppBar/Back/RU–EN, SafeArea and scrolling maximum-width-440 form with inset 24 and established spacing.
4. Components: standard outlined fields, filled primary action and Material text/outlined/icon entry actions; inherited shape, depth and state treatment.
5. Named rule: retain **The Theme Role Rule** and the **Visible durable state** north star; readable queue, credential and error labels remain explicit.

Not canonized or repaired: the pre-existing `design-sidecar-stale` mention is preserved as historical tooling drift, not a proven new token conflict. Earlier account-access prose and the existing surface STORY describe new-device onboarding and omit same-profile access repair; their history/lost-store recovery restrictions still apply. This task-local repair behavior is documented here and in `docs/SESSION_RECOVERY.md`, without rewriting that incumbent contract or promoting ordinary extension details to new global tokens or prohibitions.

## Limits

Repair requires the available, unlocked local store and its existing signing key. It does not restore a lost store, forgotten local passphrase, history from another device or a revoked device. Local enrollment gates remain in force. The successful GUI run's single-session/once-delivered assertions describe that scenario; interrupted password reauthentication is not advertised as exactly-once server login. Full recovery semantics, signed-refresh retention and local backup boundaries are described in `docs/SESSION_RECOVERY.md`.

Dark-mode repair captures, Android/iOS execution, screen readers, complete focus/keyboard traversal, IME/back behavior, target hit testing, contrast combinations and full-flow large-text/reduced-motion qualification remain outside the supplied evidence. No independent security audit is established. Wider missing-feature and RustSec blockers remain; this report does not resolve them. Product status remains **PARTIAL / NOT_READY**. **PRODUCTION_APPROVED=false**.
