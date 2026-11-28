#!/usr/bin/env python3
"""Chromium PWA recovery against live Kestrel, PostgreSQL and Mailpit."""
import json
import re
import secrets
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

import live_browser as live


def recovery_token(email):
    query = urllib.parse.urlencode({"query": f"to:{email}"})
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        with urllib.request.urlopen(f"{live.MAIL_ORIGIN}/api/v1/search?{query}", timeout=3) as response:
            messages = json.load(response)["messages"]
        for message in messages:
            if "recovery" not in message.get("Subject", "").lower():
                continue
            with urllib.request.urlopen(f"{live.MAIL_ORIGIN}/api/v1/message/{message['ID']}", timeout=3) as response:
                token = json.load(response)["Text"].strip()
            assert re.fullmatch(r"[a-f0-9]{64}", token)
            return token
        time.sleep(.1)
    raise AssertionError("Mailpit did not receive the recovery email")


def browser_args(api_port, pin):
    return ["--no-proxy-server",
        f"--host-resolver-rules=MAP {live.API_HOST} 127.0.0.1:{api_port}, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
        f"--ignore-certificate-errors-spki-list={pin}"]


def exercise(app_origin, api_port, pin):
    username = "recover_" + uuid.uuid4().hex[:16]
    email = username + "@securemesh.test"
    old_password = secrets.token_urlsafe(25)
    new_password = secrets.token_urlsafe(25)
    old_sessions = []
    new_sessions = []
    recovery_requests = []

    with sync_playwright() as playwright, playwright.chromium.launch(args=browser_args(api_port, pin)) as browser:
        original = browser.new_context().new_page()
        original.set_default_timeout(25_000)
        original.on("response", lambda response: old_sessions.append(response.json())
                    if response.url == live.API_ORIGIN + "/v2/auth/login" and response.ok else None)
        original.goto(app_origin + "/app/profile.html")
        live.create_profile(original, username, old_password)
        original.locator("#register [name=email]").fill(email)
        original.locator("#register button").click()
        original.locator("#verify [name=code]").fill(live.verification_token(email))
        original.locator("#verify button").click()
        original.locator("#login button").click()
        expect(original.locator("#conversations")).to_be_visible(timeout=20_000)
        assert old_sessions and old_sessions[-1]["trustState"] == "DEVICE_TRUSTED"

        replacement = browser.new_context().new_page()
        replacement.set_default_timeout(25_000)
        replacement.on("request", lambda request: recovery_requests.append(request.post_data_json)
                       if request.url == live.API_ORIGIN + "/v2/auth/recovery/complete" else None)
        replacement.on("response", lambda response: new_sessions.append(response.json())
                       if response.url == live.API_ORIGIN + "/v2/auth/login" and response.ok else None)
        replacement.goto(app_origin + "/app/profile.html")
        live.create_profile(replacement, username, new_password)
        expect(replacement.locator("#recovery")).to_be_visible()
        replacement.locator("#recovery summary").click()
        replacement.locator("#recovery-request [name=email]").fill(email)
        replacement.locator("#recovery-request button").click()
        expect(replacement.locator("#notice")).to_contain_text("Если адрес подтверждён")
        token = recovery_token(email)
        replacement.locator("#recovery-complete [name=code]").fill(token)
        replacement.locator("#recovery-complete button").click()
        expect(replacement.locator("#notice")).to_contain_text("Пароль аккаунта восстановлен")
        assert recovery_requests and recovery_requests[-1]["username"] == username
        assert recovery_requests[-1]["token"] == token
        assert set(recovery_requests[-1]) == {"username", "token", "credential"}
        assert new_password not in json.dumps(recovery_requests[-1])

        replacement.locator("#login button").click()
        expect(replacement.locator("#notice")).to_contain_text("ожидает независимой проверки")
        assert replacement.locator("#conversations").is_hidden()
        assert new_sessions and new_sessions[-1]["trustState"] == "DEVICE_PENDING_TRUST"

        old_status = original.evaluate("""async token => (await fetch(
          "https://securemesh.90-156-230-119.sslip.io/v1/users/me",
          {headers: {Authorization: `Bearer ${token}`}, cache: "no-store"})).status""",
          old_sessions[-1]["accessToken"])
        assert old_status == 401, old_status
        old_refresh = original.evaluate("""async token => (await fetch(
          "https://securemesh.90-156-230-119.sslip.io/v1/auth/refresh",
          {method: "POST", headers: {"Content-Type": "application/json"},
           body: JSON.stringify({token}), cache: "no-store"})).status""",
          old_sessions[-1]["refreshToken"])
        assert old_refresh == 401, old_refresh
        pending_status = replacement.evaluate("""async token => (await fetch(
          "https://securemesh.90-156-230-119.sslip.io/v1/conversations",
          {headers: {Authorization: `Bearer ${token}`}, cache: "no-store"})).status""",
          new_sessions[-1]["accessToken"])
        assert pending_status == 403, pending_status
        browser.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="securemesh-recovery-pwa-") as directory, live.postgres_database() as connection:
        with live.origins(Path(directory), connection) as (app_origin, api_port, pin):
            exercise(app_origin, api_port, pin)
    print("Chromium PWA recovery reset a v2 credential, invalidated the previous session, and left the clean device pending independent trust")
