#!/usr/bin/env python3
"""Drive the packaged offline profile in Mobile Safari through Apple's WebDriver."""
import argparse
import json
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
from subprocess import run
from threading import Thread
from time import monotonic, sleep
from urllib.error import HTTPError
from urllib.request import Request, urlopen


class FixtureHandler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm",
                      ".js": "text/javascript", ".webmanifest": "application/manifest+json"}

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
                         "connect-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'")
        super().end_headers()

    def do_GET(self):
        if self.server.offline:
            self.send_error(503, "Fixture network unavailable")
        else:
            super().do_GET()

    def log_message(self, *_):
        pass


class SafariWebDriverError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(f"Safari WebDriver {code}: {message}")
        self.code = code


class SafariSession:
    def __init__(self, endpoint, simulator):
        self.endpoint = endpoint
        capabilities = {"capabilities": {"alwaysMatch": {
            "browserName": "safari", "platformName": "iOS",
            "safari:useSimulator": True, "safari:deviceType": "iPhone",
            "safari:deviceUDID": simulator, "acceptInsecureCerts": False,
        }}}
        try:
            session = self.command("/session", capabilities)
        except SafariWebDriverError as error:
            if error.code != "session not created" or "waiting for its RWIApplication to appear" not in str(error):
                raise
            # A booted simulator can still miss Safari's remote inspector
            # handshake. Reload Safari once, before any test page is opened.
            print(f"{error}; relaunching Mobile Safari for one session retry", flush=True)
            run(["xcrun", "simctl", "launch", "--terminate-running-process",
                 simulator, "com.apple.mobilesafari"], check=True, timeout=60)
            session = self.command("/session", capabilities)
        self.identifier = session["sessionId"]

    def command(self, path, body=None, method=None):
        data = json.dumps(body).encode() if body is not None else None
        request = Request(self.endpoint + path, data, {"Content-Type": "application/json"}, method=method)
        try:
            with urlopen(request, timeout=150) as response:
                return json.load(response)["value"]
        except HTTPError as error:
            value = json.load(error)["value"]
            raise SafariWebDriverError(value["error"], value.get("message", "")) from error

    def navigate(self, url):
        self.command(f"/session/{self.identifier}/url", {"url": url})

    def javascript(self, script, *args):
        return self.command(f"/session/{self.identifier}/execute/sync", {"script": script, "args": args})

    def close(self):
        self.command(f"/session/{self.identifier}", method="DELETE")


class DesktopSession:
    def __init__(self, browser_name):
        from playwright.sync_api import sync_playwright

        self.driver = sync_playwright().start()
        self.browser = getattr(self.driver, browser_name).launch()
        self.page = self.browser.new_page()

    def navigate(self, url):
        self.page.goto(url)

    def javascript(self, script, *args):
        return self.page.evaluate(f"args => (function () {{ {script} }}).apply(null, args)", args)

    def close(self):
        self.browser.close()
        self.driver.stop()


def wait(browser, description, script, *args):
    deadline = monotonic() + 45
    while monotonic() < deadline:
        if browser.javascript(script, *args):
            return
        sleep(0.3)
    status = browser.javascript(
        "return document.querySelector('#notice')?.textContent || "
        "document.querySelector('#offline-status')?.textContent || document.title;"
    )
    raise AssertionError(f"Timed out waiting for {description}; page status: {status!r}")


def exercise(browser, fixture, origin, expect_ios):
    browser.navigate(origin + "/app/")
    navigator = browser.javascript("return [navigator.userAgent, isSecureContext];")
    if not navigator[1]:
        raise AssertionError("Fixture did not load in a secure browsing context")
    if expect_ios and ("iPhone" not in navigator[0] or "Safari/" not in navigator[0]):
        raise AssertionError(f"Expected iPhone Safari, got {navigator[0]}")
    wait(browser, "the packaged service worker to control the guide",
         "return Boolean(navigator.serviceWorker.controller && document.querySelector('#offline-status[data-ready]'));")

    # The fixture refuses all network loads before the profile page is opened.
    # Browser HTTP caching is disabled. Service worker caching must supply the
    # page, its modules, the WASM worker and the WASM binary.
    fixture.offline = True
    browser.navigate(origin + "/app/profile.html")
    wait(browser, "the fresh local profile form", "return document.querySelector('#entry')?.hidden === false;")
    password = "Симулятор 🔐 только для теста 2026"
    browser.javascript("""
        const form = document.querySelector('#entry');
        form.elements.name.value = 'Проверка Safari';
        form.elements.username.value = 'safari_fixture';
        form.elements.password.value = arguments[0];
        form.elements.remembered.checked = true;
        form.requestSubmit();
    """, password)
    wait(browser, "an offline WASM identity and encrypted local profile",
         "return !document.querySelector('#lock').hidden && "
         "/^[0-9A-F]{4}( [0-9A-F]{4}){15}$/.test(document.querySelector('#my-code').textContent);")
    fingerprint = browser.javascript("return document.querySelector('#my-code').textContent;")

    browser.javascript("document.querySelector('#lock').click();")
    wait(browser, "the original profile to lock",
         "return document.querySelector('#account').hidden && !document.querySelector('#entry').hidden && "
         "!document.querySelector('#my-code').textContent;")
    browser.javascript("window.secureMeshOldDocument = true;")
    browser.navigate(origin + "/app/profile.html")
    wait(browser, "the persistent encrypted profile unlock form",
         "return !window.secureMeshOldDocument && document.querySelector('#entry')?.hidden === false && "
         "document.querySelector('#new-fields').hidden;")
    submit_password = """
        const form = document.querySelector('#entry');
        form.elements.password.value = arguments[0];
        form.requestSubmit();
    """
    browser.javascript(submit_password, "An incorrect test password")
    wait(browser, "the wrong password to fail",
         "return !document.querySelector('#entry').hidden && document.querySelector('#lock').hidden && "
         "Boolean(document.querySelector('#notice').textContent);")
    browser.javascript(submit_password, password)
    wait(browser, "the securely unlocked profile with the same WASM identity",
         "return !document.querySelector('#lock').hidden && "
         "document.querySelector('#my-code').textContent === arguments[0];", fingerprint)
    assert browser.javascript("return document.querySelector('#conversations').hidden;")
    print(f"Packaged offline profile passed in {navigator[0]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    engine = parser.add_mutually_exclusive_group(required=True)
    engine.add_argument("--simulator", help="Booted disposable iPhone simulator UDID")
    engine.add_argument("--desktop-engine", choices=["webkit", "chromium"])
    parser.add_argument("--webdriver", default="http://127.0.0.1:4444")
    parser.add_argument("--certificate", type=Path)
    parser.add_argument("--key", type=Path)
    args = parser.parse_args()
    if args.simulator and not (args.certificate and args.key):
        parser.error("The Mobile Safari fixture requires a certificate trusted by the simulator")
    if not (args.bundle / "app" / "profile.html").is_file():
        parser.error("Package the PWA bundle first")
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(FixtureHandler, directory=args.bundle)) as fixture:
        fixture.offline = False
        scheme = "http"
        if args.certificate:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(args.certificate, args.key)
            fixture.socket = context.wrap_socket(fixture.socket, server_side=True)
            scheme = "https"
        origin = f"{scheme}://127.0.0.1:{fixture.server_port}"
        server = Thread(target=fixture.serve_forever, daemon=True)
        server.start()
        browser = None
        try:
            browser = (SafariSession(args.webdriver, args.simulator) if args.simulator
                       else DesktopSession(args.desktop_engine))
            exercise(browser, fixture, origin, bool(args.simulator))
        finally:
            try:
                if browser:
                    browser.close()
            finally:
                fixture.shutdown()
                server.join()


if __name__ == "__main__":
    main()
