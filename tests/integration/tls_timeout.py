"""A TLS peer completes its handshake after the real client's connection timeout."""
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def run_case(mode, cert, context):
    dart = os.environ.get('DART_BIN', str(ROOT / '.local/flutter/bin/dart'))
    trial = ROOT / 'apps/client_flutter/tool/tls_timeout_trial.dart'
    with socket.create_server(('127.0.0.1', 0)) as server:
        endpoint = f'https://127.0.0.1:{server.getsockname()[1]}'
        server.settimeout(10)
        errors = []

        def serve():
            try:
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(8)
                    if mode == 'late':
                        time.sleep(0.7)
                    try:
                        with context.wrap_socket(conn, server_side=True) as tls:
                            if mode == 'untrusted':
                                raise AssertionError('untrusted handshake succeeded')
                            if mode == 'healthy':
                                assert tls.recv(4096).startswith(b'GET / HTTP/1.1')
                                tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
                            else:
                                # Keep the peer alive. The client owns closing the
                                # abandoned connection and may send FIN or RST.
                                assert tls.recv(1) == b''
                    except ssl.SSLError:
                        if mode != 'untrusted':
                            raise
                    except (BrokenPipeError, ConnectionResetError):
                        if mode == 'healthy':
                            raise
            except BaseException as exc:
                errors.append(exc)

        thread = threading.Thread(target=serve)
        thread.start()
        try:
            subprocess.run([dart, str(trial), endpoint, str(cert), mode],
                           cwd=ROOT, check=True, timeout=5)
        finally:
            thread.join()
        if errors:
            raise errors[0]


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as tmp:
        key, cert = Path(tmp) / 'tls.key', Path(tmp) / 'tls.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1'],
                       check=True, capture_output=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        for case in ('healthy', 'untrusted', 'late'):
            run_case(case, cert, tls)
        print('PASS: trusted HTTPS, untrusted certificate rejection, and bounded client exit after a late TLS handshake')
