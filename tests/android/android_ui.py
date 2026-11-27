"""ADB and Android accessibility interactions for the installed APK."""
import json
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
        try:
            hits = [n for n in snapshot() if n.get('package') in packages and matches(n)]
            if hits:
                return hits[0]
        except ElementTree.ParseError:
            pass
        time.sleep(.35)
    raise RuntimeError(f'No Android UI element for {description}')


def snapshot():
    # UIAutomator can fail during a window transition. Clear the old dump so
    # a fresh screenshot or user action is never paired with stale bounds.
    xml = adb('shell', 'rm -f /sdcard/interop-ui.xml && '
              'uiautomator dump /sdcard/interop-ui.xml >/dev/null && '
              'cat /sdcard/interop-ui.xml', check=False)
    return list(ElementTree.fromstring(xml).iter('node'))


def bounds(node):
    return tuple(map(int, re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.attrib['bounds']).groups()))


def composer_button(action):
    captions = {
        'send': ('Поставить сообщение в очередь', 'Queue message'),
        'file': ('Прикрепить файл', 'Attach file'),
        'video': ('Записать видеосообщение', 'Record video message'),
    }
    nodes = [n for n in snapshot() if n.get('package') == PACKAGE]
    for n in nodes:
        if n.get('enabled') == 'true' and any(
            label in n.get(k, '') for label in captions[action]
            for k in ('content-desc', 'text', 'tooltip-text', 'tooltip', 'hint')
        ):
            return n
    # API 28's UIAutomator XML omits AccessibilityNodeInfo.tooltipText. The
    # composer exposes three standalone action buttons left of its sole input
    # and one submit button right of it. Refuse ambiguous layouts.
    fields = [n for n in nodes if n.get('class') == 'android.widget.EditText']
    if len(fields) != 1:
        raise RuntimeError('Expected exactly one chat input')
    x1, y1, x2, y2 = bounds(fields[0])
    left, right = {}, {}
    for n in nodes:
        if n.get('clickable') != 'true' or n.get('enabled') != 'true':
            continue
        a, b, c, d = bounds(n)
        if not y1 <= (b + d) // 2 <= y2:
            continue
        if c <= x1 + 1:
            left[(a, c)] = n
        if a >= x2 - 1:
            right[(a, c)] = n
    if action == 'send' and len(right) == 1:
        return next(iter(right.values()))
    if action != 'send' and len(left) == 3:
        return left[sorted(left)[{'video': 0, 'file': 1}[action]]]
    raise RuntimeError(f'Cannot uniquely locate {action} in composer with {len(left)} left and {len(right)} right actions')


def type_challenge(value):
    field = wait_node('chat input', lambda n: n.get('class') == 'android.widget.EditText')
    x1, y1, x2, y2 = bounds(field)
    # The suffix formatting button occupies the trailing part of a narrow field.
    adb('shell', 'input', 'tap', str(x1 + (x2 - x1) // 3), str((y1 + y2) // 2))
    wait_node('focused chat input', lambda n: n.get('class') == 'android.widget.EditText' and n.get('focused') == 'true')
    adb('shell', 'input', 'text', value.replace(' ', '%s'))
    wait_node('entered synthetic challenge', lambda n: n.get('class') == 'android.widget.EditText' and
              any(value in n.get(k, '') for k in ('text', 'content-desc')))
    if 'mInputShown=true' in adb('shell', 'dumpsys', 'input_method'):
        adb('shell', 'input', 'keyevent', '4')
    wait_node('retained draft after IME', lambda n: n.get('class') == 'android.widget.EditText' and
              any(value in n.get(k, '') for k in ('text', 'content-desc')))


def chat_diagnostics(report, challenge, response):
    # Called only after unlocking this disposable chat; redact every unknown
    # label instead of writing raw accessibility dumps or arbitrary screenshots.
    labels = {'Message', 'Сообщение', 'Formatting', 'Форматирование', 'Queue message',
              'Поставить сообщение в очередь', 'Send', 'Отправить', 'Private chat', 'Приватный чат'}
    redacted = []
    for n in snapshot():
        if n.get('package') != PACKAGE:
            continue
        entry = {k: n.get(k) for k in ('class', 'bounds', 'clickable', 'enabled', 'focused', 'password')}
        for k in ('text', 'content-desc', 'hint', 'tooltip-text'):
            v = n.get(k)
            if v:
                entry[k] = ('<challenge>' if challenge in v else '<reply>' if response in v
                            else v if v in labels else '<redacted>')
        redacted.append(entry)
    (report / 'android-chat-layout.json').write_text(json.dumps(redacted, indent=2))

def text_node(*labels, timeout=60):
    return wait_node(labels[0], lambda node: any(
        label in ' '.join(node.get(k, '') for k in ('text', 'content-desc', 'hint', 'tooltip-text', 'tooltip'))
        for label in labels), timeout)


def tap(node):
    x1, y1, x2, y2 = bounds(node)
    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))


def type_field(node, value):
    tap(node)
    adb('shell', 'input', 'text', value)
    if 'mInputShown=true' in adb('shell', 'dumpsys', 'input_method'):
        adb('shell', 'input', 'keyevent', '4')
