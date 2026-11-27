# Security limitations — release blocked

## Current native dependency candidate

The candidate pins OpenMLS 0.10.0-rc.1, the matching 0.7.0-rc.1 RustCrypto and basic-credential crates, and the 0.4.0-rc.1 SQLite provider. Version 0.9.2 is the latest stable OpenMLS line inspected and cannot resolve the patched arithmetic and HPKE graph. The RC raises the project’s Rust minimum to 1.94. The application still selects the same MLS X25519/AES128-GCM/SHA-256/Ed25519 ciphersuite.

| Advisory | Previous locked package | Candidate |
|---|---|---|
| RUSTSEC-2026-0387 | crypto-bigint 0.5.5 | 0.7.11 |
| RUSTSEC-2026-0330 / 0331 | libcrux-kem 0.0.9 | 0.0.11 |
| RUSTSEC-2026-0459 / 0502 | libsqlite3-sys 0.35.0; an intermediate resolver probe selected sqlcipher-src 419.0.6 | Upstream libsqlite3-sys Git revision 0f1ab739 (0.39.1), with sqlcipher-src 420.0.0, SQLCipher 4.20.0 and SQLite 3.54.1 |

The registry version of the FFI crate with the same version number still uses affected SQLCipher sources. Preserve the full Git revision in Cargo.lock. The upstream change is part of [rusqlite PR 1932](https://github.com/rusqlite/rusqlite/pull/1932). Replace the Git pin when OpenMLS storage and refinery accept a fixed registry release. The underlying [SQLCipher advisory](https://rustsec.org/advisories/RUSTSEC-2026-0502.html) covers the bundled C implementation.

cargo-audit 0.23.0 reported zero vulnerability advisories against the candidate lockfile. RUSTSEC-2026-0173 remains an informational maintenance warning for proc-macro-error2. The database revision and test scopes are in [the candidate evidence](../reports/evidence/rustsec-remediation.json). The changed native dependency graph requires platform acceptance and independent review. Earlier downloadable binaries retain their original dependencies.

The prior client validates its schema migration history when unlocking a profile. Running upstream V7/V8 during the candidate evaluation caused the prior client to reject the upgraded file. SecureMesh therefore embeds the six shared upstream migrations for its standard MLS profile. Virtual-client draft features are disabled. A compatibility test checks the stored checksums against the complete upstream migration set on a disposable database.

## Historical baseline

The modernization scan using cargo-audit 0.23.0 and RustSec advisory DB commit `c9f6c91a44dbad9d71742329e9df061279f9c4be` (2026-11-26) found five advisories in the original lockfile. Updating `url` from 2.5.8 to 2.5.9 and `form_urlencoded` from 1.2.2 to 1.2.3 cleared RUSTSEC-2026-0592. The second scan exited 1 with the four findings listed below. The scoped before/after results are in `reports/evidence/modernization-rustsec.json`.

Historical V2 RustSec scan exits 1 (`reports/evidence/v2-rustsec-initial.txt` and `reports/evidence/rustsec-current.txt`), database commit 472a4c9a785030434f15d7da84964d60fbe789ab. The baseline recorded the following four findings:

| Advisory | Locked package | Finding |
|---|---|---|
| RUSTSEC-2026-0387 | crypto-bigint 0.5.5 | Timing variability in intended constant-time operations |
| RUSTSEC-2026-0330 | libcrux-kem 0.0.9 | Hybrid encapsulation short-seed panic |
| RUSTSEC-2026-0331 | libcrux-kem 0.0.9 | Additional KEM advisory; authoritative details in retained JSON |
| RUSTSEC-2026-0459 | libsqlite3-sys 0.35.0 | Malicious SQLite/WAL files can expose stale process memory |

`proc-macro-error2` is also reported unmaintained. No advisory was ignored. Selected ciphersuite is X25519/AES128GCM/Ed25519; P256 dependencies are still compiled via the current upstream provider. `cargo tree -i libcrux-kem --target all` reports no selected dependency path, in that version; this is not a completed reachability assessment or clearance.

Real compatibility probes attempting crypto-bigint 0.7.6 and libsqlite3-sys 0.39.1 failed dependency constraints (`compat-bigint.txt`, `compat-sqlite.txt`). The former version was also reported yanked. A fresh compatible update selected zero changes. Updating only Cargo.lock cannot fix upstream version/API constraints. The SQLite advisory also identifies affected bundled SQLCipher in newer wrappers: a higher wrapper version alone is not clearance. These constraints motivated the candidate evaluation above. Do not hand-edit cryptographic arithmetic, suppress advisories, substitute plaintext storage or claim clearance.

NuGet vulnerability query returned exit 0; that only means its queried feed reported no vulnerable packages. Initial OSV access failed; a current OSV query now covers all 55 hosted Pub lock versions, including the new native dependencies, with zero reported package advisories. A known-affected archive 3.3.6 positive control returns its actual advisory IDs; no affected package is installed for this check. Evidence: reports/evidence/v2-pub-osv.txt and v2-pub-osv.json; API contract: https://google.github.io/osv.dev/post-v1-querybatch/. This feed result is not a security clearance or remediation of the four historical RustSec findings. Cargo license metadata and CycloneDX inventory are retained. allo-isolate lacks a license expression in metadata; its supplied Apache 2.0 LICENSE is copied under third_party/licenses. A complete multi-ecosystem license/SBOM/container review is still pending.

Signed manual device enrollment/activation and the consented initial-DM KeyPackage/Welcome path now have real negative/integration tests. This is not independent security assurance, a transparency service, QR-camera enrollment, multi-device MLS membership or old-history recovery. Account passwords never unlock old MLS history. Native WSS/HTTPS fault handling and signup/DM UI are exercised on Linux; other platforms remain unverified. Secure keyring/keystore, admin MFA and audited browser private support are absent. Missing social/media/calls/admin capabilities are not security-reviewed features. Browser private chat is disabled. Production API startup deliberately rejects non-Development environments. Do not use this alpha with real sensitive data. Independent crypto/mobile/infra audits are future requirements, not completed work.

PRODUCTION_APPROVED=false
