// Store the complete JSON profile in one atomic IndexedDB transaction.
const databaseName = "securemesh-profile";
const storeName = "vault";
const profileKey = "profile";
const format = "securemesh-browser-vault";
const version = 1;
const iterations = 600_000;
const maxStateBytes = 16 * 1024 * 1024;
export const maxBackupLength = 4 * Math.ceil((maxStateBytes + 16) / 3) + 512;
const maxRevision = 0xffff_ffff;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const sessions = new WeakMap();

class VaultError extends Error {
  constructor(code, message, cause) {
    super(message, { cause });
    this.name = "VaultError";
    this.code = code;
  }
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(storeName);
    request.onerror = () => reject(request.error);
    request.onblocked = () => {
      request.onsuccess = () => request.result.close();
      reject(new Error("The vault database is blocked"));
    };
    request.onsuccess = () => {
      const database = request.result;
      database.onversionchange = () => database.close();
      resolve(database);
    };
  });
}

async function accessRecord(replacement, expected, session) {
  let database;
  try {
    database = await openDatabase();
    return await new Promise((resolve, reject) => {
      const transaction = replacement
        ? database.transaction(storeName, "readwrite", { durability: "strict" })
        : database.transaction(storeName, "readonly");
      const store = transaction.objectStore(storeName);
      const request = store.get(profileKey);
      let result;
      let failure;
      transaction.oncomplete = () => resolve(result);
      transaction.onabort = () => reject(failure ?? transaction.error);
      request.onsuccess = () => {
        result = request.result;
        if (!replacement) return;
        if (session?.closed) {
          failure = new VaultError("locked", "The profile is locked");
        } else if (expected && (
          result?.revision !== expected.revision || result.salt !== expected.salt ||
          result.iv !== expected.iv || result.ciphertext !== expected.ciphertext ||
          result.version !== expected.version || result.format !== expected.format
        )) {
          failure = new VaultError("conflict", "The profile changed in another session");
        } else if (!expected && result !== undefined) {
          failure = new VaultError("exists", "A local profile already exists");
        }
        if (failure) transaction.abort();
        else store.put(replacement, profileKey);
      };
    });
  } catch (error) {
    if (error instanceof VaultError) throw error;
    throw new VaultError("storage", "Could not access the profile database", error);
  } finally {
    database?.close();
  }
}

function encodeBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(binary);
}

function decodeBase64(value, min, max) {
  if (typeof value !== "string" || value.length < 4 * Math.ceil(min / 3) ||
      value.length > 4 * Math.ceil(max / 3) || value.length % 4 !== 0) {
    throw new VaultError("format", "The encrypted profile has invalid encoding");
  }
  const binary = atob(value);
  if (binary.length < min || binary.length > max || btoa(binary) !== value) {
    throw new VaultError("format", "The encrypted profile has invalid encoding");
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function validateRecord(record) {
  if (record?.format !== format || record.version !== version ||
      !Number.isInteger(record.revision) || record.revision < 0 ||
      record.revision > maxRevision) {
    throw new VaultError("format", "The encrypted profile format is unsupported");
  }
  try {
    return {
      salt: decodeBase64(record.salt, 32, 32),
      iv: decodeBase64(record.iv, 12, 12),
      ciphertext: decodeBase64(record.ciphertext, 18, maxStateBytes + 16),
    };
  } catch (error) {
    throw new VaultError("format", "The encrypted profile has invalid encoding", error);
  }
}

function requireState(state) {
  if (!state || typeof state !== "object" || Array.isArray(state)) {
    throw new VaultError("format", "The profile state must be a JSON object");
  }
  return state;
}

async function deriveKey(password, salt) {
  if (typeof password !== "string" || password.length > 4096 ||
      /\p{Surrogate}/u.test(password)) {
    throw new VaultError("password", "The profile password is invalid");
  }
  let length = 0;
  for (const _ of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(password)) {
    if (++length === 16) break;
  }
  if (length < 16) {
    throw new VaultError("password", "Use at least 16 characters for the profile password");
  }
  const bytes = encoder.encode(password);
  try {
    const material = await crypto.subtle.importKey("raw", bytes, "PBKDF2", false, ["deriveKey"]);
    return await crypto.subtle.deriveKey({
      name: "PBKDF2", hash: "SHA-256", iterations, salt,
    }, material, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  } finally {
    bytes.fill(0);
  }
}

function cipherParameters(record, iv) {
  return {
    name: "AES-GCM",
    iv,
    tagLength: 128,
    additionalData: encoder.encode(JSON.stringify([format, version, record.salt, record.revision])),
  };
}

async function seal(key, salt, revision, state) {
  let serialized;
  try {
    serialized = JSON.stringify(requireState(state));
    if (serialized.length > maxStateBytes) {
      throw new VaultError("size", "The profile is too large to save");
    }
    state = requireState(JSON.parse(serialized));
  } catch (error) {
    if (error instanceof VaultError) throw error;
    throw new VaultError("format", "The profile state cannot be encoded", error);
  }
  const plaintext = encoder.encode(serialized);
  try {
    if (plaintext.length > maxStateBytes) {
      throw new VaultError("size", "The profile is too large to save");
    }
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const record = { format, version, salt, revision, iv: encodeBase64(iv) };
    const ciphertext = await crypto.subtle.encrypt(cipherParameters(record, iv), key, plaintext);
    record.ciphertext = encodeBase64(new Uint8Array(ciphertext));
    return { record, state };
  } finally {
    plaintext.fill(0);
  }
}

async function openRecord(password, record) {
  const { salt, iv, ciphertext } = validateRecord(record);
  const key = await deriveKey(password, salt);
  let plaintext;
  try {
    plaintext = new Uint8Array(await crypto.subtle.decrypt(cipherParameters(record, iv), key, ciphertext));
  } catch (error) {
    throw new VaultError("authentication", "The password is incorrect or the profile was altered", error);
  }
  try {
    return { key, state: requireState(JSON.parse(decoder.decode(plaintext))) };
  } catch (error) {
    throw new VaultError("format", "The decrypted profile state is invalid", error);
  } finally {
    plaintext.fill(0);
  }
}

function makeHandle(key, record, state) {
  const session = { key, record, state, closed: false };
  const handle = Object.freeze({
    get state() { return session.state; },
    get revision() { return session.record?.revision; },
  });
  sessions.set(handle, session);
  return handle;
}

function unlockedSession(handle) {
  const session = sessions.get(handle);
  if (!session || session.closed) throw new VaultError("locked", "The profile is locked");
  return session;
}

export async function hasVault() {
  return await accessRecord() !== undefined;
}

export async function createVault(password, state) {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const key = await deriveKey(password, salt);
  const sealed = await seal(key, encodeBase64(salt), 0, state);
  await accessRecord(sealed.record);
  return makeHandle(key, sealed.record, sealed.state);
}

export async function unlockVault(password) {
  const record = await accessRecord();
  if (record === undefined) throw new VaultError("missing", "There is no local profile");
  const { key, state } = await openRecord(password, record);
  return makeHandle(key, record, state);
}

export async function commitVault(handle, state) {
  const session = unlockedSession(handle);
  const expected = session.record;
  const revision = expected.revision + 1;
  if (revision > maxRevision) throw new VaultError("size", "The profile revision limit was reached");
  const sealed = await seal(session.key, expected.salt, revision, state);
  await accessRecord(sealed.record, expected, session);
  if (!session.closed) {
    session.record = sealed.record;
    session.state = sealed.state;
  }
  return revision;
}

// Supply an archival copy of the relevant data, excluding active MLS state.
export async function exportBackup(password, state) {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const key = await deriveKey(password, salt);
  const { record } = await seal(key, encodeBase64(salt), 0, state);
  return JSON.stringify(record);
}

export async function readBackup(password, backup, validateState) {
  if (typeof backup !== "string") {
    throw new VaultError("format", "The encrypted backup must be JSON text");
  }
  if (backup.length > maxBackupLength) {
    throw new VaultError("size", "The encrypted backup is too large");
  }
  let record;
  try {
    record = JSON.parse(backup);
  } catch (error) {
    throw new VaultError("format", "The encrypted backup is not valid JSON", error);
  }
  const { state } = await openRecord(password, record);
  if (validateState && validateState(state) !== true) {
    throw new VaultError("format", "The encrypted backup contains unsupported profile data");
  }
  return state;
}

export async function importVault(password, backup, validateState) {
  const state = await readBackup(password, backup, validateState);
  return createVault(password, state);
}

export function closeVault(handle) {
  const session = sessions.get(handle);
  if (session) {
    session.closed = true;
    session.state = undefined;
    session.key = undefined;
    session.record = undefined;
    sessions.delete(handle);
  }
}
