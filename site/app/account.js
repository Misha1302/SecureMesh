export const apiOrigin = "https://securemesh.90-156-230-119.sslip.io";

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const lowerHex = /^[0-9a-f]{64}$/;
const usernamePattern = /^[a-z0-9_]{3,32}$/;
const trustStates = new Set(["DEVICE_TRUSTED", "DEVICE_PENDING_TRUST"]);
const methods = new Set(["GET", "POST", "PUT", "DELETE", "PATCH"]);
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const protocolError = "ACCOUNT_RESPONSE_MISMATCH";

export class AccountError extends Error {
  constructor(code, status = 0) {
    super(code);
    this.name = "AccountError";
    this.code = code;
    this.status = status;
  }
}

function require(check, code = protocolError) {
  if (!check) throw new AccountError(code);
}

function isId(value) {
  return typeof value === "string" && value.length === 36 && uuid.test(value) &&
    value !== "00000000-0000-0000-0000-000000000000";
}

function isToken(value) {
  return typeof value === "string" && value.length === 64 && lowerHex.test(value);
}

function decodeBase64(value, length) {
  require(typeof value === "string" && value.length <= 2048);
  try {
    const binary = atob(value);
    require(btoa(binary) === value && (length === undefined || binary.length === length));
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
  } catch {
    throw new AccountError(protocolError);
  }
}

export async function deviceFingerprint(publicKey) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", decodeBase64(publicKey, 32)));
  const hex = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("").toUpperCase();
  return hex.match(/.{4}/g).join(" ");
}

function principal(state) {
  require(state.endpoint === apiOrigin, "SERVER_ORIGIN_MISMATCH");
  require(typeof state.username === "string" && state.username === state.username.trim() &&
    usernamePattern.test(state.username), "INVALID_USERNAME");
  require(isId(state.identity?.identity), "LOCAL_DEVICE_MISMATCH");
  decodeBase64(state.identity.public_key, 32);
  const { userId, trustState } = state;
  if (userId != null || trustState != null) {
    require(isId(userId) && trustStates.has(trustState), "ACCOUNT_BINDING_MISMATCH");
  }
  return {
    endpoint: state.endpoint,
    username: state.username,
    deviceId: state.identity.identity,
    publicKey: state.identity.public_key,
    userId: userId ?? null,
    trustState: trustState ?? null,
  };
}

function stillBound(state, original) {
  const current = principal(state);
  require(Object.keys(original).every((key) => current[key] === original[key]), "ACCOUNT_BINDING_MISMATCH");
}

function exchangeUrl(path) {
  require(typeof path === "string" && /^\/v[12]\/[A-Za-z]/.test(path) &&
    !/[\\#\u0000-\u0020]/.test(path), "INVALID_API_PATH");
  const url = new URL(path, apiOrigin);
  require(url.origin === apiOrigin && /^\/v[12]\//.test(url.pathname), "INVALID_API_PATH");
  return url;
}

async function exchange(path, data, method = data === undefined ? "GET" : "POST", token) {
  const url = exchangeUrl(path);
  require(methods.has(method), "INVALID_API_METHOD");
  const headers = { Accept: "application/json" };
  if (token !== undefined) {
    require(isToken(token), "SESSION_INVALID");
    headers.Authorization = `Bearer ${token}`;
  }
  if (data !== undefined) headers["Content-Type"] = "application/json";
  let response;
  try {
    response = await fetch(url.href, {
      method, headers,
      body: data === undefined ? undefined : JSON.stringify(data),
      redirect: "error", credentials: "omit", cache: "no-store",
      referrerPolicy: "no-referrer", mode: "cors",
    });
  } catch {
    throw new AccountError("NETWORK_UNAVAILABLE");
  }
  require(!response.redirected && (!response.url || response.url === url.href), "SERVER_ORIGIN_MISMATCH");
  let body;
  if (response.status !== 204 && response.status !== 202) {
    const json = /^application\/(?:json|problem\+json)(?:\s*;|$)/i.test(response.headers.get("content-type") ?? "");
    if (json) {
      try { body = await response.json(); } catch { /* handled below */ }
    }
  }
  if (!response.ok) {
    const code = typeof body?.code === "string" && /^[A-Z][A-Z0-9_]{0,83}$/.test(body.code)
      ? body.code : "SERVER_REQUEST_FAILED";
    throw new AccountError(code, response.status);
  }
  require(body !== undefined || response.status === 202 || response.status === 204);
  return body;
}

function checkChallenge(challenge, binding) {
  const code = "DEVICE_CHALLENGE_MISMATCH";
  try {
    require(isId(challenge?.challengeId), code);
    const parts = utf8.decode(decodeBase64(challenge.payload)).split("\n");
    require(parts.length === 5 && parts[0] === "SecureMesh/device/v1" &&
      parts[1] === challenge.challengeId && parts[2] === binding.deviceId &&
      parts[3] === binding.username && isToken(parts[4]), code);
  } catch {
    throw new AccountError(code);
  }
}

function validatedSession(session, binding) {
  require(session?.deviceId === binding.deviceId && trustStates.has(session.trustState) &&
    (binding.trustState === null || session.trustState === binding.trustState) &&
    isToken(session.accessToken) && isToken(session.refreshToken) &&
    session.accessToken !== session.refreshToken &&
    Number.isInteger(session.expiresIn) && session.expiresIn >= 1 && session.expiresIn <= 86400);
  return {
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    expiresIn: session.expiresIn,
    deviceId: session.deviceId,
    trustState: session.trustState,
  };
}

async function checkedAccount(session, binding) {
  const me = await exchange("/v1/users/me", undefined, "GET", session.accessToken);
  require(isId(me?.userId) && me.deviceId === binding.deviceId &&
    me.trustState === session.trustState && (binding.userId === null || me.userId === binding.userId));
  return me;
}

export function createAccount(ctx) {
  let authenticating = false;
  let rotation;
  let activityAttempt = -Infinity;

  async function register(name, email, password, displayName) {
    const state = ctx.state();
    const binding = principal(state);
    require(binding.userId === null && name === binding.username, "ACCOUNT_BINDING_MISMATCH");
    require(typeof email === "string" && email.trim().length <= 254 && email.trim().includes("@"), "INVALID_EMAIL");
    const display = displayName ?? state.displayName ?? name;
    require(typeof display === "string" && display.trim().length > 0, "INVALID_DISPLAY_NAME");
    const credential = await ctx.derive(apiOrigin, name, password);
    decodeBase64(credential, 32);
    stillBound(ctx.state(), binding);
    await exchange("/v2/auth/register", { username: name, email: email.trim(), displayName: display.trim(), credential });
    await ctx.update((draft) => {
      stillBound(draft, binding);
      draft.registrationStage ??= "registered";
    });
  }

  async function resendVerification(password) {
    const state = ctx.state();
    const binding = principal(state);
    require(binding.userId === null, "ACCOUNT_BINDING_MISMATCH");
    require(["registered", "verifying"].includes(state.registrationStage), "REGISTRATION_REQUIRED");
    const credential = await ctx.derive(apiOrigin, binding.username, password);
    decodeBase64(credential, 32);
    stillBound(ctx.state(), binding);
    await exchange("/v2/auth/resend-verification", { username: binding.username, credential });
  }

  async function verify(code) {
    const state = ctx.state();
    const binding = principal(state);
    require(binding.userId === null, "ACCOUNT_BINDING_MISMATCH");
    require(typeof code === "string" && isToken(code.trim()), "INVALID_TOKEN");
    const prior = state.registrationStage;
    require(prior === "registered" || prior === "verifying", "REGISTRATION_REQUIRED");
    await ctx.update((draft) => {
      stillBound(draft, binding);
      require(draft.registrationStage === prior, "REGISTRATION_CHANGED");
      draft.registrationStage = "verifying";
    });
    try {
      await exchange("/v1/auth/verify-email", { token: code.trim() });
    } catch (error) {
      if (prior === "registered" && error.status === 400 && error.code === "INVALID_TOKEN") {
        await ctx.update((draft) => {
          stillBound(draft, binding);
          if (draft.registrationStage === "verifying") draft.registrationStage = "registered";
        });
      }
      throw error;
    }
    await ctx.update((draft) => {
      stillBound(draft, binding);
      draft.registrationStage = "verified";
    });
  }

  async function login(password) {
    require(!authenticating, "SIGN_IN_BUSY");
    authenticating = true;
    try {
      if (rotation) await rotation.catch(() => undefined);
      const state = ctx.state();
      const binding = principal(state);
      const existing = binding.userId !== null;
      const canEnroll = state.registrationStage === "verified" || state.registrationStage === "verifying";
      require(existing || canEnroll, "EMAIL_VERIFICATION_REQUIRED");
      const challenge = await exchange("/v1/auth/challenge", {
        username: binding.username, deviceId: binding.deviceId,
      });
      checkChallenge(challenge, binding);
      stillBound(ctx.state(), binding);
      const proof = await ctx.run("sign", { payload: challenge.payload });
      decodeBase64(proof?.signature, 64);
      const credential = await ctx.derive(apiOrigin, binding.username, password);
      decodeBase64(credential, 32);
      stillBound(ctx.state(), binding);
      const data = {
        username: binding.username, credential, deviceId: binding.deviceId,
        publicKey: binding.publicKey, challengeId: challenge.challengeId, signature: proof.signature,
      };
      if (existing) {
        data.expectedUserId = binding.userId;
        data.expectedTrustState = binding.trustState;
      }
      const session = validatedSession(await exchange(
        existing ? "/v2/auth/reauthenticate" : "/v2/auth/login", data,
      ), binding);
      const me = await checkedAccount(session, binding);
      await ctx.update((draft) => {
        stillBound(draft, binding);
        draft.userId = me.userId;
        draft.trustState = me.trustState;
        draft.session = session;
        if (!existing) {
          require(draft.registrationStage === "verified" || draft.registrationStage === "verifying", "REGISTRATION_CHANGED");
          draft.registrationStage = "verified";
          draft.enrollmentVerified = me.trustState === "DEVICE_TRUSTED";
        }
      });
      activityAttempt = -Infinity;
      return me;
    } finally {
      authenticating = false;
    }
  }

  async function clearSession(binding, accessToken) {
    await ctx.update((draft) => {
      stillBound(draft, binding);
      if (draft.session?.accessToken === accessToken) draft.session = null;
    });
  }

  async function rotate(binding, session) {
    try {
      // Reserve the single-use token in the encrypted vault before sending.
      // This also prevents a second tab holding an old vault revision from
      // using the same refresh token. A crash after reservation requires login.
      await ctx.update((draft) => {
        stillBound(draft, binding);
        require(draft.session?.accessToken === session.accessToken && !draft.session.refreshPending, "SESSION_CHANGED");
        draft.session.refreshPending = true;
      });
    } catch (error) {
      throw new AccountError(error?.code === "locked" ? "PROFILE_LOCKED" : "SESSION_CHANGED");
    }

    try {
      stillBound(ctx.state(), binding);
      const next = validatedSession(await exchange("/v1/auth/refresh", { token: session.refreshToken }), binding);
      require(next.accessToken !== session.accessToken && next.refreshToken !== session.refreshToken);
      await checkedAccount(next, binding);
      await ctx.update((draft) => {
        stillBound(draft, binding);
        require(draft.session?.accessToken === session.accessToken && draft.session.refreshPending === true, "SESSION_CHANGED");
        draft.session = next;
      });
    } catch (error) {
      // A refresh may have succeeded server-side even when the response was
      // lost. An already-reserved token must never be sent again.
      try { await clearSession(binding, session.accessToken); } catch { /* durable reservation remains */ }
      throw new AccountError("SESSION_EXPIRED", error?.status ?? 0);
    }
  }

  async function api(path, data, method) {
    const url = exchangeUrl(path);
    require(!/^\/v[12]\/auth\/(?:register|resend-verification|verify-email|challenge|login|reauthenticate|refresh)(?:\/|$)/.test(url.pathname), "INVALID_API_PATH");
    const state = ctx.state();
    const binding = principal(state);
    require(binding.userId !== null && !authenticating, "SESSION_REQUIRED");
    require(state.enrollmentVerified === true && binding.trustState === "DEVICE_TRUSTED", "DEVICE_ENROLLMENT_REQUIRED");
    if (rotation) await rotation;
    stillBound(ctx.state(), binding);
    const currentSession = () => {
      const { session } = ctx.state();
      require(session !== null && session !== undefined && !session.refreshPending, "SESSION_REQUIRED");
      return validatedSession(session, binding);
    };
    const observed = currentSession();
    const send = async (session) => {
      const result = await exchange(path, data, method, session.accessToken);
      stillBound(ctx.state(), binding);
      return result;
    };

    try {
      return await send(observed);
    } catch (error) {
      if (error?.status !== 401) throw error;
      stillBound(ctx.state(), binding);
      require(!authenticating, "SESSION_REQUIRED");
      if (!rotation && currentSession().accessToken === observed.accessToken) {
        rotation = rotate(binding, observed).finally(() => { rotation = undefined; });
      }
      if (rotation) await rotation;
      stillBound(ctx.state(), binding);
      const next = currentSession();
      try {
        return await send(next);
      } catch (failure) {
        if (failure?.status !== 401) throw failure;
        await clearSession(binding, next.accessToken);
        throw new AccountError("SESSION_EXPIRED", failure.status);
      }
    }
  }

  async function activity() {
    if (document.visibilityState !== "visible") return;
    const state = ctx.state();
    if (!state.session || state.enrollmentVerified !== true || state.trustState !== "DEVICE_TRUSTED" || authenticating) return;
    const now = performance.now();
    if (now - activityAttempt < 60_000) return;
    activityAttempt = now;
    await api("/v1/auth/session/activity", undefined, "POST");
  }

  return { register, resendVerification, verify, login, api, activity };
}
