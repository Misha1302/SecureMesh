#!/usr/bin/env python3
"""Real Chromium lifecycle test for the private-photo UI control."""

import functools
import threading
from contextlib import contextmanager
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[2]


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def end_headers(self):
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; img-src 'self' blob:")
        super().end_headers()


@contextmanager
def app_origin():
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=ROOT / "site"))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join()


def main():
    with app_origin() as origin, sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(origin + "/app/index.html")
        page.evaluate("""async () => {
          const { privatePhotoControl } = await import('/app/private-image.js');
          window.releaseCount = 0;
          const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pWQAAAAASUVORK5CYII='), c => c.charCodeAt(0));
          window.control = privatePhotoControl({
            name: 'photo.png',
            open: async () => URL.createObjectURL(new Blob([png], { type: 'image/png' })),
            release: () => { window.releaseCount++; },
            onError: error => { throw error; },
          });
          document.body.append(window.control.element);
        }""")
        button = page.get_by_role("button", name="Посмотреть фото")
        button.click()
        image = page.locator("img.private-photo-preview")
        expect(image).to_be_visible()
        expect(image).to_have_attribute("alt", "photo.png")
        image.evaluate("img => img.decode()")
        page.get_by_role("button", name="Скрыть фото").click()
        expect(page.locator("img.private-photo-preview")).to_have_count(0)
        assert page.evaluate("window.releaseCount") == 1

        # Disposal while the asynchronous open is pending releases a late URL.
        page.evaluate("""async () => {
          const { privatePhotoControl } = await import('/app/private-image.js');
          let resolveOpen;
          window.late = privatePhotoControl({
            name: 'late.png',
            open: () => new Promise(resolve => { resolveOpen = resolve; }),
            release: () => { window.releaseCount++; },
            onError: () => {},
          });
          document.body.append(window.late.element);
          window.late.element.querySelector('button').click();
          window.late.dispose();
          window.resolveLate = resolveOpen;
        }""")
        page.evaluate("window.resolveLate(URL.createObjectURL(new Blob(['x'], {type:'image/png'})))")
        page.wait_for_timeout(0)
        assert page.evaluate("window.releaseCount") == 2
        assert page.locator("img.private-photo-preview").count() == 0
        browser.close()
    print("Private photo Chromium lifecycle passed.")


if __name__ == "__main__":
    main()
