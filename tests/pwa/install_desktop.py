"""Install the SecureMesh PWA in an isolated desktop Chromium profile and launch it offline."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
from threading import Thread

from playwright.sync_api import expect, sync_playwright


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def exercise(root, scratch, captures, headed):
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(root))) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"
        app_url = origin + "/app/"
        env = dict(os.environ)
        for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            directory = scratch / name
            directory.mkdir()
            env[name] = str(directory)
        with sync_playwright() as pw, pw.chromium.launch_persistent_context(
            scratch / "profile", channel="chromium", headless=not headed, env=env, no_viewport=True
        ) as context:
            page = context.pages[0]
            page.goto(app_url)
            expect(page.locator("#offline-status")).to_have_text("Справка доступна офлайн")
            expect(page.get_by_role("link", name="Открыть мессенджер")).to_have_attribute("href", "./profile.html")
            for label, text in [("iPhone и iPad", "Safari"), ("Android", "Chrome"), ("Windows и Linux", "Edge")]:
                guide = page.locator("details").filter(has=page.get_by_text(label, exact=True))
                guide.locator("summary").click()
                expect(guide.locator("p")).to_contain_text(text)
                guide.locator("summary").click()
            if captures:
                captures.mkdir(parents=True, exist_ok=True)
                for name, width, height in [("desktop", 1280, 800), ("phone", 390, 844)]:
                    page.set_viewport_size({"width": width, "height": height})
                    page.evaluate("window.scrollTo(0, 0)")
                    page.screenshot(path=captures / (name + ".png"))
            # Exercise the one-shot button handler separately from Chromium's actual
            # installation below. The synthetic dismissal never changes OS state.
            page.evaluate("""() => {
                window.promptCalls = 0;
                const event = new Event('beforeinstallprompt', {cancelable: true});
                event.prompt = () => { window.promptCalls++; return Promise.resolve(); };
                event.userChoice = Promise.resolve({outcome: 'dismissed'});
                dispatchEvent(event);
            }""")
            page.get_by_role("button", name="Установить SecureMesh").click()
            expect(page.locator("#install-app")).to_be_hidden()
            expect(page.locator("#install-guide")).to_be_visible()
            assert page.evaluate("window.promptCalls") == 1
            cdp = context.new_cdp_session(page)
            manifest = cdp.send("Page.getAppManifest")
            assert not manifest["errors"], manifest["errors"]
            issues = cdp.send("Page.getInstallabilityErrors")["installabilityErrors"]
            assert not issues, issues
            # Chromium resolves the existing relative manifest ID against the origin.
            assert manifest["manifest"]["id"] == origin + "/"
            params = {"manifestId": manifest["manifest"]["id"]}
            cdp.send("PWA.install", {**params, "installUrlOrBundleUrl": app_url})
            try:
                assert "badgeCount" in cdp.send("PWA.getOsAppState", params)
                cdp.send("PWA.changeAppUserSettings", {**params, "displayMode": "standalone"})
                context.set_offline(True)
                with context.expect_page() as window:
                    cdp.send("PWA.launch", params)
                installed = window.value
                installed.wait_for_url(app_url + "profile.html")
                expect(installed.locator("#entry")).to_be_visible()
                assert installed.evaluate("matchMedia('(display-mode: standalone)').matches")
                installed.get_by_role("link", name="SecureMesh").click()
                expect(installed.locator("#standalone")).to_be_visible()
                expect(installed.locator("#install-guide")).to_be_hidden()
                assert installed.evaluate("Boolean(navigator.serviceWorker.controller)")
            finally:
                cdp.send("PWA.uninstall", params)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="directory containing app/")
    parser.add_argument("--screenshots", type=Path)
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        exercise(args.root.resolve(), Path(temporary), args.screenshots, args.headed)
    print("PASS desktop Chromium installed the PWA and launched the vault and guide offline in standalone mode")
