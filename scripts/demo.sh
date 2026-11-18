#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
export ConnectionStrings__Database="Host=127.0.0.1;Port=55438;Database=securemesh;Username=securemesh;Password=$SECUREMESH_DB_PASSWORD"
export ASPNETCORE_ENVIRONMENT=Development
exec dotnet run --no-launch-profile --project src/SecureMesh.Api --urls http://127.0.0.1:5088
