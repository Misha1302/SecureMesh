#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local/tmp
export TMPDIR="$PWD/.local/tmp"
failures=0
check() {
  if python3 scripts/record.py "$@"; then
    return 0
  else
    failures=$((failures+1))
    return 1
  fi
}
check bundle python3 tools/verify_bundle.py
check build dotnet build src/SecureMesh.Api --no-restore
check crypto-build cargo build --locked --manifest-path src/crypto_core/Cargo.toml
check crypto python3 tests/crypto/process_spike.py
check smoke python3 tests/integration/smoke.py
check delivery .local/venv/bin/python tests/integration/delivery.py
check epochs .local/venv/bin/python tests/integration/epochs.py
check secrets python3 scripts/scan_secrets.py
check rust-format cargo fmt --manifest-path src/crypto_core/Cargo.toml -- --check
if [[ -x .local/security/bin/cargo-audit ]]; then
  check rustsec-current .local/security/bin/cargo-audit audit --file src/crypto_core/Cargo.lock --db .local/advisory-db --json
fi
if [[ -x .local/flutter/bin/flutter ]]; then
  check flutter-check bash -c 'FLUTTER_SUPPRESS_ANALYTICS=true PUB_CACHE="$PWD/.local/pub-cache" .local/flutter/bin/flutter analyze --no-pub apps/client_flutter'
  check flutter-layout bash -c 'cd apps/client_flutter && FLUTTER_SUPPRESS_ANALYTICS=true PUB_CACHE="$(pwd)/../../.local/pub-cache" ../../.local/flutter/bin/flutter test --no-pub test'
fi
check network-report python3 scripts/render_network_report.py
check acceptance-gate python3 tools/check_completion.py

if (( failures > 0 )); then
  echo "Verification failed: $failures check groups failed; see reports/evidence."
  exit 1
fi
