#!/usr/bin/env python3
"""Exercise browser contact block/unblock in an established pair on local TLS."""
import re
import tempfile
import uuid
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

import live_browser as live


def exercise(origin, api_port, pin):
    with sync_playwright() as playwright, live.launch_browser(playwright, "chromium", origin, api_port, pin, None) as (browser, options):
        owner, peer = (browser.new_context(**options).new_page() for _ in range(2))
        suffix = uuid.uuid4().hex[:9]
        owner_name, peer_name = "owner_" + suffix, "peer_" + suffix
        owner_code, owner_password = live.register(owner, origin, owner_name)
        peer_code, _ = live.register(peer, origin, peer_name)

        editor = peer.locator("#profile-text")
        editor.locator("summary").click()
        editor.get_by_label("О себе", exact=True).fill("Видимая анкета")
        editor.get_by_label("Показывать собеседникам").check()
        editor.get_by_role("button", name="Сохранить", exact=True).click()
        expect(editor.get_by_role("status")).to_have_text("Сохранено")
        editor.locator("summary").click()

        owner.locator("#invite [name=peer]").fill(peer_name)
        owner.locator("#invite button").click()
        accept = peer.locator("[data-action=accept]")
        accept.locator("..").locator("input").fill(owner_code)
        accept.click()
        establish = owner.locator("[data-action=establish]")
        establish.locator("..").locator("input").fill(peer_code)
        establish.click()
        peer.locator("[data-action=join]").click()
        row = owner.locator("#chat-list").get_by_role("button", name=re.compile(peer_name))
        row.click()
        peer.locator("#chat-list").get_by_role("button", name=re.compile(owner_name)).click()

        toggle = owner.locator("#peer-profile-open")
        action = owner.locator("#peer-block")
        bio = owner.locator("#peer-profile-bio")
        note = owner.locator("#peer-block-note")
        path = "/v1/contact-blocks/" + peer_name
        toggle.click()
        owner.locator("#peer-invitations summary").click()
        expect(bio).to_have_text("Видимая анкета", timeout=25_000)
        expect(action).to_have_text("Заблокировать приглашения")
        toggle.click()

        # Hold one real old profile response and drop the reply to a real block
        # mutation. Neither may make the UI display data or assume a result.
        owner.evaluate("""() => {
          const fetchRequest = window.fetch;
          window.fetch = async (...args) => {
            const response = await fetchRequest(...args);
            const endpoint = String(args[0]);
            if (endpoint.includes('/profile-text/') && !window.releaseOldProfile) {
              await new Promise(resolve => {
                window.releaseOldProfile = resolve;
                document.documentElement.dataset.heldProfile = "1";
              });
            }
            if (endpoint.includes('/contact-blocks/') && args[1]?.method === 'PUT' && !window.lostBlockReply) {
              window.lostBlockReply = true;
              throw new TypeError("fixture lost the HTTP response");
            }
            return response;
          };
        }""")
        toggle.click()
        owner.locator("#peer-invitations summary").click()
        expect(owner.locator("html")).to_have_attribute("data-held-profile", "1")
        action.click()
        expect(note).to_contain_text("Не удалось подтвердить изменение.")
        owner.evaluate("window.releaseOldProfile()")
        expect(bio).to_have_text("")
        expect(action).to_have_text("Повторить проверку")
        action.click()
        expect(action).to_have_text("Разблокировать")
        expect(bio).to_have_text("")

        peer.locator("#invite [name=peer]").fill(owner_name)
        with peer.expect_response(lambda response: response.url.endswith("/v1/chat-requests") and
                                  response.request.method == "POST") as blocked_invite:
            peer.locator("#invite button").click()
        assert blocked_invite.value.status == 404
        assert blocked_invite.value.json() == {"code": "USER_NOT_FOUND"}

        text = "Существующий чат по-прежнему доставляет сообщения"
        peer.locator("#compose textarea").fill(text)
        peer.locator("#compose button").click()
        expect(owner.locator("#messages").get_by_text(text, exact=True)).to_be_visible(timeout=25_000)

        # Reload the established chat after locking and see server state again.
        owner.locator("#lock").click()
        expect(owner.locator("#peer-profile")).to_be_hidden()
        expect(action).to_be_disabled()
        expect(action).to_have_text("Проверить блокировку")
        assert not owner.locator("#peer-invitations").evaluate("panel => panel.open")
        expect(bio).to_have_text("")
        owner.locator("#password").fill(owner_password)
        owner.locator("#enter").click()
        row.click()
        toggle.click()
        owner.locator("#peer-invitations summary").click()
        expect(action).to_have_text("Разблокировать")

        # DELETE has cross-origin authorization only for this route and origin.
        request = playwright.request.new_context(base_url=f"https://127.0.0.1:{api_port}", ignore_https_errors=True)
        try:
            for route, source, allowed in (
                (path, origin, True),
                (path, "https://unrelated.invalid", False),
                ("/v1/messages", origin, False),
            ):
                result = request.fetch(route, method="OPTIONS", headers={
                    "Origin": source, "Access-Control-Request-Method": "DELETE",
                    "Access-Control-Request-Headers": "authorization",
                })
                allow_origin = result.headers.get("access-control-allow-origin")
                allow_methods = result.headers.get("access-control-allow-methods", "").split(",")
                assert ((allow_origin == source and "DELETE" in allow_methods) == allowed), (
                    route, result.status, allow_origin, allow_methods
                )
                if allowed:
                    assert allow_methods == ["DELETE"]
        finally:
            request.dispose()
        with owner.expect_response(lambda response: response.url.endswith(path) and
                                   response.request.method == "DELETE" and response.status == 204):
            action.click()
        expect(action).to_have_text("Заблокировать приглашения")
        expect(bio).to_have_text("Видимая анкета")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="securemesh-pwa-block-") as scratch, live.postgres_database() as db:
        with live.origins(Path(scratch), db) as (origin, api_port, pin):
            exercise(origin, api_port, pin)
    print("PASS browser block scope, lost mutation response, stale peer reply, existing delivery, lock and scoped CORS unblock")
