"""Record the virtual camera and microphone in the installed, unmodified APK."""
import array
import base64
import hashlib
import json
import math
import subprocess
import sys
import time
import urllib.request

import android_ui as ui


def run(*args):
    return subprocess.check_output(args, timeout=30)


def exact(*labels):
    return ui.wait_node(labels[0], lambda n: n.get('enabled') == 'true' and any(
        n.get(k, '').strip() in labels for k in ('content-desc', 'text')))


def green_pixels(rgb):
    return sum(g > 130 and g > 2 * r and g > 2 * b for r, g, b in zip(
        rgb[::3], rgb[1::3], rgb[2::3]))


def contains_tone(raw):
    # Input is mono s16le, 8 kHz. Compare the energy of the applied 733-Hz
    # signal to total energy in successive 200-ms windows, ignoring lead-in.
    pcm = array.array('h')
    pcm.frombytes(raw)
    if sys.byteorder != 'little':
        pcm.byteswap()
    size = 1600
    angle = 2 * math.pi * 733 / 8000
    sine = [math.sin(angle * i) for i in range(size)]
    cosine = [math.cos(angle * i) for i in range(size)]
    for offset in range(0, len(pcm) - size + 1, size):
        samples = pcm[offset:offset + size]
        power = sum(v*v for v in samples)
        if power < size * 25**2:
            continue
        a = sum(v*w for v, w in zip(samples, sine))
        b = sum(v*w for v, w in zip(samples, cosine))
        if 2 * (a*a + b*b) > 0.30 * size * power:
            return True
    return False


def capture(root, report, peer, token, group, delivery):
    if ui.adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('Virtual media test requires a disposable emulator')
    ui.adb('shell', 'pm', 'grant', ui.PACKAGE, 'android.permission.CAMERA')
    ui.adb('shell', 'pm', 'grant', ui.PACKAGE, 'android.permission.RECORD_AUDIO')
    if 'OK' not in ui.adb('emu', 'avd', 'hostmicon'):
        raise RuntimeError('Unable to enable the virtual microphone')
    exercise(root, report, peer, token, group, delivery)


def exercise(root, report, peer, token, group, delivery):
    stim = subprocess.Popen([
        'ffmpeg', '-nostdin', '-loglevel', 'error', '-re', '-f', 'lavfi', '-i',
        'sine=frequency=733:sample_rate=48000', '-f', 'pulse', '-device',
        'mesh_mic', 'synthetic-camera-audio',
    ])
    try:
        ui.tap(ui.text_node('Record video message', 'Записать видеосообщение'))
        ui.tap(exact('Record', 'Записать'))
        # Wait for the application's own 12-second stop and native preview.
        ui.tap(exact('Send', 'Отправить'))
        if stim.poll() is not None:
            raise RuntimeError('Synthetic microphone source stopped unexpectedly')
    finally:
        if stim.poll() is None:
            stim.terminate()
            stim.wait(timeout=10)

    # Reopen the current group on the real Linux recipient and authenticate the
    # delivered video through its MLS event, private blob and own local key.
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        delivery.sync(peer, token, group)
        timeline = peer.call('timeline', group=group)['messages']
        video = next((m for m in timeline if not m['own'] and
                      (m.get('attachment') or {}).get('media') == 'video'), None)
        if video:
            break
        time.sleep(2)
    else:
        raise RuntimeError('Linux recipient did not receive the video envelope')
    metadata = video['attachment']
    req = urllib.request.Request(
        delivery.BASE + f"/v1/conversations/{group}/blobs/{metadata['blobId']}",
        headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(req, context=delivery.TLS, timeout=20) as response:
        cipher = response.read(4*1024*1024 + 17)
    if len(cipher) != metadata['size'] + 16 or metadata['size'] > 4*1024*1024:
        raise RuntimeError('Invalid attachment size')
    opened = peer.call('attachment_open', group=group, id=video['id'],
                       ciphertext=base64.b64encode(cipher).decode())
    clip = root / 'emulated-camera.mp4'
    clip.write_bytes(base64.b64decode(opened['data'], validate=True))
    probe = json.loads(run('ffprobe', '-v', 'error', '-show_streams', '-show_format',
                           '-of', 'json', str(clip)))
    duration = float(probe['format']['duration'])
    kinds = {stream['codec_type'] for stream in probe['streams']}
    if kinds != {'audio', 'video'} or not 9 <= duration <= 14:
        raise RuntimeError('Recorded video missing its sound track or duration bound')
    rgb = run('ffmpeg', '-v', 'error', '-ss', '2', '-i', str(clip), '-frames:v', '1',
              '-vf', 'crop=iw/2:ih/2,scale=48:48', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-')
    pcm = run('ffmpeg', '-v', 'error', '-i', str(clip), '-vn', '-ac', '1',
              '-ar', '8000', '-f', 's16le', '-')
    if green_pixels(rgb) < 1000 or not contains_tone(pcm):
        raise RuntimeError('Decoded media does not reproduce the synthetic lens and microphone')

    ui.adb('shell', 'media', 'volume', '--stream', '3', '--set', '10')
    ui.tap(ui.text_node('Play video', 'Смотреть видео'))
    play = exact('Play', 'Смотреть')
    # Monitor ONLY the Android speaker sink: input and output are isolated.
    speaker = root / 'speaker.pcm'
    with speaker.open('wb') as output:
        listen = subprocess.Popen(['parec', '--device=mesh_speaker.monitor',
                                   '--rate=8000', '--channels=1', '--format=s16le',
                                   '--raw'], stdout=output)
        try:
            ui.tap(play)
            time.sleep(4)
            shot = run('adb', 'exec-out', 'screencap', '-p')
        finally:
            listen.terminate()
            listen.wait(timeout=10)
    pixels = subprocess.run(['convert', 'png:-', '-resize', '240x320!', '-depth', '8', 'rgb:-'],
                            input=shot, capture_output=True, check=True, timeout=10).stdout
    if green_pixels(pixels) < 800 or not contains_tone(speaker.read_bytes()):
        raise RuntimeError('Native Android playback did not render the synthetic image and tone')
    (report / 'android-video-playback.png').write_bytes(shot)
    data = json.loads((report / 'interop.json').read_text())
    data['videoCapture'] = dict(durationSeconds=duration, bytes=clip.stat().st_size,
                                sha256=hashlib.sha256(clip.read_bytes()).hexdigest(),
                                syntheticLens='green', microphoneAndSpeakerHz=733,
                                linuxRecipientOpened=True, androidPlaybackVerified=True)
    (report / 'interop.json').write_text(json.dumps(data, indent=2) + '\n')
    print('PASS: installed APK recorded synthetic lens and microphone, Linux decrypted both tracks, '
          'and Android rendered the authenticated clip to its screen and virtual speaker.')
