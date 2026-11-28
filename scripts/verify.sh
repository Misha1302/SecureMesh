#!/usr/bin/env bash
set -uo pipefail
ulimit -c 0
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
check directory-bootstrap cargo test --locked --manifest-path src/crypto_core/Cargo.toml --test directory_bootstrap
check key-directory-proofs cargo test --locked --manifest-path src/key_directory/Cargo.toml
check profile-schema cargo test --locked --manifest-path src/crypto_core/Cargo.toml --lib profile_schema
check encrypted-drafts cargo test --locked --manifest-path src/crypto_core/Cargo.toml --test conversation_drafts
check encrypted-replies cargo test --locked --manifest-path src/crypto_core/Cargo.toml --test message_replies
check private-call-signals cargo test --locked --manifest-path src/crypto_core/Cargo.toml --test call_signals
check private-chat-views cargo test --locked --manifest-path src/crypto_core/Cargo.toml --test favorites --test history_pages --test media_directory
check private-history-search cargo test --locked --manifest-path src/crypto_core/Cargo.toml --test history_search
check reordered-delivery python3 tests/crypto/reordered_delivery.py
check crypto python3 tests/crypto/process_spike.py
check device-roster python3 tests/crypto/device_roster.py
check smoke python3 tests/integration/smoke.py
check delivery .local/venv/bin/python tests/integration/delivery.py
check credential-versions .local/venv/bin/python tests/integration/credential_versions.py
check session-inactivity .local/venv/bin/python tests/integration/session_inactivity.py
check epochs .local/venv/bin/python tests/integration/epochs.py
check device-enrollment .local/venv/bin/python tests/integration/enrollment.py
check linked-device .local/venv/bin/python tests/integration/linked_device.py
check enrollment-quota .local/venv/bin/python tests/integration/enrollment_quota.py
check migrations .local/venv/bin/python tests/integration/migrations.py
check account-removal .local/venv/bin/python tests/integration/account_removal.py
check private-blobs .local/venv/bin/python tests/integration/private_blobs.py
check verification-email-queue .local/venv/bin/python tests/integration/verification_email_queue.py
check account-recovery .local/venv/bin/python tests/integration/account_recovery.py
check contact-blocks .local/venv/bin/python tests/integration/contact_blocks.py
check mls-directory .local/venv/bin/python tests/integration/directory.py
check public-channels .local/venv/bin/python tests/integration/public_channels.py
check restore-v2 .local/venv/bin/python tests/integration/restore_v2.py
check secrets python3 scripts/scan_secrets.py
check pub-osv python3 tools/audit_pub_osv.py
check rust-format cargo fmt --manifest-path src/crypto_core/Cargo.toml -- --check
if [[ -x .local/security/bin/cargo-audit ]]; then
  check rustsec-current .local/security/bin/cargo-audit audit --file src/crypto_core/Cargo.lock --db .local/advisory-db --json
else
  check rustsec-tool test -x .local/security/bin/cargo-audit
fi
if [[ -x .local/flutter/bin/flutter ]]; then
  check pub-dependency-graph bash -c 'cd apps/client_flutter && PUB_CACHE="$PWD/../../.local/pub-cache" ../../.local/flutter/bin/dart pub deps --json > ../../reports/evidence/v2-pub-deps.json'
  check pub-license-inventory python3 tools/inventory_pub_licenses.py
  check flutter-check bash -c 'FLUTTER_SUPPRESS_ANALYTICS=true PUB_CACHE="$PWD/.local/pub-cache" .local/flutter/bin/flutter analyze --no-pub apps/client_flutter'
  check flutter-layout bash -c 'cd apps/client_flutter && FLUTTER_SUPPRESS_ANALYTICS=true PUB_CACHE="$(pwd)/../../.local/pub-cache" ../../.local/flutter/bin/flutter test --no-pub test'
  check tls-timeout python3 tests/integration/tls_timeout.py
  check native-transport .local/venv/bin/python tests/integration/native_transport.py
  check native-session .local/venv/bin/python tests/integration/native_session.py
  check onboarding-recovery .local/venv/bin/python tests/integration/onboarding_recovery.py
else
  check flutter-sdk test -x .local/flutter/bin/flutter
fi
check network-report python3 scripts/render_network_report.py
check native-network-report python3 scripts/render_native_network_report.py
check acceptance-gate python3 tools/check_completion.py
check v2-acceptance-gate python3 scripts/check_v2_completion.py

if (( failures > 0 )); then
  echo "Verification failed: $failures check groups failed; see reports/evidence."
  exit 1
fi
