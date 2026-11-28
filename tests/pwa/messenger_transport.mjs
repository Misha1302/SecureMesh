// Real browser MLS WASM with an in-process fixture for the native HTTP wire contract.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mock } from "node:test";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
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
let omitChats = false;
let malformedTail = false;
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
      assert.equal(invitations.get(data.invitationId)?.recipient, username);
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
      if (omitChats) return [];
      const result = [...groups].filter(([, group]) => group.members.includes(username))
        .map(([id, group]) => {
          const peerName = group.members.find((name) => name !== username);
          const peer = clients.get(peerName).own;
          return { id, peerName, peerDevice: peer.identity,
            peerKey: replaceKey ? initialized.result.public_key : peer.public_key };
        });
      if (malformedTail) result.push({ id: "malformed" });
      return result;
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
    api(path, data, _method, handoff) {
      return handoff ? handoff(() => api(path, data)) : api(path, data);
    },
    state: () => stored,
    async handoff(check, send) {
      await check((op, fields) =>
        JSON.parse(execute(stored.snapshot, JSON.stringify({ ...fields, op }))).result);
      return send();
    },
    async update(mutate) {
      const draft = structuredClone(stored);
      mutate(draft);
      stored = draft;
    },
    async run(op, fields, mutate) {
      const result = JSON.parse(execute(stored.snapshot, JSON.stringify({ ...fields, op })));
      if (op === "directory_consent" || op === "keypackage") packages.set(device, result.result);
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
await assert.rejects(b.join({ ...welcome, reference: alice.own.public_key }), { code: "invitation" });
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
assert.equal(alice.ctx.state().messenger.chats[group].receivedCount ?? 0, 0);
assert(!Buffer.from(sendCalls[0].ciphertext, "base64").includes("first queue entry"));

wrongSender = true;
await assert.rejects(b.tick(), { code: "invalid-envelope" });
assert.equal(bob.ctx.state().messenger.chats[group].cursor, "");
assert.deepEqual(bob.ctx.state().messenger.chats[group].messages, []);
wrongSender = false;
const second = await a.send(group, "second queue entry");
const blockedRetry = structuredClone(alice.ctx.state().messenger.outbox[second]);
const apiBeforeBlock = alice.ctx.api;
alice.ctx.api = (path, ...args) => {
  if (path === "/v1/messages")
    throw Object.assign(new Error("delivery paused"), { code: "CONVERSATION_MESSAGES_BLOCKED", status: 409 });
  return apiBeforeBlock(path, ...args);
};
await assert.rejects(reopened.tick(), { code: "CONVERSATION_MESSAGES_BLOCKED" });
assert.deepEqual(alice.ctx.state().messenger.outbox[second], blockedRetry);
assert.equal(alice.ctx.state().messenger.chats[group].messages.at(-1).status, "queued");
alice.ctx.api = apiBeforeBlock;
await reopened.tick();
assert.equal(sendCalls.at(-1).ciphertext, blockedRetry.ciphertext);
assert.equal(sendCalls.at(-1).clientMessageId, second);
bob.failOn(second);
await assert.rejects(b.tick(), /vault write failure/);
assert.equal(bob.ctx.state().messenger.chats[group].cursor, "");
assert.deepEqual(bob.ctx.state().messenger.chats[group].messages.map((message) => message.text),
  ["first queue entry 🔐"]);
assert.equal(bob.ctx.state().messenger.chats[group].receivedCount, 1);
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
assert.equal(bob.ctx.state().messenger.chats[group].receivedCount, 3);
assert.equal(alice.ctx.state().messenger.chats[group].receivedCount, 1);
assert.equal(placeholder.id, unsupported);
assert.equal(placeholder.status, "unsupported");
assert(placeholder.text.includes("Зашифрованное"));
assert(!placeholder.text.includes("fixture plaintext"));

const queuedBeforeChange = await reopened.send(group, "durable pre-conflict draft");
const attemptsBeforeChange = sendCalls.length;
assert(reopened.canViewPeer(group));
let profileCleared = false;
alice.ctx.onBindingConflict = id => {
  assert.equal(id, group);
  assert.equal(reopened.canViewPeer(group), false);
  assert(!alice.ctx.state().messenger.chats[group].bindingConflict);
  profileCleared = true;
};
replaceKey = true;
await reopened.refresh();
delete alice.ctx.onBindingConflict;
assert(profileCleared);
assert.equal(reopened.canViewPeer(group), false);
await assert.rejects(reopened.send(group, "blocked"), { code: "changed-key" });
assert.equal(alice.ctx.state().messenger.chats[group].peerKey, bob.own.public_key);

const afterConflict = createMessenger(alice.ctx);
omitChats = true;
await afterConflict.tick();
assert.equal(sendCalls.length, attemptsBeforeChange);
assert(alice.ctx.state().messenger.outbox[queuedBeforeChange]);
const originalCode = await fingerprint(bob.own.public_key);
await assert.rejects(afterConflict.reconfirmChat(group, originalCode), {code: "changed-key"});
omitChats = false;
await assert.rejects(afterConflict.reconfirmChat(group, originalCode), {code: "changed-key"});
replaceKey = false;
await afterConflict.refresh();
await assert.rejects(afterConflict.send(group, "still blocked"), {code: "changed-key"});
await assert.rejects(afterConflict.reconfirmChat(group, "bad"), {code: "verification"});
await afterConflict.reconfirmChat(group, originalCode);
await afterConflict.tick();
assert(!alice.ctx.state().messenger.outbox[queuedBeforeChange]);
assert.equal(alice.ctx.state().messenger.chats[group].peerKey, bob.own.public_key);

// The account layer can suspend actual network handoff after the outbox was selected.
const delayed = await afterConflict.send(group, "queued before the actual HTTP handoff");
const beforeDelay = sendCalls.length;
const realApi = alice.ctx.api;
let unblock, seen;
const waitForSend = new Promise((resolve) => { seen = resolve; });
const allowSend = new Promise((resolve) => { unblock = resolve; });
alice.ctx.api = async (...args) => {
  if (args[0] === "/v1/messages") {
    seen();
    await allowSend;
  }
  return realApi.apply(alice.ctx, args);
};
const withDelay = createMessenger(alice.ctx);
const draining = withDelay.tick();
await waitForSend;
replaceKey = true;
await withDelay.refresh();
unblock();
await assert.rejects(draining, { code: "changed-key" });
assert.equal(sendCalls.length, beforeDelay);
assert(alice.ctx.state().messenger.outbox[delayed]);
alice.ctx.api = realApi;

// A newer conflicting observation cannot be erased by a suspended reconfirmation.
replaceKey = false;
let verified, finish;
const checkingPin = new Promise((resolve) => { verified = resolve; });
const finishPin = new Promise((resolve) => { finish = resolve; });
const realRun = alice.ctx.run;
alice.ctx.run = async (...args) => {
  if (args[0] === "peer_key_status") {
    verified();
    await finishPin;
  }
  return realRun.apply(alice.ctx, args);
};
const verifying = createMessenger(alice.ctx);
const clearing = verifying.reconfirmChat(group, originalCode);
await checkingPin;
replaceKey = true;
await verifying.refresh();
finish();
await assert.rejects(clearing, { code: "changed-key" });
assert(alice.ctx.state().messenger.chats[group].bindingConflict);
alice.ctx.run = realRun;
replaceKey = false;
const restored = createMessenger(alice.ctx);
await restored.reconfirmChat(group, originalCode);

// A malformed later directory row must not discard an already observed conflict.
replaceKey = true;
malformedTail = true;
await assert.rejects(restored.refresh(), { code: "format" });
assert(alice.ctx.state().messenger.chats[group].bindingConflict);
assert.equal(sendCalls.length, beforeDelay);
replaceKey = false;
malformedTail = false;
await restored.reconfirmChat(group, originalCode);

// A pin conflict observed during a sealed upload must still stop the MLS
// descriptor before it can leave the browser. Retry retains the exact bytes.
const photoId = randomUUID(), blobId = randomUUID();
await alice.ctx.run("queue", {group, id: photoId, blobId, text: "Фото", photo: "AA=="}, (draft, entry) => {
  draft.messenger.outbox[photoId] = entry;
  draft.messenger.chats[group].messages.push({id: photoId, direction: "outgoing", text: "Фото"});
});
const queuedPhoto = structuredClone(alice.ctx.state().messenger.outbox[photoId]);
const blobPath = `/v1/conversations/${group}/blobs/${blobId}`;
let uploaded = 0;
alice.ctx.api = (path, data, method, guard) => {
  if (path !== blobPath) return realApi(path, data, method, guard);
  assert.equal(method, "PUT");
  assert.equal(Buffer.from(data).toString("base64"), queuedPhoto.photo.sealed);
  return guard(async () => {
    uploaded++;
    omitChats = false;
    replaceKey = true;
    await restored.refresh();
  });
};
await assert.rejects(restored.tick(), {code: "changed-key"});
assert.equal(uploaded, 1);
assert.equal(sendCalls.length, beforeDelay + 1); // Earlier text drained before the photo.
assert.deepEqual(alice.ctx.state().messenger.outbox[photoId], queuedPhoto);
await restored.tick();
assert.equal(uploaded, 1);
replaceKey = false;
await restored.reconfirmChat(group, originalCode);
alice.ctx.api = realApi;

// Even a queued, valid ciphertext cannot leave a restored snapshot missing its original pin.
await alice.ctx.update((draft) => {
  const saved = JSON.parse(draft.snapshot);
  const profile = saved.profile ?? saved;
  assert(profile.pins[bob.own.identity]);
  delete profile.pins[bob.own.identity];
  draft.snapshot = JSON.stringify(saved);
});
await assert.rejects(restored.tick(), { code: "changed-key" });
assert(alice.ctx.state().messenger.chats[group].bindingConflict);
assert(alice.ctx.state().messenger.outbox[photoId]);
assert.equal(sendCalls.length, beforeDelay + 1);

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

// A real native SQLCipher/OpenMLS client creates the Welcome, sealed photo,
// and MLS application event. The browser WASM joins and opens that payload.
const nativeRecipient = client("native_recipient");
const nativeProcess = spawn("python3", [new URL("./native_photo_fixture.py", import.meta.url).pathname], {
  stdio: ["pipe", "pipe", "pipe"],
});
const nativeLines = createInterface({ input: nativeProcess.stdout });
let nativeStderr = "";
nativeProcess.stderr.setEncoding("utf8").on("data", (chunk) => { nativeStderr += chunk; });
const nextNativeLine = () => new Promise((resolve, reject) => {
  nativeLines.once("line", resolve);
  nativeProcess.once("error", reject);
  nativeProcess.once("exit", (code) => {
    if (code !== 0) reject(new Error(`Native attachment fixture exited ${code}: ${nativeStderr}`));
  });
});
const nativeStart = JSON.parse(await nextNativeLine());
await nativeRecipient.ctx.run("pin", {
  identity: nativeStart.sender, public_key: nativeStart.senderKey, confirmed: true,
});
const nativeConsent = await nativeRecipient.ctx.run("directory_consent", {
  invitation: nativeStart.invitation, sender: nativeStart.sender,
  senderKey: nativeStart.senderKey, confirmed: true,
});
nativeProcess.stdin.write(JSON.stringify({
  recipient: nativeRecipient.own.identity,
  recipientKey: nativeRecipient.own.public_key,
  keypackage: nativeConsent.keypackage,
  reference: nativeConsent.reference,
}) + "\n");
const nativePhoto = JSON.parse(await nextNativeLine());
nativeProcess.stdin.end();
if (nativeProcess.exitCode === null) await once(nativeProcess, "exit");
assert.equal(nativeProcess.exitCode, 0);
const { bootstrap, group: nativeGroup, id: nativeMessageId, envelope: nativeEnvelope,
  sealed: nativeSealed, plain: nativePlain } = nativePhoto;
assert.equal(bootstrap.binding.sender, nativeStart.sender);
assert.equal(bootstrap.binding.reference, nativeConsent.reference);
const nativeJoined = JSON.parse(execute(nativeRecipient.ctx.state().snapshot, JSON.stringify({
  op: "directory_join", group: nativeGroup, invitation: nativeStart.invitation,
  lease: nativeStart.lease, sender: nativeStart.sender,
  recipient: nativeRecipient.own.identity, reference: nativeConsent.reference,
  welcome: bootstrap.welcome, signature: bootstrap.signature,
})));
await nativeRecipient.ctx.update((draft) => { draft.snapshot = nativeJoined.snapshot; });
const nativeMessage = await nativeRecipient.ctx.run("process", {
  group: nativeGroup, id: nativeMessageId, sender: nativeStart.sender,
  kind: nativeEnvelope.kind, epoch: nativeEnvelope.epoch,
  ciphertext: nativeEnvelope.ciphertext,
});
assert.equal(nativeMessage.attachment.media, "photo");
assert.equal(nativeMessage.attachment.name, "native-photo.png");
assert.equal(nativeMessage.attachment.caption, "Native to browser");
const openedNativePhoto = await nativeRecipient.ctx.run("attachment_open", {
  group: nativeGroup, id: nativeMessageId, attachment: nativeMessage.attachment,
  ciphertext: nativeSealed,
});
assert.equal(openedNativePhoto.data, nativePlain);
const corruptNative = Buffer.from(nativeSealed, "base64");
corruptNative[corruptNative.length - 1] ^= 1;
await assert.rejects(nativeRecipient.ctx.run("attachment_open", {
  group: nativeGroup, id: nativeMessageId, attachment: nativeMessage.attachment,
  ciphertext: corruptNative.toString("base64"),
}));
await assert.rejects(nativeRecipient.ctx.run("attachment_open", {
  group: nativeGroup, id: randomUUID(), attachment: nativeMessage.attachment,
  ciphertext: nativeSealed,
}));
await assert.rejects(nativeRecipient.ctx.run("attachment_open", {
  group: nativeGroup, id: nativeMessageId,
  attachment: { ...nativeMessage.attachment, media: "file" }, ciphertext: nativeSealed,
}));
// Prior releases kept the consent only in the outer encrypted vault and
// published into the recipient's unscoped package pool.
for (const pooledMismatch of [false, true]) {
  const label = pooledMismatch ? "mismatch" : "matched";
  const senderName = "sender_" + label, recipientName = "legacy_" + label;
  const sender = client(senderName), recipient = client(recipientName);
  const send = createMessenger(sender.ctx), receive = createMessenger(recipient.ctx);
  const invitation = await send.invite(recipientName);
  const code = await fingerprint(sender.own.public_key);
  await recipient.ctx.run("pin", { ...sender.own, confirmed: true });
  const pkg = await recipient.ctx.run("keypackage", {});
  await recipient.ctx.update((draft) => {
    draft.messenger = { chats: {}, invites: {}, proposals: {}, outbox: {}, accepted: {
      [invitation]: { peerDevice: sender.own.identity, peerKey: sender.own.public_key,
        peerName: senderName, ...pkg, posted: true },
    }};
    const legacy = JSON.parse(draft.snapshot);
    legacy.version = 1;
    delete legacy.consents;
    draft.snapshot = JSON.stringify(legacy);
  });
  await recipient.ctx.api(`/v1/chat-requests/${invitation}/accept`, {});
  if (pooledMismatch) await recipient.ctx.run("keypackage", {});
  const [row] = (await send.refresh()).requests;
  const group = await send.establish(row, await fingerprint(recipient.own.public_key));
  const [welcome] = (await receive.refresh()).welcomes;
  if (pooledMismatch) {
    await assert.rejects(receive.join(welcome, code), { code: "invitation" });
    assert.equal(recipient.ctx.state().messenger.chats[group], undefined);
    assert(groups.get(group).pending);
  } else {
    await assert.rejects(receive.join(welcome), { code: "verification" });
    await assert.rejects(receive.join(welcome, "wrong"), { code: "verification" });
    assert.equal(await receive.join(welcome, code), group);
    await recipient.ctx.update((draft) => {
      // A previously joined v1 group can replay the identical signed receipt.
      const legacy = JSON.parse(draft.snapshot);
      legacy.version = 1;
      delete legacy.consents;
      draft.snapshot = JSON.stringify(legacy);
      delete draft.messenger.accepted[invitation].coreConsent;
    });
    assert.equal(await createMessenger(recipient.ctx).join(welcome), group);
  }
}
console.log("Browser messenger transport passed with real WASM");
