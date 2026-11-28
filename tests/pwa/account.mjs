import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { setImmediate as nextTurn } from "node:timers/promises";

const source = await readFile(new URL("../../site/app/account.js", import.meta.url), "base64");
const { createAccount, deviceFingerprint, apiOrigin } = await import(`data:text/javascript;base64,${source}`);
globalThis.crypto ??= webcrypto;
globalThis.document = { visibilityState: "visible" };

const identity = "7376c51f-25fb-4c94-9828-70932703dd31";
const userId = "1d3fa786-d887-4150-8c38-31935665b08c";
const challengeId = "93ab518b-538b-4548-ae41-1a800b91575c";
const publicKey = Buffer.alloc(32, 1).toString("base64");
const signature = Buffer.alloc(64, 7).toString("base64");
const derived = Buffer.alloc(32, 2).toString("base64");
const username = "marina_24";
const passphrase = "  Пароль-🔑 phrase  ";
const trustState = "DEVICE_TRUSTED";
const emailCode = "e".repeat(64);
const session = (access = "a", refresh = "b") => ({ deviceId: identity, trustState,
  accessToken: access.repeat(64), refreshToken: refresh.repeat(64), expiresIn: 900 });
const challenge = (parts = {}) => ({
  challengeId,
  payload: Buffer.from([
    parts.protocol ?? "SecureMesh/device/v1", parts.challengeId ?? challengeId,
    parts.deviceId ?? identity, parts.username ?? username, parts.nonce ?? "c".repeat(64),
  ].join("\n")).toString("base64"),
});
const me = { userId, deviceId: identity, trustState, displayName: "Марина — 🪴" };
const request = (body, status = 200) => new Response(body === undefined ? undefined : JSON.stringify(body),
  { status, headers: body === undefined ? {} : { "Content-Type": "application/json" } });
const calls = [];
let fake;
globalThis.fetch = async (rawUrl, options) => {
  const url = new URL(rawUrl);
  assert.equal(url.origin, apiOrigin);
  assert.equal(options.redirect, "error");
  assert.equal(options.credentials, "omit");
  assert.equal(options.cache, "no-store");
  assert.equal(options.referrerPolicy, "no-referrer");
  assert.equal(options.mode, "cors");
  const entry = { path: url.pathname, method: options.method,
    authorization: options.headers.Authorization,
    data: options.body ? JSON.parse(options.body) : undefined };
  calls.push(entry);
  return fake(entry);
};

function context(initial) {
  let state = Object.assign({ endpoint: apiOrigin, username, identity: { identity, public_key: publicKey },
    userId: null, trustState: null, session: null }, initial);
  let open = true;
  let signs = 0;
  const ctx = {
    state() { assert(open, "profile locked"); return state; },
    async update(mutate) {
      assert(open, "profile locked");
      const draft = structuredClone(state);
      mutate(draft);
      state = draft;
    },
    async run(op, payload) {
      assert.equal(op, "sign");
      assert.equal(payload.payload, challenge().payload);
      signs++;
      return { signature };
    },
    async derive(origin, principal, password) {
      assert.equal(origin, apiOrigin);
      assert.equal(principal, username);
      assert.equal(password, passphrase);
      return derived;
    },
  };
  return { ctx, signs: () => signs, lock: () => { open = false; } };
}

const expected = createHash("sha256").update(Buffer.from(publicKey, "base64"))
  .digest("hex").toUpperCase().match(/.{4}/g).join(" ");
assert.equal(await deviceFingerprint(publicKey), expected);
await assert.rejects(deviceFingerprint(publicKey + "\n"), /ACCOUNT_RESPONSE_MISMATCH/);

const { ctx, signs } = context({ registrationStage: "verified" });
const account = createAccount(ctx);
for (const changed of [
  { protocol: "SecureMesh/another-protocol" },
  { challengeId: userId }, { deviceId: userId }, { username: "different" },
  { nonce: "c".repeat(64) + "\r" },
]) {
  fake = ({ path }) => {
    assert.equal(path, "/v1/auth/challenge");
    return request(challenge(changed));
  };
  await assert.rejects(account.login(passphrase), /DEVICE_CHALLENGE_MISMATCH/);
}
assert.equal(signs(), 0);

fake = ({ path, data, authorization }) => {
  switch (path) {
    case "/v2/auth/register":
      assert.deepEqual(data, { username, email: "marina@example.org", displayName: me.displayName, credential: derived });
      return request(undefined, 202);
    case "/v2/auth/resend-verification":
      assert.deepEqual(data, { username, credential: derived });
      return request(undefined, 202);
    case "/v1/auth/verify-email":
      assert.deepEqual(data, { token: emailCode });
      return request(undefined, 204);
    case "/v1/auth/challenge": return request(challenge());
    case "/v2/auth/login":
      assert.deepEqual(data, { username, credential: derived, deviceId: identity, publicKey,
        challengeId, signature });
      return request(session());
    case "/v1/users/me":
      assert.equal(authorization, `Bearer ${session().accessToken}`);
      return request(me);
    default: assert.fail(path);
  }
};
await ctx.update((state) => { delete state.registrationStage; });
await assert.rejects(account.login(passphrase), /EMAIL_VERIFICATION_REQUIRED/);
await account.register(username, " marina@example.org ", passphrase, me.displayName);
assert.equal(ctx.state().registrationStage, "registered");
await account.resendVerification(passphrase);
assert.equal(ctx.state().registrationStage, "registered");
await account.verify(emailCode);
assert.equal(ctx.state().registrationStage, "verified");
assert.deepEqual(await account.login(passphrase), me);
assert.equal(ctx.state().userId, userId);
assert.equal(ctx.state().session.deviceId, identity);
assert.equal(ctx.state().enrollmentVerified, true);
assert.equal(signs(), 1);

await ctx.update((state) => { state.session = null; });
fake = ({ path, data }) => {
  if (path === "/v1/auth/challenge") return request(challenge());
  assert.equal(path, "/v2/auth/reauthenticate");
  assert.equal(data.expectedUserId, userId);
  assert.equal(data.expectedTrustState, trustState);
  return request({ code: "REAUTHENTICATION_MISMATCH" }, 403);
};
await assert.rejects(account.login(passphrase), /REAUTHENTICATION_MISMATCH/);
assert.equal(ctx.state().userId, userId);
assert.equal(ctx.state().session, null);

fake = ({ path }) => {
  if (path === "/v1/auth/challenge") return request(challenge());
  if (path === "/v2/auth/reauthenticate") return request(session());
  assert.equal(path, "/v1/users/me");
  return request({ ...me, userId: identity });
};
await assert.rejects(account.login(passphrase), /ACCOUNT_RESPONSE_MISMATCH/);
assert.equal(ctx.state().session, null);
assert.equal(ctx.state().userId, userId);

fake = ({ path }) => {
  if (path === "/v1/auth/challenge") return request(challenge());
  if (path === "/v2/auth/reauthenticate") return request(session());
  return request(me);
};
await account.login(passphrase);

let release;
let rotationCount = 0;
const blocked = new Promise((resolve) => { release = resolve; });
fake = async ({ path, data, authorization }) => {
  if (path === "/v1/auth/refresh") {
    rotationCount++;
    assert.equal(ctx.state().session.refreshPending, true);
    assert.equal(data.token, session().refreshToken);
    await blocked;
    return request(session("d", "f"));
  }
  if (path === "/v1/users/me") {
    assert.equal(authorization, `Bearer ${session("d", "f").accessToken}`);
    return request(me);
  }
  return authorization === `Bearer ${session().accessToken}`
    ? request({ code: "AUTH_REQUIRED" }, 401) : request({ ok: true });
};
const concurrent = [account.api("/v1/conversations"), account.api("/v1/conversations")];
await nextTurn();
assert.equal(rotationCount, 1);
await assert.rejects(createAccount(ctx).api("/v1/conversations"), /SESSION_REQUIRED/);
release();
assert.deepEqual(await Promise.all(concurrent), [{ ok: true }, { ok: true }]);
assert.equal(ctx.state().session.accessToken, session("d", "f").accessToken);

const activityStart = calls.length;
document.visibilityState = "hidden";
await account.activity();
document.visibilityState = "visible";
await account.activity();
await account.activity();
assert.equal(calls.length - activityStart, 1);
assert.equal(calls.at(-1).path, "/v1/auth/session/activity");
assert.equal(calls.at(-1).method, "POST");

fake = async ({ path }) => {
  if (path === "/v1/auth/refresh") throw new TypeError("connection dropped");
  return request({ code: "AUTH_REQUIRED" }, 401);
};
await assert.rejects(account.api("/v1/conversations"), /SESSION_EXPIRED/);
assert.equal(ctx.state().session, null);
assert.equal(ctx.state().userId, userId);
await assert.rejects(account.api("/v1/conversations"), /SESSION_REQUIRED/);
await assert.rejects(account.api("//evil.example/v1/conversations"), /INVALID_API_PATH/);
await assert.rejects(account.api("/v1/auth/refresh", {}), /INVALID_API_PATH/);

const other = context({ endpoint: "https://evil.example" });
await assert.rejects(createAccount(other.ctx).login(passphrase), /SERVER_ORIGIN_MISMATCH/);
const locked = context({ userId, trustState, enrollmentVerified: true, session: session() });
fake = async () => { locked.lock(); return request({ inaccessible: true }); };
await assert.rejects(createAccount(locked.ctx).api("/v1/conversations"), /profile locked/);

const ambiguous = context({ registrationStage: "registered" });
const uncertainAccount = createAccount(ambiguous.ctx);
fake = async ({ path }) => {
  if (path === "/v1/auth/verify-email") throw new TypeError("connection dropped");
  if (path === "/v1/auth/challenge") return request(challenge());
  if (path === "/v2/auth/login") return request(session());
  return request(me);
};
await assert.rejects(uncertainAccount.verify(emailCode), /NETWORK_UNAVAILABLE/);
assert.equal(ambiguous.ctx.state().registrationStage, "verifying");
await uncertainAccount.login(passphrase);
assert.equal(ambiguous.ctx.state().registrationStage, "verified");

const pending = context({ registrationStage: "verified" });
const pendingAccount = createAccount(pending.ctx);
fake = async ({ path }) => {
  if (path === "/v1/auth/challenge") return request(challenge());
  if (path === "/v2/auth/login") return request({ ...session(), trustState: "DEVICE_PENDING_TRUST" });
  return request({ ...me, trustState: "DEVICE_PENDING_TRUST" });
};
await pendingAccount.login(passphrase);
assert.equal(pending.ctx.state().enrollmentVerified, false);
await assert.rejects(pendingAccount.api("/v1/conversations"), /DEVICE_ENROLLMENT_REQUIRED/);

console.log("Browser account protocol, origin constraints and session rotation passed");
