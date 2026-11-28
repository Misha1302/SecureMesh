"""Share a profile from one account and open its discovery link in a locked browser."""
import tempfile
import uuid
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

import live_browser as live


def exercise(origin, port, pin):
    with sync_playwright() as pw, live.launch_browser(pw, "chromium", origin, port, pin, None) as (browser, options):
        owner = browser.new_context(**options).new_page()
        viewer = browser.new_context(**options).new_page()
        # Force the ordinary permission-denied fallback without modifying a system clipboard.
        owner.add_init_script("""Object.defineProperty(navigator, 'clipboard', {value: undefined});""")
        suffix = uuid.uuid4().hex[:8]
        owner_name, viewer_name = 'owner_' + suffix, 'viewer_' + suffix
        live.register(owner, origin, owner_name)
        _, password = live.register(viewer, origin, viewer_name)
        panel = owner.locator("#profile-text")
        panel.locator("summary").click()
        panel.get_by_role("button", name="Скопировать ссылку на профиль").click()
        field = owner.locator("#own-profile-link")
        link = origin + "/app/profile.html#/@" + owner_name
        expect(field).to_have_value(link)
        panel.locator("summary").click()
        expect(field).to_have_value("")
        invited = []
        viewer.on("request", lambda r: invited.append(r) if r.method == "POST" and
                  r.url.endswith("/v1/chat-requests") else None)

        viewer.goto("about:blank")
        viewer.goto(link)
        expect(viewer.locator("#entry")).to_be_visible()
        assert viewer.evaluate("location.hash") == ""
        viewer.locator("#password").fill(password)
        viewer.locator("#enter").click()
        target = viewer.locator("#invite [name=peer]")
        expect(target).to_have_value(owner_name)
        expect(owner.locator("[data-action=accept]")).to_have_count(0)
        assert invited == []

        target.fill("unfinished_draft")
        viewer.evaluate("(name) => { location.hash = '/@' + name; }", owner_name)
        choice = viewer.locator("#use-linked-peer")
        expect(choice).to_be_visible()
        expect(target).to_have_value("unfinished_draft")
        choice.click()
        expect(target).to_have_value(owner_name)
        for fragment in ("/@bad%2Fname", "/@https%3A%2F%2Fexample.org", "/@" + viewer_name):
            viewer.evaluate("(value) => { location.hash = value; }", fragment)
            viewer.wait_for_function("!location.hash")
            expect(target).to_have_value(owner_name)
            expect(choice).to_be_hidden()
        assert invited == []
        viewer.locator("#invite button").click()
        expect(owner.locator("[data-action=accept]")).to_be_visible(timeout=25_000)
        assert len(invited) == 1
        viewer.locator("#lock").click()
        expect(target).to_have_value("")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="smesh-profile-links-") as tmp, live.postgres_database() as db:
        with live.origins(Path(tmp), db) as (origin, port, pin):
            exercise(origin, port, pin)
    print("PASS shared profile discovery across lock, same-page navigation, explicit consent and clipboard fallback")
