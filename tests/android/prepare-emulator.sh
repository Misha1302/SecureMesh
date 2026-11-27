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
timeout -k 5s 45s adb root
timeout -k 5s 45s adb wait-for-device
timeout -k 5s 45s adb remount
hash=$(openssl x509 -subject_hash_old -in "$out/root.pem" -noout)
dest="/system/etc/security/cacerts/$hash.0"
# Fail on a hash collision, never replace a preexisting system root.
timeout -k 5s 45s adb shell test ! -e "$dest"
timeout -k 5s 45s adb push "$out/root.pem" "$dest"
timeout -k 5s 45s adb shell chmod 0644 "$dest"
printf 'Restoring test CA label\n'
timeout -k 5s 20s adb shell restorecon "$dest"
apk="$RUNNER_TEMP/android-candidate/app-release.apk"
remote=/data/local/tmp/securemesh-interop.apk
for attempt in 1 2; do
  printf 'Uploading release APK (attempt %s)\n' "$attempt"
  if timeout -k 5s 90s adb push "$apk" "$remote" &&
     timeout -k 5s 120s adb shell pm install -r "$remote" &&
     timeout -k 5s 10s adb shell pm path com.example.securemesh_client | grep -q '^package:'; then
    timeout -k 5s 10s adb shell rm -f "$remote"
    exit 0
  fi
  timeout -k 2s 5s adb devices -l || true
  timeout -k 2s 5s adb shell service check package || true
  timeout -k 2s 10s adb logcat -d -t 120 PackageManager:I PackageInstaller:I installd:I ActivityManager:W AndroidRuntime:E '*:S' || true
  timeout -k 2s 15s adb wait-for-device || true
done
exit 1
