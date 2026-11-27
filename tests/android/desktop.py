"""Drive the installed Linux release through GTK/X11 in an isolated display."""
import csv
import io
import os
from pathlib import Path
import subprocess
import sys
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, timeout=20, **kwargs)


class Desktop:
    def __init__(self, bundle, store, certificate):
        self.bundle, self.store, self.certificate = bundle, store, certificate

    def __enter__(self):
        env = dict(os.environ, SECUREMESH_PROFILE=str(self.store.path),
                   SECUREMESH_CERT_FILE=str(self.certificate), GDK_BACKEND='x11',
                   LIBGL_ALWAYS_SOFTWARE='1', GTK_USE_PORTAL='0', LANG='C.UTF-8')
        env.pop('SECUREMESH_CRYPTO_LIB', None)  # Validate the bundled Rust library.
        self.process = subprocess.Popen([self.bundle / 'securemesh_client'], env=env,
                                        cwd=self.store.path.parent)
        try:
            found = run('xdotool', 'search', '--sync', '--onlyvisible', '--pid',
                        str(self.process.pid), capture_output=True, text=True)
            self.window = found.stdout.splitlines()[0]
            run('xdotool', 'windowfocus', '--sync', self.window)
            # Apply English labels in the app to keep the OCR vocabulary small.
            self.click(self.word('RU'))
            self.click(self.word('passphrase'))
            self.type(self.store.password)
            self.key('Return')
            # The normal online chat dedicates its viewport to the timeline.
            # The later byte-for-byte exchange verifies the actual connection.
            self.word('Message')
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, exc_type, *_):
        if exc_type and self.process.poll() is None and hasattr(self, 'window') and os.environ.get('RUNNER_TEMP'):
            report = Path(os.environ['RUNNER_TEMP']) / 'android-interop-evidence'
            report.mkdir(mode=0o700, exist_ok=True)
            try:
                self.screenshot(report / 'linux-file-failure.png')
            except subprocess.SubprocessError:
                pass
        self.process.terminate()
        self.process.wait(timeout=10)

    def words(self, layout=11, region=None):
        if self.process.poll() is not None:
            raise RuntimeError('Linux packaged client exited')
        frame = run('import', '-window', self.window, 'png:-', capture_output=True).stdout
        x, y, scale = 0, 0, 2
        crop = []
        if region is not None:
            x, y, width, height = region
            crop = ['-crop', f'{width}x{height}+{x}+{y}', '+repage']
            scale = 3
        large = run('convert', 'png:-', *crop, '-resize', f'{scale * 100}%', 'png:-', input=frame,
                    capture_output=True).stdout
        raw = run('tesseract', 'stdin', 'stdout', '--psm', str(layout), 'tsv', input=large,
                  capture_output=True).stdout.decode()
        return [(r['text'].strip().casefold(), x + (int(r['left']) + int(r['width']) // 2) // scale,
                 y + (int(r['top']) + int(r['height']) // 2) // scale)
                for r in csv.DictReader(io.StringIO(raw), delimiter='\t') if r.get('text')]

    def word(self, expected, timeout=35, region=None):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            # Sparse segmentation can omit the label of an outlined text field.
            # The block pass locates it on the same rendered Linux window.
            for layout in (11, 6):
                for text, x, y in self.words(layout, region):
                    if text.strip('.,:;/|') == expected.casefold():
                        return x, y
            time.sleep(.25)
        raise RuntimeError(f'Linux window did not display {expected}')

    def click(self, point):
        run('xdotool', 'mousemove', '--window', self.window,
            str(point[0]), str(point[1]), 'click', '1')

    def key(self, key):
        run('xdotool', 'key', '--clearmodifiers', key)

    def type(self, value):
        # The passphrase never enters the command line or diagnostic output.
        run('xdotool', 'type', '--clearmodifiers', '--delay', '3', '--file', '-',
            input=value, text=True)

    def chooser_path(self, path, title):
        # Require the expected GTK file-selector action on this client process.
        end = time.monotonic() + 20
        while time.monotonic() < end:
            dialogs = subprocess.run(
                ['xdotool', 'search', '--all', '--onlyvisible', '--pid',
                 str(self.process.pid), '--name', f'^{title}$'],
                capture_output=True, text=True, timeout=5,
            ).stdout.splitlines()
            if len(dialogs) == 1:
                dialog, = dialogs
                run('xdotool', 'windowfocus', '--sync', dialog)
                self.key('ctrl+l')
                self.key('ctrl+a')
                self.type(str(path))
                self.key('Return')
                # GtkFileChooser can consume the first Enter for path completion.
                # Confirm again only while focus still belongs to this same dialog.
                for _ in range(5):
                    time.sleep(.65)
                    windows = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid',
                                              str(self.process.pid)], capture_output=True,
                                             text=True, timeout=5).stdout.splitlines()
                    if dialog not in windows:
                        return
                    if run('xdotool', 'getwindowfocus', capture_output=True,
                           text=True).stdout.strip() == dialog:
                        self.key('Return')
                raise RuntimeError('Linux file chooser did not accept the supplied path')
            time.sleep(.2)
        raise RuntimeError(f'Linux GTK {title} dialog did not open')

    def receive(self, dest, expected):
        self.click(self.word('Save', timeout=70))
        self.chooser_path(dest, 'Save File')
        end = time.monotonic() + 30
        while time.monotonic() < end:
            if dest.is_file() and dest.read_bytes() == expected:
                return
            time.sleep(.25)
        raise RuntimeError('Linux export did not reproduce the Android file')

    def send(self, path):
        # Restore focus after GTK Save. Xvfb can deliver a button click even
        # when Flutter's hover tooltip is absent on the captured frame.
        run('xdotool', 'windowfocus', '--sync', self.window)
        geometry = run('xdotool', 'getwindowgeometry', '--shell', self.window,
                       capture_output=True, text=True).stdout.splitlines()
        dimensions = dict(line.split('=', 1) for line in geometry)
        width, height = int(dimensions['WIDTH']), int(dimensions['HEIGHT'])
        mx, my = self.word('Message', region=(0, height - 48, width, 32))
        # The wide Linux composer places Attach, Paste image and Voice in
        # consecutive 48 px targets. From the editor label center to the
        # attach target center is 52 px inside the editor plus 2.5 targets.
        self.click((mx - 172, my))
        self.chooser_path(path, 'Open File')
        self.word('this')
        self.word(path.name)
        self.key('ctrl+Return')

    def screenshot(self, output):
        run('import', '-window', self.window, str(output))
