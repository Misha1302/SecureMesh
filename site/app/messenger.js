const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const usernamePattern = /^[a-z0-9_]{3,32}$/;
const empty = Object.freeze({});
const pageSize = 6;

function requireValue(condition, code, message) {
  if (!condition) throw Object.assign(new Error(message), { code });
}

function uuid(value) {
  requireValue(typeof value === "string" && uuidPattern.test(value) &&
    value !== "00000000-0000-0000-0000-000000000000", "format", "Invalid server or device identifier");
  return value;
}

function base64(value, min, max = min) {
  requireValue(typeof value === "string" && value.length <= Math.ceil(max / 3) * 4 &&
    /^[A-Za-z0-9+/]*={0,2}$/.test(value), "format", "Invalid encoded message data");
  const binary = atob(value);
  requireValue(binary.length >= min && binary.length <= max && btoa(binary) === value,
    "format", "Invalid encoded message data");
  return Uint8Array.from(binary, (byte) => byte.charCodeAt(0));
}

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export async function fingerprint(key) {
  const digest = await sha256(base64(key, 32));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("")
    .toUpperCase().match(/.{4}/g).join(" ");
}

async function ciphertextDigest(ciphertext) {
  const digest = await sha256(base64(ciphertext, 1, 32_768));
  return btoa(String.fromCharCode(...digest));
}

function samePeer(left, right) {
  return left?.peerDevice === right.peerDevice && left?.peerKey === right.peerKey &&
    left?.peerName === right.peerName;
}

function peerInfo(device, key, name) {
  uuid(device);
  base64(key, 32);
  requireValue(typeof name === "string" && usernamePattern.test(name),
    "format", "Invalid contact username");
  return { peerDevice: device, peerKey: key, peerName: name };
}

function transport(state) {
  return state.messenger ??= { chats: {}, invites: {}, accepted: {}, proposals: {}, outbox: {} };
}

function sameEnvelope(left, right) {
  return left.id === right.id && left.sender === right.sender && left.seq === right.seq &&
    left.serverId === right.serverId && left.kind === right.kind && left.epoch === right.epoch &&
    left.digest === right.digest;
}

export function createMessenger(ctx) {
  let running = false;
  let generation = 0;
  let timer;
  let activeTick;
  let directory;
  const remoteBlocked = new Set();

  const state = () => ctx.state()?.messenger ?? empty;
  const readChat = (id) => {
    const chat = state().chats?.[uuid(id)];
    requireValue(chat, "unknown-chat", "This conversation has not been verified");
    return chat;
  };

  function ensureUsable(chat) {
    requireValue(chat.active !== false, "inactive-chat", "This conversation is inactive");
    requireValue(!remoteBlocked.has(chat.id), "changed-key", "The conversation contact changed");
  }

  async function identity() {
    const saved = ctx.state()?.identity;
    return uuid(saved?.identity ?? saved?.deviceId ?? (await ctx.run("identity", {})).identity);
  }

  async function pin(peer, entered, alreadyBound = false) {
    const fields = { identity: peer.peerDevice, public_key: peer.peerKey };
    const { status } = await ctx.run("peer_key_status", fields);
    requireValue(status === "unknown" || status === "matches", "changed-key", "The contact device key changed");
    if (alreadyBound && !entered) {
      requireValue(status === "matches", "verification", "The contact device key must be verified");
      return;
    }
    const enteredCode = typeof entered === "string" && entered.length <= 256
      ? entered.replace(/\s+/gu, "").toUpperCase() : "";
    requireValue(enteredCode === (await fingerprint(peer.peerKey)).replaceAll(" ", ""),
      "verification", "Enter the contact device code received through a trusted channel");
    if (status === "unknown") await ctx.run("pin", { ...fields, confirmed: true });
  }

  async function refresh() {
    const [requests, welcomes, chats] = await Promise.all([
      ctx.api("/v1/chat-requests"),
      ctx.api("/v1/crypto/welcomes"),
      ctx.api("/v1/conversations"),
    ]);
    requireValue(Array.isArray(requests) && requests.length <= 100 &&
      Array.isArray(welcomes) && welcomes.length <= 20 && Array.isArray(chats) && chats.length <= 100,
      "format", "Invalid conversation directory");
    for (const row of chats) {
      const chat = state().chats?.[uuid(row.id)];
      if (chat && !samePeer(chat, row)) remoteBlocked.add(row.id);
    }
    directory = { requests, welcomes, chats };
    return directory;
  }

  async function postInvitation(row) {
    const response = await ctx.api("/v1/chat-requests", row);
    requireValue(response?.id === row.id, "format", "Invalid invitation response");
    await ctx.update((draft) => { delete transport(draft).invites[row.id]; });
  }

  async function invite(input) {
    const username = input.trim().replace(/^@/, "").toLowerCase();
    requireValue(usernamePattern.test(username), "username", "Use 3–32 lowercase letters, numbers or underscores");
    let row;
    await ctx.update((draft) => {
      const data = transport(draft);
      row = Object.values(data.invites).find((saved) => saved.username === username) ??
        { id: crypto.randomUUID(), username };
      data.invites[row.id] = row;
    });
    await postInvitation(row);
    return row.id;
  }

  async function postAccept(id, accepted) {
    const result = await ctx.api("/v1/crypto/keypackages", { payload: accepted.keypackage });
    requireValue(result?.reference === accepted.reference, "format", "Invalid key package publication response");
    await ctx.api(`/v1/chat-requests/${id}/accept`, {});
    await ctx.update((draft) => { transport(draft).accepted[id].posted = true; });
  }

  async function accept(request, code) {
    const id = uuid(request.id);
    requireValue(request.outgoing === false, "invitation", "This is not an incoming invitation");
    const peer = peerInfo(request.senderDevice, request.senderKey, request.username);
    const existing = state().accepted?.[id];
    requireValue(!existing || samePeer(existing, peer), "changed-key", "The invitation sender changed");
    await pin(peer, code, Boolean(existing));
    if (!existing) {
      await ctx.run("keypackage", {}, (draft, result) => {
        const accepted = transport(draft).accepted;
        requireValue(!accepted[id] || samePeer(accepted[id], peer),
          "changed-key", "The invitation sender changed");
        accepted[id] ??= { ...peer, keypackage: result.keypackage, reference: result.reference, posted: false };
      });
    }
    const pending = state().accepted[id];
    if (!pending.posted) await postAccept(id, pending);
    return id;
  }

  function saveChat(draft, id, peer, welcomePending) {
    const chats = transport(draft).chats;
    requireValue(!chats[id] || samePeer(chats[id], peer), "changed-key", "The conversation identity changed");
    chats[id] ??= { ...peer, id, messages: [], cursor: "", seq: 0, epoch: 1, envelopes: {}, welcomePending };
  }

  async function postEstablish(id, proposal) {
    const { id: group, invitationId, leaseId, welcome, signature } = proposal.prepared;
    const result = await ctx.api("/v1/conversations/establish", {
      id: group, invitationId, leaseId, welcome, signature,
    });
    requireValue(result?.id === group, "format", "Invalid conversation bootstrap response");
    await ctx.update((draft) => {
      saveChat(draft, group, proposal, false);
      transport(draft).proposals[id].posted = true;
    });
    return group;
  }

  async function establish(request, code) {
    const id = uuid(request.id);
    requireValue(request.outgoing === true && request.accepted === true &&
      request.senderDevice === await identity(), "invitation", "An accepted outgoing invitation is required");
    const peer = peerInfo(request.recipientDevice, request.recipientKey, request.username);
    const existing = state().proposals?.[id];
    requireValue(!existing || samePeer(existing, peer), "changed-key", "The invitation recipient changed");
    await pin(peer, code, Boolean(existing));
    if (!existing) {
      await ctx.update((draft) => {
        const proposals = transport(draft).proposals;
        requireValue(!proposals[id] || samePeer(proposals[id], peer),
          "changed-key", "The invitation recipient changed");
        proposals[id] ??= { ...peer, lease: crypto.randomUUID() };
      });
    }
    const proposal = state().proposals[id];
    if (proposal.posted) return proposal.prepared.id;
    if (!proposal.prepared) {
      const packageReply = await ctx.api("/v1/crypto/keypackages/lease", {
        invitationId: id, requestId: proposal.lease,
      });
      requireValue(packageReply?.lease === proposal.lease && packageReply.recipient === peer.peerDevice &&
        packageReply.publicKey === peer.peerKey, "changed-key", "Key package coordinates do not match the verified contact");
      await ctx.run("directory_prepare", {
        invitation: id, lease: proposal.lease, recipient: peer.peerDevice,
        reference: packageReply.reference, keypackage: packageReply.keypackage,
      }, (draft, prepared) => { transport(draft).proposals[id].prepared = prepared; });
    }
    return postEstablish(id, state().proposals[id]);
  }

  async function ackWelcome(group) {
    await ctx.api(`/v1/crypto/welcomes/${group}/ack`, {});
    await ctx.update((draft) => { transport(draft).chats[group].welcomePending = false; });
  }

  async function join(welcome) {
    const group = uuid(welcome.group);
    const invitation = uuid(welcome.invitation);
    const accepted = state().accepted?.[invitation];
    requireValue(accepted?.posted && accepted.peerDevice === welcome.sender && accepted.peerKey === welcome.senderKey &&
      welcome.recipient === await identity(), "invitation", "Welcome does not match the verified invitation");
    await pin(accepted, undefined, true);
    const { lease, sender, recipient, reference, signature } = welcome;
    requireValue(!accepted.joined || accepted.joined === group, "invitation", "This invitation already has a conversation");
    await ctx.run("directory_join", {
      group, invitation, lease, sender, recipient, reference, signature, welcome: welcome.welcome,
    }, (draft) => {
      const binding = transport(draft).accepted[invitation];
      requireValue(!binding.joined || binding.joined === group,
        "invitation", "This invitation already has a conversation");
      saveChat(draft, group, accepted, true);
      binding.joined = group;
    });
    await ackWelcome(group);
    return group;
  }

  async function send(group, text) {
    ensureUsable(readChat(group));
    requireValue(typeof text === "string" && text.trim() && [...text].length <= 4000,
      "text", "Enter a message of 1–4000 characters");
    const id = crypto.randomUUID();
    await ctx.run("queue", { group, id, text }, (draft, envelope) => {
      const data = transport(draft);
      data.outbox[id] = envelope;
      data.chats[group].messages.push({ id, text, direction: "outgoing", status: "queued" });
    });
    if (running) schedule(0);
    return id;
  }

  async function flushOne(entry) {
    const chat = readChat(entry.group);
    ensureUsable(chat);
    const digest = await ciphertextDigest(entry.ciphertext);
    let ack;
    try {
      ack = await ctx.api("/v1/messages", {
        conversationId: entry.group, clientMessageId: entry.id, mlsEpoch: entry.epoch,
        envelopeKind: entry.kind, ciphertext: entry.ciphertext,
      });
    } catch (error) {
      const text = chat.messages.find((message) => message.direction === "outgoing" && message.id === entry.id)?.text;
      if (error.code !== "MLS_EPOCH_CONFLICT" || !(chat.epoch > entry.epoch) || !text ||
          Object.values(chat.envelopes).some((old) => old.id === entry.id)) throw error;
      // The server checks deduplication before epochs. A definite epoch rejection,
      // plus a verified newer MLS commit, allows this unsaved ID to be re-encrypted.
      await ctx.run("queue", { group: entry.group, id: entry.id, text }, (draft, replacement) => {
        const outbox = transport(draft).outbox;
        requireValue(outbox[entry.id]?.ciphertext === entry.ciphertext && replacement.epoch > entry.epoch,
          "conflict", "The queued message changed");
        outbox[entry.id] = replacement;
      });
      return flushOne(state().outbox[entry.id]);
    }
    requireValue(ack?.durable === true && Number.isSafeInteger(ack.serverSequence) && ack.serverSequence > 0,
      "durability", "The server did not confirm a durable save");
    const serverId = uuid(ack.serverMessageId);
    await ctx.update((draft) => {
      const data = transport(draft);
      const saved = data.chats[entry.group];
      const message = saved.messages.find((item) => item.direction === "outgoing" && item.id === entry.id);
      const echo = Object.values(saved.envelopes).find((old) => old.id === entry.id && old.digest === digest);
      requireValue(!echo || (echo.seq === ack.serverSequence && echo.serverId === serverId),
        "invalid-envelope", "The durable response conflicts with the saved envelope");
      Object.assign(message, { status: "saved", seq: ack.serverSequence, serverId, digest, epoch: entry.epoch, kind: entry.kind });
      delete data.outbox[entry.id];
    });
  }

  async function ingest(group, row, ownId, nextCursor) {
    const chat = readChat(group);
    const envelope = {
      id: uuid(row.clientMessageId), sender: uuid(row.senderDeviceId),
      kind: row.envelopeKind, epoch: row.mlsEpoch, seq: row.serverSequence,
      digest: row.ciphertextSha256, serverId: uuid(row.serverMessageId),
    };
    requireValue(row.conversationId === group && Number.isSafeInteger(envelope.seq) && envelope.seq > 0 &&
      Number.isSafeInteger(envelope.epoch) && envelope.epoch >= 1 &&
      (envelope.kind === 1 || envelope.kind === 3) &&
      (envelope.sender === ownId || envelope.sender === chat.peerDevice),
      "invalid-envelope", "Message coordinates do not match the conversation");
    base64(envelope.digest, 32);
    const own = envelope.sender === ownId;
    requireValue(own ? row.ciphertext === "" : await ciphertextDigest(row.ciphertext) === envelope.digest,
      "invalid-envelope", "Message digest does not match the ciphertext");
    const previous = chat.envelopes[envelope.seq];
    function finish(draft, processed) {
      const data = transport(draft);
      const saved = data.chats[group];
      if (processed?.text !== undefined) {
        saved.messages.push({ id: envelope.id, text: processed.text, direction: "incoming", status: "received" });
      }
      if (processed?.active === false) saved.active = false;
      if (processed?.epoch !== undefined) saved.epoch = processed.epoch;
      saved.envelopes[envelope.seq] = envelope;
      saved.seq = Math.max(saved.seq, envelope.seq);
      if (nextCursor) saved.cursor = nextCursor;
    }
    if (previous) {
      requireValue(sameEnvelope(previous, envelope), "invalid-envelope", "A previously saved envelope changed");
      if (nextCursor) await ctx.update((draft) => finish(draft));
      return;
    }
    requireValue(envelope.seq === chat.seq + 1, "invalid-envelope", "The server omitted conversation messages");
    if (own) {
      const pending = state().outbox?.[envelope.id];
      const sent = chat.messages.find((item) => item.direction === "outgoing" && item.id === envelope.id);
      requireValue(sent && (pending
        ? pending.kind === envelope.kind && pending.epoch === envelope.epoch &&
          await ciphertextDigest(pending.ciphertext) === envelope.digest
        : sent.kind === envelope.kind && sent.epoch === envelope.epoch && sent.digest === envelope.digest &&
          sent.seq === envelope.seq && sent.serverId === envelope.serverId),
        "invalid-envelope", "Own envelope does not match the local outbox");
      await ctx.update((draft) => finish(draft));
      return;
    }
    requireValue(!Object.values(chat.envelopes).some((old) => old.id === envelope.id && old.sender === envelope.sender),
      "invalid-envelope", "The sender reused a message identifier");
    await ctx.run("process", {
      group, id: envelope.id, sender: envelope.sender, kind: envelope.kind, epoch: envelope.epoch,
      ciphertext: row.ciphertext,
    }, (draft, processed) => finish(draft, processed));
  }

  async function pull(group, ownId) {
    let cursor = readChat(group).cursor;
    let rebased = false;
    for (let index = 0; index < 4 && readChat(group).active !== false; index++) {
      ensureUsable(readChat(group));
      const query = new URLSearchParams({ conversationId: group, cursor, limit: String(pageSize) });
      let page;
      try {
        page = await ctx.api(`/v1/sync?${query}`);
      } catch (error) {
        if (error.code !== "INVALID_CURSOR" || !cursor || rebased) throw error;
        cursor = "";
        rebased = true;
        continue;
      }
      requireValue(page?.conversationId === group && Array.isArray(page.messages) && page.messages.length <= pageSize &&
        typeof page.nextCursor === "string" && page.nextCursor.length > 0 && page.nextCursor.length <= 2048 &&
        typeof page.hasMore === "boolean" && (!page.hasMore || page.messages.length > 0),
        "format", "Invalid conversation sync response");
      let pageSequence = 0;
      for (const [offset, row] of page.messages.entries()) {
        requireValue(row.serverSequence > pageSequence, "invalid-envelope", "Messages are out of order");
        pageSequence = row.serverSequence;
        const last = offset === page.messages.length - 1;
        await ingest(group, row, ownId, last ? page.nextCursor : "");
        if (readChat(group).active === false) break;
      }
      if (!page.hasMore) break;
      cursor = page.nextCursor;
    }
  }

  async function cycle() {
    let failure;
    async function attempt(work) {
      try { await work(); } catch (error) {
        if (["conflict", "locked"].includes(error.code)) throw error;
        failure ??= error;
      }
    }
    await attempt(refresh);
    for (const row of Object.values(state().invites ?? {})) await attempt(() => postInvitation(row));
    for (const [id, accepted] of Object.entries(state().accepted ?? {})) {
      if (!accepted.posted) await attempt(() => postAccept(id, accepted));
    }
    for (const [id, proposal] of Object.entries(state().proposals ?? {})) {
      if (proposal.prepared && !proposal.posted) await attempt(() => postEstablish(id, proposal));
    }
    const ownId = await identity();
    for (const chat of Object.values(state().chats ?? {})) {
      if (chat.welcomePending) await attempt(() => ackWelcome(chat.id));
      if (chat.active === false || readChat(chat.id).welcomePending) continue;
      await attempt(() => pull(chat.id, ownId));
      // Oldest first so one failed send cannot be overtaken within this conversation.
      for (const entry of Object.values(state().outbox ?? {}).filter((row) => row.group === chat.id).slice(0, 6)) {
        try { await flushOne(entry); } catch (error) {
          await attempt(() => { throw error; });
          break;
        }
      }
    }
    if (failure) throw failure;
    return directory;
  }

  function tick() {
    activeTick ??= cycle().finally(() => { activeTick = undefined; });
    return activeTick;
  }

  let notifyUpdate;
  let notifyError;
  let retryDelay = 1000;
  function schedule(delay) {
    clearTimeout(timer);
    const current = generation;
    timer = setTimeout(async () => {
      if (!running || current !== generation) return;
      let wait = 3000;
      try {
        const result = await tick();
        if (running && current === generation) notifyUpdate?.(result);
        retryDelay = 1000;
      } catch (error) {
        if (running && current === generation) notifyError?.(error);
        if (["locked", "conflict"].includes(error.code)) {
          stop();
          return;
        }
        wait = retryDelay;
        retryDelay = Math.min(retryDelay * 2, 30_000);
      }
      if (running && current === generation) schedule(wait);
    }, delay);
  }

  function wake() {
    if (running) schedule(0);
  }

  function start(onUpdate, onError) {
    notifyUpdate = onUpdate;
    notifyError = onError;
    if (!running) {
      running = true;
      globalThis.addEventListener?.("online", wake);
    }
    schedule(0);
  }

  function stop() {
    running = false;
    generation++;
    clearTimeout(timer);
    globalThis.removeEventListener?.("online", wake);
  }

  return { refresh, invite, accept, establish, join, send, tick, start, stop };
}
