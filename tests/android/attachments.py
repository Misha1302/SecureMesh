"""File-picker, export and integrity checks across two installed native clients."""
import hashlib
import json
import os
import subprocess
import time
from xml.etree import ElementTree

import android_ui as ui
from desktop import Desktop


def attachments(repo, root, report, peer, linux_profile):
    try:
        return exchange_files(repo, root, report, peer, linux_profile)
    except Exception:
        # Only synthetic fixture accounts and files are ever created on this emulator.
        with (report / 'android-file-failure.png').open('wb') as evidence:
            subprocess.run(['adb', 'exec-out', 'screencap', '-p'], stdout=evidence, timeout=15)
        raise


def exchange_files(repo, root, report, peer, linux_profile):
    docs = {'com.android.documentsui', 'com.google.android.documentsui'}

    def picker_node(description, match, timeout=30):
        return ui.wait_node(description, match, timeout=timeout, packages=docs)

    def navigate_downloads():
        nav = picker_node('system document navigation', lambda n: (
            'roots' in n.get('content-desc', '').lower() or
            'navigation' in n.get('content-desc', '').lower() or
            'drawer' in n.get('content-desc', '').lower()))
        ui.tap(nav)
        downloads = picker_node('Downloads location', lambda n: n.get('text', '').lower() in
                                {'downloads', 'загрузки', 'скачанные файлы'})
        ui.tap(downloads)

    def exact(label, *others):
        allowed = {s.casefold() for s in (label, *others)}
        return lambda n: any(n.get(k, '').strip().casefold() in allowed for k in ('text', 'content-desc'))

    def bottom_save():
        end = time.monotonic() + 45
        while time.monotonic() < end:
            ui.adb('shell', 'uiautomator', 'dump', '/sdcard/interop-ui.xml', check=False)
            try:
                tree = ElementTree.fromstring(ui.adb('shell', 'cat', '/sdcard/interop-ui.xml'))
            except ElementTree.ParseError:
                continue
            hits = [n for n in tree.iter('node') if n.get('package') == ui.PACKAGE and exact('Сохранить', 'Save')(n)]
            if hits:
                return hits[-1]  # Newest attachment is last in the timeline.
        raise RuntimeError('Missing Android attachment export action')

    # Both filenames are synthetic. Distinct random payloads rule out successful
    # tests based on stale downloads or an echo of a previous upload.
    upload = root / 'AndroidPacket.bin'
    reply = root / 'LinuxPacket.bin'
    upload.write_bytes(os.urandom(8193))
    reply.write_bytes(os.urandom(12289))
    peer.call('profile_put', profile=linux_profile)
    bundle = repo / 'apps/client_flutter/build/linux/x64/release/bundle'
    with Desktop(bundle, peer, repo / '.local/interop/root.pem') as linux:
        ui.adb('shell', 'mkdir', '-p', '/sdcard/Download')
        ui.adb('push', str(upload), '/sdcard/Download/' + upload.name)
        ui.adb('shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE',
               '-d', 'file:///sdcard/Download/' + upload.name)
        ui.tap(ui.text_node('Прикрепить файл', 'Attach file'))
        navigate_downloads()
        ui.tap(picker_node('Android input file', exact(upload.name)))
        ui.tap(ui.wait_node('Android file confirmation', exact('Отправить', 'Send')))
        linux.receive(root / 'desktop-output.bin', upload.read_bytes())
        linux.send(reply)
        ui.text_node(reply.name, timeout=75)
        ui.tap(bottom_save())
        navigate_downloads()
        ui.tap(picker_node('system export confirmation', exact('Save', 'Сохранить')))
        exported = root / 'android-output.bin'
        end = time.monotonic() + 30
        while time.monotonic() < end:
            if ui.adb('shell', 'stat', '-c', '%s', '/sdcard/Download/' + reply.name, check=False).strip() == str(reply.stat().st_size):
                ui.adb('pull', '/sdcard/Download/' + reply.name, str(exported), check=False)
            if exported.exists() and exported.read_bytes() == reply.read_bytes():
                break
            time.sleep(.3)
        else:
            raise RuntimeError('Android export did not reproduce the Linux file')
        linux.screenshot(report / 'linux-attachments.png')
        (report / 'android-attachments.png').write_bytes(
            subprocess.check_output(['adb', 'exec-out', 'screencap', '-p'], timeout=15))
        data = json.loads((report / 'interop.json').read_text())
        data['privateFiles'] = {
            'androidToLinux': {'bytes': upload.stat().st_size, 'sha256': hashlib.sha256(upload.read_bytes()).hexdigest()},
            'linuxToAndroid': {'bytes': reply.stat().st_size, 'sha256': hashlib.sha256(reply.read_bytes()).hexdigest()},
            'linuxPackagedAotSha256': hashlib.sha256((bundle / 'lib/libapp.so').read_bytes()).hexdigest(),
            'bothNativePickersAndExportsMatched': True,
        }
        (report / 'interop.json').write_text(json.dumps(data, indent=2) + '\n')
        print('PASS: installed Android and Linux clients selected, encrypted, transferred and exported two distinct private files; both SHA-256 checks matched.')
