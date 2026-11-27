#!/usr/bin/env bash
set -euo pipefail
# Signing secrets come from the release operator or secret store.
: "${SECUREMESH_SIGNING_STORE:?set the absolute path to the distribution keystore}"
: "${SECUREMESH_STORE_PASSWORD:?set the keystore password}"
: "${SECUREMESH_KEY_ALIAS:?set the release key alias}"
: "${SECUREMESH_KEY_PASSWORD:?set the private key password}"
: "${SECUREMESH_SIGNER_SHA256:?set the trusted certificate SHA-256 digest}"
: "${ANDROID_HOME:?set the Android SDK location}"
cd "$(dirname "$0")/../apps/client_flutter"
flutter pub get --enforce-lockfile
flutter build apk --release --no-pub
apk=build/app/outputs/flutter-apk/app-release.apk
android_tools=$(find "$ANDROID_HOME/build-tools" -type f -name apksigner | sort -V | tail -n 1)
if [[ ! -x "$android_tools" ]]; then
  echo 'Install Android SDK Build Tools with apksigner.' >&2
  exit 1
fi
certificate=$("$android_tools" verify --print-certs "$apk")
actual=$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"$certificate")
expected=${SECUREMESH_SIGNER_SHA256//:/}
if [[ ! "$expected" =~ ^[0-9A-Fa-f]{64}$ || "${actual,,}" != "${expected,,}" ]]; then
  echo 'APK signer does not match the trusted distribution certificate.' >&2
  exit 1
fi
python3 - "$apk" <<'PY'
import sys
from zipfile import ZipFile

with ZipFile(sys.argv[1]) as apk:
    for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
        for library in ('libflutter.so', 'libapp.so', 'libsecuremesh_crypto.so'):
            with apk.open(f'lib/{abi}/{library}') as stream:
                if stream.read(4) != b'\x7fELF':
                    raise SystemExit(f'Invalid library for {abi}: {library}')
PY
sha256sum "$apk"
