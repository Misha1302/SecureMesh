//! Resumable account setup lives in the same SQLCipher transaction as the keys.
//! Account and store passwords are never journaled.
use super::*;

const DRAFT: &str = "onboarding_draft";

fn optional_meta(db: &Connection, key: &str) -> Result<Option<Value>> {
    let raw: Option<String> = db
        .query_row("SELECT value FROM app_meta WHERE key=?", [key], |r| {
            r.get(0)
        })
        .optional()?;
    raw.map(|value| Ok(serde_json::from_str(&value)?))
        .transpose()
}

fn principal(input: &Value) -> Result<(&str, &str)> {
    let endpoint = s(input, "endpoint")?;
    let username = s(input, "username")?;
    server_credential::validate_principal(endpoint, username)?;
    Ok((endpoint, username))
}

pub(super) fn server_credential(req: &Value) -> Result<String> {
    let credential = server_credential::derive_server_credential(
        s(req, "endpoint")?,
        s(req, "username")?,
        s(req, "password")?,
    )?;
    Ok(json!({"credential": credential}).to_string())
}

pub(super) fn prepare(db: &Connection, input: &Value, identity: &str) -> Result<()> {
    let (endpoint, username) = principal(input)?;
    let version = input
        .get("credentialVersion")
        .map_or(Some(1), Value::as_u64);
    ensure!(matches!(version, Some(1 | 2)), "invalid credential version");
    let registered = input["registeredHere"]
        .as_bool()
        .context("registration state")?;
    set_meta(
        db,
        DRAFT,
        &json!({
            "version": 1,
            "credentialVersion": version,
            "deviceId": identity,
            "endpoint": endpoint,
            "username": username,
            "registeredHere": registered,
            "loginUncertain": false,
        })
        .to_string(),
    )
}

pub(super) fn execute(db: &Connection, req: &Value, identity: &str) -> Result<Value> {
    let complete = optional_meta(db, "local_profile")?.is_some();
    let draft = optional_meta(db, DRAFT)?;
    if s(req, "op")? == "onboarding_state" {
        return if complete {
            Ok(json!({"stage": "complete"}))
        } else if let Some(draft) = draft {
            ensure!(s(&draft, "deviceId")? == identity, "draft device mismatch");
            Ok(
                json!({"stage": if draft.get("session").is_some() { "authenticated" } else { "prepared" }, "draft": draft}),
            )
        } else {
            Ok(json!({"stage": "missing"}))
        };
    }
    ensure!(!complete, "profile already complete");
    let mut draft = draft.context("missing onboarding draft")?;
    ensure!(s(&draft, "deviceId")? == identity, "draft device mismatch");
    match s(req, "op")? {
        "onboarding_attempt" => {
            ensure!(draft.get("session").is_none(), "session already saved");
            let prior = draft["loginUncertain"].as_bool().context("attempt state")?;
            draft["loginUncertain"] = json!(true);
            set_meta(db, DRAFT, &draft.to_string())?;
            return Ok(json!({"priorUncertain": prior}));
        }
        "onboarding_rejected" => {
            ensure!(draft.get("session").is_none(), "session already saved");
            // Called only for a conclusive first rejection, never an ambiguous
            // reply or a rejection after an earlier potentially accepted login.
            draft["loginUncertain"] = json!(false);
        }
        "onboarding_session" => {
            let session = &req["session"];
            ensure!(
                s(session, "deviceId")? == identity,
                "session device mismatch"
            );
            let trust = s(session, "trustState")?;
            ensure!(
                matches!(trust, "DEVICE_TRUSTED" | "DEVICE_PENDING_TRUST"),
                "invalid trust state"
            );
            for key in ["accessToken", "refreshToken"] {
                ensure!(
                    (1..=4096).contains(&s(session, key)?.len()),
                    "invalid session token"
                );
            }
            let expires = session["expiresIn"].as_u64().context("session expiry")?;
            ensure!((1..=86400).contains(&expires), "invalid session expiry");
            // Explicit allowlist: no credentials or unknown response fields.
            draft["session"] = json!({
                "deviceId": identity,
                "accessToken": session["accessToken"],
                "refreshToken": session["refreshToken"],
                "expiresIn": expires,
                "trustState": trust,
            });
        }
        "onboarding_reauthenticate" => {
            draft
                .as_object_mut()
                .context("invalid draft")?
                .remove("session");
        }
        "onboarding_complete" => {
            let account = &req["account"];
            ensure!(
                s(account, "deviceId")? == identity,
                "account device mismatch"
            );
            uuid::Uuid::parse_str(s(account, "userId")?)?;
            let trust = s(account, "trustState")?;
            ensure!(
                matches!(trust, "DEVICE_TRUSTED" | "DEVICE_PENDING_TRUST"),
                "invalid account trust"
            );
            let mut profile = draft.get("session").context("missing session")?.clone();
            let registered = draft["registeredHere"]
                .as_bool()
                .context("registration state")?;
            profile["credentialVersion"] =
                draft.get("credentialVersion").cloned().unwrap_or(json!(1));
            profile["endpoint"] = draft["endpoint"].clone();
            profile["username"] = draft["username"].clone();
            profile["userId"] = account["userId"].clone();
            profile["requiresEnrollment"] = json!(
                !registered
                    || trust != "DEVICE_TRUSTED"
                    || profile["trustState"] != "DEVICE_TRUSTED"
            );
            profile["enrollmentVerified"] = json!(
                registered
                    && trust == "DEVICE_TRUSTED"
                    && profile["trustState"] == "DEVICE_TRUSTED"
            );
            set_meta(db, "local_profile", &profile.to_string())?;
            db.execute("DELETE FROM app_meta WHERE key=?", [DRAFT])?;
            return Ok(json!({"saved": true}));
        }
        _ => bail!("unknown onboarding operation"),
    }
    set_meta(db, DRAFT, &draft.to_string())?;
    Ok(json!({"saved": true}))
}

#[cfg(test)]
mod credential_tests {
    use super::*;

    #[test]
    fn argon2id_v2_matches_reference_with_exact_utf8_and_spacing() {
        let mut request = json!({"endpoint":"https://example.org","username":"marina_24","password":"  Пароль-🔑 phrase  "});
        let body: Value = serde_json::from_str(&server_credential(&request).unwrap()).unwrap();
        // Generated independently with the Argon2 reference C library.
        assert_eq!(
            body["credential"],
            "6o6VxV36UehxRt6qSoL6b2PpP8FxoiHtEQ/oG8NHl4s="
        );
        request["password"] = json!("👨‍👩‍👧‍👦".repeat(15));
        assert!(server_credential(&request).is_err());
    }
}
