#!/usr/bin/env python3
"""Block established message delivery in Chromium through local TLS and PostgreSQL."""
import re
import tempfile
import uuid
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

import live_browser as live


def exercise(origin, port, pin):
    with sync_playwright() as pw, live.launch_browser(pw, "chromium", origin, port, pin, None) as (browser, options):
        sender, recipient = (browser.new_context(**options).new_page() for _ in range(2))
        suffix = uuid.uuid4().hex[:8]
        sender_name, recipient_name = f"sender_{suffix}", f"recipient_{suffix}"
        sender_code, _ = live.register(sender, origin, sender_name)
        recipient_code, _ = live.register(recipient, origin, recipient_name)
        sender.locator("#invite [name=peer]").fill(recipient_name)
        sender.locator("#invite button").click()
        accept = recipient.locator("[data-action=accept]")
        accept.locator("..").locator("input").fill(sender_code)
        accept.click()
        establish = sender.locator("[data-action=establish]")
        establish.locator("..").locator("input").fill(recipient_code)
        establish.click()
        recipient.locator("[data-action=join]").click()
        sender.locator("#chat-list").get_by_role("button", name=re.compile(recipient_name)).click()
        recipient.locator("#chat-list").get_by_role("button", name=re.compile(sender_name)).click()

        def send(text):
            sender.locator("#compose textarea").fill(text)
            sender.locator("#compose button").click()

        history = recipient.locator("#messages")
        accepted = "До блокировки"
        send(accepted)
        expect(history.get_by_text(accepted, exact=True)).to_be_visible(timeout=25_000)
        recipient.locator("#peer-profile-open").click()
        recipient.locator("#peer-messages summary").click()
        action = recipient.locator("#dm-block")
        expect(action).to_have_text("Заблокировать сообщения")
        action.click()
        expect(action).to_have_text("Снять блокировку сообщений")
        expect(recipient.locator("#compose")).to_be_hidden()
        expect(history.get_by_text(accepted, exact=True)).to_be_visible()

        pending = "В очереди до возобновления"
        with sender.expect_response(lambda r: r.url.endswith("/v1/messages") and r.status == 409) as denial:
            send(pending)
        assert denial.value.json() == {"code": "CONVERSATION_MESSAGES_BLOCKED"}
        expect(sender.locator("#messages li").filter(has_text=pending)).to_contain_text("В очереди")
        expect(history.get_by_text(pending, exact=True)).to_have_count(0)

        with recipient.expect_response(lambda r: r.url.endswith("/message-block") and
                                       r.request.method == "DELETE" and r.ok):
            action.click()
        expect(action).to_have_text("Заблокировать сообщения")
        expect(recipient.locator("#compose")).to_be_visible()
        expect(history.get_by_text(pending, exact=True)).to_be_visible(timeout=25_000)
        expect(history.get_by_text(accepted, exact=True)).to_be_visible()
        expect(history.locator("li")).to_have_count(2)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="securemesh-message-block-") as tmp, live.postgres_database() as db:
        with live.origins(Path(tmp), db) as (origin, port, pin):
            exercise(origin, port, pin)
    print("PASS Chromium explicit established message pause, stored history, queued rejection and resume")
