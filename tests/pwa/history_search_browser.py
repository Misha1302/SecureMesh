#!/usr/bin/env python3
"""Search real decrypted history in Chromium after a native MLS sender supplies older pages."""
import re
import secrets
import ssl
import sys
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch
from urllib.parse import unquote

from playwright.sync_api import expect, sync_playwright

import live_browser as live
from native_photo_browser import fingerprint

sys.path.insert(0, str(live.ROOT / "tests/integration"))
import delivery as d
from process_spike import Device, PersistentDevice


def exercise(root, origin, port, pin):
    device = Device(root)
    name = "history_" + uuid.uuid4().hex[:10]
    recipient = "reader_" + uuid.uuid4().hex[:10]
    email, password = name + "@securemesh.test", secrets.token_urlsafe(24)
    endpoint = f"https://127.0.0.1:{port}"
    tls = ssl.create_default_context(cafile=str(root / "test-cert.pem"))
    with sync_playwright() as pw, live.launch_browser(pw, "chromium", origin, port, pin, None) as (browser, options):
        page = browser.new_context(**options).new_page()
        direct = pw.request.new_context(base_url=endpoint, ignore_https_errors=True)
        session = {}

        def post(path, data, status=200):
            headers = {"Authorization": "Bearer " + session["accessToken"]} if session else {}
            response = direct.post(path, data=data, headers=headers)
            assert response.status == status, (path, response.status)
            return response.json() if response.body() else None

        post("/v1/auth/register", dict(username=name, email=email, password=password), 202)
        post("/v1/auth/verify-email", dict(token=live.verification_token(email)), 204)
        challenge = post("/v1/auth/challenge", dict(username=name, deviceId=device.identity))
        proof = device.call("sign", payload=challenge["payload"])
        session = post("/v1/auth/login", dict(username=name, password=password, deviceId=device.identity,
                       publicKey=device.public, challengeId=challenge["challengeId"], signature=proof["signature"]))
        viewer_code, viewer_password = live.register(page, origin, recipient)
        invite, lease = str(uuid.uuid4()), str(uuid.uuid4())
        post("/v1/chat-requests", dict(id=invite, username=recipient), 201)
        accept = page.locator("[data-action=accept]")
        accept.locator("..").locator("input").fill(" ".join(re.findall("....", fingerprint(device.public))))
        with page.expect_response(lambda r: r.url.endswith(f"/{invite}/accept") and r.ok):
            accept.click()
        package = post("/v1/crypto/keypackages/lease", dict(invitationId=invite, requestId=lease))
        assert fingerprint(package["publicKey"]) == viewer_code.replace(" ", "").upper()
        device.call("pin", identity=package["recipient"], public_key=package["publicKey"], confirmed=True)
        setup = device.call("directory_prepare", invitation=invite, lease=lease, recipient=package["recipient"],
                            reference=package["reference"], keypackage=package["keypackage"])
        post("/v1/conversations/establish", setup, 201)
        with page.expect_response(lambda r: r.url.endswith("/ack") and r.ok):
            page.locator("[data-action=join]").click(timeout=25_000)
        row = page.locator("#chat-list").get_by_role("button", name=re.compile(name))
        row.click()

        native = PersistentDevice.wrap(device)
        try:
            with patch.object(d, "BASE", endpoint), patch.object(d, "TLS", tls):
                stream = d.Stream(session["accessToken"], native)
                try:
                    group = setup["id"]

                    def send(text):
                        message = native.call("queue", group=group, text=text, id=str(uuid.uuid4()))
                        ack = stream.send(message, group)
                        assert ack.kind == d.wire.DURABLE_ACK

                    older, newer, latest = "Игла в старом сообщении", "Игла в новом сообщении", "Последняя ИГЛА"
                    send(older)
                    for index in range(100):
                        send(f"Сообщение {index:03}")
                    send(newer)
                    messages = page.locator("#messages")
                    expect(messages.get_by_text(newer, exact=True)).to_be_visible(timeout=70_000)
                    expect(messages.get_by_text(older, exact=True)).to_have_count(0)

                    collected = []
                    page.on("request", lambda request: collected.append((request.url, request.post_data or "")))
                    page.context.set_offline(True)
                    page.set_viewport_size({"width": 390, "height": 844})
                    page.locator("#compose textarea").fill("Черновик при поиске")
                    toggle = page.locator("#chat-search-toggle")
                    toggle.click()
                    query = page.locator("#chat-search-query")
                    expect(query).to_be_focused()
                    assert page.locator("#timeline").bounding_box()["height"] >= 320
                    expect(page.locator("#compose button")).to_be_in_viewport(ratio=1)
                    query.fill("ИГЛА")
                    match = messages.locator("[aria-current=true]")
                    expect(match).to_contain_text(newer)
                    page.locator("#chat-search-older").click()
                    expect(match).to_contain_text(older)
                    expect(match).to_be_in_viewport()
                    assert messages.locator("li").count() <= 100
                    expect(page.locator("#compose textarea")).to_have_value("Черновик при поиске")

                    page.context.set_offline(False)
                    send(latest)
                    # A new delivery updates navigation without taking focus away from the old match.
                    expect(match).to_contain_text(older)
                    next_button = page.locator("#chat-search-newer")
                    next_button.click()
                    expect(match).to_contain_text(newer)
                    expect(next_button).to_be_enabled(timeout=25_000)
                    next_button.click()
                    expect(match).to_contain_text(latest)
                    assert all("ИГЛА" not in unquote(url) + body for url, body in collected)
                    page.locator("#peer-profile-open").click()
                    expect(query).to_have_value("")
                    expect(page.locator("#chat-search")).to_be_hidden()
                    expect(page.locator("#peer-profile")).to_be_visible()
                    assert page.locator("#timeline").bounding_box()["height"] >= 320
                    expect(page.locator("#compose button")).to_be_in_viewport(ratio=1)
                    toggle.click()
                    expect(page.locator("#peer-profile")).to_be_hidden()
                    expect(page.locator("#peer-profile-bio")).to_have_text("")
                    query.fill("ИГЛА")
                    expect(match).to_contain_text(latest)

                    page.locator("#to-chats").click()
                    expect(query).to_have_value("")
                    row.click()
                    expect(page.locator("#chat-search")).to_be_hidden()
                    expect(messages.locator("[aria-current=true]")).to_have_count(0)
                    expect(page.locator("#compose textarea")).to_have_value("Черновик при поиске")
                    toggle.click()
                    query.fill("ИГЛА")
                    expect(match).to_contain_text(latest)
                    page.set_viewport_size({"width": 1280, "height": 900})
                    page.locator("#lock").click()
                    expect(query).to_have_value("")
                    expect(messages.locator("li")).to_have_count(0)
                    page.locator("#password").fill(viewer_password)
                    page.locator("#enter").click()
                    row.click()
                    expect(page.locator("#chat-search")).to_be_hidden()
                    page.locator("#compose button").click()
                    expect(messages.locator("li").filter(has_text="Черновик при поиске")).to_contain_text(
                        "Принято сервером", timeout=25_000)
                    d.sync(native, session["accessToken"], group)
                    history = native.call("history", group=group)["events"]
                    assert any(event["text"] == "Черновик при поиске" for event in history)
                finally:
                    stream.close()
        finally:
            native.close()
            direct.dispose()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="securemesh-pwa-history-") as scratch, live.postgres_database() as db:
        root = Path(scratch)
        with live.origins(root, db) as (origin, port, pin):
            exercise(root, origin, port, pin)
    print("PASS real MLS history search across timeline pages, offline, new delivery, draft, deselection and lock")
