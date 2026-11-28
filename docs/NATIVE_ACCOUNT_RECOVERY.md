# Native account recovery

Open **Sign in on this device**, select the HTTPS server used by the account, and choose **Forgot account password?**. Enter the account username and email, or choose **I already have a code** with the account username. Paste the code from the email and choose a new password.

The native client uses the same v2 credential derivation as registration and sign-in, bound to the selected HTTPS origin and normalized username. It sends only the derived credential, username and one-time code when completing recovery. The password reset returns to sign-in without opening, creating or rekeying a local profile.

To use an existing profile, go back and unlock it with its original local store passphrase. Use **Sign in again** with the new account password. A fresh profile on a second device still requires approval from an existing trusted device. The reset restores account authentication only. Local chat history requires the original profile and its passphrase.

The disposable integration test `tests/integration/native_account_recovery.py` uses the native Flutter onboarding screen, Rust credential derivation, local TLS, PostgreSQL and Mailpit. It checks the original SQLCipher file and profile directory, rejection of the old password and session, successful existing-device sign-in, and pending trust on a new device. Set `SECUREMESH_TEST_FLUTTER` if Flutter is unavailable on PATH.
