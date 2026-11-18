#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SECUREMESH_CRYPTO_LIB="$PWD/src/crypto_core/target/debug/libsecuremesh_crypto.so"
export SECUREMESH_CERT_FILE="$PWD/.local/tls.pem"
exec apps/client_flutter/build/linux/x64/debug/bundle/securemesh_client
