#!/usr/bin/env bash
# Provision a disposable API 28 AOSP emulator with the job's private TLS root.
# The shipped APK, hostname verification and trust configuration are unchanged.
set -euo pipefail
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]]
[[ "$(adb shell getprop ro.build.version.sdk | tr -d '\r')" == 28 ]]
[[ "$(adb shell getprop ro.debuggable | tr -d '\r')" == 1 ]]
[[ -n "${RUNNER_TEMP:-}" ]]
umask 077
out=.local/interop
mkdir -p "$out"
openssl req -x509 -newkey rsa:3072 -nodes -days 1 -subj '/CN=SecureMesh temporary CI root' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign' \
  -keyout "$out/root.key" -out "$out/root.pem"
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -keyout "$out/server.key" -out "$out/server.csr"
cat > "$out/server.extensions" <<'EXT'
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -in "$out/server.csr" -CA "$out/root.pem" -CAkey "$out/root.key" \
  -CAcreateserial -days 1 -extfile "$out/server.extensions" -out "$out/server.pem"
openssl verify -purpose sslserver -verify_ip 127.0.0.1 -CAfile "$out/root.pem" "$out/server.pem"
adb root
adb wait-for-device
adb remount
hash=$(openssl x509 -subject_hash_old -in "$out/root.pem" -noout)
dest="/system/etc/security/cacerts/$hash.0"
# Fail on a hash collision, never replace a preexisting system root.
adb shell test ! -e "$dest"
adb push "$out/root.pem" "$dest"
adb shell chmod 0644 "$dest"
adb shell restorecon "$dest"
adb install "$RUNNER_TEMP/android-candidate/app-release.apk"
