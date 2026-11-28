#!/usr/bin/env python3
"""Exercise private photos in both directions against the native MLS core and real API."""
import argparse
import base64
import hashlib
import re
import secrets
import sys
import tempfile
import uuid
import zlib
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import expect, sync_playwright

import live_browser as live

sys.path.insert(0, str(live.ROOT / "tests/crypto"))
from process_spike import Device


def fingerprint(key):
    return hashlib.sha256(base64.b64decode(key, validate=True)).hexdigest().upper()


def exchange(root, origin, api_port, pin, engine):
    device = Device(root)
    name = "photo_" + uuid.uuid4().hex[:10]
    email = name + "@securemesh.test"
    password = secrets.token_urlsafe(24)
    recipient = "viewer_" + uuid.uuid4().hex[:10]
    with sync_playwright() as pw, live.launch_browser(pw, engine, origin, api_port, pin, live.Outage()) as (browser, options):
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
        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#to-chats").click()
        expect(preview).to_have_count(0)
        page.locator("#chat-list").get_by_role("button", name=re.compile(name)).click()
        page.get_by_role("button", name="Посмотреть фото").click()
        expect(preview).to_be_visible()
        ours = page.locator("#send-photo")
        file = ours.locator("input")
        uploads, submissions = [], []
        def upstream(request):
            return direct.fetch(urlsplit(request.url).path, method=request.method,
                                headers={key: value for key, value in request.all_headers().items()
                                         if key in {"authorization", "content-type", "origin"}},
                                data=request.post_data_buffer)

        def lose_reply(route):
            request = route.request
            if request.method == "PUT":
                data = request.post_data_buffer
                uploads.append((request.url, data))
                response = upstream(request)
                assert response.status == (201 if len(uploads) == 1 else 204)
                if len(uploads) == 1:
                    route.abort()
                else:
                    route.fulfill(response=response)
            else:
                route.continue_()

        def lose_message_reply(route):
            request = route.request
            submissions.append(request.post_data_json)
            response = upstream(request)
            assert response.status == 200
            if len(submissions) == 1:
                route.abort()
            else:
                route.fulfill(response=response)

        page.route("**/v1/conversations/*/blobs/*", lose_reply)
        page.route("**/v1/messages", lose_message_reply)
        raw_png = base64.b64decode(png)

        def png_chunk(tag, content):
            payload = tag + content
            return len(content).to_bytes(4, "big") + payload + zlib.crc32(payload).to_bytes(4, "big")

        for invalid in [
            b"not an image",
            b"x" * (4 * 1024 * 1024 + 1),
            raw_png[:16] + bytes.fromhex("0001000000000001") + raw_png[24:],
            raw_png[:33] + png_chunk(b"acTL", bytes.fromhex("0000000200000000")) + raw_png[33:],
        ]:
            file.set_input_files({"name": "fake.png", "mimeType": "image/png", "buffer": invalid})
            ours.get_by_role("button", name="Отправить фото").click()
            expect(page.get_by_text("Вложение", exact=False)).to_be_visible()
            assert not uploads and not submissions
        source = raw_png[:-12] + png_chunk(b"tEXt", b"Comment\0local-only-source-metadata") + raw_png[-12:]
        file.set_input_files({"name": "original-private-name.png", "mimeType": "image/png", "buffer": source})
        assert not uploads and not submissions
        with page.expect_response(lambda r: r.url.endswith("/v1/messages") and r.ok, timeout=40_000):
            ours.get_by_role("button", name="Отправить фото").click()
        expect(page.get_by_text("Фото", exact=True).last).to_be_visible()
        assert len(uploads) >= 2 and len(submissions) >= 2
        assert all(record == uploads[0] for record in uploads)
        assert all(record == submissions[0] for record in submissions)
        envelope = submissions[0]
        assert set(envelope) == {"conversationId", "clientMessageId", "mlsEpoch", "envelopeKind", "ciphertext"}
        blob_url, sealed = uploads[0]
        assert b"original-private-name" not in sealed and b"local-only-source-metadata" not in sealed
        header = {"Authorization": "Bearer " + session["accessToken"]}
        rows = direct.get(f"/v1/sync?conversationId={group}&limit=10", headers=header)
        assert rows.ok, (rows.status, rows.text())
        events = [row for row in rows.json()["messages"] if row["clientMessageId"] == envelope["clientMessageId"]]
        assert len(events) == 1
        row = events[0]
        received = device.call("process", group=group, ciphertext=row["ciphertext"], sender=package["recipient"],
                               epoch=row["mlsEpoch"], kind=row["envelopeKind"])
        assert received["attachment"]["name"] == "photo.jpg" and received["attachment"]["media"] == "photo"
        mid = envelope["clientMessageId"]
        remote = direct.get(f"/v1/conversations/{group}/blobs/{received['attachment']['blobId']}", headers=header)
        assert remote.ok and remote.body() == sealed and blob_url.endswith(received["attachment"]["blobId"])
        tampered = sealed[:-1] + bytes([sealed[-1] ^ 1])
        device.call("attachment_open", reject=True, group=group, id=mid, ciphertext=base64.b64encode(tampered).decode())
        opened = device.call("attachment_open", group=group, id=mid, ciphertext=base64.b64encode(sealed).decode())
        jpeg = base64.b64decode(opened["data"])
        assert jpeg.startswith(b"\xff\xd8") and jpeg.endswith(b"\xff\xd9")
        assert b"Exif\0\0" not in jpeg and b"local-only-source-metadata" not in jpeg
        page.locator("#lock").click()
        expect(preview).to_have_count(0)
        direct.dispose()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", choices=("chromium", "firefox", "webkit"), default="chromium")
    engine = parser.parse_args().browser
    with tempfile.TemporaryDirectory(prefix="securemesh-photo-pwa-") as root, live.postgres_database() as db:
        root = Path(root)
        with live.origins(root, db) as (origin, port, pin):
            exchange(root, origin, port, pin, engine)
    print("Private photo interoperability over TLS in both directions; byte-identical retry and preview cleanup")
