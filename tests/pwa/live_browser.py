#!/usr/bin/env python3
"""Live Chromium UI, Kestrel, PostgreSQL, and Mailpit on loopback.

Prerequisites: local Compose db/mailpit, built Debug API and key-package validator,
OpenSSL, PostgreSQL client tools, and Playwright Chromium. Run from any directory
with python tests/pwa/live_browser.py. The API hostname maps to loopback only
inside this test's Chromium process. Production network and DNS are untouched.
"""

import base64
import functools
import hashlib
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import expect, sync_playwright


ROOT = Path(__file__).resolve().parents[2]
API_HOST = "securemesh.90-156-230-119.sslip.io"
API_ORIGIN = f"https://{API_HOST}"
MAIL_ORIGIN = "http://127.0.0.1:58028"


def port_number():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def postgres_database():
    dotenv = dict(line.split("=", 1) for line in (ROOT / ".env").read_text().splitlines() if "=" in line)
    password = dotenv["SECUREMESH_DB_PASSWORD"]
    database = "pwa_test_" + uuid.uuid4().hex
    config = dict(os.environ, PGHOST="127.0.0.1", PGPORT="55438", PGUSER="securemesh", PGPASSWORD=password)
    subprocess.run(["createdb", database], env=config, check=True)
    try:
        yield f"Host=127.0.0.1;Port=55438;Database={database};Username=securemesh;Password={password}"
    finally:
        subprocess.run(["dropdb", "--force", database], env=config, check=True)


class StaticHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def end_headers(self):
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; "
                         "style-src 'self'; img-src 'self'; manifest-src 'self'; "
                         f"worker-src 'self'; connect-src 'self' {API_ORIGIN}; "
                         "base-uri 'none'; object-src 'none'; form-action 'none'; frame-ancestors 'none'")
        super().end_headers()


@contextmanager
def origins(directory, connection):
    cert = directory / "test-cert.pem"
    key = directory / "test-key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", f"/CN={API_HOST}", "-addext", f"subjectAltName=DNS:{API_HOST},IP:127.0.0.1",
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    public_pem = subprocess.check_output(["openssl", "x509", "-pubkey", "-noout", "-in", str(cert)])
    public_der = subprocess.check_output(["openssl", "pkey", "-pubin", "-outform", "DER"], input=public_pem)
    pin = base64.b64encode(hashlib.sha256(public_der).digest()).decode()
    with ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(StaticHandler, directory=ROOT / "site")) as static:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        static.socket = tls.wrap_socket(static.socket, server_side=True)
        worker = threading.Thread(target=static.serve_forever, daemon=True)
        worker.start()
        app_origin = f"https://127.0.0.1:{static.server_port}"
        api_port = port_number()
        api_address = f"https://127.0.0.1:{api_port}"
        environment = dict(
            os.environ, ASPNETCORE_ENVIRONMENT="Development", ConnectionStrings__Database=connection,
            Kestrel__Certificates__Default__Path=str(cert), Kestrel__Certificates__Default__KeyPath=str(key),
            BrowserClientOrigin=app_origin, VerificationEmail__Provider="Mailpit",
        )
        try:
            with (directory / "api.log").open("w") as log:
                process = subprocess.Popen(
                    ["dotnet", "src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll", "--urls", api_address],
                    cwd=ROOT, env=environment, stdout=log, stderr=log,
                )
                try:
                    api_tls = ssl.create_default_context(cafile=str(cert))
                    for _ in range(150):
                        if process.poll() is not None:
                            raise RuntimeError("The disposable API exited before readiness")
                        try:
                            with urllib.request.urlopen(api_address + "/health/ready", context=api_tls, timeout=1) as ready:
                                if ready.status == 200:
                                    break
                        except OSError:
                            time.sleep(0.1)
                    else:
                        raise RuntimeError("The disposable API did not become ready")
                    yield app_origin, api_port, pin
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
        finally:
            static.shutdown()
            worker.join()


def verification_token(email):
    query = urllib.parse.urlencode({"query": f"to:{email}"})
    for _ in range(100):
        with urllib.request.urlopen(f"{MAIL_ORIGIN}/api/v1/search?{query}", timeout=3) as response:
            messages = json.load(response)["messages"]
        if messages:
            with urllib.request.urlopen(f"{MAIL_ORIGIN}/api/v1/message/{messages[0]['ID']}", timeout=3) as response:
                token = json.load(response)["Text"].strip()
            assert re.fullmatch(r"[a-f0-9]{64}", token), "Unexpected verification token format"
            return token
        time.sleep(0.1)
    raise RuntimeError("Mailpit did not receive the disposable verification email")


def register(page, base, username):
    password = secrets.token_urlsafe(25)
    email = f"{username}@securemesh.test"
    page.goto(base + "/app/profile.html")
    page.locator("#entry [name=name]").fill(username)
    page.locator("#entry [name=username]").fill(username)
    page.locator("#password").fill(password)
    page.locator("#entry [name=remembered]").check()
    page.locator("#enter").click()
    page.locator("#register [name=email]").fill(email)
    page.locator("#register [name=secret]").fill(password)
    page.locator("#register button").click()
    page.locator("#verify [name=code]").fill(verification_token(email))
    page.locator("#verify button").click()
    page.locator("#login [name=secret]").fill(password)
    page.locator("#login button").click()
    expect(page.locator("#conversations")).to_be_visible(timeout=20_000)
    code = page.locator("#my-code")
    expect(code).to_have_text(re.compile(r"^(?:[A-F0-9]{4} ){15}[A-F0-9]{4}$"))
    return code.text_content(), password


def exercise(app_origin, api_port, pin):
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(args=[
            "--no-proxy-server",
            f"--host-resolver-rules=MAP {API_HOST} 127.0.0.1:{api_port}, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
            f"--ignore-certificate-errors-spki-list={pin}",
        ])
        pages = [browser.new_context().new_page() for _ in range(2)]
        traffic = []
        for page in pages:
            page.set_default_timeout(25_000)
            page.on("response", lambda response: traffic.append(response.request.post_data_json)
                    if response.url == API_ORIGIN + "/v1/messages" and response.request.method == "POST"
                    and response.ok else None)
        alice, bob = pages
        suffix = uuid.uuid4().hex[:12]
        alice_name, bob_name = f"pwa_a_{suffix}", f"pwa_b_{suffix}"
        alice_code, alice_password = register(alice, app_origin, alice_name)
        bob_code, _ = register(bob, app_origin, bob_name)
        assert alice_code != bob_code
        alice.locator("#invite [name=peer]").fill(bob_name)
        alice.locator("#invite button").click()
        accept = bob.locator("[data-action=accept]")
        expect(accept).to_be_visible(timeout=20_000)
        accept.locator("..").locator("input").fill(alice_code)
        accept.click()
        establish = alice.locator("[data-action=establish]")
        expect(establish).to_be_visible(timeout=20_000)
        establish.locator("..").locator("input").fill(bob_code)
        establish.click()
        bob.locator("[data-action=join]").click()
        for page, peer in [(alice, bob_name), (bob, alice_name)]:
            page.locator("#chat-list").get_by_role("button", name=re.compile(peer)).click()
        for sender, recipient, text in [(alice, bob, "Первое сообщение на iPhone 🔐"),
                                        (bob, alice, "Ответ с другого профиля 🔐")]:
            sender.locator("#compose textarea").fill(text)
            sender.locator("#compose button").click()
            expect(recipient.locator("#messages").get_by_text(text, exact=True)).to_be_visible(timeout=20_000)

        alice.context.set_offline(True)
        queued = "Очередь сохраняется после блокировки 🔐"
        alice.locator("#compose textarea").fill(queued)
        alice.locator("#compose button").click()
        row = alice.locator("#messages li").filter(has_text=queued)
        expect(row).to_contain_text("В очереди")
        alice.locator("#lock").click()
        expect(alice.locator("#messages li")).to_have_count(0)
        alice.locator("#password").fill(alice_password)
        alice.locator("#enter").click()
        alice.locator("#chat-list").get_by_role("button", name=re.compile(bob_name)).click()
        expect(row).to_contain_text("В очереди")
        expect(bob.locator("#messages").get_by_text(queued, exact=True)).to_have_count(0)
        alice.context.set_offline(False)
        expect(bob.locator("#messages").get_by_text(queued, exact=True)).to_be_visible(timeout=20_000)
        expect(row).to_contain_text("Принято сервером")

        assert len(traffic) == 3, "Expected three durably stored encrypted messages"
        assert len({row["conversationId"] for row in traffic}) == 1
        assert len({row["clientMessageId"] for row in traffic}) == 3
        for row in traffic:
            assert set(row) == {"conversationId", "clientMessageId", "mlsEpoch", "envelopeKind", "ciphertext"}
            wire = base64.b64decode(row["ciphertext"], validate=True)
            assert row["envelopeKind"] == 1 and len(wire) > 32
            assert not any(word.encode() in wire for word in ("сообщение", "профиля", "Очередь"))
        browser.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="securemesh-live-pwa-") as directory, postgres_database() as connection:
        with origins(Path(directory), connection) as (app_origin, api_port, pin):
            exercise(app_origin, api_port, pin)
    print("Two isolated Chromium profiles exchanged verified MLS text through live .NET, PostgreSQL, and Mailpit")
    print("An offline message survived vault lock and unlock and was durably saved on reconnect")
