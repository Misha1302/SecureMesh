# Crypto integration checkpoint — not an audit

2026-11-18. OpenMLS 0.9.2, basic_credential/RustCrypto 0.6.0, sqlite_storage 0.3.0. Ciphersuite MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519. MIT dependencies; complete license/SBOM review still pending.

`src/crypto_core/src/main.rs` performs identity generation, signed KeyPackages, group creation/Welcome, encrypted application messages and membership rekey. OpenMLS performs cryptography; no project crypto primitives. SQLCipher is compiled with vendored OpenSSL; all OpenMLS and application changes share one FULL synchronous SQLite transaction.

Executed: `python3 tests/crypto/process_spike.py`, exit 0. Evidence: `reports/evidence/m1-crypto.txt`. Every operation launches a fresh process, exercising persistence/reload. Verified independent keys, two-party encrypted Unicode message, third member add/remove/rekey and denial after removal, replay rejection, rejection of unpinned KeyPackage and changed pinned signature key, encrypted store and wrong-passphrase failure, immutable outbox, abort before COMMIT and successful retry.

Limitations: this is a CLI, not a verified Flutter bridge. Explicit pin confirmation is supplied by the test harness to model out-of-band comparison; a usable safety-number/QR workflow is missing. No key transparency, platform keystore, recovery backup or independent audit. Group mutation currently merges locally before server acceptance; concurrent commit rebase is not implemented. Do not use this alpha with real private data.

WASM storage provider explicitly does not support wasm32 in its upstream source; separate web provider/bridge is required. Browser private chat must remain disabled. Native/WASM platform probes are recorded separately; build support alone is not interoperability proof.
