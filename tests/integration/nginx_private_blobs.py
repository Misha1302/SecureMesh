#!/usr/bin/env python3
"""Verify scoped ingress sizes through real loopback nginx, TLS and the HTTPS API fixture."""
import hashlib
import http.client
import os
import socket
import ssl
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import delivery as d
from directory import establish
from private_blobs import database

WHOLE_BLOB_MAX = 4 * 1024 * 1024 + 16
PHOTO_MAX = 1024 * 1024 + 16
DEFAULT_MAX = 128 * 1024
BROWSER_ORIGIN = "https://pwa.securemesh.test"


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def ingress(root, api_port):
    endpoint = port()
    cert, key = root / "cert.pem", root / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-noenc", "-days", "1",
                    "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                    "-out", str(cert), "-keyout", str(key)], check=True, capture_output=True)
    template = (d.ROOT / "deploy/reverse-proxy.conf.template").read_text()
    template = template.replace("listen 443 ssl;", f"listen 127.0.0.1:{endpoint} ssl;")
    template = template.replace("http://api:8080", f"http://127.0.0.1:{api_port}")
    template = template.replace("${SECUREMESH_DOMAIN}", "localhost")
    template = template.replace("${SECUREMESH_TLS_CERT_PATH}", "/fixture/cert.pem")
    template = template.replace("${SECUREMESH_TLS_KEY_PATH}", "/fixture/key.pem")
    (root / "nginx.conf").write_text("events {}\nhttp {\n" + template + "\n}\n")
    container = "securemesh-ingress-test-" + uuid.uuid4().hex
    command = ["docker", "run", "--rm", "--detach", "--pull=never", "--network=host",
               "--name", container, "--entrypoint=nginx",
               "-v", f"{root}:/fixture:ro,Z", os.environ.get("SECUREMESH_TEST_NGINX_IMAGE", "nginx:1.27-alpine"),
               "-c", "/fixture/nginx.conf", "-g", "daemon off;"]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    tls = ssl.create_default_context(cafile=str(cert))
    try:
        for _ in range(100):
            try:
                status, _, _ = exchange(endpoint, tls, "GET", "/health/ready")
                assert status == 200, status
                break
            except OSError:
                time.sleep(.1)
        else:
            logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
            raise RuntimeError("nginx did not become ready: " + logs.stderr)
        yield endpoint, tls
    finally:
        subprocess.run(["docker", "stop", "-t", "2", container], check=True, capture_output=True)


def exchange(port_number, tls, method, path, body=None, headers=None):
    connection = http.client.HTTPSConnection("127.0.0.1", port_number, timeout=10, context=tls)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.headers, response.read()
    finally:
        connection.close()


def verify(endpoint, tls, group, account):
    token = account["session"]["accessToken"]
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/octet-stream"}
    blob = f"/v1/conversations/{group}/blobs/{uuid.uuid4()}"

    def send(method, path, expected, body=None, length=None, extra=None, proxy_limit=False):
        request_headers = {**headers, **(extra or {})}
        if length is not None:
            # A rejected Content-Length is checked before reading the body.
            request_headers.update({"Content-Length": str(length), "Expect": "100-continue"})
        status, response, payload = exchange(endpoint, tls, method, path, body, request_headers)
        assert status == expected, (method, path, status, payload[:120])
        if proxy_limit:
            assert response["Content-Type"].startswith("text/html"), payload[:120]
        return payload

    for size in (WHOLE_BLOB_MAX, PHOTO_MAX):
        route = f"/v1/conversations/{group}/blobs/{uuid.uuid4()}"
        sealed = os.urandom(size)
        send("PUT", route + "?fixture=1", 201, body=sealed)
        assert send("GET", route, 200) == sealed
    send("PUT", blob, 413, length=WHOLE_BLOB_MAX + 1, proxy_limit=True)
    send("GET", blob, 413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("POST", "/v1/auth/session/activity", 413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("PUT", blob + "/parts?offset=0", 413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("PUT", f"/v1/conversations/{group.upper()}/blobs/{str(uuid.uuid4()).upper()}",
         413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("PUT", blob + "/", 413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("PUT", blob.replace("/blobs/", "//blobs/"), 413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("PUT", blob.replace("/blobs/", "/%62lobs/"), 413, length=DEFAULT_MAX + 1, proxy_limit=True)
    send("PUT", "/_securemesh/whole-blob" + blob, 404, body=b"a" * 17)

    status, response, _ = exchange(endpoint, tls, "OPTIONS", blob, headers={
        "Origin": BROWSER_ORIGIN,
        "Access-Control-Request-Method": "PUT",
        "Access-Control-Request-Headers": "authorization,content-type",
    })
    assert status == 204 and response["Access-Control-Allow-Origin"] == BROWSER_ORIGIN
    assert response["Access-Control-Allow-Methods"] == "GET,POST,PUT"

    part = os.urandom(32 * 1024)
    send("PUT", blob + "/parts?offset=0", 200, body=part, extra={
        "X-Blob-Length": str(len(part)),
        "X-Blob-SHA256": hashlib.sha256(part).hexdigest(),
    })
    assert send("GET", blob, 200) == part
    send("POST", "/v1/auth/session/activity", 200, body=b"x" * DEFAULT_MAX)
    with patch.object(d, "BASE", f"https://127.0.0.1:{endpoint}"), patch.object(d, "TLS", tls):
        stream = d.Stream(token, account["device"])
        try:
            assert stream.exchange(d.wire.Frame(protocol_version=1, kind=d.wire.PING)).kind == d.wire.PONG
        finally:
            stream.close()


def main():
    api_port = port()
    d.BASE = f"http://127.0.0.1:{api_port}"
    env = {"SECUREMESH_TEST_URLS": d.BASE, "BrowserClientOrigin": BROWSER_ORIGIN}
    with patch.dict(os.environ, env), database() as db:
        with d.Server(db, legacy_bootstrap=False), tempfile.TemporaryDirectory() as work:
            root = Path(work)
            owner, peer = (d.account(root) for _ in range(2))
            owner["device"].pin(peer["device"])
            peer["device"].pin(owner["device"])
            group = establish(owner, peer)
            with tempfile.TemporaryDirectory() as frontend:
                with ingress(Path(frontend), api_port) as (endpoint, tls):
                    verify(endpoint, tls, group, owner)
    print("PASS nginx private upload bounds, scoped limits, parts, PWA preflight, ordinary HTTP and WSS HELLO/PING")


if __name__ == "__main__":
    main()
