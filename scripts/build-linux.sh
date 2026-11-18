#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t securemesh-linux-builder:local -f tests/linux-builder.Dockerfile tests
docker run --rm --network securemesh_default --security-opt label=disable --user "$(id -u):$(id -g)" \
  -v "$PWD:$PWD" -w "$PWD/apps/client_flutter" \
  -e FLUTTER_SUPPRESS_ANALYTICS=true -e PUB_CACHE="$PWD/.local/pub-cache" \
  securemesh-linux-builder:local "$PWD/.local/flutter/bin/flutter" build linux --debug --no-pub
