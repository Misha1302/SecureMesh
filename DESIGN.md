---
name: SecureMesh native interface
description: Material 3 task interface for a partial local encrypted messaging alpha.
colors:
  seed: "#16685B"
  light-primary: "#026B5D"
  light-on-primary: "#FFFFFF"
  light-primary-container: "#9FF2E0"
  light-secondary-container: "#CDE8E0"
  light-on-secondary-container: "#334B46"
  light-surface: "#F5FBF7"
  light-surface-container: "#E9EFEC"
  light-surface-container-high: "#E3EAE6"
  light-on-surface: "#171D1B"
  light-on-surface-variant: "#3F4946"
  light-outline: "#6F7976"
  light-outline-variant: "#BEC9C5"
  light-error: "#BA1A1A"
  dark-primary: "#84D5C4"
  dark-on-primary: "#00382F"
  dark-primary-container: "#005045"
  dark-secondary-container: "#334B46"
  dark-on-secondary-container: "#CDE8E0"
  dark-surface: "#0E1513"
  dark-surface-container: "#1B211F"
  dark-surface-container-high: "#252B29"
  dark-on-surface: "#DEE4E1"
  dark-on-surface-variant: "#BEC9C5"
  dark-outline: "#89938F"
  dark-outline-variant: "#3F4946"
  dark-error: "#FFB4AB"
typography:
  headline-medium:
    fontFamily: "Roboto"
    fontSize: "28px"
    fontWeight: 400
    lineHeight: 1.29
    letterSpacing: "0px"
  title-large:
    fontFamily: "Roboto"
    fontSize: "22px"
    fontWeight: 400
    lineHeight: 1.27
    letterSpacing: "0px"
  body-large:
    fontFamily: "Roboto"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0.5px"
  body-medium:
    fontFamily: "Roboto"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: "0.25px"
  label-large:
    fontFamily: "Roboto"
    fontSize: "14px"
    fontWeight: 500
    lineHeight: 1.43
    letterSpacing: "0.1px"
  label-medium:
    fontFamily: "Roboto"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.33
    letterSpacing: "0.5px"
  label-small:
    fontFamily: "Roboto"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.45
    letterSpacing: "0.5px"
rounded:
  field-outline: "4px"
  message: "16px"
spacing:
  message-label-gap: "6px"
  small: "8px"
  medium: "12px"
  control: "16px"
  unlock-action-gap: "20px"
  section: "24px"
  browser-gate-inset: "32px"
components:
  button-primary-light:
    backgroundColor: "{colors.light-primary}"
    textColor: "{colors.light-on-primary}"
    typography: "{typography.label-large}"
  button-primary-dark:
    backgroundColor: "{colors.dark-primary}"
    textColor: "{colors.dark-on-primary}"
    typography: "{typography.label-large}"
  button-text-light:
    textColor: "{colors.light-primary}"
    typography: "{typography.label-large}"
  button-outlined-light:
    textColor: "{colors.light-primary}"
    typography: "{typography.label-large}"
  field-outlined-light:
    textColor: "{colors.light-on-surface}"
    typography: "{typography.body-large}"
    rounded: "{rounded.field-outline}"
  navigation-compact-light:
    backgroundColor: "{colors.light-surface-container}"
    typography: "{typography.label-medium}"
  message-own-light:
    backgroundColor: "{colors.light-primary-container}"
    textColor: "{colors.light-on-surface}"
    rounded: "{rounded.message}"
    padding: "12px 16px"
    width: "560px"
  message-own-dark:
    backgroundColor: "{colors.dark-primary-container}"
    textColor: "{colors.dark-on-surface}"
    rounded: "{rounded.message}"
    padding: "12px 16px"
    width: "560px"
  message-contact-light:
    backgroundColor: "{colors.light-surface-container-high}"
    textColor: "{colors.light-on-surface}"
    rounded: "{rounded.message}"
    padding: "12px 16px"
    width: "560px"
---

# Design System: SecureMesh native interface

## Current native UI

Android conversations occupy the full content area. Back returns to the inbox. At widths of 980 dp or more, the directory and conversation share a split view. Both themes use the native Material text scale and padded touch targets. Local settings control chat font size and background. The following earlier implementation notes describe previous revisions wherever their screens differ from the current app.

Device verification compares the entered or optically scanned fingerprint with the selected device key before confirmation becomes available. A contact’s display name, username, picture or mere presence in the server directory has no role in that comparison.


## Overview

**Creative North Star: "Visible durable state"**

SecureMesh uses the Material 3 direction pinned by the product brief. The interface is quiet, task focused and explicit about local persistence, connection state and key comparison. Native controls and readable labels carry the design; the green seed supplies continuity across light and dark themes.

This document records the implemented local alpha and its account-access extension. Sources are `apps/client_flutter/lib/native.dart`, `onboarding.dart`, `account_hub.dart`, `http_api.dart`, `local_client.dart`, `session.dart`, `delivery_client.dart`, `transport.dart` and `public_web.dart`, plus resolved `material_ui` 1.11.1 defaults. Generated colors were reproduced with resolved `material_color_utilities` 0.13.0, tonal spot and standard contrast. Frontmatter uses portable CSS units corresponding to Flutter logical pixels and unscaled type sizes. Message component `width` means maximum width in Flutter. The extension preserves the incumbent tokens, Material controls and green semantic theme.

Actual Linux GTK/Xvfb captures in `.impeccable/review/` show registration at (1280×720) and (320×844), plus email verification, sign-in, account hub, comparison, conversation and offline/recovered states. The file named `phone.png` is a compact Linux window, not an Android or iOS capture. Captures are test evidence, not shipping raster UI assets. New account flows have no supplied dark-theme or mobile-platform captures. Product status remains **PARTIAL / NOT_READY**, with four reported RustSec findings, no independent security audit and **PRODUCTION_APPROVED=false**.

**Key Characteristics:**

- Material controls with one green seed and semantic light/dark roles.
- Reusable account forms that distinguish server credentials from the local encrypted-store passphrase.
- Explicit contact comparison and staged device approval before account use.
- Separate connection, queue and message-persistence labels.
- Compact bottom navigation and expanded navigation rail.
- Russian/English application labels and selectable message/key text.
- Visible local-alpha limitations without readiness or audit claims.

## Colors

The palette is generated from one green seed. Use the theme's semantic roles in Dart rather than copying extracted light values into widgets.

### Primary

- **Deep green seed** (`seed`): input to `ColorScheme.fromSeed`, not a universal button color.
- **Action green** (`*-primary`, `*-on-primary`): filled actions, unlock key/lock emphasis, active switches and Material emphasis.
- **Message mint** (`*-primary-container`): own-message background and framework avatar treatment. Message text currently inherits `onSurface`; it does not explicitly bind to `onPrimaryContainer`.

### Secondary

- **Quiet green selection** (`*-secondary-container`, `*-on-secondary-container`): Material navigation selection indicators and their contents. This is a generated role, not a separately chosen brand accent.

### Neutral

- **Theme surface** (`*-surface`): Scaffold and surrounding app canvas.
- **Tonal containers** (`*-surface-container`, `*-surface-container-high`): compact navigation and contact-message backgrounds respectively.
- **Readable ink** (`*-on-surface`, `*-on-surface-variant`): primary and supporting Material text/icons.
- **Outlines** (`*-outline`, `*-outline-variant`): outlined controls and separators through framework defaults.
- **Error** (`*-error`): key/storage, unlock, connection and send errors. Text explains the state; color never supplies the whole message.

**The Theme Role Rule.** Keep the generated light/dark role relationship. The frontmatter captures this dependency version; `ColorScheme.fromSeed` remains the implementation source of truth.

## Typography

**Display and body font:** framework-selected Material typography; Roboto is the current Android/Linux family. No custom font assets or font override are declared. Apple platform typography follows framework defaults and is not validated by the Linux captures.

The app uses Material 2021 roles without a custom type scale. Frontmatter records roles used by the composition or its standard controls. Cyrillic and Latin labels use the same hierarchy.

- **Headline medium:** unlock, account-form, account-hub and Settings headings.
- **Title large:** AppBar title, chat/device sections and Account devices heading.
- **Body large:** field input and standard Material list titles where selected by the control.
- **Body medium:** explanatory copy, connection text and inherited message text.
- **Label large:** standard Material button labels.
- **Label medium:** compact navigation labels through Material defaults.
- **Label small:** explicit persistence caption beneath each message.

Keep strings in the existing `tr(ru, en)` path. The app toggles its own Russian/English strings; `MaterialApp` has no explicit `locale`, `supportedLocales` or localization delegates. Full localization of built-in menus, semantics and formatting is not established.

## Layout

`Scaffold`, AppBar and `SafeArea` frame one selected task. At available body width of at least (760 logical pixels), a labeled navigation rail sits beside Chat or Settings. Below that threshold, bottom navigation replaces it. The rail tests `LayoutBuilder` body width; bottom navigation tests `MediaQuery` window width. Insets near the threshold have not been separately verified.

Unlock and account-onboarding content scroll inside a centered maximum width of (440 logical pixels), with the section inset. Account onboarding has its own AppBar with Back and RU / EN, followed by one headline, supporting copy, vertically stacked labeled fields and a primary action. Account hub and Settings are scrolling lists with the same inset. The account hub uses section headings, request/conversation ListTiles, outlined inputs and aligned filled/text/outlined actions. Chat consists of a peer/trust ListTile, connection and queue row, optional verification banner/error, divider, expanding message list, optional new-message action and persistent composer.

Spacing is the observed set, not a strict 8-unit grid. Section/list insets use `section`; composer inset and message horizontal padding use `control`; inter-message spacing and vertical message padding use `medium`; captions use `message-label-gap`. Unlock also uses `unlock-action-gap`. Preserve these distinctions rather than normalizing to an invented scale.

Messages align right for own messages and left for contact messages, shrink to content and stop at (560 logical pixels). The list is single-column on desktop. No conversation sidebar, group layout or multi-pane flow is implemented. The composer expands from one to four lines, accepts at most (4000 characters) and keeps queueing beside it.

The browser route is a separate availability gate: centered content, maximum width (560 logical pixels), browser-gate inset, lock icon and bilingual explanatory copy. It is not a private-chat screen. Its heading uses a one-off explicit (28 logical pixels) style. It has no theme picker or native adaptive navigation.

## Elevation & Depth

Custom message containers are flat: tonal fills and rounded boundaries distinguish them, with no custom shadow. Other depth is inherited Material behavior. Filled buttons rest at zero elevation and use framework hover elevation (1); dialogs and navigation retain framework defaults. No app shadow tokens or overrides exist.

The app defines no custom motion duration, easing, message entrance or animated scrolling. Timeline following and New messages call `jumpTo`; Material controls/dialogs/theme changes retain inherited transitions. The previous seed's reduced-motion sentence was a requirement, not an implemented animation contract. Explicit reduced-motion validation remains open. Do not add motion that obscures queue, verification or error state.

## Shapes

Messages use `rounded.message`. Fields explicitly use `OutlineInputBorder`, whose current default is `rounded.field-outline`. Filled, outlined and text buttons retain standard Material stadium shapes; icon buttons, navigation selection pills, CircleAvatar and AlertDialog retain framework shapes. There is no app-wide shape override or custom card component.

Material icons supply familiar lock, key, chat, settings, cloud, reconnect, send and device affordances. Do not replace them with branded messenger assets. Peer/device identity uses text and a generic icon; no custom avatar imagery exists.

## Components

### Buttons

Use `FilledButton` for unlock, account submission, chat requests and key/approval confirmation, `IconButton.filled` for queueing, `OutlinedButton.icon` for locking, `OutlinedButton` for checking another device, and `TextButton` for secondary dialog/retry/new-message actions. Unlock and account submission add `medium` label padding inside the standard button. Hover, focus, pressed and disabled treatments come from Material state layers; no custom focus ring is defined.

Unlock disables its action while opening. Onboarding disables fields, submission, language switching and route departure while working. Account-hub actions disable during an action or refresh. The conversation key-confirmation dialog disables its actions while persisting. Queueing disables the send icon until keys are confirmed and while saving. Do not show successful persistence merely because the action was pressed.

### Inputs / Fields

Profile path, passphrase, account credentials, verification code, contact username, device-request identifier and message use labeled outlined fields. Secret fields are obscured with suggestions/autocorrect disabled; account fields also disable autocorrect, and endpoint/email fields select their corresponding keyboard types. Account onboarding reuses one field builder and `Form` with length validators; validation errors appear at the field before a network request. Action/network failures appear separately in the semantic error color, with a live region in onboarding and the account hub. Unlock and message fields retain separate error text. Message limits are in Layout. Queue failure before commit preserves the draft. A post-commit view-refresh failure instead says the message is already queued and asks to reopen the profile.

### Account access and email verification

Registration asks for HTTPS server, username, email and account password. The next step asks for the code from email and explains that local development mail is available in Mailpit. Successful verification opens sign-in on this device. Registration and sign-in can be switched through a secondary text action; email verification is its own step, with invalid/used-code recovery text and retry.

Sign-in shows the account password and a separate local-store passphrase. The account password authenticates with the server; the local passphrase opens this device's encrypted key/store file and is not sent to the server. A new sign-in generates independent device keys. Both RU and EN guidance say device approval is required and that old-history transfer and recovery are unavailable in this alpha. Approval must never be presented as importing old messages.

A conclusive unauthenticated (400/401/403) rejection releases the unused prepared store/identity so username, endpoint and local passphrase can be corrected on the same form. The unused encrypted file is retained. Ambiguous failures and failures after authentication retain the prepared identity rather than silently replacing it. Password and verification failures keep an actionable error and allow retry when idle; no password-reset, history-import or recovery flow is implemented here.

### Navigation

Chat and Settings are the two destinations. The expanded rail always shows labels; compact navigation also shows icon and label. Selection uses tonal indicators. Chat opens the account hub when no conversation is selected; a conversation's back-arrow action returns to that hub. Selecting Settings loads account devices. Pending-device instructions refer to Chat and the back arrow, matching the visible route. The locked screen has no task navigation; its secondary account action opens onboarding.

### Account hub and consent

The hub leads with Your account and the username, a refresh action and a trust-dependent task list. A trusted device sees conversations, an empty-state explanation, Contact username and Send chat request. Request rows distinguish incoming, waiting and accepted states. Accept, Create chat and a ready-Welcome row lead through explicit comparison before opening a conversation. Reopening a listed conversation also calls the comparison flow. Consent, key comparison and MLS establishment are separate operations; an accepted request alone is not a delivered message.

Refresh runs periodically and can be requested manually. Action errors and refresh errors are stored separately: an action failure stays visible across successful background/manual refreshes and clears when a new account action starts. A successful refresh clears its own refresh failure. Missing fresh key packages have specific retry guidance; other action failures ask the user to check connection and device keys. Do not let a background success erase a failed deliberate action.

### Device enrollment states

The pending hub explains that a password opens only the account and asks for approval from an existing trusted device. It offers a request action, a selectable/copyable request identifier and a retry action for expired requests. The trusted hub provides an outlined identifier field and Verify device. Both sides compare selectable keys through an independent channel before confirming.

| State | Implemented behavior and visible treatment |
| --- | --- |
| Pending | The device stays in the approval-required hub; chat/delivery use remains gated. It can create a signed enrollment request and share its identifier. |
| Approved | A trusted old device has compared the candidate key and signed approval. On refresh, the new device offers Verify approval signature; server approval alone does not unlock the trusted hub. |
| Locally verified | The new device compares and pins the approver key, then verifies the grant locally and creates an activation signature. This is an intermediate operation, not a separate success screen or history-transfer state. |
| Activated | After the activation request succeeds and the local profile records verification, refresh must also report a trusted server device before the trusted hub appears. An activation failure retains the gated flow and an action error for retry. |

The flow authorizes device identity. Full multi-device MLS enrollment/rekey, old-history transfer, recovery and camera/QR enrollment UI remain unavailable. Keep these limits visible instead of equating approval with access to another device's encrypted history.

### Message and durable-state labels

Each message contains selectable text and a small persistence caption. Author semantics distinguish own/contact messages. Captions are **Queued on this device**, **Saved on server** for acknowledged own messages and **Saved on device** for received messages. No read or peer-delivered indicator is implemented in this screen. The queue counter has a live-region semantic wrapper.

The connection row pairs a cloud icon with Connected, Weak connection, Offline, Check keys, Sign in required or Server error text; reconnect has a tooltip. Weak connection means the last pump took more than (2500 milliseconds), not an independently measured radio/network class. Error copy distinguishes retained queue, failed save and queued-but-unrefreshed view. Send-error text has a live-region wrapper.

### Verification dialogs and trust banner

The account-hub comparison dialog shows selectable own key, contact device identifier and contact key, plus an independent-channel instruction that the server does not verify contact identity. Its comparison checkbox starts unchecked; Confirm stays disabled until checked. Cancel/dismissal does not pin the key. After confirmation, pinning must succeed before the account action continues. A failed pin returns an account action error; it does not establish trust. This pattern is also used on both sides of device approval.

The existing conversation verification dialog is a separate incumbent pattern. Unconfirmed conversation trust produces a MaterialBanner with Compare keys. Its dialog presents selectable own/contact public keys, an independent-comparison instruction, Later and Keys match, without the account-hub checkbox. Modal-barrier clicks do not dismiss this dialog; no custom back-navigation interception is installed. A failed pin keeps it open with failure text. The peer subtitle changes only after local confirmation is persisted.

### Settings and scope notice

Settings contains a language switch, system/light/dark dropdown, device list, selectable device-identifier dialog, local-alpha limitation text and Lock profile. Media, public channels and calls are described as unconnected. This notice is product truth, not proof of security or completeness.

### Accessibility implementation and limits

Current native light/dark themes explicitly select `MaterialTapTargetSize.padded` and `VisualDensity.standard`, preserving Material's padded (48 dp) hit-target convention across platforms. An icon button's painted area can remain (40 dp). The app also uses native focus/keyboard behavior, labeled fields, tooltips, selectable text, author semantics and explicit live regions for queue, send and account-action errors. It does not cap system text scaling. Connection, trust and persistence have text labels.

Retained evidence records three passing widget tests, including (320×844) account/unlock layout at (1.3×) text scaling, RU/EN switching and empty-input validation (`reports/evidence/v2-layout.txt`, exit 0). Analyzer and Linux debug build logs also record exit 0. The real GTK/Xvfb scenario records registration, email verification, independent-key sign-in, username consent/comparison, routed Welcome, two-way encrypted text and offline queue/SIGKILL/reopen recovery (`reports/evidence/v2-native-gui-review-fixes.txt`, exit 0). These logs were inspected for documentation, not rerun by the documenter. Enrollment process evidence separately records signed approval, pinned-approver checks and negative scenarios (`reports/evidence/v2-device-enrollment.txt`, exit 0); it does not prove a full native enrollment walkthrough or multi-device MLS history access.

These implementation choices and limited tests are not a completed assistive-technology or security audit. Target sizes need hit-test verification; full-flow large-text overflow, screen-reader behavior, contrast combinations, keyboard order, reduced-motion settings, Android back/IME behavior and Apple-platform conventions still need device-level checks. New account dark flows are uninspected. Do not report those checks as passed from Linux screenshots alone. The browser gate retains framework defaults rather than the native target-size overrides.

The sidecar's self-contained HTML/CSS previews are schematic translations for the design panel. Production styling and behavior live in Flutter, and native rendering takes precedence over a browser preview.

## Do's and Don'ts

### Do:

- **Do** use Material 3 controls and current theme roles for new native UI.
- **Do** keep persistence, connection and key confirmation explicit in text.
- **Do** distinguish account credentials, local-store ownership, server approval, local verification and device activation.
- **Do** preserve readable action errors across background refreshes and give a deliberate retry path.
- **Do** retain RU/EN strings, selectable message/key text and labeled actions.
- **Do** validate compact/expanded, light/dark and large-text behavior after UI changes.
- **Do** preserve the local-alpha scope notice until implementation and evidence change.

### Don't:

- **Don't** hardcode the light palette into dark-mode widgets.
- **Don't** imply read or peer-delivered receipts from server acknowledgement.
- **Don't** imply that an account password or device approval transfers old history or provides recovery.
- **Don't** substitute visual polish for device-trust, offline-queue or accessibility verification.
- **Don't** claim completed groups, media, calls, browser private chat, mobile verification or independent audit.
- **Don't** treat the sidecar's HTML previews as production Flutter widgets or platform test evidence.
