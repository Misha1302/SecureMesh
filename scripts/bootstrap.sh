#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .local reports/evidence
chmod 700 .local
if [[ ! -f .env ]]; then
  python3 - <<'PY'
import secrets
from pathlib import Path
Path('.env').write_text('SECUREMESH_DB_PASSWORD='+secrets.token_hex(32)+'\n')
PY
fi
docker compose --profile mail up -d --wait db mailpit
python3 -m venv .local/venv
.local/venv/bin/pip install -r requirements-dev.txt
.local/venv/bin/python -m grpc_tools.protoc -Icontracts --python_out=.local contracts/wire.proto
if [[ ! -f .local/tls.pem || ! -f .local/tls.key ]]; then
  openssl req -x509 -newkey rsa:3072 -noenc -keyout .local/tls.key -out .local/tls.pem -days 30 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1
fi
dotnet restore src/SecureMesh.Api
cargo build --manifest-path src/crypto_core/Cargo.toml
echo 'Bootstrap complete. Use make demo.'
