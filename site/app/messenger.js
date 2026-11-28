import { normalizeSelectedPhoto, outgoingPhotoLimit, photoHeader } from "./private-image.js";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const usernamePattern = /^[a-z0-9_]{3,32}$/;
const empty = Object.freeze({});
const pageSize = 6;
const privateAttachmentLimit = 4 * 1024 * 1024;
const backgroundPullInterval = 9_000;
const activePollInterval = 2_500;

function jitter(delay) {
  return Math.round(delay * (0.85 + Math.random() * 0.3));
}

function nextAfter(ids, previous) {
  return ids.length ? ids[(ids.indexOf(previous) + 1) % ids.length] : undefined;
}

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

function encodeBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + 0x8000, bytes.length)));
  }
  return btoa(binary);
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
  let directoryRequest;
  let directory;
  let directoryDue = 0;
  let selected;
  let preferredSend;
  let previousBackground;
  let previousOutbox;
  let previousAction;
  let backgroundDue = 0;
  let rateLimitedUntil = 0;
  let rateLimitFailure;
  const remoteBlocked = new Map();
  const reconfirming = new Set();
  const privateImageUrls = new Set();
  let privateImageGeneration = 0;

  function releasePhoto(url) {
    if (privateImageUrls.delete(url)) URL.revokeObjectURL(url);
  }
  function clearPhotos() {
    privateImageGeneration++;
    for (const url of privateImageUrls) URL.revokeObjectURL(url);
    privateImageUrls.clear();
  }

  async function openPhoto(group, message) {
    const chat = readChat(group);
    ensureUsable(chat);
    const id = uuid(message?.id);
    const info = message?.attachment;
    requireValue(info?.media === "photo" && Number.isSafeInteger(info.size) &&
      info.size > 0 && info.size <= privateAttachmentLimit &&
      typeof info.name === "string" && info.name.length <= 255,
      "attachment", "This encrypted attachment is not a supported image");
    const generationAtStart = privateImageGeneration;
    const active = () => requireValue(generationAtStart === privateImageGeneration,
      "locked", "The private image view was closed");
    const sealed = await ctx.apiBytes(
      `/v1/conversations/${uuid(group)}/blobs/${uuid(info.blobId)}`, info.size + 16,
    );
    let opened;
    try {
      active();
      requireValue(sealed.length === info.size + 16, "attachment", "The encrypted image size does not match its message");
      opened = await ctx.run("attachment_open", {
        group, id, attachment: info, ciphertext: encodeBase64(sealed),
      });
      active();
    } finally {
      sealed.fill(0);
    }
    requireValue(opened?.media === "photo" && opened.size === info.size,
      "attachment", "The encrypted image did not authenticate");
    let plain = base64(opened.data, info.size, info.size);
    delete opened.data;
    let source;
    try {
      const { mime } = photoHeader(plain);
      source = new Blob([plain], { type: mime });
    } finally {
      plain.fill(0);
      plain = null;
    }
    let bitmap;
    try {
      bitmap = await createImageBitmap(source);
      active();
      requireValue(bitmap.width > 0 && bitmap.height > 0 && bitmap.width <= 8192 &&
        bitmap.height <= 8192 && bitmap.width * bitmap.height <= 16_000_000,
        "attachment", "The image dimensions exceed the safe preview limit");
      const scale = Math.min(1, 960 / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      const context = canvas.getContext("2d", { alpha: false });
      requireValue(context, "attachment", "Image preview is unavailable");
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      const safeBlob = await new Promise((resolve) => canvas.toBlob(resolve, "image/webp", 0.86));
      canvas.width = 0;
      canvas.height = 0;
      requireValue(safeBlob && safeBlob.size > 0 && safeBlob.size <= privateAttachmentLimit,
        "attachment", "The image preview could not be encoded safely");
      active();
      const url = URL.createObjectURL(safeBlob);
      privateImageUrls.add(url);
      return url;
    } finally {
      bitmap?.close();
    }
  }


  const state = () => ctx.state()?.messenger ?? empty;
  const readChat = (id) => {
    const chat = state().chats?.[uuid(id)];
    requireValue(chat, "unknown-chat", "This conversation has not been verified");
    return chat;
  };

  function observeConflict(id) {
    remoteBlocked.set(id, Symbol());
  }

  async function persistConflicts(ids) {
    if (!ids.length) return;
    if (ctx.persistBindingConflicts) await ctx.persistBindingConflicts(ids);
    else await ctx.update((draft) => {
      for (const id of ids) {
        const chat = transport(draft).chats[id];
        if (chat) chat.bindingConflict = true;
      }
    });
  }

  function ensureUsable(chat) {
    requireValue(chat, "unknown-chat", "This conversation has not been verified");
    requireValue(chat.active !== false, "inactive-chat", "This conversation is inactive");
    requireValue(!chat.bindingConflict && !remoteBlocked.has(chat.id) && !reconfirming.has(chat.id),
      "changed-key", "The conversation contact changed");
  }

  async function identity() {
    const saved = ctx.state()?.identity;
    return uuid(saved?.identity ?? saved?.deviceId ?? (await ctx.run("identity", {})).identity);
  }

  async function pin(peer, entered, alreadyBound = false) {
    const fields = { identity: peer.peerDevice, public_key: peer.peerKey };
    const { status } = await ctx.run("peer_key_status", fields);
    requireValue(status === "unknown" || status === "matches", "changed-key", "The contact device key changed");
    if (alreadyBound) {
      requireValue(status === "matches", "verification", "The saved contact device key is unavailable");
      if (!entered) return;
    }
    const enteredCode = typeof entered === "string" && entered.length <= 256
      ? entered.replace(/\s+/gu, "").toUpperCase() : "";
    requireValue(enteredCode === (await fingerprint(peer.peerKey)).replaceAll(" ", ""),
      "verification", "Enter the contact device code received through a trusted channel");
    if (status === "unknown") await ctx.run("pin", { ...fields, confirmed: true });
  }

  async function fetchDirectory() {
    const [requests, welcomes, chats] = await Promise.all([
      ctx.api("/v1/chat-requests"),
      ctx.api("/v1/crypto/welcomes"),
      ctx.api("/v1/conversations"),
    ]);
    requireValue(Array.isArray(requests) && requests.length <= 100 &&
      Array.isArray(welcomes) && welcomes.length <= 20 && Array.isArray(chats) && chats.length <= 100,
      "format", "Invalid conversation directory");
    const changed = new Set();
    try {
      for (const row of chats) {
        const chat = state().chats?.[uuid(row.id)];
        if (chat && !samePeer(chat, row)) {
          observeConflict(row.id);
          if (!chat.bindingConflict || reconfirming.has(row.id)) changed.add(row.id);
        }
      }
      directory = { requests, welcomes, chats };
    } finally {
      await persistConflicts([...changed]);
    }
    const pending = welcomes.length || requests.some((row) => !row.established);
    const populated = Object.keys(state().chats ?? {}).length > 0;
    directoryDue = performance.now() + jitter(pending || !populated ? 12_500 : 30_000);
    return directory;
  }

  function refresh() {
    if (performance.now() < rateLimitedUntil) return Promise.reject(rateLimitFailure);
    directoryRequest ??= fetchDirectory().catch((error) => {
      rememberRateLimit(error);
      throw error;
    }).finally(() => { directoryRequest = undefined; });
    return directoryRequest;
  }

  async function reconfirmChat(group, code) {
    const chat = readChat(group);
    requireValue(chat.bindingConflict && !reconfirming.has(group), "verification", "No conflict to resolve");
    requireValue(typeof code === "string" && code.length > 0, "verification", "Enter the original device code");
    reconfirming.add(group);
    try {
      await refresh();
      const observed = remoteBlocked.get(group);
      const matchesOriginal = () => {
        const matches = directory?.chats.filter((row) => row.id === group);
        return matches?.length === 1 && samePeer(chat, matches[0]) && remoteBlocked.get(group) === observed;
      };
      requireValue(matchesOriginal(), "changed-key", "The saved contact binding has not returned");
      await pin(chat, code, true);
      await ctx.update((draft) => {
        const saved = transport(draft).chats[group];
        requireValue(saved?.bindingConflict && samePeer(saved, chat) && matchesOriginal(),
          "changed-key", "The contact binding changed");
        delete saved.bindingConflict;
      });
      if (!matchesOriginal()) {
        observeConflict(group);
        await persistConflicts([group]);
        requireValue(false, "changed-key", "The contact binding changed");
      }
      remoteBlocked.delete(group);
    } finally {
      reconfirming.delete(group);
    }
  }

  function rememberRateLimit(error) {
    if (error.status !== 429 || performance.now() < rateLimitedUntil) return;
    rateLimitedUntil = performance.now() + jitter(12_000);
    rateLimitFailure = error;
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
    const result = await ctx.api("/v1/crypto/keypackages", {
      payload: accepted.keypackage, invitationId: accepted.offeredFor,
    });
    requireValue(result?.reference === accepted.reference, "format", "Invalid key package publication response");
    await ctx.api(`/v1/chat-requests/${id}/accept`, {});
    await ctx.update((draft) => { transport(draft).accepted[id].posted = true; });
  }

  async function confirmInvitation(id, peer, code) {
    const existing = state().accepted?.[id];
    requireValue(!existing || samePeer(existing, peer), "changed-key", "The invitation sender changed");
    if (existing?.coreConsent) {
      await pin(peer, code, true);
      return;
    }
    // Upgrading a pending pre-v2 receipt requires a fresh independent code.
    await pin(peer, code);
    await ctx.run("directory_consent", {
      invitation: id, sender: peer.peerDevice, senderKey: peer.peerKey, confirmed: true,
      ...(existing ? { keypackage: existing.keypackage, reference: existing.reference } : {}),
    }, (draft, result) => {
      const accepted = transport(draft).accepted;
      if (existing) {
        const saved = accepted[id];
        requireValue(saved && samePeer(saved, peer) && saved.reference === result.reference &&
          saved.keypackage === result.keypackage, "invitation", "The saved invitation changed");
        saved.coreConsent = true;
      } else {
        requireValue(!accepted[id], "invitation", "The invitation changed");
        accepted[id] = { ...peer, coreConsent: true, offeredFor: id, keypackage: result.keypackage,
          reference: result.reference, posted: false };
      }
    });
  }

  async function accept(request, code) {
    const id = uuid(request.id);
    requireValue(request.outgoing === false, "invitation", "This is not an incoming invitation");
    const peer = peerInfo(request.senderDevice, request.senderKey, request.username);
    await confirmInvitation(id, peer, code);
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

  async function join(welcome, code) {
    const group = uuid(welcome.group);
    const invitation = uuid(welcome.invitation);
    const accepted = state().accepted?.[invitation];
    requireValue(accepted?.posted && accepted.reference === welcome.reference && accepted.peerDevice === welcome.sender && accepted.peerKey === welcome.senderKey &&
      welcome.recipient === await identity(), "invitation", "Welcome does not match the verified invitation");
    if (!accepted.coreConsent && !accepted.joined) {
      await confirmInvitation(invitation, accepted, code);
    } else {
      await pin(accepted, undefined, true);
    }
    const { lease, sender, recipient, reference, signature } = welcome;
    requireValue(!accepted.joined || accepted.joined === group, "invitation", "This invitation already has a conversation");
    await ctx.run("directory_join", {
      group, invitation, lease, sender, recipient, reference, signature, welcome: welcome.welcome,
    }, (draft) => {
      const binding = transport(draft).accepted[invitation];
      requireValue(binding.reference === reference && (!binding.joined || binding.joined === group),
        "invitation", "This invitation already has a conversation");
      saveChat(draft, group, accepted, true);
      binding.joined = group;
    });
    await ackWelcome(group);
    return group;
  }

  async function send(group, text, draftRevision) {
    ensureUsable(readChat(group));
    requireValue(typeof text === "string" && text.trim() && [...text].length <= 4000,
      "text", "Enter a message of 1–4000 characters");
    const id = crypto.randomUUID();
    await ctx.run("queue", { group, id, text }, (draft, envelope) => {
      const data = transport(draft);
      ensureUsable(data.chats[group]);
      data.outbox[id] = envelope;
      if (draftRevision && data.chats[group].draft?.revision === draftRevision) {
        delete data.chats[group].draft;
      }
      data.chats[group].messages.push({ id, text, direction: "outgoing", status: "queued", recordedAt: Date.now() });
    });
    preferredSend = group;
    if (running) schedule(0);
    return id;
  }

  let preparingPhoto = false;
  async function sendPhoto(group, file) {
    const chat = readChat(group);
    const generationAtStart = privateImageGeneration;
    const active = () => {
      requireValue(generationAtStart === privateImageGeneration && selected === group &&
        samePeer(chat, readChat(group)), "locked", "The conversation changed");
      ensureUsable(readChat(group));
    };
    active();
    requireValue(!preparingPhoto, "attachment", "Another photo is being prepared");
    preparingPhoto = true;
    let bytes;
    try {
      bytes = await normalizeSelectedPhoto(file, active);
      active();
      const id = crypto.randomUUID();
      const text = "Фото";
      await ctx.run("queue", { group, id, text, blobId: crypto.randomUUID(), photo: encodeBase64(bytes) },
        (draft, envelope) => {
          active();
          const data = transport(draft);
          ensureUsable(data.chats[group]);
          requireValue(Object.values(data.outbox).filter((entry) => entry.photo).length < 4,
            "attachment", "Too many photos are waiting to send");
          data.outbox[id] = envelope;
          data.chats[group].messages.push({ id, text, attachment: envelope.photo.descriptor,
            direction: "outgoing", status: "queued", recordedAt: Date.now() });
        });
      preferredSend = group;
      if (running) schedule(0);
      return id;
    } finally {
      bytes?.fill(0);
      preparingPhoto = false;
    }
  }

  async function flushOne(entry) {
    const chat = readChat(entry.group);
    const assertQueued = () => {
      const current = readChat(entry.group);
      ensureUsable(current);
      const saved = state().outbox?.[entry.id];
      requireValue(samePeer(chat, current) && saved?.group === entry.group &&
        saved.epoch === entry.epoch && saved.kind === entry.kind && saved.ciphertext === entry.ciphertext &&
        saved.photo?.sealed === entry.photo?.sealed &&
        saved.photo?.descriptor?.blobId === entry.photo?.descriptor?.blobId,
      "conflict", "The queued message or its contact changed");
      return current;
    };
    async function checkPin(inspect) {
      const current = assertQueued();
      const { status } = await inspect("peer_key_status", {
        identity: current.peerDevice, public_key: current.peerKey,
      });
      if (status !== "matches") observeConflict(entry.group);
      requireValue(status === "matches", "changed-key", "The saved contact device key is unavailable");
    }
    const handoff = async (request) => {
      const send = () => {
        assertQueued();
        return request();
      };
      requireValue(ctx.handoff, "handoff-unavailable", "A profile lock is required to send");
      return ctx.handoff(checkPin, send);
    };
    assertQueued();
    const digest = await ciphertextDigest(entry.ciphertext);
    let ack;
    try {
      if (entry.photo) {
        const { descriptor, sealed } = entry.photo;
        requireValue(Number.isSafeInteger(descriptor.size) && descriptor.size > 0 &&
          descriptor.size <= outgoingPhotoLimit, "attachment", "Invalid queued photo size");
        const ciphertext = base64(sealed, descriptor.size + 16);
        try {
          await ctx.api(`/v1/conversations/${uuid(entry.group)}/blobs/${uuid(descriptor.blobId)}`,
            ciphertext, "PUT", handoff);
        } finally {
          ciphertext.fill(0);
        }
      }
      ack = await ctx.api("/v1/messages", {
        conversationId: entry.group, clientMessageId: entry.id, mlsEpoch: entry.epoch,
        envelopeKind: entry.kind, ciphertext: entry.ciphertext,
      }, undefined, handoff);
    } catch (error) {
      if (error.code === "changed-key" && remoteBlocked.has(entry.group) && !readChat(entry.group).bindingConflict) {
        await persistConflicts([entry.group]);
      }
      if (error.code !== "MLS_EPOCH_CONFLICT") throw error;
      const latest = assertQueued();
      const text = latest.messages.find((message) => message.direction === "outgoing" && message.id === entry.id)?.text;
      if (!(latest.epoch > entry.epoch) || !text ||
          Object.values(latest.envelopes).some((old) => old.id === entry.id)) throw error;
      // A definite epoch rejection allows this unsaved ID to be re-encrypted.
      await ctx.run("queue", { group: entry.group, id: entry.id, text,
        ...(entry.photo && { attachment: entry.photo.descriptor }) }, (draft, replacement) => {
        const data = transport(draft);
        ensureUsable(data.chats[entry.group]);
        requireValue(data.outbox[entry.id]?.ciphertext === entry.ciphertext && replacement.epoch > entry.epoch,
          "conflict", "The queued message changed");
        data.outbox[entry.id] = entry.photo ? { ...replacement, photo: entry.photo } : replacement;
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
    ensureUsable(chat);
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
      const previousLength = saved.messages.length;
      if (processed?.text !== undefined) {
        saved.messages.push({ id: envelope.id, text: processed.text, direction: "incoming", status: "received", recordedAt: Date.now() });
      } else if (processed?.attachment?.media === "photo") {
        saved.messages.push({ id: envelope.id, text: processed.attachment.caption ?? "Фото",
          attachment: processed.attachment, direction: "incoming", status: "received", recordedAt: Date.now() });
      } else if (processed?.unsupported === true) {
        saved.messages.push({
          id: envelope.id,
          text: "Зашифрованное вложение или событие. Этот клиент его не отображает.",
          direction: "incoming",
          status: "unsupported", recordedAt: Date.now(),
        });
      }
      if (saved.messages.length > previousLength) saved.receivedCount = (saved.receivedCount ?? 0) + 1;
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
    const { seq: initialSeq, cursor: savedCursor } = readChat(group);
    let cursor = savedCursor;
    let rebased = false;
    for (let index = 0; index < 2 && readChat(group).active !== false; index++) {
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
      return { changed: pageSequence > initialSeq, hasMore: page.hasMore };
    }
    return { changed: false, hasMore: false };
  }

  async function cycle(forceDirectory) {
    if (performance.now() < rateLimitedUntil) throw rateLimitFailure;
    let failure;
    async function attempt(work) {
      try { return await work(); } catch (error) {
        if (error.status === 429) {
          rememberRateLimit(error);
          throw error;
        }
        if (["conflict", "locked"].includes(error.code)) throw error;
        failure ??= error;
      }
    }
    const pendingActions = new Map([
      ...Object.entries(state().invites ?? {}).map(([id, row]) => [id, () => postInvitation(row)]),
      ...Object.entries(state().accepted ?? {}).filter(([, row]) => !row.posted)
        .map(([id, row]) => [id, () => postAccept(id, row)]),
      ...Object.entries(state().proposals ?? {}).filter(([, row]) => row.prepared && !row.posted)
        .map(([id, row]) => [id, () => postEstablish(id, row)]),
      ...Object.values(state().chats ?? {}).filter((chat) => chat.welcomePending)
        .map((chat) => [chat.id, () => ackWelcome(chat.id)]),
    ]);
    const actionIds = [...pendingActions.keys()];
    for (let index = 0; index < Math.min(2, actionIds.length); index++) {
      previousAction = nextAfter(actionIds, previousAction);
      await attempt(pendingActions.get(previousAction));
    }
    if (forceDirectory || performance.now() >= directoryDue) await attempt(refresh);

    const usable = Object.values(state().chats ?? {}).filter((chat) => (
      chat.active !== false && !chat.welcomePending && !chat.bindingConflict && !remoteBlocked.has(chat.id)
    )).map((chat) => chat.id);
    const pending = Object.values(state().outbox ?? {}).filter((entry) => usable.includes(entry.group));
    const dispatchGroups = [...new Set(pending.map((entry) => entry.group))];
    const outbound = dispatchGroups.includes(preferredSend)
      ? preferredSend : nextAfter(dispatchGroups, previousOutbox);
    preferredSend = undefined;
    previousOutbox = outbound;
    const foreground = outbound ?? (usable.includes(selected) ? selected : undefined);
    const candidates = usable.filter((id) => id !== foreground);
    let background;
    // At most two sync pages per cycle regardless of how many chats are stored.
    if (candidates.length && (forceDirectory || performance.now() >= backgroundDue)) {
      background = candidates.includes(selected) && !previousBackground
        ? selected : nextAfter(candidates, previousBackground);
      previousBackground = background;
      backgroundDue = performance.now() + jitter(backgroundPullInterval);
    }
    let busy = pending.length > 0 || pendingActions.size > 2;
    if (foreground || background) {
      const ownId = await identity();
      for (const id of [foreground, background].filter(Boolean)) {
        const result = await attempt(() => pull(id, ownId));
        if (result?.changed || result?.hasMore) busy = true;
      }
    }
    if (outbound && readChat(outbound).active !== false) {
      // Oldest first so one failed send cannot be overtaken within this conversation.
      for (const entry of pending.filter((row) => row.group === outbound).slice(0, 3)) {
        if (!await attempt(async () => { await flushOne(entry); return true; })) break;
      }
    }
    if (failure) throw failure;
    return busy;
  }

  function work(forceDirectory) {
    activeTick ??= cycle(forceDirectory).finally(() => { activeTick = undefined; });
    return activeTick;
  }

  async function tick({ forceDirectory = true } = {}) {
    if (activeTick && forceDirectory) await refresh();
    await work(forceDirectory);
    return directory;
  }

  function select(id) {
    const next = id ? uuid(id) : undefined;
    if (selected === next) return;
    clearPhotos();
    selected = next;
    if (running) schedule(0);
  }

  let notifyUpdate;
  let notifyError;
  let retryDelay = 1000;
  let idleDelay = activePollInterval;
  let timerSequence = 0;
  function schedule(delay) {
    clearTimeout(timer);
    const current = generation;
    const sequence = ++timerSequence;
    timer = setTimeout(async () => {
      if (!running || current !== generation) return;
      let wait;
      try {
        const busy = await work(false);
        if (running && current === generation) notifyUpdate?.(directory);
        retryDelay = 1000;
        idleDelay = busy ? activePollInterval : Math.min(idleDelay * 1.5, selected ? 6500 : 14_000);
        wait = Math.min(jitter(idleDelay), Math.max(0, directoryDue - performance.now()));
      } catch (error) {
        if (running && current === generation) notifyError?.(error);
        if (["locked", "conflict"].includes(error.code)) {
          stop();
          return;
        }
        wait = Math.max(jitter(retryDelay), rateLimitedUntil - performance.now());
        retryDelay = Math.min(retryDelay * 2, 30_000);
      }
      if (running && current === generation && sequence === timerSequence) schedule(wait);
    }, delay);
  }

  function wake() {
    if (running) {
      directoryDue = 0;
      backgroundDue = 0;
      schedule(0);
    }
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
    clearPhotos();
    globalThis.removeEventListener?.("online", wake);
  }

  return { refresh, invite, accept, establish, join, reconfirmChat, send, sendPhoto, tick, select, start, stop,
    openPhoto, releasePhoto };
}
