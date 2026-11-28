#!/usr/bin/env python3
"""Native MLS sender uploads sealed image bytes; the PWA fetches and displays them."""
import base64
import hashlib
import re
import secrets
import sys
import tempfile
import uuid
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

import live_browser as live

sys.path.insert(0, str(live.ROOT / "tests/crypto"))
from process_spike import Device


def fingerprint(key):
    return hashlib.sha256(base64.b64decode(key, validate=True)).hexdigest().upper()


def exchange(root, origin, api_port, pin):
    device = Device(root)
    name = "photo_" + uuid.uuid4().hex[:10]
    email = name + "@securemesh.test"
    password = secrets.token_urlsafe(24)
    recipient = "viewer_" + uuid.uuid4().hex[:10]
    with sync_playwright() as pw, live.launch_browser(pw, "chromium", origin, api_port, pin, None) as (browser, options):
        page = browser.new_context(**options).new_page()
        direct = pw.request.new_context(base_url=f"https://127.0.0.1:{api_port}", ignore_https_errors=True)
        session = {}
        def post(path, body, status=200):
            headers = {"Authorization": "Bearer " + session["accessToken"]} if session else {}
            response = direct.post(path, data=body, headers=headers)
            assert response.status == status, (path, response.status)
            return response.json() if response.body() else None

        post("/v1/auth/register", dict(username=name, email=email, password=password), 202)
        post("/v1/auth/verify-email", dict(token=live.verification_token(email)), 204)
        challenge = post("/v1/auth/challenge", dict(username=name, deviceId=device.identity))
        proof = device.call("sign", payload=challenge["payload"])
        session = post("/v1/auth/login", dict(username=name, password=password, deviceId=device.identity,
                       publicKey=device.public, challengeId=challenge["challengeId"], signature=proof["signature"]))
        viewer_code, _ = live.register(page, origin, recipient)
        invitation, lease = (str(uuid.uuid4()) for _ in range(2))
        post("/v1/chat-requests", dict(id=invitation, username=recipient), 201)
        accept = page.locator("[data-action=accept]")
        expect(accept).to_be_visible(timeout=25_000)
        accept.locator("..").locator("input").fill(" ".join(re.findall("....", fingerprint(device.public))))
        with page.expect_response(lambda r: r.url.endswith(f"/{invitation}/accept") and r.ok):
            accept.click()
        package = post("/v1/crypto/keypackages/lease", dict(invitationId=invitation, requestId=lease))
        assert fingerprint(package["publicKey"]) == viewer_code.replace(" ", "").upper()
        device.call("pin", identity=package["recipient"], public_key=package["publicKey"], confirmed=True)
        setup = device.call("directory_prepare", invitation=invitation, lease=lease, recipient=package["recipient"],
                            reference=package["reference"], keypackage=package["keypackage"])
        post("/v1/conversations/establish", setup, 201)
        page.locator("[data-action=join]").click(timeout=25_000)
        page.locator("#chat-list").get_by_role("button", name=re.compile(name)).click()
        group, message = setup["id"], str(uuid.uuid4())
        png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP8z/CfgYEBAAoEAgDdrjB4AAAAAElFTkSuQmCC"
        staged = device.call("attachment_prepare", group=group, id=message, data=png,
                             name="private.png", media="photo", caption="Тестовое фото")
        ciphertext = device.call("attachment_ciphertext", group=group, id=message)["ciphertext"]
        route = f"/v1/conversations/{group}/blobs/{staged['blobId']}"
        sealed = base64.b64decode(ciphertext)
        assert sealed != base64.b64decode(png) and len(sealed) == len(base64.b64decode(png)) + 16
        result = direct.put(route, data=sealed, headers={"Authorization":"Bearer " + session["accessToken"],
                                                         "Content-Type":"application/octet-stream"})
        assert result.status == 201, result.status
        envelope = device.call("attachment_queue", group=group, id=message)
        post("/v1/messages", dict(conversationId=group, clientMessageId=message, mlsEpoch=envelope["epoch"],
                                 envelopeKind=envelope["kind"], ciphertext=envelope["ciphertext"]))
        with page.expect_response(lambda r: r.url.endswith(route) and r.ok):
            page.get_by_role("button", name="Посмотреть фото").click(timeout=25_000)
        preview = page.locator("#messages img.private-photo-preview")
        expect(preview).to_be_visible()
        assert preview.evaluate("async img => { await img.decode(); return [img.naturalWidth, img.naturalHeight]; }") == [2, 1]
        page.locator("#lock").click()
        expect(preview).to_have_count(0)
        direct.dispose()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="securemesh-photo-pwa-") as root, live.postgres_database() as db:
        root = Path(root)
        with live.origins(root, db) as (origin, port, pin):
            exchange(root, origin, port, pin)
    print("Native encrypted photo uploaded over TLS and displayed in Chromium; preview removed at lock")
