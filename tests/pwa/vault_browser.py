"""Exercise real WebCrypto and IndexedDB with python tests/pwa/vault_browser.py."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from playwright.sync_api import sync_playwright


class QuietHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<!doctype html><title>SecureMesh Vault Test</title>")
        elif self.path == "/app/vault.js":
            super().do_GET()
        else:
            self.send_error(404)

    def log_message(self, *_):
        pass


def run(origin):
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        context = browser.new_context()
        page = context.new_page()
        other = context.new_page()
        for tab in (page, other):
            tab.goto(origin)
        page.evaluate(
            """async () => {
              const vault = await import("/app/vault.js");
              window.vault = vault;
              window.password = "👨‍👩‍👧‍👦".repeat(16);
              window.assert = (condition, label) => {
                if (!condition) throw new Error(label);
              };
              window.expectError = async (func, code) => {
                try { await func(); } catch (error) {
                  if (error.code === code) return;
                  throw error;
                }
                throw new Error("Expected " + code);
              };
              assert(!(await vault.hasVault()), "fresh origin");
              await expectError(() => vault.unlockVault(password), "missing");
              await expectError(() => vault.createVault("👨‍👩‍👧‍👦".repeat(15), {}), "password");
              const state = {
                snapshot: "plaintext-wasm-snapshot", outbox: ["initial"], cursor: 1,
              };
              window.profile = await vault.createVault(password, state);
              assert(await vault.hasVault(), "created profile");
              await expectError(() => vault.createVault(password, {}), "exists");
              await expectError(() => vault.unlockVault("wrong password test value"), "authentication");
              window.readRecord = () => new Promise((resolve, reject) => {
                const request = indexedDB.open("securemesh-profile");
                request.onerror = () => reject(request.error);
                request.onsuccess = () => {
                  const db = request.result;
                  const tx = db.transaction("vault");
                  const read = tx.objectStore("vault").get("profile");
                  tx.onabort = () => reject(tx.error);
                  tx.oncomplete = () => { db.close(); resolve(read.result); };
                };
              });
              const stored = await readRecord();
              assert(Object.keys(stored).sort().join() === "ciphertext,format,iv,revision,salt,version",
                "only encrypted record");
              assert(!JSON.stringify(stored).includes(state.snapshot), "no plaintext in database");
              window.firstIv = stored.iv;
            }"""
        )
        other.evaluate(
            """async () => {
              window.vault = await import("/app/vault.js");
              window.profile = await vault.unlockVault("👨‍👩‍👧‍👦".repeat(16));
            }"""
        )
        page.evaluate(
            """async () => {
              const first = vault.commitVault(profile, { snapshot: "next", outbox: ["queued"], cursor: 2 });
              const second = vault.commitVault(profile, { snapshot: "other", outbox: [], cursor: 3 });
              const results = await Promise.allSettled([first, second]);
              assert(results.filter((entry) => entry.status === "fulfilled").length === 1, "one winning commit");
              assert(results.filter((entry) => entry.reason?.code === "conflict").length === 1, "one conflict");
              assert(profile.revision === 1, "revision advances once");
              assert((await readRecord()).iv !== firstIv, "fresh IV per commit");
            }"""
        )
        other.evaluate(
            """async () => {
              try {
                await vault.commitVault(profile, { snapshot: "stale", outbox: [], cursor: 4 });
              } catch (error) {
                if (error.code === "conflict") return;
                throw error;
              }
              throw new Error("stale tab overwrote profile");
            }"""
        )
        expected = page.evaluate("JSON.stringify(profile.state)")
        page.reload()
        persisted = page.evaluate(
            """async () => {
              const vault = await import("/app/vault.js");
              const handle = await vault.unlockVault("👨‍👩‍👧‍👦".repeat(16));
              const state = JSON.stringify(handle.state);
              vault.closeVault(handle);
              if (handle.state !== undefined) throw new Error("closed state remains accessible");
              try {
                await vault.commitVault(handle, {});
              } catch (error) {
                if (error.code === "locked") return state;
                throw error;
              }
              throw new Error("closed session remained active");
            }"""
        )
        assert persisted == expected
        backup = page.evaluate(
            """async () => {
              const vault = await import("/app/vault.js");
              return vault.exportBackup("archive password string", { messages: ["private transcript"] });
            }"""
        )
        restored = browser.new_context().new_page()
        restored.goto(origin)
        restored.evaluate(
            """async (backup) => {
              const vault = await import("/app/vault.js");
              const password = "archive password string";
              const reject = async (func, code) => {
                try { await func(); } catch (error) {
                  if (error.code === code) return;
                  throw error;
                }
                throw new Error("Expected " + code);
              };
              const record = JSON.parse(backup);
              await reject(() => vault.importVault(password, "{"), "format");
              await reject(() => vault.importVault(password, "a".repeat(vault.maxBackupLength + 1)), "size");
              await reject(() => vault.importVault(password, JSON.stringify({ ...record, version: 2 })), "format");
              await reject(() => vault.importVault(password, JSON.stringify({ ...record, revision: 1 })), "authentication");
              const corrupted = (record.ciphertext[0] === "A" ? "B" : "A") + record.ciphertext.slice(1);
              await reject(() => vault.importVault(password, JSON.stringify({ ...record, ciphertext: corrupted })), "authentication");
              await reject(() => vault.importVault(password, backup, () => false), "format");
              if (await vault.hasVault()) throw new Error("invalid backup created local profile");
              const handle = await vault.importVault(password, backup, (state) => Array.isArray(state.messages));
              if (handle.state.messages[0] !== "private transcript") throw new Error("lost restored data");
              await reject(() => vault.importVault(password, backup), "exists");
            }""",
            backup,
        )
        browser.close()


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=root / "site")) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run(f"http://127.0.0.1:{server.server_port}")
        finally:
            server.shutdown()
            thread.join()
    print("Browser vault tests passed")
