#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .local
if [[ ! -x .local/flutter/bin/flutter ]]; then
  curl --fail --location --retry 2 -o .local/flutter-sdk.tar.xz https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.50.0-stable.tar.xz
  python3 - <<'PY'
import hashlib,tarfile
from pathlib import Path
p=Path('.local/flutter-sdk.tar.xz')
assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()=='6ea2d806fd57269ae783e6788e2a81fc26eaad782f1e0d0ff38623bb765ff9f5'
with tarfile.open(p) as archive:archive.extractall('.local',filter='data')
PY
fi
FLUTTER_SUPPRESS_ANALYTICS=true PUB_CACHE="$PWD/.local/pub-cache" .local/flutter/bin/flutter pub get --enforce-lockfile --directory apps/client_flutter
