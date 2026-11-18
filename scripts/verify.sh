#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/record.py bundle python3 tools/verify_bundle.py
python3 scripts/record.py build dotnet build src/SecureMesh.Api --no-restore
python3 scripts/record.py crypto-build cargo build --locked --manifest-path src/crypto_core/Cargo.toml
python3 scripts/record.py crypto python3 tests/crypto/process_spike.py
python3 scripts/record.py smoke python3 tests/integration/smoke.py
python3 scripts/record.py acceptance-gate python3 tools/check_completion.py
