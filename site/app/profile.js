import {
  hasVault,
  createVault,
  unlockVault,
  closeVault,
  commitVault,
  readBackup,
  exportBackup,
  maxBackupLength,
} from "./vault.js";
import { createAccount, apiOrigin, deviceFingerprint } from "./account.js";
import { createMessenger } from "./messenger.js";

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
  NETWORK_UNAVAILABLE:
    "Нет соединения с совместимым сервером. Проверьте сеть и доступность API.",
  INVALID_TOKEN: "Не удалось подтвердить код.",
  INVALID_DISPLAY_NAME: "Проверьте имя профиля.",
  INVALID_CREDENTIALS: "Проверьте пароль и подтверждение почты.",
  SESSION_REQUIRED: "Войдите в аккаунт ещё раз.",
  SESSION_EXPIRED: "Срок сессии истёк. Очередь сохранена.",
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
    if (!edited.size) {
      closeVault(handle);
      return;
    }
    // The UI and worker lock immediately. Finish only the pending local vault write.
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
        if (error.code === "conflict" && opened === instance) {
          lock();
          notice(codes.conflict);
        }
        throw error;
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
  instance.account = createAccount(ctx);
  instance.mesh = createMessenger({ ...ctx, api: instance.account.api });
  return instance;
}
function lock() {
  generation++;
  const current = opened;
  opened = null;
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
  if (!state) return;
  byId("account-name").textContent =
    state.displayName + " · @" + state.username;
  const stage = state.registrationStage;
  show("register", !stage && !state.userId);
  show("verify", !state.userId && ["registered", "verifying"].includes(stage));
  show("resend-verification", !state.userId && ["registered", "verifying"].includes(stage));
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
      const btn = element("button", "@" + peerName);
      btn.onclick = () => {
        if (selected !== id) {
          opened.visibleMessages = 100;
          byId("compose").elements.text.value = opened.getDraft(id)?.text ?? "";
          composeRevision++;
        }
        selected = id;
        opened.mesh.select(id);
        renderChats();
      };
      list.append(btn);
    }
    if (!identities.length)
      list.textContent = "Здесь появятся проверенные диалоги.";
  }
  const chat = chats[selected];
  show("thread", Boolean(chat));
  if (!chat) return;
  byId("peer").textContent = "@" + chat.peerName;
  const messages = byId("messages");
  const count = opened.visibleMessages ?? 100;
  show("earlier", chat.messages.length > count);
  const rows = chat.messages.slice(-count);
  const version = JSON.stringify([
    selected,
    rows.map(({ id, status }) => [id, status]),
  ]);
  if (opened.timelineSignature === version) return;
  opened.timelineSignature = version;
  messages.replaceChildren();
  for (const message of rows) {
    const row = element("li", message.text);
    row.dir = "auto";
    if (message.direction === "outgoing") {
      row.className = "out";
      row.append(
        element(
          "small",
          message.status === "saved" ? "Принято сервером" : "В очереди",
        ),
      );
    }
    messages.append(row);
  }
}
function renderRequests(current, value) {
  const root = byId("requests");
  const rows = [];
  for (const row of value?.requests ?? []) {
    if (!row.established && !row.outgoing && !row.accepted)
      rows.push(["accept", row, "Принять приглашение от @" + row.username]);
    if (!row.established && row.outgoing && row.accepted)
      rows.push(["establish", row, "Открыть чат с @" + row.username]);
  }
  for (const row of value?.welcomes ?? [])
    rows.push(["join", row, "Открыть проверенное приглашение"]);
  // Keep the fingerprint field and its focus during background refreshes.
  const key = JSON.stringify(rows);
  if (current.requestKey === key) return;
  current.requestKey = key;
  root.replaceChildren();
  for (const [act, row, label] of rows) {
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
      await current.mesh[act](row, form.elements.fingerprint?.value);
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
for (const id of ["register", "verify", "resend-verification", "login"]) {
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
