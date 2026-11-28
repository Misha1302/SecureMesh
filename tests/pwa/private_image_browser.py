#!/usr/bin/env python3
"""Exercise the private-photo UI lifecycle and local normalization in Chromium."""

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
          window.released = [];
          const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pWQAAAAASUVORK5CYII='), c => c.charCodeAt(0));
          window.control = privatePhotoControl({
            name: 'photo.png',
            open: async () => URL.createObjectURL(new Blob([png], { type: 'image/png' })),
            release: url => { window.released.push(url); URL.revokeObjectURL(url); },
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
        displayed = image.get_attribute("src")
        page.get_by_role("button", name="Скрыть фото").click()
        expect(page.locator("img.private-photo-preview")).to_have_count(0)
        assert page.evaluate("window.released") == [displayed]

        # Disposal while the asynchronous open is pending releases a late URL.
        page.evaluate("""async () => {
          const { privatePhotoControl } = await import('/app/private-image.js');
          let resolveOpen;
          window.late = privatePhotoControl({
            name: 'late.png',
            open: () => new Promise(resolve => { resolveOpen = resolve; }),
            release: url => { window.released.push(url); URL.revokeObjectURL(url); },
            onError: () => {},
          });
          document.body.append(window.late.element);
          window.late.element.querySelector('button').click();
          window.late.dispose();
          window.resolveLate = resolveOpen;
        }""")
        late = page.evaluate("""() => {
          const url = URL.createObjectURL(new Blob(['x'], {type:'image/png'}));
          window.resolveLate(url);
          return url;
        }""")
        page.wait_for_timeout(0)
        assert page.evaluate("window.released") == [displayed, late]
        assert page.locator("img.private-photo-preview").count() == 0
        normalized = page.evaluate("""async () => {
          const { normalizeSelectedPhoto, photoHeader } = await import('/app/private-image.js');
          const canvas = document.createElement('canvas');
          canvas.width = 1200;
          canvas.height = 600;
          canvas.getContext('2d').fillRect(0, 0, canvas.width, canvas.height);
          const source = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg'));
          const original = new Uint8Array(await source.arrayBuffer());
          // APP1 with a little-endian TIFF IFD0 setting orientation to 6 (rotate 90°).
          const exif = Uint8Array.of(
            0xff, 0xe1, 0, 34, 69, 120, 105, 102, 0, 0,
            73, 73, 42, 0, 8, 0, 0, 0, 1, 0,
            0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0);
          const selected = new File([original.slice(0, 2), exif, original.slice(2)], 'source.jpg',
            { type: 'application/octet-stream' });
          const jpeg = await normalizeSelectedPhoto(selected, () => {});
          return { ...photoHeader(jpeg),
            hasExif: new TextDecoder().decode(jpeg).includes(String.fromCharCode(69,120,105,102,0,0)) };
        }""")
        assert normalized == {"mime": "image/jpeg", "width": 480, "height": 960, "hasExif": False}
        browser.close()
    print("Private photo Chromium lifecycle and EXIF-free normalization passed.")


if __name__ == "__main__":
    main()
