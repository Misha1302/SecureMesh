# Interrupted sign-in documentation handoff

Scope: ordinary, code-led extension of the existing Material 3 **Operate** surface. Implementation baseline: `1c08659`; the subsequent narrow RU/EN feedback correction was inspected in the working tree. This documenter writes only this report. No design-world replacement, approved token change, comp, shipping raster, deployment or production approval applies.

## Recorded behavior

- The profile-field folder action lists saved `.db` files without a plaintext account-label index. Selection clears the entered local passphrase; manual paths remain available. Discovery stops at 128 encountered files and sorts that selection by modification time. Empty-list, folder-access and wrong-passphrase errors provide next actions.
- Unlocking a prepared/authenticated journal opens **Continue sign-in** with the saved HTTPS origin, username and device binding. Those fields are read-only. The original store passphrase unlocks the local keys; the account password authenticates to the server.
- A prepared draft requests the account password. A saved session offers **Finish signing in** without requesting it again. A rejected/expired saved session removes that session, retains the same device identity and asks for the account password. A conclusive first rejection can release an unused draft; a rejection after an ambiguous login preserves the potentially registered keys.
- `AccountSetup` uses the existing OpenMLS/SQLCipher journal before network login, validates the device-authentication challenge before signing, saves the allowlisted session before account lookup, and completes the profile/journal transition transactionally. A lost accepted reply can issue another session on retry with the same device/key; exactly-once session issuance is not claimed.
- Completion returns to the existing account hub. Pending-device private-data access stays gated. Account credentials and resumed sign-in do not approve a device, transfer history, recover a forgotten store passphrase or restore lost-all-devices access.
- The locale correction stores RU/EN error pairs and chooses the visible text during build, including resume-load failures. Switching the application language no longer requires discarding recovery feedback. The test now enters the account password before switching locale to exercise preservation of entered state.

Sources inspected: `apps/client_flutter/lib/{native,onboarding,account_setup,profile_files}.dart`, supporting `src/crypto_core/src/onboarding.rs`, `tests/gui/v2_resume_scenario.json`, and `docs/ONBOARDING_RESUME.md`.

## Incumbent design comparison

`PRODUCT.md`, `DESIGN.md`, `.impeccable/design.json` and `.impeccable/surfaces/apps-client-flutter-lib-native-dart.md` were read directly; context was not rerun. The extension keeps the green (`#16685B`) generated light/dark theme, Material typography, padded targets and standard density. The account form retains its AppBar/Back/RU–EN control, SafeArea, scroll view, maximum width 440, inset 24, labeled outlined fields, filled primary action and semantic error live region. The chooser uses the existing platform dialog language. No new palette, font, shadow, motion or decorative imagery was introduced.

The documenter opened all 11 current captures under `.impeccable/review/`: `v2-resume-{empty,picker,wrong-passphrase,prepared,completed,authenticated,authenticated-complete,expired,expired-compact,expired-compact-en,expired-complete}.png`. Each shows its named state without a blank render or visible overlap/clipping. The prepared and cached-session captures retain the narrow form and saved-key/no-history explanation. Both compact locale states preserve the obscured entered password; the English error now follows the selected language. Completion captures show the approval-required hub rather than an approved device or recovered history. Compact captures are **320×844 Linux GTK/Xvfb windows**, not Android/iOS evidence; desktop captures are 1280×720. Captures are test evidence, not shipping image assets. The HTML/CSS detector was not run because it cannot assess this native Flutter surface.

## Evidence inspected

These are retained actual execution logs, read by this documenter rather than rerun here:

| Evidence | Recorded command/result | Supported scope |
| --- | --- | --- |
| `reports/evidence/v2-onboarding-challenge-recovery.txt` | `make onboarding-recovery`; exit 0 | Real Dart/OpenMLS/SQLCipher/TLS/PostgreSQL process checks: substituted challenge rejection before signing/login, lost accepted reply and SIGKILL continuity, saved/expired sessions, foreign binding denial, pre/post-COMMIT cases, wrong passphrase, initializer rollback and pending-access denial. |
| `reports/evidence/v2-onboarding-gui-before-locale-fix.txt` | `make gui-onboarding-recovery`; exit 0 | Actual native prepared, authenticated and expired resume modes with same-device completion and pending-access checks; this earlier pass contains the reviewed language defect. |
| `reports/evidence/v2-resume-locale-analyze.txt` | Flutter `analyze --no-pub apps/client_flutter`; exit 0 | Analyzer found no issues after the narrow locale correction. |
| `reports/evidence/v2-resume-locale-linux-build.txt` | `make build-linux`; exit 0 | Actual Linux debug bundle built after the correction. |
| `reports/evidence/v2-onboarding-gui-locale-fix.txt` | `make gui-onboarding-recovery`; exit 0 | Corrected native prepared/authenticated/expired modes completed with same-device/profile and pending-access checks. Password entry precedes locale switching; the recaptures show the corrected feedback and retained obscured input. |

The same reviewer's final `.impeccable/review/v2-onboarding-finish-report.md` now records **disposition: ship**, with the sole P2 recovery-feedback language finding scored **resolved**. The reviewer independently reopened all 11 replacement captures and identified no regression from this fix in those captures or the runtime diff. This verdict scores that listed correction on the supplied light Linux evidence; it is not a new whole-surface review or whole-product acceptance.

## Preservation and historical drift

`git diff --stat -- PRODUCT.md DESIGN.md .impeccable/design.json .impeccable/surfaces/apps-client-flutter-lib-native-dart.md` produced no changes. Their full-file SHA-256 values at inspection were:

```text
PRODUCT.md: c2cc9fdc7519babd8532915dc9e21f9bd24bbe4fe5152d468a930e13ac23ed6b
DESIGN.md: e92adc9b1a869152c2e814184955df33c2552e4a8087e25996aa5405ae1b2501
.impeccable/design.json: 916b547d31ac150be0f8de0b0746dd3cdc7e02e57bb764aacc3cfb860e5e83ba
.impeccable/surfaces/apps-client-flutter-lib-native-dart.md: 810ce14d17fa1ea1648e8edb397acd231bd924d6fb36d4f733ce5e230fea12f4
```

A read-only Python documentation check returned exit 0: all four preserved hashes matched, the sidecar parsed as JSON, report whitespace was valid, and the five cited logs ended with `Exit code: 0`. Product tests were not rerun by this documenter.

The existing design account-access prose and surface STORY describe the earlier new-device sign-in flow. Their rejection-release wording predates the explicit prior-ambiguous-attempt guard; the current implementation and `docs/ONBOARDING_RESUME.md` supply that qualification. The sidecar's account-flow narrative is also historical and omits this interrupted-sign-in journal.

The parent's existing context result reported `design-sidecar-stale` (severity `mention`): DESIGN.md was edited after `.impeccable/design.json` was generated, so the sidecar's ramps, shadows, motion tokens and component snippets **may** contradict it. This is a reported staleness warning, not a newly established token contradiction. No refresh or tooling repair was performed. The separate `config-build-path-unset` finding concerns Persuade/Experience and does not apply to this code-led Operate extension.

## Limits

This local component does not complete registration/email recovery before journal creation, OS keyring integration, camera/QR enrollment, full multi-device MLS enrollment/rekey, old-history recovery, groups, media, calls or the remaining product acceptance work. The supplied light Linux evidence does not verify new-flow dark mode, Android/iOS, full-flow enlarged text, screen readers, focus/keyboard traversal, IME/back behavior, reduced motion or all contrast/target combinations. No independent security audit is established.

Full product status remains **PARTIAL / NOT_READY**; four reported RustSec findings remain. **PRODUCTION_APPROVED=false**.
