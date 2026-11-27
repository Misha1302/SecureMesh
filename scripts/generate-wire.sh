#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PUB_CACHE="$PWD/.local/pub-cache"
export PATH="$PWD/.local/flutter/bin:$PATH"
dart pub global activate protoc_plugin 25.1.0
.local/venv/bin/python -m grpc_tools.protoc -Icontracts/runtime \
  --plugin="protoc-gen-dart=$PUB_CACHE/bin/protoc-gen-dart" \
  --dart_out=apps/client_flutter/lib/src/wire contracts/runtime/wire.proto
