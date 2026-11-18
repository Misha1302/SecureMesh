#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DISPLAY=:98
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
export SECUREMESH_CRYPTO_LIB="$PWD/src/crypto_core/target/debug/libsecuremesh_crypto.so"
export SECUREMESH_CERT_FILE="$PWD/.local/tls.pem"
export SECUREMESH_PROFILE
SECUREMESH_PROFILE=$(python3 -c 'import json;print(json.load(open(".local/demo/profiles.json"))[0]["database"])')
Xvfb :98 -screen 0 1280x900x24 -nolisten tcp -ac > .local/xvfb.log 2>&1 &
xvfb_pid=$!
trap 'kill "$xvfb_pid"' EXIT
sleep 1
apps/client_flutter/build/linux/x64/debug/bundle/securemesh_client > >(python3 tests/redact_ui_log.py > .local/gui-runtime.log) 2>&1 &
app_pid=$!
trap 'kill "$app_pid" "$xvfb_pid"' EXIT
wait "$app_pid"
