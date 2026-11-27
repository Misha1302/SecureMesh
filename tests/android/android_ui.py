"""ADB and Android accessibility interactions for the installed APK."""
import re
import subprocess
import time
from xml.etree import ElementTree

PACKAGE = 'com.example.securemesh_client'
PROFILE = f'/data/user/0/{PACKAGE}/files/interop.db'


def adb(*args, timeout=30, check=True):
    # Do not include command arguments (which can contain the ephemeral store
    # passphrase) in failure reports.
    run = subprocess.run(['adb', *args], capture_output=True, text=True, timeout=timeout)
    if check and run.returncode:
        raise RuntimeError(f'ADB {args[0]} failed with status {run.returncode}')
    return run.stdout


def wait_node(description, matches, timeout=60, packages=(PACKAGE,)):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        adb('shell', 'uiautomator', 'dump', '/sdcard/interop-ui.xml', check=False)
        try:
            nodes = ElementTree.fromstring(adb('shell', 'cat', '/sdcard/interop-ui.xml'))
            hits = [n for n in nodes.iter('node') if n.get('package') in packages and matches(n)]
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
