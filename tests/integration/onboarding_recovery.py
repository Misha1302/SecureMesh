#!/usr/bin/env python3
"""Real Dart controller, SQLCipher/OpenMLS, HTTPS API/PG and owned SIGKILLs.

The TLS proxy pauses real responses after server commit; no success is mocked.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import json
import os
from pathlib import Path
import secrets
import select
import signal
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

import delivery as d


def sql(statement):
    return subprocess.check_output(
        ['docker', 'compose', 'exec', '-T', 'db', 'psql', '-U', 'securemesh',
         '-d', 'securemesh', '-v', 'ON_ERROR_STOP=1', '-Atc', statement],
        cwd=d.ROOT, text=True).strip()


class GateProxy:
    def __enter__(self):
        owner = self
        self.path = None
        self.hit = threading.Event()
        self.release = threading.Event()
        self.errors = []
        self.corrupt = None
        self.login_requests = 0

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.forward()

            def do_GET(self):
                self.forward()

            def forward(self):
                try:
                    if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                        chunks = bytearray()
                        while True:
                            line = self.rfile.readline(128)
                            assert line.endswith(b'\r\n')
                            size = int(line.split(b';', 1)[0], 16)
                            assert size >= 0 and len(chunks) + size <= 262144
                            if size == 0:
                                assert self.rfile.readline(128) == b'\r\n'
                                break
                            chunks.extend(self.rfile.read(size))
                            assert self.rfile.read(2) == b'\r\n'
                        body = bytes(chunks)
                    else:
                        assert not self.headers.get('Transfer-Encoding')
                        length = int(self.headers.get('Content-Length', '0'))
                        assert 0 <= length <= 262144
                        body = self.rfile.read(length) if length else None
                    headers = {'Content-Type': 'application/json'}
                    if self.headers.get('Authorization'):
                        headers['Authorization'] = self.headers['Authorization']
                    request = urllib.request.Request(d.BASE + self.path, data=body,
                                                     headers=headers, method=self.command)
                    if self.path == '/v1/auth/login':
                        owner.login_requests += 1
                    try:
                        response = urllib.request.urlopen(request, context=d.TLS, timeout=10)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        status, raw = response.status, response.read()
                    if status == 200 and self.path == '/v1/auth/challenge' and owner.corrupt:
                        value = json.loads(raw)
                        parts = base64.b64decode(value['payload']).decode().split('\n')
                        kind = owner.corrupt
                        owner.corrupt = None
                        if kind == 'purpose':
                            parts[0] = 'SecureMesh/enrollment-grant/v1'
                        elif kind == 'device':
                            parts[2] = str(uuid.uuid4())
                        elif kind == 'username':
                            parts[3] = 'another_user'
                        elif kind == 'challenge':
                            value['challengeId'] = str(uuid.uuid4())
                        else:
                            raise AssertionError('unknown negative challenge fixture')
                        value['payload'] = base64.b64encode('\n'.join(parts).encode()).decode()
                        raw = json.dumps(value).encode()
                    if status == 200 and self.path == owner.path:
                        owner.path = None
                        owner.hit.set()
                        if not owner.release.wait(40):
                            raise TimeoutError('test gate was not released')
                    self.send_response(status)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError):
                    pass  # The test deliberately SIGKILLs this client.
                except Exception as error:
                    owner.errors.append(type(error).__name__)

        self.server = ThreadingHTTPServer(('127.0.0.1', 15992), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(d.ROOT / '.local/tls.pem', d.ROOT / '.local/tls.key')
        self.server.socket = tls.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = 'https://127.0.0.1:15992'
        return self

    def arm(self, path):
        self.hit.clear()
        self.release.clear()
        self.path = path

    def __exit__(self, *_):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def registration():
    username = 'resume_' + uuid.uuid4().hex[:16]
    email = username + '@securemesh.test'
    password = secrets.token_urlsafe(24)
    d.request('/v1/auth/register', dict(username=username, email=email, password=password), expected=202)
    token = d.verification_token(email)
    d.request('/v1/auth/verify-email', dict(token=token), expected=204)
    return dict(username=username, password=password)


class Trial:
    def __init__(self, root, proxy, account, registered=False):
        self.root = root
        self.device = d.Device.__new__(d.Device)
        self.device.identity = str(uuid.uuid4())
        self.device.password = secrets.token_urlsafe(24)
        self.device.path = root / (self.device.identity + '.db')
        self.fixture = root / (self.device.identity + '.json')
        self.input = dict(path=str(self.device.path), passphrase=self.device.password,
                          device=self.device.identity, endpoint=proxy.endpoint,
                          username=account['username'], accountPassword=account['password'],
                          registeredHere=registered, create=True,
                          library=str(d.ROOT / 'src/crypto_core/target/debug/libsecuremesh_crypto.so'),
                          cert=str(d.ROOT / '.local/tls.pem'))
        self.process = None

    def start(self, **changes):
        assert self.process is None or self.process.poll() is not None
        data = self.input | changes
        self.fixture.write_text(json.dumps(data))
        self.fixture.chmod(0o600)
        self.process = subprocess.Popen(
            [str(d.ROOT / '.local/flutter/bin/dart'), 'run', 'tool/onboarding_trial.dart', str(self.fixture)],
            cwd=d.ROOT / 'apps/client_flutter', env={**os.environ, 'PUB_CACHE': str(d.ROOT / '.local/pub-cache')},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True)

    def kill(self):
        assert self.process.poll() is None, 'Expected an actual live native process'
        os.killpg(self.process.pid, signal.SIGKILL)
        output, errors = self.process.communicate(timeout=10)
        assert self.process.returncode == -signal.SIGKILL
        assert 'Unhandled exception' not in errors
        self.check_log_secrets(output + errors)

    def done(self, expected=0):
        output, errors = self.process.communicate(timeout=35)
        self.check_log_secrets(output + errors)
        assert self.process.returncode == expected, 'Dart trial failed: ' + errors[:300]
        return json.loads(output.strip().splitlines()[-1])

    def check_log_secrets(self, output):
        for value in (self.input['accountPassword'], self.device.password):
            assert value not in output, 'Credential leaked in native output'

    def state(self):
        return self.device.call('onboarding_state')

    def count_sessions(self):
        return int(sql(f"SELECT count(*) FROM sessions WHERE device_id='{self.device.identity}'"))

    def assert_encrypted(self):
        draft = self.state().get('draft', {})
        assert 'password' not in draft and 'passphrase' not in draft
        sentinels = [self.input['username'], self.input['accountPassword'], self.device.password]
        sentinels += list(draft.get('session', {}).get(k, '') for k in ('accessToken', 'refreshToken'))
        for path in self.root.glob(self.device.path.name + '*'):
            raw = path.read_bytes()
            for value in sentinels:
                if value:
                    assert value.encode() not in raw, 'Plaintext in encrypted store or sidecar'

    def close(self):
        if self.process and self.process.poll() is None:
            self.kill()


def gated_kill(trial, proxy, route):
    proxy.arm(route)
    trial.start()
    deadline = time.monotonic() + 30
    while not proxy.hit.wait(.1) and trial.process.poll() is None and time.monotonic() < deadline:
        pass
    if not proxy.hit.is_set():
        if trial.process.poll() is None:
            trial.kill()
            raise TimeoutError('Live Dart child did not reach the real API commit barrier')
        output, errors = trial.process.communicate(timeout=5)
        trial.check_log_secrets(output + errors)
        raise RuntimeError('Dart exited before API commit barrier: ' + output[-1000:] + errors[-2000:])
    trial.kill()
    proxy.release.set()


def main():
    os.umask(0o077)
    d.BASE = 'https://127.0.0.1:5096'
    trials = []
    results = []
    with d.Server(legacy_bootstrap=False), GateProxy() as proxy, tempfile.TemporaryDirectory(
            prefix='securemesh-onboarding-', dir=d.ROOT / '.local') as tmp:
        root = Path(tmp)
        try:
            first = registration()
            for kind in ('purpose', 'challenge', 'device', 'username'):
                negative = Trial(root, proxy, first, registered=True)
                trials.append(negative)
                proxy.corrupt = kind
                before = proxy.login_requests
                negative.start()
                assert negative.done(2)['code'] == 'DEVICE_CHALLENGE_MISMATCH'
                assert proxy.login_requests == before and negative.count_sessions() == 0
                assert not negative.state()['draft']['loginUncertain']
            results.append('server challenge purpose/ID/device/username substitutions denied before signing/login POST; zero server sessions')
            a = Trial(root, proxy, first, registered=True)
            trials.append(a)
            gated_kill(a, proxy, '/v1/auth/login')
            state = a.state()
            assert state['stage'] == 'prepared' and state['draft']['loginUncertain']
            original = a.device.call('identity')
            assert a.count_sessions() == 1
            assert sql(f"SELECT trusted FROM devices WHERE id='{a.device.identity}'") == 't'
            a.assert_encrypted()
            # A later wrong password cannot prove the earlier lost reply failed.
            a.start(create=False, accountPassword='definitely incorrect password')
            assert a.done(2)['stage'] == 'rejected'
            assert a.state()['draft']['loginUncertain'] and a.count_sessions() == 1
            a.start(create=False)
            assert a.done()['stage'] == 'complete'
            assert a.device.call('identity') == original
            assert a.count_sessions() == 2
            profile = a.device.call('profile')
            assert profile['enrollmentVerified'] and not profile['requiresEnrollment']
            assert sql(f"SELECT count(*) FROM devices WHERE user_id='{profile['userId']}'") == '1'
            assert a.state() == {'stage': 'complete'}
            results.append('lost accepted login reply + SIGKILL + wrong-password retry preserves same trusted key and one server device')

            existing = d.account(root)
            b = Trial(root, proxy, existing)
            trials.append(b)
            gated_kill(b, proxy, '/v1/users/me')
            state = b.state()
            assert state['stage'] == 'authenticated'
            original = b.device.call('identity')
            assert b.count_sessions() == 1
            b.assert_encrypted()
            # Foreign-device session and account responses cannot finish setup.
            b.device.call('onboarding_session', reject=True, session=existing['session'])
            b.device.call('onboarding_complete', reject=True, account=d.request('/v1/users/me', token=existing['session']['accessToken']))
            assert b.state() == state
            b.device.call('onboarding_complete', reject=True,
                          account=d.request('/v1/users/me', token=state['draft']['session']['accessToken']),
                          crash_before_commit=True)
            assert b.state() == state
            b.start(create=False, accountPassword=None)
            assert b.done()['stage'] == 'complete'
            assert b.device.call('identity') == original and b.count_sessions() == 1
            profile = b.device.call('profile')
            assert profile['requiresEnrollment'] and not profile['enrollmentVerified']
            d.request('/v1/conversations', token=profile['accessToken'], expected=403)
            results.append('durable session + SIGKILL resumes without password/new login; foreign binding and pre-COMMIT abort rejected; pending device remains private-data denied')

            c = Trial(root, proxy, existing)
            trials.append(c)
            gated_kill(c, proxy, '/v1/users/me')
            original = c.device.call('identity')
            sql(f"UPDATE sessions SET expires_at=now()-interval '1 second' WHERE device_id='{c.device.identity}'")
            c.start(create=False, accountPassword=None)
            assert c.done(2)['code'] == 'ONBOARDING_SESSION_EXPIRED'
            assert c.state()['stage'] == 'prepared' and c.state()['draft']['loginUncertain']
            c.start(create=False, waitAfterComplete=True)
            assert select.select([c.process.stdout], [], [], 35)[0], 'Profile COMMIT not reached'
            assert json.loads(c.process.stdout.readline()) == {'stage': 'complete'}
            c.kill()
            assert c.state() == {'stage': 'complete'}
            before = c.count_sessions()
            c.start(create=False, accountPassword=None)
            assert c.done()['stage'] == 'complete' and c.count_sessions() == before
            assert c.device.call('identity') == original
            results.append('expired saved session requests password with same key; SIGKILL after profile COMMIT reopens without another login')

            wrong = d.Device.__new__(d.Device)
            wrong.path, wrong.password = c.device.path, secrets.token_urlsafe(24)
            wrong.call('onboarding_state', reject=True)
            assert c.device.call('identity') == original
            # A rejected draft initializer rolls the keys back too.
            blank = d.Device.__new__(d.Device)
            blank.path, blank.password = root / 'invalid.db', secrets.token_urlsafe(24)
            blank.call('init', reject=True, identity=str(uuid.uuid4()),
                       onboarding=dict(endpoint='http://127.0.0.1', username='valid_name', registeredHere=True))
            blank.call('init', identity=str(uuid.uuid4()))
            assert blank.call('onboarding_state') == {'stage': 'missing'}
            results.append('wrong local passphrase denied; invalid initializer rolls back identity+journal; legacy initialized store remains compatible')
            assert not proxy.errors, proxy.errors
            report = dict(source_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=d.ROOT, text=True).strip(),
                          source_tree_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=d.ROOT, text=True).strip()),
                          cases=results, production_approved=False,
                          source_sha256={str(p.relative_to(d.ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [
                              d.ROOT / 'apps/client_flutter/lib/account_setup.dart',
                              d.ROOT / 'src/crypto_core/src/onboarding.rs',
                              d.ROOT / 'apps/client_flutter/tool/onboarding_trial.dart']})
            (d.ROOT / 'reports/evidence/v2-onboarding-recovery.json').write_text(json.dumps(report, indent=2) + '\n')
            for result in results:
                print('PASS:', result, flush=True)
        finally:
            proxy.release.set()
            for trial in trials:
                trial.close()


if __name__ == '__main__':
    main()
