# Interrupted account sign-in

Status: local Linux component, not device/history recovery. PRODUCTION_APPROVED=false.

The account form uses `AccountSetup` in `apps/client_flutter/lib/account_setup.dart`; the journal operations live in `src/crypto_core/src/onboarding.rs`. These extend the existing OpenMLS/SQLCipher store and HTTPS APIs. There is no new key derivation, encryption primitive, server recovery key or plaintext fallback.

## Durable sequence

1. Before a login request, one SQLCipher transaction creates the independent OpenMLS signing identity, its own pin and a versioned setup journal. The journal binds the random device ID, canonical HTTPS origin, username and registration provenance. It contains neither account password nor store passphrase.
2. Before signing, the native controller checks the challenge's device-authentication purpose, challenge ID, device ID, username, nonce format and payload bound. A server-controlled arbitrary message is not signed as a login proof. Before the login POST, an encrypted `loginUncertain` flag is committed. A lost reply or process death therefore cannot silently replace potentially registered keys. A conclusive rejection of the first attempt may release an unused draft so the form can correct credentials. A rejection after an earlier ambiguous attempt preserves the identity and binding.
3. A successful login response is immediately allowlisted and saved in SQLCipher before fetching `/v1/users/me`. Device ID, trust-state names and token/expiry bounds are checked. The access/refresh tokens are encrypted with the existing store, including its WAL.
4. The authenticated account response must bind to the same device. Profile creation and journal deletion share one transaction. Death before COMMIT retains the draft; death after COMMIT leaves a usable completed profile. An error after completing the profile can retry the UI handoff without another login.

An accepted login whose response never became durable can create another server session on retry, using the **same device and key**. This is not exactly-once session issuance. A durably saved valid session resumes without another login. A 401 clears only the draft session and asks for the account password; it retains the identity, origin and username. No automatic refresh-token rotation is attempted in the setup flow.

## Native flow

On the unlock screen, the folder action lists saved `.db` files from the application profile directory (or the explicitly configured local development directory). Account labels are not stored in a plaintext index. The existing manual path field remains available. The list is bounded to 128 encountered files, sorted by modification time; discovery of more profiles and OS-native file picking remain future work.

Unlock the chosen file with its original store passphrase. A prepared or authenticated setup journal opens **Continue sign-in**. The server/username binding is read-only. A prepared draft asks for the account password; a cached valid session offers **Finish signing in** without asking again. Expiration explains that the account password is needed with the same device keys. A wrong store passphrase fails closed. Back preserves the encrypted file.

Private-data access still follows the existing pending-device rules. Resuming does not approve a device, insert an MLS leaf, import another device's keys, transfer history, recover a forgotten passphrase or restore lost-all-devices access. Interruptions of registration/email verification before journal creation are outside this component. OS keyring, QR camera and full onboarding recovery remain separate roadmap work.

Completed legacy profiles remain usable. An older incomplete file without this journal is not automatically converted or assigned a new identity; it needs a separate explicit migration/recovery path. The new flow prevents this gap for sign-ins prepared with the journal.

## Executed evidence

`make onboarding-recovery` runs the production Dart controller, actual OpenMLS/SQLCipher, local TLS API and PostgreSQL. An owned test-only TLS proxy delays real responses after server commit. Actual owned Dart process groups receive SIGKILL. The scenario checks lost login replies, a later incorrect password, saved and expired sessions, same-key continuity, foreign-session/account denial, abort before local COMMIT, restart after COMMIT, wrong local passphrase and pending-device API denial. Additional negative responses change the real challenge's purpose, ID, device or username; the controller must reject them before signing or sending a login POST, with zero issued sessions.

Successful first run after the fixture correction: `reports/evidence/v2-onboarding-recovery-chunked-fix.txt` and `v2-onboarding-recovery.json`. The first overlapping registration exceeded the existing 10-second fixture timeout; an isolated unchanged registration returned 202 in 1.927 seconds. The next failure exposed a test proxy that failed to decode Dart's real chunked POST body and forwarded an empty body; API correctly returned `INVALID_REQUEST`. The proxy now decodes a bounded body. All failed runs are retained. No timeout, authorization assertion or crypto gate was relaxed.

Actual native GUI qualification and the latest aggregate result are recorded in `reports/ONBOARDING_RESUME_REPORT.md` after execution. Broader acceptance matrices remain incomplete; dependency advisories and independent audit still block production.

## Choosing the account server

Unconfigured native clients ask for the HTTPS origin supplied by the operator. A distributor can compile in a default, for example `flutter build linux --release --dart-define=SECUREMESH_API_ORIGIN=https://chat.example.org`. For the signed Android helper, set the environment variable `SECUREMESH_API_ORIGIN` before running the script. Desktop launch environments can override the compiled default with that variable. For a local TLS fixture set it to the fixture origin explicitly. A configured origin is shown before credentials are submitted and can be changed before registering or signing in. The selected origin stays fixed through email verification and subsequent sign-in. Reopening an interrupted encrypted profile uses its saved server.

Registration on the included API requires an email address. The verification code expires after 30 minutes. Local test mail goes to Mailpit when configured. External SMTP requires an operator-configured sender. The username, account password, email address and verification code are sent only after the relevant submit action using the normal certificate-validating HTTPS client.
