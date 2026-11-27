// Real browser MLS WASM with an in-process fixture for the native HTTP wire contract.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mock } from "node:test";
import { createMessenger, fingerprint } from "../../site/app/messenger.js";
import init, { execute } from "../../site/app/crypto/securemesh_browser_crypto.js";

await init({ module_or_path: readFileSync(new URL("../../site/app/crypto/securemesh_browser_crypto_bg.wasm", import.meta.url)) });

const invitations = new Map();
const groups = new Map();
const packages = new Map();
const clients = new Map();
let loseAck = false;
let wrongSender = false;
let replaceKey = false;
let sendCalls = [];
const digest = (ciphertext) => createHash("sha256").update(Buffer.from(ciphertext, "base64")).digest("base64");

function client(username) {
  const device = randomUUID();
  const initialized = JSON.parse(execute(undefined, JSON.stringify({ op: "init", identity: device })));
  let stored = { snapshot: initialized.snapshot, identity: initialized.result };
  let failProcess;
  let unsupportedProcess;
  async function api(path, data) {
    const { pathname, searchParams } = new URL(path, "https://api.example");
    if (path === "/v1/chat-requests") {
      if (data) {
        invitations.set(data.id, { sender: username, recipient: data.username });
        return { id: data.id };
      }
      return [...invitations].filter(([, invite]) => [invite.sender, invite.recipient].includes(username))
        .map(([id, invite]) => {
          const outgoing = invite.sender === username;
          const sender = clients.get(invite.sender).own;
          const receiver = invite.accepted ? clients.get(invite.recipient).own : {};
          return { id, username: outgoing ? invite.recipient : invite.sender, outgoing,
            senderDevice: sender.identity, senderKey: sender.public_key, recipientDevice: receiver.identity,
            recipientKey: receiver.public_key, accepted: !!invite.accepted, established: !!invite.group };
        });
    }
    if (pathname.endsWith("/accept")) {
      invitations.get(pathname.split("/")[3]).accepted = true;
      return null;
    }
    if (path === "/v1/crypto/keypackages") {
      // The real database stores the validated reference. The fixture receives
      // the WASM result separately below and checks the published package bytes.
      const published = packages.get(device);
      assert.equal(data.payload, published.keypackage);
      return { reference: published.reference };
    }
    if (path === "/v1/crypto/keypackages/lease") {
      const invite = invitations.get(data.invitationId);
      assert.equal(invite.sender, username);
      assert(invite.accepted);
      const peer = clients.get(invite.recipient).own;
      invite.lease = data.requestId;
      return { ...packages.get(peer.identity), lease: invite.lease, recipient: peer.identity, publicKey: peer.public_key };
    }
    if (path === "/v1/conversations/establish") {
      const invite = invitations.get(data.invitationId);
      assert.equal(data.leaseId, invite.lease);
      const peer = clients.get(invite.recipient).own;
      invite.group = data.id;
      groups.set(data.id, { members: [username, invite.recipient], rows: [], pending: {
        group: data.id, invitation: data.invitationId, lease: data.leaseId, sender: device,
        senderKey: initialized.result.public_key, recipient: peer.identity,
        reference: packages.get(peer.identity).reference, signature: data.signature, welcome: data.welcome,
      } });
      return { id: data.id };
    }
    if (path === "/v1/crypto/welcomes") {
      return [...groups.values()].map((group) => group.pending).filter((welcome) => welcome?.recipient === device);
    }
    if (pathname.endsWith("/ack")) {
      delete groups.get(pathname.split("/")[4]).pending;
      return null;
    }
    if (path === "/v1/conversations") {
      return [...groups].filter(([, group]) => group.members.includes(username))
        .map(([id, group]) => {
          const peerName = group.members.find((name) => name !== username);
          const peer = clients.get(peerName).own;
          return { id, peerName, peerDevice: peer.identity,
            peerKey: replaceKey ? initialized.result.public_key : peer.public_key };
        });
    }
    if (path === "/v1/messages") {
      sendCalls.push(structuredClone(data));
      assert.deepEqual(Object.keys(data).sort(),
        ["ciphertext", "clientMessageId", "conversationId", "envelopeKind", "mlsEpoch"]);
      const group = groups.get(data.conversationId);
      let row = group.rows.find((message) => message.clientMessageId === data.clientMessageId);
      if (!row) {
        row = { ...data, senderDeviceId: device, serverSequence: group.rows.length + 1,
          serverMessageId: randomUUID(), ciphertextSha256: digest(data.ciphertext) };
        group.rows.push(row);
      } else {
        assert.equal(row.ciphertext, data.ciphertext);
      }
      if (loseAck) {
        loseAck = false;
        throw new Error("simulated response loss");
      }
      return { durable: true, serverSequence: row.serverSequence, serverMessageId: row.serverMessageId };
    }
    if (pathname === "/v1/sync") {
      const group = searchParams.get("conversationId");
      const offset = Number(searchParams.get("cursor") || 0);
      const limit = Number(searchParams.get("limit"));
      const rows = groups.get(group).rows;
      return { conversationId: group, nextCursor: String(Math.min(offset + limit, rows.length)),
        hasMore: rows.length > offset + limit, messages: rows.slice(offset, offset + limit).map((row) => ({
          ...row, senderDeviceId: wrongSender ? randomUUID() : row.senderDeviceId,
          ciphertext: row.senderDeviceId === device ? "" : row.ciphertext,
        })) };
    }
    throw new Error("Unexpected API route " + path);
  }

  const ctx = {
    api,
    state: () => stored,
    async update(mutate) {
      const draft = structuredClone(stored);
      mutate(draft);
      stored = draft;
    },
    async run(op, fields, mutate) {
      const result = JSON.parse(execute(stored.snapshot, JSON.stringify({ ...fields, op })));
      if (op === "keypackage") packages.set(device, result.result);
      if (op === "process" && fields.id === failProcess) throw new Error("simulated vault write failure");
      if (op === "process" && fields.id === unsupportedProcess) {
        // Exercise the WASM caller's authenticated unsupported-event result shape.
        result.result = { unsupported: true };
      }
      await ctx.update((draft) => {
        draft.snapshot = result.snapshot;
        mutate?.(draft, result.result);
      });
      return result.result;
    },
  };
  const record = {
    own: initialized.result, ctx,
    failOn(id) { failProcess = id; },
    unsupportedOn(id) { unsupportedProcess = id; },
  };
  clients.set(username, record);
  return record;
}

const alice = client("alice");
const bob = client("bobby");
const a = createMessenger(alice.ctx);
const b = createMessenger(bob.ctx);
await a.invite("@Bobby");
const incoming = (await b.refresh()).requests[0];
await assert.rejects(b.accept(incoming, "mismatched code"), { code: "verification" });
await b.accept(incoming, await fingerprint(alice.own.public_key));
const accepted = (await a.refresh()).requests[0];
const group = await a.establish(accepted, await fingerprint(bob.own.public_key));
const welcome = (await b.refresh()).welcomes[0];
await assert.rejects(b.join({ ...welcome, senderKey: bob.own.public_key }), { code: "invitation" });
assert.equal(await b.join(welcome), group);

const first = await a.send(group, "first queue entry 🔐");
assert.equal(sendCalls.length, 0);
assert.equal(alice.ctx.state().messenger.outbox[first].kind, 1);
loseAck = true;
await assert.rejects(a.tick(), /response loss/);
assert(alice.ctx.state().messenger.outbox[first]);
// Construct a fresh transport from the committed state between attempts.
const reopened = createMessenger(alice.ctx);
await reopened.tick();
assert.deepEqual(sendCalls[0], sendCalls[1]);
assert.equal(alice.ctx.state().messenger.outbox[first], undefined);
assert.equal(alice.ctx.state().messenger.chats[group].messages[0].status, "saved");
assert(!Buffer.from(sendCalls[0].ciphertext, "base64").includes("first queue entry"));

wrongSender = true;
await assert.rejects(b.tick(), { code: "invalid-envelope" });
assert.equal(bob.ctx.state().messenger.chats[group].cursor, "");
assert.deepEqual(bob.ctx.state().messenger.chats[group].messages, []);
wrongSender = false;
const second = await a.send(group, "second queue entry");
await reopened.tick();
bob.failOn(second);
await assert.rejects(b.tick(), /vault write failure/);
assert.equal(bob.ctx.state().messenger.chats[group].cursor, "");
assert.deepEqual(bob.ctx.state().messenger.chats[group].messages.map((message) => message.text),
  ["first queue entry 🔐"]);
bob.failOn(undefined);
await b.tick();
assert.equal(bob.ctx.state().messenger.chats[group].cursor, "2");
assert.deepEqual(bob.ctx.state().messenger.chats[group].messages.map((message) => message.text),
  ["first queue entry 🔐", "second queue entry"]);

await b.send(group, "reverse direction");
await b.tick();
await reopened.tick();
assert.equal(alice.ctx.state().messenger.chats[group].messages.at(-1).text, "reverse direction");
const unsupported = await a.send(group, "fixture plaintext for hidden event");
bob.unsupportedOn(unsupported);
await reopened.tick();
await b.tick();
const placeholder = bob.ctx.state().messenger.chats[group].messages.at(-1);
assert.equal(placeholder.id, unsupported);
assert.equal(placeholder.status, "unsupported");
assert(placeholder.text.includes("Зашифрованное"));
assert(!placeholder.text.includes("fixture plaintext"));

replaceKey = true;
await reopened.refresh();
await assert.rejects(reopened.send(group, "blocked"), { code: "changed-key" });
assert.equal(alice.ctx.state().messenger.chats[group].peerKey, bob.own.public_key);

// Keep the background directory cadence independent of the active thread and
// prove that every idle group eventually gets a turn in the bounded sync slot.
let now = 1;
mock.method(performance, "now", () => now);
const ids = Array.from({ length: 11 }, () => randomUUID());
const idleState = {
  identity: alice.own,
  messenger: { chats: Object.fromEntries(ids.map((id) => [id, { id, seq: 0, cursor: "" }])) },
};
let paths = [];
let limited = false;
const idle = createMessenger({
  state: () => idleState,
  api: async (path) => {
    paths.push(path);
    if (limited) throw Object.assign(new Error("limited"), { status: 429 });
    if (!path.startsWith("/v1/sync?")) return [];
    const conversationId = new URL(path, "https://fixture.test").searchParams.get("conversationId");
    return { conversationId, messages: [], hasMore: false, nextCursor: "empty" };
  },
});
const syncGroups = (routes) => routes.filter((p) => p.startsWith("/v1/sync?"))
  .map((p) => new URL(p, "https://fixture.test").searchParams.get("conversationId"));
idle.select(ids[0]);
await idle.tick({ forceDirectory: false });
assert.deepEqual(syncGroups(paths), ids.slice(0, 2));
paths = [];
now += 2_500;
await idle.tick({ forceDirectory: false });
assert.deepEqual(paths.length, 1);
assert.deepEqual(syncGroups(paths), [ids[0]]);
paths = [];
await idle.tick();
assert.equal(paths.filter((path) => !path.startsWith("/v1/sync?")).length, 3, "manual refresh must query directory");

const background = new Set(ids.slice(1, 3));
for (let index = 0; index < ids.length; index++) {
  paths = [];
  now += 11_000;
  await idle.tick({ forceDirectory: false });
  const pulled = syncGroups(paths);
  assert(pulled.length <= 2);
  assert.equal(pulled[0], ids[0]);
  if (pulled[1]) background.add(pulled[1]);
}
assert.equal(background.size, ids.length - 1);
limited = true;
await assert.rejects(idle.tick(), { status: 429 });
paths = [];
await assert.rejects(idle.tick({ forceDirectory: false }), { status: 429 });
assert.deepEqual(paths, []);
mock.restoreAll();
console.log("Browser messenger transport passed with real WASM");
