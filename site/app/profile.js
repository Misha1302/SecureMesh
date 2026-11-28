import {
  hasVault,
  createVault,
  unlockVault,
  closeVault,
  commitVault,
  persistBindingConflicts,
  handoffVault,
  readBackup,
  exportBackup,
  maxBackupLength,
} from "./vault.js";
import { createAccount, apiOrigin, deviceFingerprint } from "./account.js";
import { createMessenger } from "./messenger.js";
import { privatePhotoControl } from "./private-image.js";

const byId = (id) => document.getElementById(id);
const show = (id, visible) => {
  byId(id).hidden = !visible;
};
const notice = (message) => {
  byId("notice").textContent = message;
};
let closingVault = Promise.resolve();
let opened,
  selected,
  generation = 0,
  hasLocal = false,
  directory = {};
const codes = {
  password: "Введите не менее 16 видимых символов.",
  authentication: "Проверьте пароль. Открыть зашифрованные данные не удалось.",
  conflict: "Профиль изменился в другой вкладке. Откройте его заново.",
  verification: "Код не совпал. Сверьте отпечаток по независимому каналу.",
  "changed-key": "Ключ собеседника изменился. Отправка остановлена.",
  "handoff-unavailable": "Браузер не может защитить отправку между вкладками.",
  NETWORK_UNAVAILABLE:
    "Нет соединения с совместимым сервером. Проверьте сеть и доступность API.",
  INVALID_TOKEN: "Не удалось подтвердить код.",
  INVALID_RECOVERY: "Код восстановления недействителен, истёк или уже использован.",
  INVALID_EMAIL: "Укажите адрес почты для восстановления.",
  INVALID_DISPLAY_NAME: "Проверьте имя профиля.",
  INVALID_CREDENTIALS: "Проверьте пароль и подтверждение почты.",
  SESSION_REQUIRED: "Войдите в аккаунт ещё раз.",
  SESSION_EXPIRED: "Срок сессии истёк. Очередь сохранена.",
  attachment: "Вложение не удалось подготовить или открыть. Проверьте формат, размер файла и очередь отправки.",
  size: "Недостаточно места или превышен лимит файла.",
  DEVICE_ENROLLMENT_REQUIRED:
    "Это устройство ожидает независимого подтверждения.",
  format: "Формат файла или ответа не поддерживается.",
  denied: "Разблокируйте профиль его паролем.",
  crypto: "Криптографическая проверка не пройдена. Действие остановлено.",
};
function errorMessage(error) {
  return error.status === 404
    ? "На сервере отсутствует нужный маршрут API. Проверьте версию сервера."
    : (codes[error.code] ??
        "Не удалось завершить действие. Проверьте данные и повторите попытку.");
}
const failure = (code) => Object.assign(new Error(code), { code });
function rpc() {
  const worker = new Worker("./mesh-worker.js", { type: "module" });
  const pending = new Map();
  let sequence = 0,
    stopped = false;
  function stop() {
    stopped = true;
    worker.terminate();
    for (const { reject } of pending.values()) reject(failure("crypto"));
    pending.clear();
  }
  worker.onerror = stop;
  worker.onmessage = ({ data }) => {
    const item = pending.get(data.id);
    if (!item) return;
    pending.delete(data.id);
    if (data.failed) item.reject(failure("crypto"));
    else item.resolve(data.value);
  };
  return {
    stop,
    call(fields) {
      return new Promise((resolve, reject) => {
        if (stopped) {
          reject(failure("crypto"));
          return;
        }
        const id = ++sequence;
        pending.set(id, { resolve, reject });
        worker.postMessage({ ...fields, id });
      });
    },
  };
}
function attach(handle, worker) {
  const instance = { handle, worker };
  opened = instance;
  let tail = Promise.resolve();
  let timer;
  const edited = new Map();
  let pendingConflicts = 0;
  function applyEdits(profile, snapshot) {
    for (const [id, edit] of snapshot) {
      const chat = profile.messenger?.chats[id];
      if (!chat) continue;
      if (edit.text) chat.draft = edit;
      else delete chat.draft;
    }
  }
  instance.getDraft = (id) => edited.get(id) ?? handle.state.messenger?.chats[id]?.draft;
  instance.edit = (id, text) => {
    edited.set(id, { text, revision: crypto.randomUUID() });
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (edited.size && opened === instance) {
        change(() => {}).catch((error) => {
          if (opened === instance) notice(errorMessage(error));
        });
      }
    }, 350);
  };
  instance.close = () => {
    clearTimeout(timer);
    if (!edited.size && !pendingConflicts) {
      closeVault(handle);
      return;
    }
    // Stop the UI and worker immediately. Finish already scheduled conflict and draft writes.
    closingVault = tail.then(async () => {
      if (!edited.size) return;
      const profile = structuredClone(handle.state);
      applyEdits(profile, edited);
      await commitVault(handle, profile);
    }).catch(() => notice("Не удалось сохранить последнее изменение черновика."))
      .finally(() => { edited.clear(); closeVault(handle); });
  };
  function state() {
    if (opened !== instance) throw failure("locked");
    return handle.state;
  }
  function handleConflict(error) {
    if (error.code === "conflict" && opened === instance) {
      lock();
      notice(codes.conflict);
    }
    throw error;
  }
  function change(work) {
    const next = tail.then(async () => {
      const draft = structuredClone(state());
      const captured = new Map(edited);
      applyEdits(draft, captured);
      const result = await work(draft);
      state();
      try {
        await commitVault(handle, draft);
        for (const [id, edit] of captured) {
          if (edited.get(id) === edit) edited.delete(id);
        }
      } catch (error) {
        handleConflict(error);
      }
      state();
      return result;
    });
    tail = next.catch(() => {});
    return next;
  }
  const ctx = {
    state,
    update: change,
    persistBindingConflicts(groups) {
      state();
      pendingConflicts++;
      const next = tail.then(() => persistBindingConflicts(handle, groups));
      tail = next.catch(() => {});
      return next.catch(handleConflict).finally(() => { pendingConflicts--; });
    },
    handoff(check, send) {
      const inspect = async (op, fields) => {
        const { result } = await worker.call({
          snapshot: state().snapshot,
          request: { ...fields, op },
        });
        state();
        return result;
      };
      return handoffVault(handle, () => check(inspect), send).catch(handleConflict);
    },
    derive: (endpoint, username) =>
      worker.call({ type: "derive", args: [endpoint, username] }),
    run: (op, fields = {}, mutate) =>
      change(async (draft) => {
        const { snapshot, result } = await worker.call({
          snapshot: draft.snapshot,
          request: { ...fields, op },
        });
        draft.snapshot = snapshot;
        if (mutate) mutate(draft, result);
        return result;
      }),
  };
  instance.markRead = (group, count) => change(draft => {
    const chat = draft.messenger.chats[group];
    if (chat) chat.readCount = Math.max(chat.readCount ?? 0, Math.min(count, chat.receivedCount ?? 0));
  });
  instance.account = createAccount(ctx);
  instance.mesh = createMessenger({
    ...ctx, api: instance.account.api, apiBytes: instance.account.apiBytes,
    onBindingConflict: group => {
      if (opened === instance && selected === group) {
        clearPeerProfile();
        show("peer-profile-open", false);
      }
    },
  });
  return instance;
}
function disposePhotoControls(current) {
  for (const control of current?.photoControls ?? []) control.dispose();
  current?.photoControls?.clear();
}

let peerProfileView;

function clearPeerProfile() {
  peerProfileView = undefined;
  const button = byId("peer-profile-open");
  button.textContent = "Анкета собеседника";
  button.setAttribute("aria-expanded", "false");
  show("peer-profile", false);
  byId("peer-profile-note").textContent = "";
  for (const id of ["peer-profile-status", "peer-profile-bio"]) {
    byId(id).textContent = "";
    show(id, false);
  }
}

function peerProfileContext() {
  const state = opened?.handle.state;
  if (!selected || !state?.session || state.session.refreshPending ||
      !state.enrollmentVerified || state.trustState !== "DEVICE_TRUSTED" ||
      !opened.mesh.canViewPeer(selected)) return;
  const { peerDevice, peerKey } = state.messenger.chats[selected];
  return { current: opened, group: selected, peerDevice, peerKey };
}

function samePeerProfile(view, context) {
  return view && context && view.current === context.current && view.group === context.group &&
    view.peerDevice === context.peerDevice && view.peerKey === context.peerKey;
}

byId("peer-profile-open").onclick = async () => {
  if (peerProfileView) {
    clearPeerProfile();
    return;
  }
  const view = peerProfileContext();
  if (!view || document.hidden) return;
  peerProfileView = view;
  const button = byId("peer-profile-open");
  button.textContent = "Закрыть анкету";
  button.setAttribute("aria-expanded", "true");
  show("peer-profile", true);
  const note = byId("peer-profile-note");
  note.textContent = "Загрузка…";
  const active = () => peerProfileView === view && !document.hidden &&
    samePeerProfile(view, peerProfileContext());
  try {
    const result = await view.current.account.api(
      `/v1/conversations/${view.group}/profile-text/${view.peerDevice}`,
    );
    if (!active()) return;
    for (const [field, limit] of [["status", 80], ["bio", 280]]) {
      const value = result?.[field];
      if (value !== null && (typeof value !== "string" || [...value].length > limit))
        throw failure("format");
    }
    for (const field of ["status", "bio"]) {
      const id = `peer-profile-${field}`;
      byId(id).textContent = result[field] ?? "";
      show(id, Boolean(result[field]));
    }
    note.textContent = result.status || result.bio ? "" : "Нет доступных сведений.";
  } catch {
    if (active()) note.textContent = "Анкета недоступна.";
  }
};

function lock() {
  generation++;
  clearPeerProfile();
  const current = opened;
  opened = null;
  disposePhotoControls(current);
  stopWatchingUnread();
  current?.mesh.stop();
  current?.worker.stop();
  current?.close();
  selected = null;
  directory = {};
  for (const form of document.forms) form.reset();
  for (const id of [
    "requests",
    "chat-list",
    "messages",
    "archive-view",
    "my-code",
    "peer",
    "account-name",
  ])
    byId(id).replaceChildren();
  byId("password").type = "password";
  notice("");
  layout();
}
const profileForm = byId("profile-text-form");
let profileRevision = null;
let profileDirty = false;
let profileRequest;

function clearProfileText() {
  profileRequest = undefined;
  profileRevision = null;
  profileDirty = false;
  profileForm.reset();
  profileForm.querySelector("fieldset").disabled = true;
  byId("profile-text").open = false;
  byId("profile-text-status").textContent = "";
  show("profile-text-reload", false);
}

async function editProfileText(save) {
  const current = opened;
  if (!current || byId("profile-text").hidden || profileRequest) return;
  if (save && profileRevision === null) return;
  const fields = profileForm.elements;
  const message = byId("profile-text-status");
  if (save && ([...fields.bio.value].length > 280 || [...fields.status.value].length > 80)) {
    message.textContent = "Описание допускает до 280 символов, статус — до 80.";
    return;
  }
  const body = save ? {bio: fields.bio.value || null, status: fields.status.value || null,
    visibleToPeers: fields.visible.checked, revision: profileRevision} : undefined;
  const request = {};
  profileRequest = request;
  const fieldset = profileForm.querySelector("fieldset");
  fieldset.disabled = true;
  message.textContent = save ? "Сохранение…" : "Загрузка…";
  show("profile-text-reload", false);
  try {
    const base = "/v1/users/me/profile-text";
    const result = await current.account.api(save ? base + "/with-visibility" : base, body, save ? "PUT" : "GET");
    if (opened !== current || profileRequest !== request) return;
    if (!Number.isSafeInteger(result?.revision) || result.revision < 0 ||
        typeof result.visibleToPeers !== "boolean" ||
        ![result.bio, result.status].every(value => value === null || typeof value === "string"))
      throw new Error("INVALID_PROFILE");
    fields.bio.value = result.bio ?? "";
    fields.status.value = result.status ?? "";
    fields.visible.checked = result.visibleToPeers;
    profileRevision = result.revision;
    profileDirty = false;
    message.textContent = save ? "Сохранено" : "";
  } catch (error) {
    if (opened !== current || profileRequest !== request) return;
    message.textContent = error.status === 409
      ? "Профиль изменён на другом устройстве. Загрузка с сервера заменит ваш черновик."
      : save ? "Не удалось сохранить изменения. Проверьте текст и повторите." : "Не удалось загрузить профиль.";
    show("profile-text-reload", !save || error.status === 409);
  } finally {
    if (profileRequest === request) {
      profileRequest = undefined;
      fieldset.disabled = profileRevision === null;
    }
  }
}
byId("profile-text").ontoggle = () => {
  if (byId("profile-text").open && !profileDirty) editProfileText(false);
};
profileForm.oninput = () => { profileDirty = true; };
profileForm.onsubmit = event => {
  event.preventDefault();
  editProfileText(true);
};
byId("profile-text-reload").onclick = () => editProfileText(false);

async function securityEmail(choice) {
  const current = opened;
  if (!current || current.securityEmailBusy || !byId("security-email").open) return;
  current.securityEmailBusy = true;
  const control = byId("security-email-enabled");
  control.disabled = true;
  byId("security-email-status").textContent = choice === undefined ? "Загрузка…" : "Сохранение…";
  show("security-email-retry", false);
  try {
    const result = await current.account.api("/v1/users/me/security-email",
      choice === undefined ? undefined : {enabled: choice}, choice === undefined ? "GET" : "PUT");
    if (opened !== current) return;
    if (typeof result?.enabled !== "boolean" || (choice !== undefined && result.enabled !== choice))
      throw new Error("INVALID_PREFERENCE");
    control.checked = result.enabled;
    control.indeterminate = false;
    control.disabled = false;
    byId("security-email-status").textContent = choice === undefined ? "" : "Сохранено";
  } catch {
    if (opened !== current) return;
    control.indeterminate = true;
    byId("security-email-status").textContent = "Не удалось проверить настройку.";
    show("security-email-retry", true);
  } finally {
    current.securityEmailBusy = false;
  }
}
byId("security-email").ontoggle = () => {
  if (byId("security-email").open) securityEmail();
};
byId("security-email-enabled").onchange = (event) => securityEmail(event.target.checked);
byId("security-email-retry").onclick = () => securityEmail();

function layout() {
  const state = opened?.handle.state;
  const trusted = Boolean(
    state?.session &&
      !state.session.refreshPending &&
      state.enrollmentVerified &&
      state.trustState === "DEVICE_TRUSTED",
  );
  show("loading", false);
  show("entry", !state);
  show("new-fields", !hasLocal);
  show("confirm-label", !hasLocal);
  show("password-hint", !hasLocal);
  if (hasLocal) byId("password").removeAttribute("aria-describedby");
  else byId("password").setAttribute("aria-describedby", "password-hint");
  const form = byId("entry");
  form.elements.username.disabled = hasLocal;
  form.elements.name.disabled = hasLocal;
  form.elements.username.required = !hasLocal;
  form.elements.name.required = !hasLocal;
  form.elements.remembered.required = !hasLocal;
  byId("password").autocomplete = hasLocal
    ? "current-password"
    : "new-password";
  byId("enter").textContent = hasLocal ? "Разблокировать" : "Создать профиль";
  byId("title").textContent = trusted
    ? "Чаты"
    : state
      ? "Аккаунт SecureMesh"
      : hasLocal
        ? "Разблокировка"
        : "Создание профиля";
  show("lock", !!state);
  show("account", !!state && !trusted);
  show("backup", !!state);
  show("conversations", trusted);
  show("profile-text", trusted);
  if (!trusted) {
    clearProfileText();
    clearPeerProfile();
  }
  show("security-email", trusted);
  if (!trusted) {
    byId("security-email").open = false;
    byId("security-email-enabled").checked = false;
    byId("security-email-enabled").indeterminate = true;
    byId("security-email-enabled").disabled = true;
    byId("security-email-status").textContent = "";
    show("security-email-retry", false);
  }
  if (!state) return;
  byId("account-name").textContent =
    state.displayName + " · @" + state.username;
  const stage = state.registrationStage;
  show("register", !stage && !state.userId);
  show("verify", !state.userId && ["registered", "verifying"].includes(stage));
  show("resend-verification", !state.userId && ["registered", "verifying"].includes(stage));
  show("recovery", !state.userId);
  show(
    "login",
    Boolean(state.userId || ["verifying", "verified"].includes(stage)),
  );
  if (trusted) renderChats();
}
function element(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  return node;
}
const chatClock = new Intl.DateTimeFormat("ru", {hour: "2-digit", minute: "2-digit"});
let unreadWatch;
function stopWatchingUnread() {
  unreadWatch?.observer.disconnect();
  unreadWatch = undefined;
}
function watchUnread(chat, target) {
  const current = opened, group = selected, total = chat?.receivedCount ?? 0;
  if (!current || !chat || !target || document.visibilityState !== "visible" || total <= (chat.readCount ?? 0)) {
    stopWatchingUnread();
    return;
  }
  if (unreadWatch?.target === target && unreadWatch.total === total) return;
  stopWatchingUnread();
  const observer = new IntersectionObserver(entries => {
    if (unreadWatch?.observer !== observer || opened !== current || selected !== group ||
        document.visibilityState !== "visible" || !entries.at(-1)?.isIntersecting) return;
    observer.disconnect();
    current.markRead(group, total).then(() => {
      if (opened === current) renderChats();
    }).catch(error => {
      if (unreadWatch?.observer === observer) stopWatchingUnread();
      if (opened === current) notice(errorMessage(error));
    });
  });
  unreadWatch = {observer, target, total};
  observer.observe(target);
}
document.addEventListener("visibilitychange", () => {
  stopWatchingUnread();
  if (document.hidden) clearPeerProfile();
  if (opened && !byId("conversations").hidden) renderChats();
});

function renderChats() {
  const chats = opened?.handle.state.messenger?.chats ?? {};
  const list = byId("chat-list");
  const identities = Object.values(chats).map(({ id, peerName }) => [
    id,
    peerName,
  ]);
  const signature = JSON.stringify(identities);
  if (opened.listSignature !== signature) {
    opened.listSignature = signature;
    list.replaceChildren();
    for (const [id, peerName] of identities) {
      const btn = element("button");
      const avatar = element("span", peerName.slice(0, 1).toUpperCase());
      avatar.className = "chat-avatar";
      avatar.setAttribute("aria-hidden", "true");
      const body = element("span");
      body.className = "chat-row-text";
      const preview = element("span");
      preview.className = "chat-preview";
      body.append(element("strong", "@" + peerName), preview);
      const unread = element("span");
      unread.className = "chat-unread";
      unread.hidden = true;
      btn.append(avatar, body, unread);
      btn.dataset.chat = id;
      btn.onclick = () => {
        if (selected !== id) {
          opened.visibleMessages = 100;
          byId("compose").elements.text.value = opened.getDraft(id)?.text ?? "";
          composeRevision++;
        }
        selected = id;
        opened.mesh.select(id);
        renderChats();
        if (window.matchMedia("(max-width: 44rem)").matches) byId("peer").focus();
      };
      list.append(btn);
    }
    if (!identities.length)
      list.textContent = "Здесь появятся проверенные диалоги.";
  }
  for (const button of list.querySelectorAll("button[data-chat]")) {
    const id = button.dataset.chat;
    const unread = button.querySelector(".chat-unread");
    const count = (chats[id].receivedCount ?? 0) - (chats[id].readCount ?? 0);
    unread.hidden = count <= 0;
    if (count > 0) {
      unread.textContent = String(count);
      unread.setAttribute("aria-label", "Непрочитанных сообщений: " + count);
    }
    const last = chats[id].messages.at(-1);
    const preview = opened.getDraft(id)?.text;
    const summary = preview ? "Черновик: " + preview : last?.text || "Пока нет сообщений";
    const field = button.querySelector(".chat-preview");
    if (field.textContent !== summary) field.textContent = summary;
    if (id === selected) button.setAttribute("aria-current", "true");
    else button.removeAttribute("aria-current");
  }
  const chat = chats[selected];
  const peerContext = peerProfileContext();
  if (peerProfileView && !samePeerProfile(peerProfileView, peerContext)) clearPeerProfile();
  show("peer-profile-open", Boolean(peerContext));
  byId("conversations").classList.toggle("thread-open", Boolean(chat));
  show("thread-placeholder", !chat);
  show("thread", Boolean(chat));
  if (!chat) {
    stopWatchingUnread();
    disposePhotoControls(opened);
    opened.mesh.select(null);
    opened.timelineSignature = null;
    opened.renderedGroup = null;
    byId("messages").replaceChildren();
    return;
  }
  byId("peer").textContent = "@" + chat.peerName;
  show("reconfirm-chat", Boolean(chat.bindingConflict));
  show("compose", !chat.bindingConflict);
  show("photo-picker", !chat.bindingConflict && chat.active !== false);
  if (opened.renderedGroup !== selected || chat.bindingConflict) {
    byId("send-photo").reset();
    byId("photo-picker").open = false;
  }
  if (opened.renderedGroup !== selected) byId("reconfirm-chat").reset();
  const messages = byId("messages");
  const count = opened.visibleMessages ?? 100;
  show("earlier", chat.messages.length > count);
  const rows = chat.messages.slice(-count);
  const version = JSON.stringify([
    selected,
    rows.map(({ id, status }) => [id, status]),
  ]);
  if (opened.timelineSignature === version) {
    watchUnread(chat, messages.lastElementChild?.querySelector("small") ?? messages.lastElementChild);
    return;
  }
  const timeline = byId("timeline");
  const previousHeight = timeline.scrollHeight;
  const previousTop = timeline.scrollTop;
  const wasAtEnd = previousHeight - previousTop - timeline.clientHeight < 48;
  const newChat = opened.renderedGroup !== selected;
  const previousFirst = messages.firstElementChild?.dataset.message;
  const prepended = !newChat && previousFirst && rows[0]?.id !== previousFirst &&
    rows.some((message) => message.id === previousFirst);
  opened.renderedGroup = selected;
  opened.timelineSignature = version;
  disposePhotoControls(opened);
  opened.photoControls ??= new Set();
  messages.replaceChildren();
  for (const message of rows) {
    const row = element("li");
    row.append(element("span", message.text));
    if (message.attachment?.media === "photo" && message.status !== "queued") {
      const name = typeof message.attachment.name === "string" ? message.attachment.name : "Фото";
      const current = opened;
      const group = selected;
      const control = privatePhotoControl({
        name,
        open: () => current.mesh.openPhoto(group, message),
        release: (url) => current.mesh.releasePhoto(url),
        onError: (error) => {
          if (opened === current) notice(errorMessage(error));
        },
      });
      opened.photoControls.add(control);
      row.append(control.element);
    }
    const footer = element("small");
    if (Number.isFinite(message.recordedAt)) {
      const when = new Date(message.recordedAt);
      if (!Number.isNaN(when.getTime())) {
        const time = element("time", chatClock.format(when));
        time.dateTime = when.toISOString();
        time.title = "Время на этом устройстве";
        footer.append(time);
      }
    }
    row.dir = "auto";
    row.dataset.message = message.id;
    if (message.direction === "outgoing") {
      row.className = "out";
      footer.append(element("span", message.status === "saved" ? "Принято сервером" : "В очереди"));
    }
    if (footer.childNodes.length) row.append(footer);
    messages.append(row);
  }
  if (prepended) timeline.scrollTop = previousTop + timeline.scrollHeight - previousHeight;
  else if (newChat || wasAtEnd) timeline.scrollTop = timeline.scrollHeight;
  watchUnread(chat, messages.lastElementChild?.querySelector("small") ?? messages.lastElementChild);
}
byId("to-chats").onclick = () => {
  const old = selected;
  selected = null;
  composeRevision++;
  byId("compose").reset();
  byId("send-photo").reset();
  renderChats();
  for (const button of byId("chat-list").querySelectorAll("button[data-chat]")) {
    if (button.dataset.chat === old) button.focus();
  }
};
function renderRequests(current, value) {
  const root = byId("requests");
  const rows = [];
  for (const row of value?.requests ?? []) {
    if (!row.established && !row.outgoing && !row.accepted)
      rows.push(["accept", row, "Принять приглашение от @" + row.username]);
    if (!row.established && row.outgoing && row.accepted)
      rows.push(["establish", row, "Открыть чат с @" + row.username]);
  }
  for (const row of value?.welcomes ?? []) {
    const receipt = current.handle.state.messenger?.accepted?.[row.invitation];
    if (!receipt?.posted || receipt.reference !== row.reference ||
        row.recipient !== current.handle.state.identity.identity ||
        receipt.peerDevice !== row.sender || receipt.peerKey !== row.senderKey) {
      rows.push(["blocked", row, "Приглашение не совпадает с сохранённым согласием. Попросите собеседника отправить новое."]);
    } else if (!receipt.coreConsent && !receipt.joined) {
      rows.push(["reconfirm", row, "Сверить код и повторно принять приглашение"]);
    } else {
      rows.push(["join", row, "Проверить приглашение и открыть чат"]);
    }
  }
  // Keep the fingerprint field and its focus during background refreshes.
  const key = JSON.stringify(rows);
  if (current.requestKey === key) return;
  current.requestKey = key;
  root.replaceChildren();
  for (const [act, row, label] of rows) {
    if (act === "blocked") {
      root.append(element("p", label));
      continue;
    }
    const form = element("form"),
      button = element("button", label);
    button.dataset.action = act;
    if (act !== "join") {
      const field = element(
        "label",
        "Код, полученный непосредственно от собеседника",
      );
      const input = element("input");
      input.name = "fingerprint";
      input.required = true;
      input.autocomplete = "off";
      input.spellcheck = false;
      field.append(input);
      form.append(field);
    }
    form.append(button);
    bind(form, async () => {
      await current.mesh[act === "reconfirm" ? "join" : act](row, form.elements.fingerprint?.value);
      await refresh(current);
    });
    root.append(form);
  }
}
async function refresh(current) {
  const result = await current.mesh.tick();
  if (opened !== current) return;
  directory = result ?? {};
  layout();
  renderRequests(current, directory);
}
function sync(current) {
  current.mesh.stop();
  if (
    !current.handle.state.session ||
    !current.handle.state.enrollmentVerified ||
    document.hidden
  )
    return;
  current.mesh.start(
    (value) => {
      if (opened !== current) return;
      directory = value ?? {};
      layout();
      renderRequests(current, directory);
    },
    (err) => {
      if (opened !== current) return;
      if (
        !current.handle.state.session ||
        current.handle.state.session.refreshPending
      ) {
        current.mesh.stop();
        layout();
      }
      notice(errorMessage(err));
    },
  );
}
function bind(form, action) {
  form.onsubmit = async (event) => {
    event.preventDefault();
    const button = form.querySelector("button");
    if (button.disabled) return;
    button.disabled = true;
    const before = generation;
    notice("");
    try {
      await action();
    } catch (error) {
      if (before === generation) notice(errorMessage(error));
    } finally {
      button.disabled = false;
    }
  };
}
bind(byId("entry"), async () => {
  const form = byId("entry"),
    password = byId("password").value;
  const before = generation;
  const worker = rpc();
  let handle;
  try {
    await closingVault;
    if (before !== generation) throw failure("locked");
    if (hasLocal) handle = await unlockVault(password);
    else {
      const username = form.elements.username.value.trim();
      const displayName = form.elements.name.value.trim();
      const segments = new Intl.Segmenter(undefined, {
        granularity: "grapheme",
      });
      if (
        !displayName ||
        [...segments.segment(displayName)].length > 64 ||
        /[\p{Cc}\u202a-\u202e\u2066-\u2069]/u.test(displayName)
      )
        throw failure("INVALID_DISPLAY_NAME");
      const { snapshot, result: identity } = await worker.call({
        request: { op: "init", identity: crypto.randomUUID() },
      });
      if (before !== generation) throw failure("locked");
      handle = await createVault(password, {
        version: 1,
        endpoint: apiOrigin,
        username,
        displayName,
        identity,
        snapshot,
        session: null,
      });
      hasLocal = true;
    }
    if (before !== generation) throw failure("locked");
    const profile = handle.state;
    await worker.call({
      type: "unlockCredential",
      args: [profile.endpoint, profile.username, password],
    });
    if (before !== generation) throw failure("locked");
    const current = attach(handle, worker);
    byId("password").value = "";
    byId("show-password").checked = false;
    byId("password").type = "password";
    const fingerprint = await deviceFingerprint(
      handle.state.identity.public_key,
    );
    if (opened !== current) return;
    byId("my-code").textContent = fingerprint;
    layout();
    sync(current);
  } catch (err) {
    if (opened?.worker === worker) lock();
    else {
      worker.stop();
      if (handle) closeVault(handle);
    }
    throw err;
  }
});
for (const id of ["register", "verify", "resend-verification", "recovery-request", "recovery-complete", "login"]) {
  const form = byId(id);
  bind(form, async () => {
    const current = opened,
      state = current.handle.state;
    if (id === "register") {
      await current.account.register(
        state.username,
        form.elements.email.value,
        undefined,
        state.displayName,
      );
      notice("Введите код из письма.");
    } else if (id === "verify") {
      try {
        await current.account.verify(form.elements.code.value);
      } finally {
        if (opened === current) layout();
      }
      notice("Почта подтверждена. Можно войти.");
      form.reset();
    } else if (id === "resend-verification") {
      await current.account.resendVerification();
      notice("Проверьте почту. Новый код можно запрашивать раз в пять минут, до пяти раз в сутки.");
    } else if (id === "recovery-request") {
      await current.account.requestRecovery(form.elements.email.value);
      notice("Если адрес подтверждён, письмо с кодом восстановления отправлено.");
    } else if (id === "recovery-complete") {
      await current.account.completeRecovery(form.elements.code.value);
      form.reset();
      notice("Пароль аккаунта восстановлен. Теперь войдите на этом устройстве.");
    } else {
      await current.account.login();
      notice(
        current.handle.state.enrollmentVerified
          ? "Вход выполнен."
          : "Устройство ожидает независимой проверки.",
      );
    }
    if (opened === current) {
      layout();
      sync(current);
    }
  });
}
bind(byId("reconfirm-chat"), async () => {
  const current = opened, group = selected, form = byId("reconfirm-chat");
  await current.mesh.reconfirmChat(group, form.elements.code.value);
  if (opened === current && selected === group) {
    form.reset();
    renderChats();
  }
});
bind(byId("invite"), async () => {
  const f = byId("invite"),
    current = opened;
  await current.mesh.invite(f.elements.peer.value);
  f.reset();
  notice("Приглашение отправлено.");
  await refresh(current);
});
let composeRevision = 0;
byId("compose").elements.text.addEventListener("input", (event) => {
  composeRevision++;
  if (opened && selected) opened.edit(selected, event.target.value);
});
bind(byId("compose"), async () => {
  const current = opened,
    form = byId("compose"),
    group = selected,
    revision = composeRevision,
    text = form.elements.text.value;
  if (!text.trim()) return;
  await current.mesh.send(group, text, current.getDraft(group)?.revision);
  if (opened !== current) return;
  if (selected === group && composeRevision === revision) form.reset();
  renderChats();
});
bind(byId("send-photo"), async () => {
  const current = opened, group = selected, form = byId("send-photo");
  const file = form.elements.photo.files[0];
  if (!current || !group || !file) return;
  await current.mesh.sendPhoto(group, file);
  if (opened !== current || selected !== group) return;
  if (form.elements.photo.files[0] === file) {
    form.reset();
    byId("photo-picker").open = false;
  }
  renderChats();
});
function archiveValid(value) {
  return (
    value &&
    Object.keys(value).sort().join(",") === "chats,type" &&
    value.type === "securemesh-text-archive-v1" &&
    Array.isArray(value.chats) &&
    value.chats.length <= 1000 &&
    value.chats.every(
      (chat) =>
        chat &&
        Object.keys(chat).sort().join(",") === "messages,name" &&
        typeof chat.name === "string" &&
        chat.name.length <= 256 &&
        Array.isArray(chat.messages) &&
        chat.messages.every(
          (m) =>
            m &&
            Object.keys(m).sort().join(",") === "mine,text" &&
            typeof m.text === "string" &&
            typeof m.mine === "boolean",
        ),
    )
  );
}
bind(byId("export"), async () => {
  const form = byId("export"),
    current = opened;
  const chats = Object.values(current.handle.state.messenger?.chats ?? {}).map(
    (chat) => ({
      name: chat.peerName,
      messages: chat.messages.map((m) => ({
        mine: m.direction === "outgoing",
        text: m.text,
      })),
    }),
  );
  const secret = form.elements.secret.value;
  form.reset();
  const bytes = await exportBackup(secret, {
    type: "securemesh-text-archive-v1",
    chats,
  });
  if (opened !== current) return;
  const url = URL.createObjectURL(
    new Blob([bytes], { type: "application/octet-stream" }),
  );
  const a = element("a");
  a.href = url;
  a.download = "SecureMesh-history.smbackup";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
});
bind(byId("restore"), async () => {
  const form = byId("restore"),
    file = form.elements.file.files[0],
    secret = form.elements.secret.value,
    before = generation;
  form.reset();
  byId("archive-view").replaceChildren();
  if (!file || file.size > maxBackupLength) throw failure("size");
  const archive = await readBackup(secret, await file.text(), archiveValid);
  if (before !== generation) return;
  byId("archive-view").append(element("p", "Архив для чтения"));
  for (const chat of archive.chats) {
    const section = element("details");
    section.append(element("summary", "@" + chat.name));
    section.ontoggle = () => {
      while (section.children.length > 1) section.lastChild.remove();
      if (section.open)
        for (const msg of chat.messages)
          section.append(element("p", (msg.mine ? "Вы: " : "") + msg.text));
    };
    byId("archive-view").append(section);
  }
});
byId("show-password").onchange = (e) => {
  byId("password").type = e.target.checked ? "text" : "password";
};
byId("earlier").onclick = () => {
  if (!opened) return;
  opened.visibleMessages = (opened.visibleMessages ?? 100) + 100;
  renderChats();
};
byId("lock").onclick = lock;
byId("refresh").onclick = () => {
  const current = opened;
  refresh(current).catch((e) => {
    if (opened === current) notice(errorMessage(e));
  });
};
window.addEventListener("pagehide", lock);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) lock();
});
for (const name of ["pointerdown", "keydown"])
  document.addEventListener(
    name,
    (e) => {
      if (e.isTrusted && opened) opened.account.activity().catch(() => {});
    },
    { passive: true },
  );
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("./sw.js", { scope: "./" }).catch(() => {
    notice(
      "Не удалось сохранить приложение для работы офлайн. Откройте справку при подключении к сети.",
    );
  });
}
try {
  hasLocal = await hasVault();
  layout();
} catch {
  notice("Браузер не разрешил защищённое локальное хранилище.");
  show("loading", false);
}
