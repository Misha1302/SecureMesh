//! Group-scoped authorization for the native transport ingest path.
//! Raw add/remove/process operations are offline MLS fixtures, not delivery authorizations.
use super::*;
use std::collections::BTreeMap;

use std::time::{SystemTime, UNIX_EPOCH};

fn now() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

type Members = BTreeMap<String, Vec<u8>>;

pub(super) fn members(g: &MlsGroup) -> Result<Members> {
    let mut result = Members::new();
    for m in g.members() {
        let cred = BasicCredential::try_from(m.credential)?;
        let device = std::str::from_utf8(cred.identity())?.to_owned();
        ensure!(
            result.insert(device, m.signature_key).is_none(),
            "duplicate device leaf"
        );
    }
    Ok(result)
}

pub(super) fn approve(db: &Connection, p: &Provider, req: &Value) -> Result<Value> {
    ensure!(
        req["confirmed"].as_bool() == Some(true),
        "explicit group confirmation required"
    );
    let gid = s(req, "group")?;
    let g = load_group(p, gid)?;
    ensure!(
        g.is_active() && req["epoch"].as_u64() == Some(g.epoch().as_u64()),
        "stale group epoch"
    );
    check_group(db, &g)?;
    let current = members(&g)?;
    let approver = s(req, "approver")?;
    let target = s(req, "device")?;
    let action = s(req, "action")?;
    let approver_key = current
        .get(approver)
        .context("approver is not a group member")?;
    ensure!(target != approver, "self change");
    let (key, expires) = match action {
        "add" => {
            ensure!(!current.contains_key(target), "device already in group");
            let (key, expires) = enrollment::verify_roster_certificate(p, req, approver_key)?;
            enrollment::execute_pin(db, target, &key)?;
            (key, expires)
        }
        "remove" => (
            current
                .get(target)
                .context("device is not in group")?
                .clone(),
            now()? + 300,
        ),
        _ => bail!("unknown roster action"),
    };
    let grant = json!({"epoch":g.epoch().as_u64(),"approver":approver,"device":target,"key":B64.encode(key),"action":action,"expires":expires});
    set_meta(db, &format!("roster-approval:{gid}"), &grant.to_string())?;
    Ok(json!({"approved":true,"group":gid,"epoch":g.epoch().as_u64(),"mls_joined":false}))
}

pub(super) fn validate_change(
    db: &Connection,
    gid: &str,
    epoch: u64,
    committer: &str,
    before: &Members,
    after: &Members,
) -> Result<()> {
    if before == after {
        return Ok(());
    }
    let slot = format!("roster-approval:{gid}");
    let serialized = meta(db, &slot).context("group roster approval required")?;
    let grant: Value = serde_json::from_str(&serialized)?;
    ensure!(
        grant["expires"].as_u64().unwrap_or(0) > now()?
            && grant["epoch"].as_u64() == Some(epoch)
            && s(&grant, "approver")? == committer,
        "wrong roster approval epoch or committer"
    );
    let target = s(&grant, "device")?;
    let key = bytes(&grant, "key")?;
    let mut expected = before.clone();
    match s(&grant, "action")? {
        "add" => ensure!(
            expected.insert(target.to_owned(), key).is_none(),
            "target present"
        ),
        "remove" => ensure!(
            expected.remove(target).as_deref() == Some(key.as_slice()),
            "target changed"
        ),
        _ => bail!("unknown roster change"),
    }
    ensure!(&expected == after, "unexpected roster transition");
    db.execute("DELETE FROM app_meta WHERE key=?", [slot])?;
    Ok(())
}
