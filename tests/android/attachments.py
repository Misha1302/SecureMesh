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

    def save_received_file(filename):
        action = exact('Save ' + filename, 'Сохранить ' + filename)
        end = time.monotonic() + 60
        previous = None
        toward_newer = True
        while time.monotonic() < end:
            try:
                nodes = [n for n in ui.snapshot() if n.get('package') == ui.PACKAGE]
            except ElementTree.ParseError:
                continue
            for node in nodes:
                if action(node) and node.get('enabled') == 'true' and node.get('clickable') == 'true':
                    return node
            # The newest bubble can be taller than the timeline. Search its
            # scroll viewport in both directions without tapping another file.
            views = [n for n in nodes if n.get('scrollable') == 'true'
                     and n.get('class') != 'android.widget.EditText']
            if len(views) == 1:
                left, top, right, bottom = ui.bounds(views[0])
                visible = tuple((n.get('bounds'), n.get('text'), n.get('content-desc'))
                                for n in nodes if top <= ui.bounds(n)[1] < bottom)
                if previous == visible:
                    toward_newer = not toward_newer
                previous = visible
                x = (left + right) // 2
                near_top = top + (bottom - top) // 4
                near_bottom = bottom - (bottom - top) // 4
                start, finish = (near_bottom, near_top) if toward_newer else (near_top, near_bottom)
                ui.adb('shell', 'input', 'swipe', str(x), str(start), str(x), str(finish), '400')
            time.sleep(.4)
        raise RuntimeError('Missing export action for received attachment')

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
        ui.tap(ui.composer_button('file'))
        navigate_downloads()
        ui.tap(picker_node('Android input file', exact(upload.name)))
        ui.tap(ui.wait_node('Android file confirmation', exact('Отправить', 'Send')))
        linux.receive(root / 'desktop-output.bin', upload.read_bytes())
        linux.send(reply)
        ui.tap(save_received_file(reply.name))
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
