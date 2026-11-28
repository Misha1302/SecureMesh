# Crypto integration checkpoint — not an audit

2026-11-18. OpenMLS 0.9.2, basic_credential/RustCrypto 0.6.0, sqlite_storage 0.3.0. Ciphersuite MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519. MIT dependencies; complete license/SBOM review still pending.

`src/crypto_core/src/main.rs` performs identity generation, signed KeyPackages, group creation/Welcome, encrypted application messages and membership rekey. OpenMLS performs cryptography; no project crypto primitives. SQLCipher is compiled with vendored OpenSSL; all OpenMLS and application changes share one FULL synchronous SQLite transaction.

Executed: `python3 tests/crypto/process_spike.py`, exit 0. Evidence: `reports/evidence/m1-crypto.txt`. Every operation launches a fresh process, exercising persistence/reload. Verified independent keys, two-party encrypted Unicode message, third member add/remove/rekey and denial after removal, replay rejection, rejection of unpinned KeyPackage and changed pinned signature key, encrypted store and wrong-passphrase failure, immutable outbox, abort before COMMIT and successful retry.

Limitations: this is a CLI, not a verified Flutter bridge. Explicit pin confirmation is supplied by the test harness to model out-of-band comparison; a usable safety-number/QR workflow is missing. No key transparency, platform keystore, recovery backup or independent audit. Group mutation currently merges locally before server acceptance; concurrent commit rebase is not implemented. Do not use this alpha with real private data.

WASM storage provider explicitly does not support wasm32 in its upstream source; separate web provider/bridge is required. Browser private chat must remain disabled. Native/WASM platform probes are recorded separately; build support alone is not interoperability proof.

Later checkpoint: Dart/FRB 2.13.0 native two-store OpenMLS smoke passed. Concurrent self-update commits now use staged persistence; epoch-conflict integration passed. Original standalone add/remove remains feasibility-only. RustSec found four advisories; see docs/SECURITY_LIMITATIONS.md and retained resolver probes. No security clearance or independent audit is claimed.

## Integration evidence on 2026-11-28

The November 18 observations above describe the original CLI spike. Native and browser clients now exchange MLS messages and private photos through a test relay. The browser uses a separate WASM build and a password-protected local vault. Chromium and Linux Playwright WebKit exchanged real encrypted images in both directions with the native core. A server that controls delivered browser code can still compromise an unlocked browser session. [Interoperability harness](../tests/pwa/native_photo_browser.py)

The native directory verifier checks a complete signed roster and all active device KeyPackages against one pinned AKD checkpoint in one SQLCipher transaction. Tests cover omitted, duplicate, additional, revoked and stale device data. An independent model reviewed the library contract at db6a716 and reran its integration test. The library verifies the forward username and reverse account proofs at the same checkpoint, with complete owner-signed reverse history on first discovery after a rename. Signed checkpoint observations require three of four enrolled witnesses. The clock floor survives rejected proofs and expiry checks; concurrent witness observation and advancement are serialized. Independent reviewers tested the scoped changes. Real registrar policy, independent witness operation and authorization at send time remain release gates. Native device-fingerprint comparison remains available. [Verified-set test](../src/key_directory/tests/package_set.rs) · [Directory implementation](../src/key_directory/README.md)

The native profile QR carries the configured server and username for chat discovery. It provides no evidence about the account owner's identity and grants no device trust. [QR protocol](../docs/PROTOCOL.md) · [Current project status](PRODUCT_HANDOFF_RU.md)
