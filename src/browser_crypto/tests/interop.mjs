import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomUUID, webcrypto } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../../", import.meta.url));
const native = resolve(process.argv[2] ?? join(root, "src/crypto_core/target/debug/securemesh-crypto"));
const bundle = resolve(process.argv[3] ?? join(root, "site/app/crypto"));
const source = readFileSync(join(bundle, "securemesh_browser_crypto.js")).toString("base64");
const { default: init, execute, derive_server_credential_v2 } = await import(`data:text/javascript;base64,${source}`);
globalThis.crypto ??= webcrypto;
await init({ module_or_path: readFileSync(join(bundle, "securemesh_browser_crypto_bg.wasm")) });

const kdf = { op: "derive_server_credential_v2", endpoint: "https://example.org",
  username: "marina_24", password: "  Пароль-🔑 phrase  " };
assert.equal(derive_server_credential_v2(kdf.endpoint, kdf.username, kdf.password),
  "6o6VxV36UehxRt6qSoL6b2PpP8FxoiHtEQ/oG8NHl4s=");
assert.throws(() => derive_server_credential_v2(kdf.endpoint, kdf.username, "too short"));

const directory = mkdtempSync(join(tmpdir(), "securemesh-browser-interop-"));
const database = join(directory, "native.db");
const passphrase = randomUUID();
let snapshot;
function browser(request) {
  const response = JSON.parse(execute(snapshot, JSON.stringify(request)));
  snapshot = response.snapshot;
  return response.result;
}

function client(args, request) {
  const result = spawnSync(native, args, { input: JSON.stringify(request), encoding: "utf8" });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function device(request) {
  return client([database], { ...request, passphrase });
}

function deliver(receive, sender, envelope, override = {}) {
  return receive({ ...envelope, op: "process", sender, ...override });
}

try {
  const alice = browser({ op: "init", identity: randomUUID() });
  const bob = device({ op: "init", identity: randomUUID() });
  assert.deepEqual(browser({ op: "identity" }), alice);
  assert.equal(device(kdf).credential, derive_server_credential_v2(kdf.endpoint, kdf.username, kdf.password));

  const pin = { op: "pin", ...bob };
  assert.throws(() => browser(pin), /verification required/);
  browser({ ...pin, confirmed: true });
  assert.throws(() => browser({ ...pin, public_key: alice.public_key, confirmed: true }), /KEY_CHANGED_REJECTED/);
  device({ op: "pin", ...alice, confirmed: true });

  for (const senderIsBrowser of [true, false]) {
    const prepare = senderIsBrowser ? browser : device;
    const accept = senderIsBrowser ? device : browser;
    const sender = senderIsBrowser ? alice : bob;
    const recipient = senderIsBrowser ? bob : alice;
    const invitation = randomUUID();
    if (senderIsBrowser) {
      device({ op: "directory_consent", confirmed: true, invitation,
        sender: sender.identity, senderKey: sender.public_key, username: "alice" });
    }
    const packageResponse = senderIsBrowser
      ? device({ op: "directory_consent_package", invitation })
      : browser({ op: "keypackage" });
    const { reference } = client(["--validate-keypackage"], { ...recipient, ...packageResponse });
    if (packageResponse.reference) assert.equal(packageResponse.reference, reference);
    const request = { op: "directory_prepare", invitation, lease: randomUUID(),
      recipient: recipient.identity, keypackage: packageResponse.keypackage, reference };
    const invite = prepare(request);
    assert.deepEqual(prepare(request), invite);
    const join = { ...invite.binding, op: "directory_join", signature: invite.signature };
    assert.throws(() => accept({ ...join, lease: randomUUID() }));
    if (!senderIsBrowser) {
      assert.throws(() => accept({ ...join, reference: alice.public_key }), /Welcome KeyPackage reference mismatch/);
    }
    if (!senderIsBrowser) {
      assert.throws(() => accept(join), /local invitation consent required/);
      const receipt = { op: "directory_consent", invitation, sender: sender.identity,
        senderKey: sender.public_key, keypackage: packageResponse.keypackage, reference };
      assert.throws(() => browser(receipt), /explicit recipient consent/);
      assert.throws(() => browser({ ...receipt, confirmed: true, reference: sender.public_key }), /legacy consent package mismatch/);
      browser({ ...receipt, confirmed: true });
      assert.throws(() => browser({ ...receipt, confirmed: true, invitation: randomUUID() }), /package already bound/);
    }
    assert.equal(accept(join).epoch, 1);
    assert.equal(accept(join).already_joined, true);

    for (const outboundIsBrowser of [true, false]) {
      const queue = outboundIsBrowser ? browser : device;
      const receive = outboundIsBrowser ? device : browser;
      const author = outboundIsBrowser ? alice : bob;
      const peer = outboundIsBrowser ? bob : alice;
      const body = { id: randomUUID(), group: invite.id, text: "Привет, iPhone 🔐" };
      const envelope = queue({ op: "queue", ...body });
      assert.equal(envelope.kind, 1);
      assert.equal(envelope.epoch, 1);
      assert(!Buffer.from(envelope.ciphertext, "base64").includes(body.text));
      if (!outboundIsBrowser) {
        assert.throws(() => deliver(receive, author.identity, envelope, { id: randomUUID() }), /message binding mismatch/);
        assert.throws(() => deliver(receive, peer.identity, envelope), /sender mismatch|cannot decrypt/i);
        assert.throws(() => deliver(receive, author.identity, envelope, { epoch: 2 }), /epoch mismatch/);
      }
      const received = deliver(receive, author.identity, envelope);
      for (const [key, value] of Object.entries(body)) assert.equal(received[key], value);
      assert.throws(() => deliver(receive, author.identity, envelope));
    }

    const rekey = device({ op: "stage_rekey", group: invite.id, id: randomUUID() });
    device({ op: "commit_saved", group: invite.id, id: rekey.id, seq: 3 });
    assert.deepEqual(deliver(browser, bob.identity, rekey), { epoch: 2, active: true });
    const afterRekey = browser({ op: "queue", group: invite.id, id: randomUUID(), text: "new epoch" });
    assert.equal(afterRekey.epoch, 2);
    assert.equal(deliver(device, alice.identity, afterRekey).text, "new epoch");
  }
  console.log("WASM/native MLS interoperability passed in both initiation and messaging directions");
} finally {
  rmSync(directory, { recursive: true, force: true });
}
