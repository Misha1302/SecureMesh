#!/usr/bin/env python3
"""Exercise packaged service worker release isolation in a real browser."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import runpy
import shutil
import sys
from tempfile import TemporaryDirectory
from threading import Thread

from playwright.sync_api import expect, sync_playwright


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = runpy.run_path(str(ROOT / "scripts/package-pwa.py"))
ASSETS = PACKAGER["ASSETS"]


def assert_stylesheet(page, expected):
    assert expected == page.evaluate("fetch('./app.css').then(response => response.text())")


def update(page):
    return page.evaluate("""async () => {
        const registration = await navigator.serviceWorker.getRegistration();
        const result = new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('Update did not finish')), 15000);
            registration.addEventListener('updatefound', () => {
                const worker = registration.installing;
                const observe = () => {
                    if (worker.state === 'installed' || worker.state === 'redundant') {
                        clearTimeout(timer);
                        resolve(worker.state);
                    }
                };
                worker.addEventListener('statechange', observe);
                observe();
            }, {once: true});
        });
        await registration.update();
        return await result;
    }""")


def verify_release(package, fixture):
    old = fixture / "old"
    new = fixture / "new"
    partial = fixture / "partial"
    shutil.copytree(package / "app", old / "app")
    shutil.copytree(old, new)

    files = {name: (new / "app" / name).read_bytes() for name in ASSETS}
    files["sw.js"] = (ROOT / "site/app/sw.js").read_bytes()
    files["app.css"] += b"\n/* integration test's new release */\n"
    (new / "app/app.css").write_bytes(files["app.css"])
    (new / "app/sw.js").write_bytes(PACKAGER["render_service_worker"](files))
    shutil.copytree(new, partial)
    shutil.copyfile(old / "app/app.css", partial / "app/app.css")
    for directory in (old, new, partial):
        (directory / "observer.html").write_text("<title>Release observer</title>", encoding="utf-8")
    deployment = old

    class Handler(SimpleHTTPRequestHandler):
        def translate_path(self, path):
            self.directory = deployment
            return super().translate_path(path)

        def copyfile(self, source, outputfile):
            try:
                super().copyfile(source, outputfile)
            except (BrokenPipeError, ConnectionResetError):
                # Chromium can cancel parallel fetches when one precache check fails.
                pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store, no-transform")
            super().end_headers()

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}/"
        with sync_playwright() as playwright, playwright.chromium.launch() as browser:
            context = browser.new_context()
            page = context.new_page()
            page.goto(base + "app/")
            expect(page.locator("#offline-status")).to_have_text("Справка доступна офлайн")
            assert page.reload().from_service_worker
            old_cache, = page.evaluate("caches.keys()")
            asset_count = len(ASSETS) - 1
            assert page.evaluate("(name) => caches.open(name).then(cache => cache.keys()).then(keys => keys.length)", old_cache) == asset_count
            old_css = page.evaluate("fetch('./app.css').then(response => response.text())")
            page.evaluate("caches.open('another-origin-app')")

            deployment = partial
            assert update(page) == "redundant"
            assert set(page.evaluate("caches.keys()")) == {old_cache, "another-origin-app"}
            assert_stylesheet(page, old_css)
            assert page.evaluate("navigator.serviceWorker.controller.state") == "activated"
            assert not page.evaluate("navigator.serviceWorker.getRegistration().then(value => Boolean(value.waiting))")

            # A missing old asset may come back from the old release, but never from a new one.
            assert page.evaluate("(name) => caches.open(name).then(cache => cache.delete('./app.css'))", old_cache)
            deployment = new
            assert page.evaluate("fetch('./app.css').then(() => false, () => true)")
            deployment = old
            assert_stylesheet(page, old_css)
            assert not page.evaluate("(name) => caches.match('./app.css', {cacheName:name}).then(Boolean)", old_cache)
            page.evaluate("""async name => {
                const response = await fetch('./app.css');
                const cache = await caches.open(name);
                await cache.put('./app.css', response);
            }""", old_cache)

            deployment = new
            assert update(page) == "installed"
            active_and_waiting = page.evaluate("caches.keys()")
            new_cache, = set(active_and_waiting) - {old_cache, "another-origin-app"}
            assert page.evaluate("(name) => caches.open(name).then(cache => cache.keys()).then(keys => keys.length)", new_cache) == asset_count
            assert page.evaluate("navigator.serviceWorker.getRegistration().then(value => value.waiting.state)") == "installed"
            assert_stylesheet(page, old_css)

            observer = context.new_page()
            observer.goto(base + "observer.html")
            page.close()
            observer.wait_for_function("""async (previous) => {
                const registration = await navigator.serviceWorker.getRegistration('/app/');
                const names = await caches.keys();
                return registration.active?.state === 'activated' && !registration.waiting &&
                    !names.includes(previous);
            }""", arg=old_cache)

            context.set_offline(True)
            page = context.new_page()
            assert page.goto(base + "app/profile.html").from_service_worker
            assert_stylesheet(page, files["app.css"].decode("utf-8"))
            assert set(page.evaluate("caches.keys()")) == {new_cache, "another-origin-app"}

            # A valid rollback may be waiting while the same active release is redeployed.
            # In that case an unsuccessful reinstall must preserve the active release's cache.
            context.set_offline(False)
            deployment = old
            assert update(page) == "installed"
            deployment = partial
            assert update(page) == "redundant"
            assert new_cache in page.evaluate("caches.keys()")
            assert_stylesheet(page, files["app.css"].decode("utf-8"))

            context.close()
        server.shutdown()


if __name__ == "__main__":
    with TemporaryDirectory() as workspace:
        verify_release(Path(sys.argv[1]).resolve(strict=True), Path(workspace))
    print("PASS PWA release integrity, atomic install, rollback, and waiting activation")
