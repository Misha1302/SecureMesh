# SecureMesh — local development checkpoint

**PARTIAL / NOT_READY. PRODUCTION_APPROVED=false.** A real encrypted-text vertical slice, not the complete product in the immutable Russian brief. Known RustSec findings block release: see [security limitations](docs/SECURITY_LIMITATIONS.md). Do not use this alpha with real sensitive data.

Implemented/exercised: .NET 10 API and PostgreSQL migrations; local Mailpit email verification; Argon2id/device proof/rotating sessions; OpenMLS 0.9.2 and SQLCipher state/outbox; durable idempotent message+outbox transaction; protobuf WSS and HTTPS services; scoped sync/cursors and epoch conflict recovery; Linux Flutter chat/settings. Native UI currently polls HTTPS. WSS-first automatic fallback and real KeyPackage/Welcome directory workflow remain missing.

```sh
make bootstrap
make demo                 # foreground TLS API, Ctrl-C to stop
# another terminal:
make smoke
make verify               # nonzero for known security/incomplete gates
make down                 # only SecureMesh, preserves DB volume
```

Requirements: Linux, Docker/Compose, Python 3, OpenSSL, .NET SDK 10.0.111, Rust 1.93.1. Credentials are generated into ignored .env; SDKs/stores/runtime files live in ignored .local. Test clients explicitly trust the local certificate; verification is never disabled. API: https://127.0.0.1:5088. Mailpit: http://127.0.0.1:58028. Production startup is disabled.

For the actual Linux UI:

```sh
bash scripts/install-flutter.sh   # pinned 3.50.0, ~1.5 GB archive, SHA-256 checked
make build-linux                 # GTK toolchain in project-only container
# keep make demo running, then:
make seed-demo                   # two real local accounts/stores, no fake messages
make client
```

Open make client twice; use each database path and synthetic local unlock value from .local/demo/profiles.json. That mode-600 ignored file is for local test data only, never real recovery. Compare public keys independently before sending. Private keys stay in each SQLCipher store. UI covers unlock/chat/settings, not registration/groups/media/calls/admin.

The full suites are exposed as make network-gprs and make network-severe; their Python driver was executed with 200 messages each direction and seeds 7/19/41 (exact commands in evidence). All 2400 IDs delivered without logical duplicates. GPRS p95 4.351–4.754 seconds after a retained failed attempt and fix. Functioning-link synthetic baselines do not complete the mixed-fault suite or prove carrier performance: [2G report](reports/2G_REPORT.md).

make verify aggregates implemented build/crypto/API/epoch/secret-pattern/format/UI checks, available RustSec scan and the recorded acceptance gate. Long network/disruptive DB restore checks have separate commands and retained evidence. A component pass does not complete an unfinished acceptance row. See [STATUS](STATUS.md), [matrix](reports/TEST_RESULTS.md), [handoff](reports/FINAL_HANDOFF_RU.md).

Linux was built/launched in Xvfb; compact Linux is layout evidence, not Android verification. Android and Apple artifacts remain unverified. Browser builds with private chat disabled pending a distinct WASM integration. Social/media/WebRTC/admin features are missing. Nothing was deployed or pushed.
