#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/verify_bundle.py
dotnet --version
cargo --version
docker compose version
echo 'Local read-only inspection. Release NOT_READY; no remote actions.'
echo 'PRODUCTION_APPROVED=false'
python3 tools/check_completion.py
