#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .local reports/evidence
if [[ ! -f .env ]]; then
  python3 - <<'PY'
import secrets
from pathlib import Path
Path('.env').write_text('SECUREMESH_DB_PASSWORD='+secrets.token_hex(32)+'\n')
PY
fi
docker compose up -d --wait db
dotnet restore src/SecureMesh.Api
cargo build --manifest-path src/crypto_core/Cargo.toml
echo 'Bootstrap complete. Use make demo.'
