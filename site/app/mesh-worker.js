import init, {
  execute,
  derive_server_credential_v2,
} from "./crypto/securemesh_browser_crypto.js";

const ready = init();
let credential;
self.onmessage = async ({ data }) => {
  try {
    await ready;
    let value;
    if (data.type === "unlockCredential") {
      const [endpoint, username, password] = data.args;
      credential = {
        endpoint,
        username,
        value: derive_server_credential_v2(endpoint, username, password),
      };
      value = true;
    } else if (data.type === "derive") {
      if (
        !credential ||
        credential.endpoint !== data.args[0] ||
        credential.username !== data.args[1]
      )
        throw Error();
      value = credential.value;
    } else {
      value = JSON.parse(
        execute(data.snapshot ?? undefined, JSON.stringify(data.request)),
      );
    }
    self.postMessage({ id: data.id, value });
  } catch {
    self.postMessage({ id: data.id, failed: true });
  }
};
