#!/usr/bin/env bash
set -euo pipefail

crate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$crate_dir/../.." && pwd)"
output="${1:-$root/site/app/crypto}"
target_dir="${CARGO_TARGET_DIR:-$crate_dir/target}"
bindgen="${WASM_BINDGEN:-wasm-bindgen}"

if [[ "$("$bindgen" --version)" != "wasm-bindgen 0.2.130" ]]; then
  printf '%s\n' 'Install wasm-bindgen-cli 0.2.130 to match the locked crate version.' >&2
  exit 1
fi
cargo build --manifest-path "$crate_dir/Cargo.toml" --locked --release \
  --target-dir "$target_dir" --target wasm32-unknown-unknown
mkdir -p "$output"
"$bindgen" --target web --no-typescript --out-dir "$output" \
  "$target_dir/wasm32-unknown-unknown/release/securemesh_browser_crypto.wasm"
