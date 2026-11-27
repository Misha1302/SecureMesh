"""Drive the installed Linux release through GTK/X11 in an isolated display."""
import csv
import io
import os
import subprocess
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
            self.word('Connected')
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        self.process.terminate()
        self.process.wait(timeout=10)

    def words(self):
        if self.process.poll() is not None:
            raise RuntimeError('Linux packaged client exited')
        frame = run('import', '-window', self.window, 'png:-', capture_output=True).stdout
        large = run('convert', 'png:-', '-resize', '200%', 'png:-', input=frame,
                    capture_output=True).stdout
        raw = run('tesseract', 'stdin', 'stdout', '--psm', '11', 'tsv', input=large,
                  capture_output=True).stdout.decode()
        return [(r['text'].strip().casefold(), (int(r['left']) + int(r['width']) // 2) // 2,
                 (int(r['top']) + int(r['height']) // 2) // 2)
                for r in csv.DictReader(io.StringIO(raw), delimiter='\t') if r.get('text')]

    def word(self, expected, timeout=35):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for text, x, y in self.words():
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

    def chooser_path(self, path):
        # Wait for the native GTK dialog, not the parent Flutter window.
        end = time.monotonic() + 20
        while time.monotonic() < end:
            found = run('xdotool', 'search', '--onlyvisible', '--pid', str(self.process.pid),
                        capture_output=True, text=True).stdout.splitlines()
            dialogs = [w for w in found if w != self.window]
            if dialogs:
                run('xdotool', 'windowfocus', '--sync', dialogs[-1])
                self.key('ctrl+l')
                self.key('ctrl+a')
                self.type(str(path))
                self.key('Return')
                return
            time.sleep(.2)
        raise RuntimeError('Linux file chooser did not open')

    def receive(self, dest, expected):
        self.click(self.word('Save', timeout=70))
        self.chooser_path(dest)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            if dest.is_file() and dest.read_bytes() == expected:
                return
            time.sleep(.25)
        raise RuntimeError('Linux export did not reproduce the Android file')

    def send(self, path):
        # Find the paperclip by its actual tooltip. Other buttons can precede
        # the editor depending on the client build (e.g. voice recording).
        mx, my = self.word('Message')
        for x in range(max(16, mx - 190), mx - 18, 13):
            run('xdotool', 'mousemove', '--window', self.window, str(x), str(my))
            time.sleep(.65)
            if any(t == 'attach' for t, _, _ in self.words()):
                self.click((x, my))
                break
        else:
            raise RuntimeError('Could not locate the desktop Attach file action')
        self.chooser_path(path)
        # The title begins with "Send"; select the lowest matching word, the
        # confirmation button below the filename.
        self.word('Cancel')
        candidates = [(x, y) for t, x, y in self.words() if t == 'send']
        if not candidates:
            raise RuntimeError('Linux file confirmation did not offer Send')
        self.click(max(candidates, key=lambda p: p[1]))

    def screenshot(self, output):
        run('import', '-window', self.window, str(output))
