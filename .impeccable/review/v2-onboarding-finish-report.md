## verdict

**P2 — resolved.** Existing onboarding recovery feedback now follows RU / EN. The replacement `v2-resume-expired-compact-en.png` visibly shows the complete expired-session instruction in English, while `v2-resume-expired-compact.png` shows the Russian instruction. Both show the prefilled, obscured account password; the replacement `v2-resume-expired-complete.png` shows completion into the same pending-device account flow. This scores the single finding from the initial review, not a new whole-surface review.

The inspected diff in `apps/client_flutter/lib/onboarding.dart` changes the error storage to a `({String ru, String en})` pair (line 41), supplies both variants for every existing error branch including load-resume failure (lines 106–109 and 223–249), and selects the visible message during build (line 417). The existing RU / EN toggle remains a state change of `ru`; no password, journal, trust, layout or palette logic changed in this diff.

Independently reopened all 11 recaptures at their original paths under `.impeccable/review/`: `v2-resume-empty.png`, `v2-resume-picker.png`, `v2-resume-wrong-passphrase.png`, `v2-resume-prepared.png`, `v2-resume-completed.png`, `v2-resume-authenticated.png`, `v2-resume-authenticated-complete.png`, `v2-resume-expired.png`, `v2-resume-expired-compact.png`, `v2-resume-expired-compact-en.png`, and `v2-resume-expired-complete.png`. The required captures exist, match their stated content, and are valid. The supplied desktop and compact dimensions remain 1280×720 and 320×844. No regression caused by this fix batch is visible in the reviewed captures or inspected runtime diff.

Inspected `reports/evidence/v2-onboarding-gui-locale-fix.txt`: it records password entry before switching, a journal check during switching, completion without another fill, same-device/profile checks, retained pending-access gating and credential/token-log checks, with exit 0. The retained analyzer log `v2-resume-locale-analyze.txt` reports no issues and exit 0; `v2-resume-locale-linux-build.txt` records a successful Linux build and exit 0. These commands were not rerun by this reviewer.

## remaining

Clear for the sole scored P2 finding. This disposition covers that fix only on the supplied light Linux GTK/Xvfb evidence. It is not whole-product acceptance, mobile-platform qualification, an accessibility audit, or security approval. Broader PARTIAL / NOT_READY status and `PRODUCTION_APPROVED=false` remain.

disposition: ship
