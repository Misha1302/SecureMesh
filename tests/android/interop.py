#!/usr/bin/env python3
"""Exchange fresh text through the installed release APK and the native Linux delivery client."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/integration'))
import delivery as d
from directory import establish

from android_ui import chat_diagnostics, composer_button, type_challenge
from android_ui import PACKAGE, PROFILE, adb, tap, text_node, type_field, wait_node
from attachments import attachments
from video_capture import capture


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
    # A single local SQLCipher profile is discovered without entering an OS path.
    text_node(Path(PROFILE).stem)
    type_field(wait_node('store passphrase', lambda n: n.get('class') == 'android.widget.EditText'
                         and n.get('password') == 'true'), store.password)
    tap(text_node('Открыть профиль', 'Unlock profile'))
    text_node('Приватный чат', 'Private chat')


class InteropServer(d.Server):
    def start(self):
        self.env.update(Kestrel__Certificates__Default__Path=str(ROOT / '.local/interop/server.pem'),
                        Kestrel__Certificates__Default__KeyPath=str(ROOT / '.local/interop/server.key'))
        super().start()


def exchange(root, phase):
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
    report = Path(os.environ['RUNNER_TEMP']) / 'android-interop-evidence'
    if phase == 'video':
        report /= 'video-api35'
    report.mkdir(mode=0o700, parents=True, exist_ok=True)
    apk = Path(os.environ['RUNNER_TEMP']) / 'android-candidate/app-release.apk'
    with apk.open('rb') as artifact:
        digest = hashlib.file_digest(artifact, 'sha256').hexdigest()
    evidence = {
        'apkSha256': digest,
        'apkSourceCommit': os.environ['APK_SOURCE_SHA'],
        'apkSourceRun': os.environ['APK_SOURCE_RUN'],
        'androidApi': adb('shell', 'getprop', 'ro.build.version.sdk').strip(),
        'sourceCommit': subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    }
    (report / 'interop.json').write_text(json.dumps(evidence, indent=2) + '\n')
    if phase == 'video':
        capture(root, report, peer, linux['session']['accessToken'], group, d)
        return
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
        try:
            type_challenge(challenge)
            tap(composer_button('send'))
            text_node(response, timeout=180)
        except Exception:
            chat_diagnostics(report, challenge, response)
            raise
        if linux_peer.wait(timeout=60) != 0:
            raise RuntimeError('Linux peer did not confirm Android receipt')
        page = d.request('/v1/sync?conversationId=' + group, token=linux['session']['accessToken'])
        sent = page['messages']
        if len(sent) != 2 or {m['senderDeviceId'] for m in sent} != {peer.identity, phone.identity}:
            raise RuntimeError('Expected one stored envelope per device')
        screenshot = subprocess.check_output(['adb', 'exec-out', 'screencap', '-p'], timeout=15)
        if not screenshot.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Android did not return a PNG screenshot')
        (report / 'android-conversation.png').write_bytes(screenshot)
        (report / 'interop.json').write_text(json.dumps({
            **evidence,
            'androidToLinuxDecrypted': True, 'linuxReplyShownOnAndroid': True,
            'linuxReplyAcknowledgedByAndroid': True, 'envelopes': len(sent),
        }, indent=2) + '\n')
        attachments(ROOT, root, report, peer, {
            **linux['session'], 'endpoint': d.BASE, 'group': group, 'peerDevice': phone.identity,
            'peerName': android['username'], 'peerKey': phone.public, 'trustConfirmed': True,
        })
        print('PASS: installed APK sent and displayed distinct private messages over verified TLS; '
              'two native clients, two committed envelopes, a recipient acknowledgement.')
    finally:
        if linux_peer.poll() is None:
            linux_peer.terminate()
            linux_peer.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('files', 'video'))
    phase = parser.parse_args().phase
    os.umask(0o077)
    d.TLS = ssl.create_default_context(cafile=str(ROOT / '.local/interop/root.pem'))
    with tempfile.TemporaryDirectory(dir=ROOT / '.local') as tmp, InteropServer(legacy_bootstrap=False):
        try:
            exchange(Path(tmp), phase)
        finally:
            adb('shell', 'am', 'force-stop', PACKAGE, check=False)
            adb('shell', 'pm', 'clear', PACKAGE, check=False)
            adb('shell', 'rm', '-f', '/sdcard/interop-ui.xml', check=False)
            adb('reverse', '--remove', 'tcp:5090', check=False)


if __name__ == '__main__':
    main()
