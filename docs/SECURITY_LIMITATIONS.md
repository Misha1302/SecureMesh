# Security limitations — release blocked

The modernization scan using cargo-audit 0.23.0 and RustSec advisory DB commit `c9f6c91a44dbad9d71742329e9df061279f9c4be` (2026-11-26) found five advisories in the original lockfile. Updating `url` from 2.5.8 to 2.5.9 and `form_urlencoded` from 1.2.2 to 1.2.3 cleared RUSTSEC-2026-0592. The second scan exited 1 with the four findings listed below. The scoped before/after results are in `reports/evidence/modernization-rustsec.json`.

Historical V2 RustSec scan exits 1 (`reports/evidence/v2-rustsec-initial.txt` and `reports/evidence/rustsec-current.txt`), database commit 472a4c9a785030434f15d7da84964d60fbe789ab. All four findings remain:

| Advisory | Locked package | Finding |
|---|---|---|
| RUSTSEC-2026-0387 | crypto-bigint 0.5.5 | Timing variability in intended constant-time operations |
| RUSTSEC-2026-0330 | libcrux-kem 0.0.9 | Hybrid encapsulation short-seed panic |
| RUSTSEC-2026-0331 | libcrux-kem 0.0.9 | Additional KEM advisory; authoritative details in retained JSON |
| RUSTSEC-2026-0459 | libsqlite3-sys 0.35.0 | Malicious SQLite/WAL files can expose stale process memory |

`proc-macro-error2` is also reported unmaintained. No advisory was ignored. Selected ciphersuite is X25519/AES128GCM/Ed25519; P256 dependencies are still compiled via the current upstream provider. `cargo tree -i libcrux-kem --target all` reports no selected dependency path, but the lockfile finding remains recorded; this is not a completed reachability assessment or clearance.

Real compatibility probes attempting crypto-bigint 0.7.6 and libsqlite3-sys 0.39.1 failed dependency constraints (`compat-bigint.txt`, `compat-sqlite.txt`). The former version was also reported yanked. A fresh compatible update selected zero changes. Updating only Cargo.lock cannot fix upstream version/API constraints. The SQLite advisory also identifies affected bundled SQLCipher in newer wrappers: a higher wrapper version alone is not clearance. Next: evaluate maintained compatible OpenMLS providers/credential/storage updates, verify SQLCipher's actual bundled SQLite patch level, then rerun all crypto/negative/persistence tests and the scan. Do not hand-edit cryptographic arithmetic, suppress advisories, substitute plaintext storage or claim clearance.

NuGet vulnerability query returned exit 0; that only means its queried feed reported no vulnerable packages. Initial OSV access failed; a current OSV query now covers all 55 hosted Pub lock versions, including the new native dependencies, with zero reported package advisories. A known-affected archive 3.3.6 positive control returns its actual advisory IDs; no affected package is installed for this check. Evidence: reports/evidence/v2-pub-osv.txt and v2-pub-osv.json; API contract: https://google.github.io/osv.dev/post-v1-querybatch/. This feed result is not a security clearance or remediation of the four RustSec findings. Cargo license metadata and CycloneDX inventory are retained. allo-isolate lacks a license expression in metadata; its supplied Apache 2.0 LICENSE is copied under third_party/licenses. A complete multi-ecosystem license/SBOM/container review is still pending.

Signed manual device enrollment/activation and the consented initial-DM KeyPackage/Welcome path now have real negative/integration tests. This is not independent security assurance, a transparency service, QR-camera enrollment, multi-device MLS membership or old-history recovery. Account passwords never unlock old MLS history. Native WSS/HTTPS fault handling and signup/DM UI are exercised on Linux; other platforms remain unverified. Secure keyring/keystore, admin MFA and audited browser private support are absent. Missing social/media/calls/admin capabilities are not security-reviewed features. Browser private chat is disabled. Production API startup deliberately rejects non-Development environments. Do not use this alpha with real sensitive data. Independent crypto/mobile/infra audits are future requirements, not completed work.

PRODUCTION_APPROVED=false
