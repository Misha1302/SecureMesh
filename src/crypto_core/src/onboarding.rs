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

pub(super) fn prepare(db: &Connection, input: &Value, identity: &str) -> Result<()> {
    let endpoint = s(input, "endpoint")?;
    let username = s(input, "username")?;
    ensure!(
        endpoint.starts_with("https://")
            && endpoint.len() > 8
            && endpoint.len() <= 2048
            && !endpoint[8..].contains(['/', '?', '#', '@'])
            && !endpoint.chars().any(char::is_whitespace),
        "invalid origin"
    );
    ensure!(
        (3..=32).contains(&username.len())
            && username
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
        "invalid username"
    );
    let registered = input["registeredHere"]
        .as_bool()
        .context("registration state")?;
    set_meta(
        db,
        DRAFT,
        &json!({
            "version": 1,
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
            draft["session"] = session::tokens(&req["session"], identity, false)?;
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
