# SecureMesh browser MLS core

This crate builds the browser-side WebAssembly module for the iPhone PWA. It uses OpenMLS 0.10.0-rc.1 with the same RustCrypto provider, signature algorithm, ciphersuite, ciphertext wire format, and signed invitation binding as the native client. The native and browser builds share the Argon2id v2 account credential derivation.

## Build and verify

Use Rust 1.100.0 and wasm-bindgen CLI 0.2.130 to regenerate the checked-in browser files. From the repository root:

```sh
rustup target add --toolchain 1.100.0 wasm32-unknown-unknown
cargo +1.100.0 install wasm-bindgen-cli --version 0.2.130 --locked
RUSTUP_TOOLCHAIN=1.100.0 src/browser_crypto/build.sh
cargo +1.100.0 build --locked --manifest-path src/crypto_core/Cargo.toml
node src/browser_crypto/tests/interop.mjs
```

The interoperability test loads the generated WebAssembly module, creates a disposable SQLCipher native profile, checks the v2 credential vector, verifies key packages with the native validator, exchanges signed MLS invitations and text in both directions, and applies a native rekey. It also checks pin replacement rejection, invitation tampering, MLS Welcome recipient references, envelope bindings, and replay rejection. A new PWA invitation publishes a dedicated KeyPackage. Joining compares the signed reference against the reference saved with local consent and the actual recipient entry inside the MLS Welcome. Existing PWA conversations retain their previous state. A Node pass covers wasm and native wire interoperability. Verify Safari, IndexedDB and iPhone home-screen behavior on their respective runners.

## Caller contract

After initialization, pass the prior decrypted profile snapshot and a serialized request to `execute`. The result contains a replacement snapshot and the operation result. Initialization takes an absent snapshot and a canonical nonzero device UUID. An error leaves the input snapshot authoritative.

Keep the snapshot in the browser vault. Persist the replacement snapshot atomically with the matching outbox entry, inbound event and cursor, or other transport state before acting on the result. Keep the decrypted snapshot and all secret key fields out of logs, network requests, and caches. The OpenMLS memory adapter exists only within the transaction. Durable profile semantics come from the vault and are subject to browser storage and runtime security.

This build supports verified one-to-one bootstrap, encrypted text, and inbound same-roster rekey. It authenticates unsupported application events without emitting attachment keys or call data. It accepts a verified removal of the local leaf and prevents further sending from the resulting inactive group. It rejects other roster changes because this browser build has no roster approval workflow. It does not qualify browser E2EE for production.
