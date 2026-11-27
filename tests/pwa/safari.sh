#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?Usage: tests/pwa/safari.sh PACKAGED_PWA_DIRECTORY}"
fixture="$(mktemp -d "${RUNNER_TEMP:-/tmp}/securemesh-safari.XXXXXX")"
simulator=''
driver_pid=''
cleanup() {
  if [[ -n "$driver_pid" ]]; then kill "$driver_pid" 2>/dev/null || true; fi
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator"
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT

read -r runtime device_type < <(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
available = [(runtime, row["deviceTypeIdentifier"]) for runtime, rows in devices.items()
             if ".iOS-" in runtime for row in rows
             if row["name"].startswith("iPhone ") and row.get("deviceTypeIdentifier")]
if not available:
    raise SystemExit("No iPhone simulator and compatible iOS runtime on this runner")
runtime, device_type = max(available, key=lambda row: tuple(map(int, row[0].split(".iOS-")[1].split("-"))))
print(runtime, device_type)
')
simulator="$(xcrun simctl create SecureMeshSafariFixture "$device_type" "$runtime")"
echo "Testing Mobile Safari on $runtime / $device_type ($simulator)"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b

# Trust is limited to this disposable simulator. The endpoint binds to loopback.
cat > "$fixture/ca.cnf" <<'CONFIG'
[req]
distinguished_name = dn
x509_extensions = root_ca
prompt = no
[dn]
CN = SecureMesh Safari Fixture CA
[root_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CONFIG
cat > "$fixture/leaf.cnf" <<'CONFIG'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CONFIG
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -config "$fixture/ca.cnf" \
  -keyout "$fixture/root.key" -out "$fixture/root.pem"
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj /CN=127.0.0.1 \
  -keyout "$fixture/server.key" -out "$fixture/server.csr"
openssl x509 -req -in "$fixture/server.csr" -CA "$fixture/root.pem" -CAkey "$fixture/root.key" \
  -CAcreateserial -sha256 -days 2 -extfile "$fixture/leaf.cnf" -out "$fixture/server.pem"
xcrun simctl keychain "$simulator" add-root-cert "$fixture/root.pem"

sudo -n /usr/bin/safaridriver --enable
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
endpoint="http://127.0.0.1:$port"
/usr/bin/safaridriver --port "$port" > "$fixture/safaridriver.log" 2>&1 &
driver_pid=$!
python3 - "$endpoint" <<'PY'
import sys
from time import monotonic, sleep
from urllib.error import URLError
from urllib.request import urlopen

deadline = monotonic() + 30
while monotonic() < deadline:
    try:
        with urlopen(sys.argv[1] + "/status", timeout=2) as response:
            if response.status == 200:
                break
    except URLError:
        sleep(0.4)
else:
    raise SystemExit("Safari WebDriver did not start")
PY
if ! python3 tests/pwa/safari.py "$bundle" --simulator "$simulator" --webdriver "$endpoint" \
  --certificate "$fixture/server.pem" --key "$fixture/server.key"; then
  cat "$fixture/safaridriver.log" >&2
  exit 1
fi
