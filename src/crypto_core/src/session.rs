//! Device-bound refresh journal. All state changes share the SQLCipher
//! transaction with the existing profile; MLS keys/ratchets are never replaced.
use super::*;

const PENDING: &str = "refresh_pending";
const RECEIPT: &str = "refresh_completed_request";

fn optional_meta(db: &Connection, key: &str) -> Result<Option<Value>> {
    let value: Option<String> = db
        .query_row("SELECT value FROM app_meta WHERE key=?", [key], |r| {
            r.get(0)
        })
        .optional()?;
    value.map(|v| Ok(serde_json::from_str(&v)?)).transpose()
}

pub(super) fn tokens(value: &Value, identity: &str, expired: bool) -> Result<Value> {
    ensure!(s(value, "deviceId")? == identity, "session device mismatch");
    for field in ["accessToken", "refreshToken"] {
        let token = s(value, field)?;
        ensure!(
            token.len() == 64
                && token
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "invalid token"
        );
    }
    let expires = value["expiresIn"].as_u64().context("expiry")?;
    ensure!(
        expires <= 86400 && (expired || expires > 0),
        "invalid expiry"
    );
    let trust = s(value, "trustState")?;
    ensure!(
        matches!(trust, "DEVICE_TRUSTED" | "DEVICE_PENDING_TRUST"),
        "invalid trust"
    );
    let binding = value["refreshBinding"]
        .as_str()
        .unwrap_or("bearer-rotation-v1");
    ensure!(
        matches!(binding, "device-signature-v1" | "bearer-rotation-v1"),
        "invalid refresh binding"
    );
    Ok(
        json!({"accessToken":value["accessToken"], "refreshToken":value["refreshToken"],
        "expiresIn":expires,"deviceId":identity,"trustState":trust,"refreshBinding":binding}),
    )
}

fn apply_tokens(profile: &mut Value, value: &Value) -> Result<()> {
    let target = profile.as_object_mut().context("profile")?;
    for (key, value) in value.as_object().context("tokens")? {
        target.insert(key.clone(), value.clone());
    }
    Ok(())
}

pub(super) fn execute(
    db: &Connection,
    req: &Value,
    identity: &str,
    signer: &SignatureKeyPair,
) -> Result<Value> {
    let mut profile: Value = serde_json::from_str(&meta(db, "local_profile")?)?;
    ensure!(
        s(&profile, "deviceId")? == identity,
        "profile device mismatch"
    );
    let pending = optional_meta(db, PENDING)?;
    match s(req, "op")? {
        "refresh_status" => Ok(json!({"pending":pending})),
        "refresh_prepare" => {
            ensure!(
                s(req, "endpoint")? == s(&profile, "endpoint")?,
                "origin mismatch"
            );
            if let Some(pending) = pending {
                ensure!(
                    s(&pending, "endpoint")? == s(&profile, "endpoint")?
                        && s(&pending["request"], "token")? == s(&profile, "refreshToken")?
                        && s(&pending["request"], "deviceId")? == identity,
                    "pending refresh mismatch"
                );
                return Ok(json!({"request":pending["request"]}));
            }
            let token = s(&profile, "refreshToken")?;
            ensure!(
                token.len() == 64
                    && token
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "invalid token"
            );
            let id = uuid::Uuid::new_v4().to_string();
            let payload = format!(
                "SecureMesh/refresh/v1\n{id}\n{identity}\n{:x}",
                Sha256::digest(token.as_bytes())
            );
            let signature = signer
                .sign(payload.as_bytes())
                .map_err(|_| anyhow!("refresh proof failed"))?;
            let request = json!({"requestId":id,"deviceId":identity,"token":token,"signature":B64.encode(signature)});
            set_meta(
                db,
                PENDING,
                &json!({"endpoint":profile["endpoint"],"request":request}).to_string(),
            )?;
            Ok(json!({"request":request}))
        }
        "refresh_complete" => {
            let response = &req["response"];
            let id = s(response, "requestId")?;
            uuid::Uuid::parse_str(id)?;
            let next = tokens(response, identity, true)?;
            ensure!(
                next["refreshBinding"] == "device-signature-v1",
                "refresh proof binding required"
            );
            if let Some(pending) = pending {
                ensure!(
                    s(&pending["request"], "requestId")? == id
                        && s(&pending["request"], "token")? == s(&profile, "refreshToken")?
                        && s(&pending, "endpoint")? == s(&profile, "endpoint")?,
                    "refresh receipt mismatch"
                );
                ensure!(
                    next["refreshToken"] != profile["refreshToken"],
                    "refresh did not rotate"
                );
                apply_tokens(&mut profile, &next)?;
                set_meta(db, "local_profile", &profile.to_string())?;
                set_meta(db, RECEIPT, &json!(id).to_string())?;
                db.execute("DELETE FROM app_meta WHERE key=?", [PENDING])?;
            } else {
                ensure!(
                    optional_meta(db, RECEIPT)? == Some(json!(id))
                        && profile["accessToken"] == next["accessToken"]
                        && profile["refreshToken"] == next["refreshToken"],
                    "missing refresh journal"
                );
            }
            Ok(json!({"profile":profile}))
        }
        "session_reauthenticate" => {
            let account = &req["account"];
            ensure!(
                s(account, "deviceId")? == identity,
                "reauthentication device mismatch"
            );
            uuid::Uuid::parse_str(s(account, "userId")?)?;
            let username = s(account, "username")?;
            ensure!(
                (3..=32).contains(&username.len())
                    && username
                        .bytes()
                        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
                "invalid username"
            );
            if let Some(owner) = profile["userId"].as_str() {
                ensure!(
                    owner == s(account, "userId")?,
                    "reauthentication account mismatch"
                );
            }
            if let Some(old) = profile["username"].as_str() {
                ensure!(old == username, "reauthentication username mismatch");
            }
            let next = tokens(&req["session"], identity, false)?;
            ensure!(
                next["refreshBinding"] == "device-signature-v1",
                "device-bound session required"
            );
            apply_tokens(&mut profile, &next)?;
            // Legacy completed profiles omitted these public account labels.
            // Adoption requires the same signing key + successful password
            // login and matching authenticated device; no new MLS identity.
            profile["userId"] = account["userId"].clone();
            profile["username"] = account["username"].clone();
            set_meta(db, "local_profile", &profile.to_string())?;
            db.execute(
                "DELETE FROM app_meta WHERE key IN (?,?)",
                [PENDING, RECEIPT],
            )?;
            Ok(json!({"profile":profile}))
        }
        _ => bail!("unknown session operation"),
    }
}
