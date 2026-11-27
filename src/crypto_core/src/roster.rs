//! Group-scoped authorization for the native transport ingest path.
//! Raw add/remove/process operations are offline MLS fixtures, not delivery authorizations.
use super::*;
use openmls_traits::crypto::OpenMlsCrypto;
use std::collections::{BTreeMap, BTreeSet};

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

pub(super) fn reserved(db: &Connection, gid: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM roster_transitions WHERE group_id=? AND status='pending')",
        [gid],
        |r| r.get(0),
    )?)
}

fn digest(value: &[u8]) -> String {
    B64.encode(Sha256::digest(value))
}

pub(super) fn stage(
    db: &Connection,
    p: &Provider,
    req: &Value,
    identity: &str,
    signer: &SignatureKeyPair,
) -> Result<Value> {
    let gid = s(req, "group")?;
    let id = s(req, "id")?;
    let target = s(req, "device")?;
    let action = s(req, "action")?;
    let epoch = req["epoch"].as_u64().context("missing epoch")?;
    for coordinate in [gid, id, target, identity] {
        ensure!(
            uuid::Uuid::parse_str(coordinate)?.to_string() == coordinate,
            "invalid coordinate"
        );
    }
    let kp = match action {
        "add" => bytes(req, "keypackage")?,
        "remove" => Vec::new(),
        _ => bail!("unknown roster action"),
    };
    let binding = json!([gid, id, identity, target, action, epoch, digest(&kp)]).to_string();
    if let Some((old, receipt, status)) = db
        .query_row(
            "SELECT binding,transition,status FROM roster_transitions WHERE group_id=? AND id=?",
            params![gid, id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .optional()?
    {
        ensure!(
            old == binding && status != "rejected",
            "reservation changed or rejected"
        );
        return Ok(serde_json::from_str(&receipt)?);
    }
    let mut group = load_group(p, gid)?;
    ensure!(
        group.is_active() && group.epoch().as_u64() == epoch && group.pending_commit().is_none(),
        "MLS epoch unavailable"
    );
    // Older queued ciphertext must receive its durable ACK before an epoch barrier.
    let busy: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM outgoing WHERE group_id=?1 AND (status='queued' OR id=?2))",
        params![gid, id],
        |r| r.get(0),
    )?;
    ensure!(
        !busy && !reserved(db, gid)?,
        "conversation has pending deliveries"
    );
    let slot = format!("roster-approval:{gid}");
    let grant: Value = serde_json::from_str(&meta(db, &slot)?)?;
    ensure!(
        grant["epoch"].as_u64() == Some(epoch)
            && s(&grant, "approver")? == identity
            && s(&grant, "action")? == action
            && s(&grant, "device")? == target
            && grant["expires"].as_u64().unwrap_or(0) > now()?,
        "current explicit approval required"
    );
    check_group(db, &group)?;
    let key = bytes(&grant, "key")?;
    let (commit, welcome) = if action == "add" {
        let package = KeyPackageIn::tls_deserialize_exact(&kp)?
            .validate(p.crypto(), ProtocolVersion::Mls10)?;
        let leaf = package.leaf_node();
        ensure!(
            BasicCredential::try_from(leaf.credential().clone())?.identity() == target.as_bytes()
                && leaf.signature_key().as_slice() == key.as_slice(),
            "candidate package mismatch"
        );
        let (commit, welcome, _) = group.add_members(p, signer, &[package])?;
        (commit, welcome.tls_serialize_detached()?)
    } else {
        let member = group
            .members()
            .find(|m| {
                m.signature_key == key
                    && BasicCredential::try_from(m.credential.clone())
                        .is_ok_and(|c| c.identity() == target.as_bytes())
            })
            .context("invalid removal target")?;
        ensure!(
            member.index != group.own_leaf_index(),
            "cannot remove own leaf"
        );
        (
            group.remove_members(p, signer, &[member.index])?.0,
            Vec::new(),
        )
    };
    let commit = commit.tls_serialize_detached()?;
    let last: i64 = db.query_row(
        "SELECT COALESCE((SELECT seq FROM local_cursors WHERE group_id=?),0)",
        [gid],
        |r| r.get(0),
    )?;
    let floor = last.checked_add(1).context("sequence exhausted")?;
    let mut result = json!({"group":gid,"id":id,"device":target,"committer":identity,"action":action,"epoch":epoch,
        "seq":floor,"commit":B64.encode(commit),"welcome":B64.encode(welcome)});
    let transcript = transcript(&result, &key)?;
    let signature = signer
        .sign(transcript.as_bytes())
        .map_err(|_| anyhow!("signature failed"))?;
    result["signature"] = json!(B64.encode(signature));
    result["digest"] = json!(digest(transcript.as_bytes()));
    db.execute("INSERT INTO roster_transitions(group_id,id,binding,transition,status) VALUES(?,?,?,?,'pending')",
        params![gid,id,binding,result.to_string()])?;
    db.execute("DELETE FROM app_meta WHERE key=?", [slot])?;
    Ok(result)
}

pub(super) fn resolve(db: &Connection, p: &Provider, req: &Value) -> Result<Value> {
    let gid = s(req, "group")?;
    let id = s(req, "id")?;
    let (raw, status, old_seq): (String, String, Option<i64>) = db.query_row(
        "SELECT transition,status,seq FROM roster_transitions WHERE group_id=? AND id=?",
        params![gid, id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let transition: Value = serde_json::from_str(&raw)?;
    ensure!(
        s(req, "digest")? == s(&transition, "digest")?,
        "acknowledgment binding mismatch"
    );
    let mut group = load_group(p, gid)?;
    if s(req, "op")? == "roster_rejected" {
        ensure!(
            req["epoch_conflict_confirmed"].as_bool() == Some(true) && status == "pending",
            "confirmed reservation conflict required"
        );
        group.clear_pending_commit(p.storage())?;
        db.execute(
            "UPDATE roster_transitions SET status='rejected' WHERE group_id=? AND id=?",
            params![gid, id],
        )?;
        return Ok(json!({"rejected":true}));
    }
    let seq = req["seq"].as_i64().context("sequence")?;
    ensure!(
        seq > 0 && req["durable"].as_bool() == Some(true),
        "durable ACK required"
    );
    ensure!(
        transition["seq"].as_i64() == Some(seq),
        "signed sequence mismatch"
    );
    if status == "saved" {
        ensure!(old_seq == Some(seq), "acknowledgment sequence changed");
        return Ok(json!({"already_saved":true,"saved":true}));
    }
    ensure!(
        status == "pending" && transition["epoch"].as_u64() == Some(group.epoch().as_u64()),
        "wrong pending epoch"
    );
    group.merge_pending_commit(p)?;
    check_group(db, &group)?;
    db.execute(
        "UPDATE roster_transitions SET status='saved',seq=? WHERE group_id=? AND id=?",
        params![seq, gid, id],
    )?;
    Ok(json!({"saved":true,"epoch":group.epoch().as_u64()}))
}

pub(super) fn pending(db: &Connection, gid: &str) -> Result<Value> {
    let raw: Option<String> = db
        .query_row(
            "SELECT transition FROM roster_transitions WHERE group_id=? AND status='pending'",
            [gid],
            |r| r.get(0),
        )
        .optional()?;
    Ok(json!({"transition":raw.map(|s| serde_json::from_str::<Value>(&s)).transpose()?}))
}

pub(super) fn has_id(db: &Connection, gid: &str, id: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM roster_transitions WHERE group_id=? AND id=?)",
        params![gid, id],
        |r| r.get(0),
    )?)
}

pub(super) fn check_echo(db: &Connection, req: &Value, digest: &[u8], seq: i64) -> Result<()> {
    let (raw, status, ack_seq): (String, String, Option<i64>) = db.query_row(
        "SELECT transition,status,seq FROM roster_transitions WHERE group_id=? AND id=?",
        params![s(req, "group")?, s(req, "id")?],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let transition: Value = serde_json::from_str(&raw)?;
    ensure!(
        status == "saved"
            && ack_seq == Some(seq)
            && req["kind"].as_i64() == Some(3)
            && req["epoch"] == transition["epoch"]
            && req["sender"] == transition["committer"]
            && Sha256::digest(bytes(&transition, "commit")?).as_slice() == digest,
        "roster echo mismatch"
    );
    Ok(())
}

fn transcript(transition: &Value, key: &[u8]) -> Result<String> {
    let coordinates = ["group", "id", "committer", "device"]
        .into_iter()
        .map(|field| {
            let value = s(transition, field)?;
            ensure!(
                uuid::Uuid::parse_str(value)?.to_string() == value,
                "invalid transition coordinate"
            );
            Ok(value)
        })
        .collect::<Result<Vec<_>>>()?
        .join("\n");
    let action = s(transition, "action")?;
    ensure!(
        matches!(action, "add" | "remove"),
        "invalid transition action"
    );
    let epoch = transition["epoch"].as_u64().context("missing epoch")?;
    let floor = transition["seq"].as_i64().context("missing sequence")?;
    ensure!(floor > 0, "invalid sequence");
    Ok(format!(
        "SecureMesh/roster-transition/v2\n{coordinates}\n{action}\n{epoch}\n{floor}\n{}\n{}\n{}",
        digest(key),
        digest(&bytes(transition, "commit")?),
        digest(&bytes(transition, "welcome")?)
    ))
}

pub(super) fn join(
    db: &Connection,
    p: &Provider,
    req: &Value,
    identity: &str,
    public: &[u8],
) -> Result<Value> {
    let transition = &req["transition"];
    let gid = s(transition, "group")?;
    let approver = s(transition, "committer")?;
    ensure!(
        s(transition, "action")? == "add"
            && s(transition, "device")? == identity
            && req["confirmed"].as_bool() == Some(true),
        "expected confirmed enrollment"
    );
    let accepted: Value = serde_json::from_str(&meta(db, "enrollment-accepted")?)?;
    ensure!(
        accepted["result"]["verified"].as_bool() == Some(true)
            && accepted["request"]["approver"].as_str() == Some(approver),
        "unexpected enrollment approver"
    );
    let key = pinned_key(db, approver)?.context("unknown approver")?;
    let payload = transcript(transition, public)?;
    let hash = digest(payload.as_bytes());
    ensure!(
        s(transition, "digest")? == hash,
        "transition digest mismatch"
    );
    p.crypto().verify_signature(
        SignatureScheme::ED25519,
        payload.as_bytes(),
        &key,
        &bytes(transition, "signature")?,
    )?;
    let expected = req["expected_members"]
        .as_array()
        .context("explicit expected devices required")?;
    ensure!((2..=64).contains(&expected.len()), "invalid roster size");
    let ids = expected
        .iter()
        .map(|v| v.as_str().context("invalid member"))
        .collect::<Result<BTreeSet<_>>>()?;
    ensure!(
        ids.len() == expected.len() && ids.contains(identity) && ids.contains(approver),
        "invalid expected devices"
    );
    let marker = format!("roster-welcome:{gid}");
    if MlsGroup::load(p.storage(), &GroupId::from_slice(gid.as_bytes()))?.is_some() {
        ensure!(meta(db, &marker)? == hash, "group already exists");
        return Ok(json!({"already_joined":true}));
    }
    let result = execute(
        db,
        p,
        &json!({"op":"join","group":gid,"welcome":transition["welcome"],"expected_members":expected}),
    )?;
    let group = load_group(p, gid)?;
    ensure!(
        members(&group)?.len() == ids.len()
            && transition["epoch"].as_u64().and_then(|e| e.checked_add(1))
                == Some(group.epoch().as_u64()),
        "unexpected Welcome epoch or roster"
    );
    let seq = transition["seq"].as_i64().context("missing sequence")?;
    db.execute(
        "INSERT INTO local_cursors(group_id,seq,cursor) VALUES(?,?,'')",
        params![gid, seq],
    )?;
    set_meta(db, &marker, &hash)?;
    Ok(result)
}
