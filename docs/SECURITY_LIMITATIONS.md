# Security limitations — release blocked

Actual RustSec scan exit 1 (`reports/evidence/cargo-rustsec-audit.txt`), database commit 233155b4025b854c68a4b199c0e32d7fd53291a2, updated 2026-11-17:

| Advisory | Locked package | Finding |
|---|---|---|
| RUSTSEC-2026-0387 | crypto-bigint 0.5.5 | Timing variability in intended constant-time operations |
| RUSTSEC-2026-0330 | libcrux-kem 0.0.9 | Hybrid encapsulation short-seed panic |
| RUSTSEC-2026-0331 | libcrux-kem 0.0.9 | Additional KEM advisory; authoritative details in retained JSON |
| RUSTSEC-2026-0459 | libsqlite3-sys 0.35.0 | Malicious SQLite/WAL files can expose stale process memory |

`proc-macro-error2` is also reported unmaintained. No advisory was ignored. Selected ciphersuite is X25519/AES128GCM/Ed25519; P256 dependencies are still compiled via the current upstream provider. `cargo tree -i libcrux-kem --target all` reports no selected dependency path, but the lockfile finding remains recorded; this is not a completed reachability assessment or clearance.

Real compatibility probes attempting crypto-bigint 0.7.6 and libsqlite3-sys 0.39.1 failed dependency constraints (`compat-bigint.txt`, `compat-sqlite.txt`). The former version was also reported yanked. Updating only Cargo.lock cannot fix upstream version/API constraints. Next: evaluate maintained compatible OpenMLS providers/credential/storage updates, verify SQLCipher's bundled SQLite patch level, then rerun all crypto/negative/persistence tests and the scan. Do not hand-edit cryptographic arithmetic, suppress advisories, substitute plaintext storage or claim clearance.

NuGet vulnerability query returned exit 0; that only means its queried feed reported no vulnerable packages. OSV was unreachable; cargo-audit was installed inside the workspace as a fallback after a temporary-directory quota failure. Cargo license metadata and CycloneDX inventory are retained. allo-isolate lacks a license expression in metadata; its supplied Apache 2.0 LICENSE is copied under third_party/licenses. A complete multi-ecosystem license/SBOM/container review is still pending.

Native prototype has no secure keyring/keystore, device transparency, production AS, admin MFA, enrollment/recovery or audited browser private support. Missing social/media/calls/admin capabilities are not security-reviewed features. Browser private chat is disabled. Production API startup deliberately rejects non-Development environments. Do not use this alpha with real sensitive data. Independent crypto/mobile/infra audits are future requirements, not completed work.

PRODUCTION_APPROVED=false
