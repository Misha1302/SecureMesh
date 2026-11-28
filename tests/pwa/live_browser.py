#!/usr/bin/env python3
"""Live browser messaging through isolated loopback Kestrel, PostgreSQL and Mailpit.

Requires the local database/mail fixture, Debug API, native key-package validator,
OpenSSL, PostgreSQL client tools and the selected Playwright browser engine.
"""

import argparse
import base64
import functools
import hashlib
import json
import os
import re
import secrets
import select
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
from http.server import BaseHTTPRequestHandler, SimpleHTTPRequestHandler, ThreadingHTTPServer
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


class Outage:
    """Disconnect only sockets of this disposable test, including reused HTTP connections."""
    def __init__(self):
        self.guard = threading.Lock()
        self.blocked = False
        self.upstreams = set()

    def set(self, blocked):
        with self.guard:
            self.blocked = blocked
            if blocked:
                for upstream in self.upstreams:
                    try:
                        upstream.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

    @contextmanager
    def track(self, upstream):
        with self.guard:
            online = not self.blocked
            if online:
                self.upstreams.add(upstream)
        try:
            yield online
        finally:
            with self.guard:
                self.upstreams.discard(upstream)


class StaticHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        outage = getattr(self.server, "outage", None)
        if outage and outage.blocked:
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if self.path == "/fixture-connectivity":
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, *_):
        pass

    def end_headers(self):
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; "
                         "style-src 'self'; img-src 'self' blob:; manifest-src 'self'; "
                         f"worker-src 'self'; connect-src 'self' {API_ORIGIN}; "
                         "base-uri 'none'; object-src 'none'; form-action 'none'; frame-ancestors 'none'")
        super().end_headers()


@contextmanager
def origins(directory, connection, outage=None):
    cert = directory / "test-cert.pem"
    key = directory / "test-key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", f"/CN={API_HOST}", "-addext", f"subjectAltName=DNS:{API_HOST},IP:127.0.0.1",
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    public_pem = subprocess.check_output(["openssl", "x509", "-pubkey", "-noout", "-in", str(cert)])
    public_der = subprocess.check_output(["openssl", "pkey", "-pubin", "-outform", "DER"], input=public_pem)
    pin = base64.b64encode(hashlib.sha256(public_der).digest()).decode()
    with ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(StaticHandler, directory=ROOT / "site")) as static:
        static.outage = outage
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
                    for origin, allowed in ((app_origin, True), ("https://unrelated.invalid", False)):
                        preflight = urllib.request.Request(
                            api_address + "/v1/users/me", method="OPTIONS",
                            headers={"Origin": origin, "Access-Control-Request-Method": "GET",
                                     "Access-Control-Request-Headers": "authorization"})
                        with urllib.request.urlopen(preflight, context=api_tls, timeout=3) as response:
                            assert response.headers.get("Access-Control-Allow-Origin") == (origin if allowed else None)
                            assert response.headers.get("Access-Control-Allow-Credentials") is None
                    yield app_origin, api_port, pin
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
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
    create_profile(page, username, password)
    page.locator("#register [name=email]").fill(email)
    page.locator("#register button").click()
    page.locator("#verify [name=code]").fill(verification_token(email))
    page.locator("#verify button").click()
    page.locator("#login button").click()
    expect(page.locator("#conversations")).to_be_visible(timeout=20_000)
    return device_code(page), password


def create_profile(page, username, password):
    page.locator("#entry [name=name]").fill(username)
    page.locator("#entry [name=username]").fill(username)
    page.locator("#password").fill(password)
    page.locator("#entry [name=remembered]").check()
    page.locator("#enter").click()


def device_code(page):
    code = page.locator("#my-code")
    expect(code).to_have_text(re.compile(r"^(?:[A-F0-9]{4} ){15}[A-F0-9]{4}$"))
    return code.text_content()


def exercise_archive(browser, exporter, app_origin, exporter_code, peer, messages, private_draft, options):
    secret = secrets.token_urlsafe(25)
    exporter.locator("#backup summary").click()
    exporter.locator("#export [name=secret]").fill(secret)
    with exporter.expect_download() as downloaded:
        exporter.locator("#export button").click()
    download = downloaded.value
    assert download.suggested_filename == "SecureMesh-history.smbackup"
    archive = download.path().read_bytes()
    assert all(text.encode() not in archive for text in messages)
    assert exporter_code.encode() not in archive

    with browser.new_context(**options) as context:
        viewer = context.new_page()
        viewer.goto(app_origin + "/app/profile.html")
        viewer.locator("#archives > summary").click()
        archive_view = viewer.locator("#archive-view")

        def open_file(content, password):
            file_input = viewer.locator("#restore input[type=file]")
            with viewer.expect_file_chooser() as chooser:
                file_input.click()
            chooser.value.set_files({
                "name": download.suggested_filename,
                "mimeType": "application/octet-stream",
                "buffer": content,
            })
            viewer.locator("#restore [name=secret]").fill(password)
            viewer.locator("#restore button").click()

        notice = viewer.locator("#notice")
        authentication_error = "Проверьте пароль. Открыть зашифрованные данные не удалось."
        open_file(archive, secrets.token_urlsafe(25))
        expect(notice).to_have_text(authentication_error)
        expect(archive_view).to_be_empty()
        record = json.loads(archive)
        old_ciphertext = record["ciphertext"]
        record["ciphertext"] = ("A" if old_ciphertext[0] != "A" else "B") + old_ciphertext[1:]
        open_file(json.dumps(record).encode(), secret)
        expect(notice).to_have_text(authentication_error)
        expect(archive_view).to_be_empty()

        # An authenticated file with identity data must also fail the text-only schema.
        malicious = viewer.evaluate("""async (password) => {
          const {exportBackup} = await import('/app/vault.js');
          return exportBackup(password, {
            type: 'securemesh-text-archive-v1', chats: [], identity: {secretKey: 'unexpected field'},
          });
        }""", secret)
        open_file(malicious.encode(), secret)
        expect(notice).to_have_text("Формат файла или ответа не поддерживается.")
        expect(archive_view).to_be_empty()

        open_file(archive, secret)
        expect(archive_view).to_contain_text("Архив для чтения")
        archive_view.get_by_text("@" + peer, exact=True).click()
        for message in messages:
            expect(archive_view.get_by_text(message)).to_be_visible()
        expect(archive_view.get_by_text(private_draft)).to_have_count(0)
        expect(viewer.locator("#conversations")).to_be_hidden()
        expect(viewer.locator("#my-code")).to_be_empty()
        assert viewer.evaluate("""async () => !(await (await import('/app/vault.js')).hasVault())""")

        create_profile(viewer, "archive_" + uuid.uuid4().hex[:12], secrets.token_urlsafe(25))
        assert device_code(viewer) != exporter_code
        expect(viewer.locator("#register")).to_be_visible()
        viewer.locator("#lock").click()
        expect(archive_view).to_be_empty()
        expect(viewer.locator("#my-code")).to_be_empty()


@contextmanager
def launch_browser(playwright, engine, app_origin, api_port, pin, outage):
    if engine == "chromium":
        browser = playwright.chromium.launch(args=[
            "--no-proxy-server",
            f"--host-resolver-rules=MAP {API_HOST} 127.0.0.1:{api_port}, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
            f"--ignore-certificate-errors-spki-list={pin}",
        ])
        try:
            yield browser, {}
        finally:
            browser.close()
        return

    # Only these two TLS sockets exist on the test network. Applications keep
    # the production origin and CORS path even on engines without host rules.
    sockets = {f"{API_HOST}:443": api_port,
               urllib.parse.urlparse(app_origin).netloc: urllib.parse.urlparse(app_origin).port}

    class LoopbackTunnel(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_CONNECT(self):
            if self.path not in sockets:
                self.send_error(403)
                return
            if outage.blocked:
                self.send_error(503)
                return
            with socket.create_connection(("127.0.0.1", sockets[self.path])) as upstream, outage.track(upstream) as online:
                if not online:
                    self.send_error(503)
                    return
                self.send_response(200)
                self.end_headers()
                try:
                    while True:
                        ready, _, _ = select.select([upstream, self.connection], [], [], 60)
                        if not ready:
                            return
                        for source in ready:
                            data = source.recv(65536)
                            if not data:
                                return
                            destination = self.connection if source is upstream else upstream
                            destination.sendall(data)
                except OSError:
                    return

    with ThreadingHTTPServer(("127.0.0.1", 0), LoopbackTunnel) as tunnel:
        thread = threading.Thread(target=tunnel.serve_forever, daemon=True)
        thread.start()
        try:
            browser = playwright[engine].launch(proxy={"server": f"http://127.0.0.1:{tunnel.server_port}"})
            try:
                yield browser, {"ignore_https_errors": True}
            finally:
                browser.close()
        finally:
            tunnel.shutdown()
            thread.join()


def exercise(app_origin, api_port, pin, engine="chromium", outage=None):
    with sync_playwright() as playwright, launch_browser(playwright, engine, app_origin, api_port, pin, outage) as (browser, options):
        pages = [browser.new_context(**options).new_page() for _ in range(2)]
        traffic = []
        for page in pages:
            page.set_default_timeout(25_000)
            page.on("response", lambda response: traffic.append(response.request.post_data_json)
                    if response.url == API_ORIGIN + "/v1/messages" and response.request.method == "POST"
                    and response.ok else None)
        alice, bob = pages
        suffix = uuid.uuid4().hex[:12]
        alice_name, bob_name = f"mila_{suffix[:6]}", f"alex_{suffix[:6]}"
        alice_code, alice_password = register(alice, app_origin, alice_name)
        bob_code, _ = register(bob, app_origin, bob_name)
        assert alice_code != bob_code
        profile_panel = alice.locator("#profile-text")
        profile_panel.locator("summary").click()
        bio = profile_panel.get_by_label("О себе", exact=True)
        status = profile_panel.get_by_label("Статус", exact=True)
        share = profile_panel.get_by_label("Показывать собеседникам")
        bio.fill("Тестовое описание")
        status.fill("В отпуске")
        share.uncheck()
        profile_panel.get_by_role("button", name="Сохранить", exact=True).click()
        expect(profile_panel.get_by_role("status")).to_have_text("Сохранено")
        profile_panel.locator("summary").click()
        with alice.expect_response(lambda r: r.url.endswith("/v1/users/me/profile-text") and r.ok):
            profile_panel.locator("summary").click()
        expect(bio).to_have_value("Тестовое описание")
        expect(status).to_have_value("В отпуске")
        expect(share).not_to_be_checked()
        # A second unlocked tab commits a newer revision while the first holds a draft.
        bio.fill("Локальный черновик")
        second_tab = alice.context.new_page()
        try:
            second_tab.goto(app_origin + "/app/profile.html")
            second_tab.locator("#password").fill(alice_password)
            second_tab.locator("#enter").click()
            second_editor = second_tab.locator("#profile-text")
            second_editor.locator("summary").click()
            second_editor.get_by_label("О себе", exact=True).fill("Новая версия")
            second_editor.get_by_role("button", name="Сохранить", exact=True).click()
            expect(second_editor.get_by_role("status")).to_have_text("Сохранено")
        finally:
            second_tab.close()
        profile_panel.get_by_role("button", name="Сохранить", exact=True).click()
        expect(profile_panel.get_by_role("status")).to_contain_text("изменён на другом устройстве")
        expect(bio).to_have_value("Локальный черновик")
        profile_panel.get_by_role("button", name="Загрузить с сервера").click()
        expect(bio).to_have_value("Новая версия")
        profile_panel.locator("summary").click()
        panel = alice.locator("#security-email")
        panel.locator("summary").click()
        preference = alice.locator("#security-email-enabled")
        expect(preference).to_be_enabled()
        expect(preference).not_to_be_checked()
        preference.check()
        expect(alice.locator("#security-email-status")).to_have_text("Сохранено")
        panel.locator("summary").click()
        with alice.expect_response(lambda r: r.url == API_ORIGIN + "/v1/users/me/security-email" and r.request.method == "GET"):
            panel.locator("summary").click()
        expect(alice.locator("#security-email-status")).to_have_text("")
        expect(preference).to_be_enabled()
        expect(preference).to_be_checked()
        alice.context.set_offline(True)
        preference.uncheck()
        expect(alice.locator("#security-email-retry")).to_be_visible()
        expect(preference).to_be_disabled()
        alice.context.set_offline(False)
        alice.locator("#security-email-retry").click()
        expect(preference).to_be_enabled()
        expect(preference).to_be_checked()
        preference.uncheck()
        expect(alice.locator("#security-email-status")).to_have_text("Сохранено")
        panel.locator("summary").click()
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
        first, reply = "Привет! Ты получил приглашение?", "Да, вижу наш чат."
        for sender, recipient, text in [(alice, bob, first), (bob, alice, reply)]:
            sender.locator("#compose textarea").fill(text)
            sender.locator("#compose button").click()
            expect(recipient.locator("#messages").get_by_text(text, exact=True)).to_be_visible(timeout=20_000)

        evidence = os.environ.get("SECUREMESH_CHAT_SCREENSHOTS")
        if evidence:
            target = Path(evidence)
            target.mkdir(parents=True, exist_ok=True)
            alice.screenshot(path=target / "desktop.png", animations="disabled")
        previous_viewport = alice.viewport_size
        alice.set_viewport_size({"width": 390, "height": 844})
        expect(alice.locator("#chat-sidebar")).to_be_hidden()
        expect(alice.locator("#to-chats")).to_be_visible()
        expect(alice.locator("#messages time")).to_have_count(2)
        expect(alice.locator("#compose button")).to_be_in_viewport(ratio=1)
        if evidence:
            alice.screenshot(path=target / "phone.png", animations="disabled")
        alice.locator("#compose textarea").fill("Черновик при возврате")
        alice.locator("#to-chats").click()
        expect(alice.locator("#thread")).to_be_hidden()
        alice.locator("#chat-list").get_by_role("button", name=re.compile(bob_name)).click()
        expect(alice.locator("#compose textarea")).to_have_value("Черновик при возврате")
        alice.set_viewport_size(previous_viewport)

        # Enter the offline scenario only after the client has installed its offline shell.
        deadline = time.monotonic() + 15
        while not alice.evaluate("Boolean(navigator.serviceWorker.controller)"):
            if time.monotonic() >= deadline:
                raise AssertionError("Offline shell did not take control")
            time.sleep(.1)
        if engine == "chromium":
            alice.context.set_offline(True)
        else:
            # On WebKit Playwright's synthetic offline mode may reject even a
            # service-worker cache hit. Disconnect the actual fixture sockets.
            probe = """async () => {
              try { return (await fetch('/fixture-connectivity', {cache: 'no-store'})).status; }
              catch { return 0; }
            }"""
            assert alice.evaluate(probe) == 204
            outage.set(True)
            offline_status = alice.evaluate(probe)
            assert offline_status == 0 or 500 <= offline_status <= 599, offline_status
        queued = "Очередь сохраняется после блокировки 🔐"
        alice.locator("#compose textarea").fill(queued)
        next_draft = "Текст следующего сообщения"
        alice.locator("#compose").evaluate("""(form, draft) => {
            form.requestSubmit();
            form.elements.text.value = draft;
            form.elements.text.dispatchEvent(new Event('input', {bubbles: true}));
        }""", next_draft)
        row = alice.locator("#messages li").filter(has_text=queued)
        expect(row).to_contain_text("В очереди")
        expect(alice.locator("#compose textarea")).to_have_value(next_draft)
        alice.locator("#lock").click()
        expect(alice.locator("#messages li")).to_have_count(0)
        expect(profile_panel).to_be_hidden()
        expect(bio).to_have_value("")
        expect(status).to_have_value("")
        alice.locator("#password").fill(alice_password)
        alice.locator("#enter").click()
        alice.locator("#chat-list").get_by_role("button", name=re.compile(bob_name)).click()
        expect(alice.locator("#compose textarea")).to_have_value(next_draft)
        expect(row).to_contain_text("В очереди")
        expect(bob.locator("#messages").get_by_text(queued, exact=True)).to_have_count(0)
        if engine == "chromium":
            alice.context.set_offline(False)
        else:
            outage.set(False)
        expect(bob.locator("#messages").get_by_text(queued, exact=True)).to_be_visible(timeout=20_000)
        expect(row).to_contain_text("Принято сервером")

        assert len(traffic) == 3, "Expected three durably stored encrypted messages"
        assert len({row["conversationId"] for row in traffic}) == 1
        assert len({row["clientMessageId"] for row in traffic}) == 3
        for row in traffic:
            assert set(row) == {"conversationId", "clientMessageId", "mlsEpoch", "envelopeKind", "ciphertext"}
            wire = base64.b64decode(row["ciphertext"], validate=True)
            assert row["envelopeKind"] == 1 and len(wire) > 32
            assert not any(word.encode() in wire for word in (first, reply, queued))
        expect(bob.locator("#compose textarea")).to_have_value("")
        exercise_archive(browser, alice, app_origin, alice_code, bob_name, [first, reply, queued], next_draft, options)
        alice.reload()
        alice.locator("#password").fill(alice_password)
        alice.locator("#enter").click()
        alice.locator("#chat-list").get_by_role("button", name=re.compile(bob_name)).click()
        expect(alice.locator("#compose textarea")).to_have_value(next_draft)
        # Delete the draft and lock in the same JS turn, before autosave fires.
        alice.locator("#compose textarea").evaluate("""field => {
            field.value = '';
            field.dispatchEvent(new Event('input', {bubbles: true}));
            document.querySelector('#lock').click();
        }""")
        alice.locator("#password").fill(alice_password)
        alice.locator("#enter").click()
        alice.locator("#chat-list").get_by_role("button", name=re.compile(bob_name)).click()
        expect(alice.locator("#compose textarea")).to_have_value("")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", choices=("chromium", "firefox", "webkit"), default="chromium")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="securemesh-live-pwa-") as directory, postgres_database() as connection:
        outage = Outage()
        with origins(Path(directory), connection, outage) as (app_origin, api_port, pin):
            exercise(app_origin, api_port, pin, args.browser, outage)
    print(f"Two isolated {args.browser} profiles exchanged verified MLS text through live .NET, PostgreSQL, and Mailpit")
    print("An offline message survived vault lock and unlock and was durably saved on reconnect")
    print("A fresh browser opened an encrypted history archive and rejected wrong passwords, tampering, and identity data")
