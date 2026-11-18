#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
cd "$(dirname "$0")/.."
source .env
export ConnectionStrings__Database="Host=127.0.0.1;Port=55438;Database=securemesh;Username=securemesh;Password=$SECUREMESH_DB_PASSWORD"
export ASPNETCORE_ENVIRONMENT=Development
export StateDirectory="$PWD/.local"
export KeyPackageValidator="$PWD/src/crypto_core/target/debug/securemesh-crypto"
export Kestrel__Certificates__Default__Path="$PWD/.local/tls.pem"
export Kestrel__Certificates__Default__KeyPath="$PWD/.local/tls.key"
echo "$$" > .local/demo-api.pid
exec dotnet run --no-launch-profile --project src/SecureMesh.Api --urls https://127.0.0.1:5088
