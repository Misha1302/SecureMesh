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
android_tools="$ANDROID_HOME/build-tools/36.0.0/apksigner"
if [[ ! -x "$android_tools" ]]; then
  echo 'Install the pinned Android SDK Build Tools 36.0.0.' >&2
  exit 1
fi
python3 - "$apk" "$android_tools" <<'PYCODE'
import hashlib
import os
import re
import ssl
import subprocess
import sys
from zipfile import ZipFile

expected = os.environ['SECUREMESH_SIGNER_SHA256'].replace(':', '').lower()
if not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise SystemExit('Expected signing certificate must be a SHA-256 fingerprint.')
report = subprocess.check_output(
    [sys.argv[2], 'verify', '--print-certs-pem', sys.argv[1]], text=True,
)
certificates = re.findall(
    r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', report, flags=re.S,
)
actual = {hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest() for cert in certificates}
if actual != {expected}:
    found = ', '.join(sorted(actual)) if actual else 'no certificate'
    raise SystemExit(f'APK signing certificate mismatch. Expected {expected}, verified {found}.')
print(f'Verified APK signing certificate SHA-256: {expected}')

with ZipFile(sys.argv[1]) as apk:
    for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
        for library in ('libflutter.so', 'libapp.so', 'libsecuremesh_crypto.so'):
            with apk.open(f'lib/{abi}/{library}') as stream:
                if stream.read(4) != b'\x7fELF':
                    raise SystemExit(f'Invalid library for {abi}: {library}')
PYCODE
sha256sum "$apk"
