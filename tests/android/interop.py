#!/usr/bin/env python3
"""Exchange fresh text through the installed release APK and the native Linux delivery client."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/integration'))
import delivery as d
from directory import establish

PACKAGE = 'com.example.securemesh_client'
PROFILE = f'/data/user/0/{PACKAGE}/files/interop.db'


def adb(*args, timeout=30, check=True):
    # Do not include command arguments (which can contain the ephemeral store
    # passphrase) in failure reports.
    run = subprocess.run(['adb', *args], capture_output=True, text=True, timeout=timeout)
    if check and run.returncode:
        raise RuntimeError(f'ADB {args[0]} failed with status {run.returncode}')
    return run.stdout


def wait_node(description, matches, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        adb('shell', 'uiautomator', 'dump', '/sdcard/interop-ui.xml', check=False)
        try:
            nodes = ElementTree.fromstring(adb('shell', 'cat', '/sdcard/interop-ui.xml'))
            hits = [n for n in nodes.iter('node') if n.get('package') == PACKAGE and matches(n)]
            if hits:
                return hits[0]
        except ElementTree.ParseError:
            pass
        time.sleep(.35)
    raise RuntimeError(f'No Android UI element for {description}')


def text_node(*labels, timeout=60):
    return wait_node(labels[0], lambda node: any(
        label in ' '.join(node.get(k, '') for k in ('text', 'content-desc', 'hint'))
        for label in labels), timeout)


def tap(node):
    x1, y1, x2, y2 = map(int, re.fullmatch(
        r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.attrib['bounds']).groups())
    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))


def type_field(node, value):
    tap(node)
    adb('shell', 'input', 'text', value)
    if 'mInputShown=true' in adb('shell', 'dumpsys', 'input_method'):
        adb('shell', 'input', 'keyevent', '4')


def setup_android(store):
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('Interop fixture requires the disposable CI emulator')
    app_dir = f'/data/user/0/{PACKAGE}'
    uid = adb('shell', 'stat', '-c', '%u', app_dir).strip()
    if not uid.isdecimal() or int(uid) < 10000:
        raise RuntimeError('Expected an installed app with a dedicated UID')
    if any(Path(str(store.path) + suffix).exists() for suffix in ('-wal', '-shm')):
        raise RuntimeError('Encrypted backup must be checkpointed before copying')
    adb('shell', 'mkdir', '-p', f'{app_dir}/files')
    adb('push', str(store.path), PROFILE)
    adb('shell', 'chown', f'{uid}:{uid}', f'{app_dir}/files', PROFILE)
    adb('shell', 'chmod', '600', PROFILE)
    adb('shell', 'restorecon', '-R', f'{app_dir}/files')
    adb('reverse', 'tcp:5090', 'tcp:5090')
    adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
    tap(text_node('Открыть сохранённый профиль', 'Open a saved profile'))
    type_field(wait_node('database path', lambda n: n.get('class') == 'android.widget.EditText'
                         and n.get('password') != 'true'), PROFILE)
    type_field(wait_node('store passphrase', lambda n: n.get('class') == 'android.widget.EditText'
                         and n.get('password') == 'true'), store.password)
    tap(text_node('Открыть профиль', 'Unlock profile'))
    text_node('Приватный чат', 'Private chat')


class InteropServer(d.Server):
    def start(self):
        self.env.update(Kestrel__Certificates__Default__Path=str(ROOT / '.local/interop/server.pem'),
                        Kestrel__Certificates__Default__KeyPath=str(ROOT / '.local/interop/server.key'))
        super().start()


def exchange(root):
    android, linux = d.account(root), d.account(root)
    phone, peer = android['device'], linux['device']
    # Two newly generated local keys are independently available to the test
    # owner. Pin both *before* exercising directory leasing and Welcome routing.
    phone.pin(peer)
    peer.pin(phone)
    group = establish(android, linux)
    phone.call('profile_put', profile={
        **android['session'], 'endpoint': d.BASE, 'group': group,
        'peerDevice': peer.identity, 'peerName': linux['username'],
        'peerKey': peer.public, 'trustConfirmed': True,
    })
    setup_android(phone)
    challenge = 'Android' + secrets.token_hex(12)
    response = 'Linux' + secrets.token_hex(12)
    fixture = dict(database=str(peer.path), passphrase=peer.password,
                   endpoint=d.BASE, group=group, device=peer.identity,
                   token=linux['session']['accessToken'], challenge=challenge, response=response)
    env = dict(os.environ, SECUREMESH_CERT_FILE=str(ROOT / '.local/interop/root.pem'),
               SECUREMESH_CRYPTO_LIB=str(ROOT / 'src/crypto_core/target/debug/libsecuremesh_crypto.so'))
    linux_peer = subprocess.Popen(
        ['dart', 'tool/android_interop_peer.dart'], cwd=ROOT / 'apps/client_flutter',
        stdin=subprocess.PIPE, text=True, env=env)
    try:
        linux_peer.stdin.write(json.dumps(fixture))
        linux_peer.stdin.close()
        type_field(wait_node('message composer', lambda n: n.get('class') == 'android.widget.EditText'),
                   challenge)
        tap(text_node('Поставить сообщение в очередь', 'Queue message'))
        text_node(response, timeout=180)
        if linux_peer.wait(timeout=60) != 0:
            raise RuntimeError('Linux peer did not confirm Android receipt')
        page = d.request('/v1/sync?conversationId=' + group, token=linux['session']['accessToken'])
        sent = page['messages']
        if len(sent) != 2 or {m['senderDeviceId'] for m in sent} != {peer.identity, phone.identity}:
            raise RuntimeError('Expected one stored envelope per device')
        report = Path(os.environ['RUNNER_TEMP']) / 'android-interop-evidence'
        report.mkdir(mode=0o700, exist_ok=True)
        screenshot = subprocess.check_output(['adb', 'exec-out', 'screencap', '-p'], timeout=15)
        if not screenshot.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Android did not return a PNG screenshot')
        (report / 'android-conversation.png').write_bytes(screenshot)
        apk = Path(os.environ['RUNNER_TEMP']) / 'android-candidate/app-release.apk'
        with apk.open('rb') as artifact:
            digest = hashlib.file_digest(artifact, 'sha256').hexdigest()
        (report / 'interop.json').write_text(json.dumps({
            'apkSha256': digest, 'androidApi': adb('shell', 'getprop', 'ro.build.version.sdk').strip(),
            'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
            'androidToLinuxDecrypted': True, 'linuxReplyShownOnAndroid': True,
            'linuxReplyAcknowledgedByAndroid': True, 'envelopes': len(sent),
        }, indent=2) + '\n')
        print('PASS: installed APK sent and displayed distinct private messages over verified TLS; '
              'two native clients, two committed envelopes, a recipient acknowledgement.')
    finally:
        if linux_peer.poll() is None:
            linux_peer.terminate()
            linux_peer.wait(timeout=10)


def main():
    os.umask(0o077)
    d.TLS = ssl.create_default_context(cafile=str(ROOT / '.local/interop/root.pem'))
    with tempfile.TemporaryDirectory(dir=ROOT / '.local') as tmp, InteropServer(legacy_bootstrap=False):
        try:
            exchange(Path(tmp))
        finally:
            adb('shell', 'am', 'force-stop', PACKAGE, check=False)
            adb('shell', 'pm', 'clear', PACKAGE, check=False)
            adb('shell', 'rm', '-f', '/sdcard/interop-ui.xml', check=False)
            adb('reverse', '--remove', 'tcp:5090', check=False)


if __name__ == '__main__':
    main()
