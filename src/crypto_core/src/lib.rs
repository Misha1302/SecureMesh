mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
// Local client process. No server keys, no plaintext fallback, no crypto primitives.
pub mod api;
mod directory;
mod enrollment;
mod onboarding;
use ::tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};
use anyhow::{anyhow, bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::RustCrypto;
use openmls_sqlite_storage::{Codec, SqliteStorageProvider};
use openmls_traits::{signatures::Signer, OpenMlsProvider};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

#[derive(Default)]
struct JsonCodec;
impl Codec for JsonCodec {
    type Error = serde_json::Error;
    fn to_vec<T: Serialize>(v: &T) -> std::result::Result<Vec<u8>, Self::Error> {
        serde_json::to_vec(v)
    }
    fn from_slice<T: DeserializeOwned>(v: &[u8]) -> std::result::Result<T, Self::Error> {
        serde_json::from_slice(v)
    }
}
struct Provider<'a> {
    crypto: RustCrypto,
    storage: SqliteStorageProvider<JsonCodec, &'a Connection>,
}
impl<'a> OpenMlsProvider for Provider<'a> {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = SqliteStorageProvider<JsonCodec, &'a Connection>;
    fn crypto(&self) -> &RustCrypto {
        &self.crypto
    }
    fn rand(&self) -> &RustCrypto {
        &self.crypto
    }
    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }
}

fn s<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or_else(|| anyhow!("missing field"))
}
fn bytes(v: &Value, key: &str) -> Result<Vec<u8>> {
    Ok(B64.decode(s(v, key)?)?)
}
fn meta(db: &Connection, key: &str) -> Result<String> {
    Ok(
        db.query_row("SELECT value FROM app_meta WHERE key=?", [key], |r| {
            r.get(0)
        })?,
    )
}
fn set_meta(db: &Connection, key: &str, val: &str) -> Result<()> {
    db.execute(
        "INSERT INTO app_meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![key, val],
    )?;
    Ok(())
}
fn credential(id: &str, signer: &SignatureKeyPair) -> CredentialWithKey {
    CredentialWithKey {
        credential: BasicCredential::new(id.as_bytes().to_vec()).into(),
        signature_key: signer.public().into(),
    }
}
fn load_group(p: &Provider, id: &str) -> Result<MlsGroup> {
    MlsGroup::load(p.storage(), &GroupId::from_slice(id.as_bytes()))?.context("missing group")
}
fn pinned_key(db: &Connection, identity: &str) -> Result<Option<Vec<u8>>> {
    Ok(db
        .query_row(
            "SELECT public_key FROM pins WHERE identity=?",
            [identity],
            |r| r.get(0),
        )
        .optional()?)
}

fn check_member(db: &Connection, cred: &Credential, key: &[u8]) -> Result<()> {
    let identity = BasicCredential::try_from(cred.clone())?;
    let id = std::str::from_utf8(identity.identity())?;
    let pin = pinned_key(db, id)?;
    ensure!(pin.as_deref() == Some(key), "KEY_VERIFICATION_REQUIRED");
    Ok(())
}
fn check_group(db: &Connection, group: &MlsGroup) -> Result<()> {
    for m in group.members() {
        check_member(db, &m.credential, &m.signature_key)?;
    }
    Ok(())
}

fn save_outgoing(
    db: &Connection,
    p: &Provider,
    gid: &str,
    id: &str,
    seq: i64,
    commit_only: bool,
) -> Result<Value> {
    ensure!(seq > 0, "invalid sequence");
    let (kind, status, old_seq): (i64, String, Option<i64>) = db.query_row(
        "SELECT json_extract(envelope,'$.kind'),status,seq FROM outgoing WHERE group_id=? AND id=?",
        params![gid, id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    ensure!(!commit_only || kind == 3, "expected MLS commit");
    let already_saved = status == "saved";
    ensure!(
        status == "queued" || already_saved,
        "unexpected outbox state"
    );
    ensure!(!already_saved || old_seq == Some(seq), "sequence changed");
    let mut result = json!({"saved":true,"already_saved":already_saved});
    if kind == 3 {
        // Older clients could persist the ACK before merging the pending commit.
        let pending_key = format!("pending:{gid}");
        if meta(db, &pending_key)? == id {
            let mut group = load_group(p, gid)?;
            group.merge_pending_commit(p)?;
            set_meta(db, &pending_key, "")?;
            result["epoch"] = json!(group.epoch().as_u64());
        } else {
            ensure!(already_saved, "pending commit mismatch");
        }
    }
    if !already_saved {
        db.execute(
            "UPDATE outgoing SET status='saved',seq=? WHERE group_id=? AND id=?",
            params![seq, gid, id],
        )?;
    }
    Ok(result)
}

fn execute(db: &Connection, p: &Provider, req: &Value) -> Result<Value> {
    let op = s(req, "op")?;
    if op == "init" {
        ensure!(
            db.query_row("SELECT count(*) FROM app_meta", [], |r| r.get::<_, i64>(0))? == 0,
            "already initialized"
        );
        let id = s(req, "identity")?;
        let signer = SignatureKeyPair::new(SUITE.signature_algorithm())?;
        signer.store(p.storage())?;
        set_meta(db, "identity", id)?;
        set_meta(db, "public", &B64.encode(signer.public()))?;
        db.execute("INSERT INTO pins VALUES(?,?)", params![id, signer.public()])?;
        if let Some(draft) = req.get("onboarding") {
            onboarding::prepare(db, draft, id)?;
        }
        return Ok(json!({"identity":id,"public_key":B64.encode(signer.public())}));
    }
    let identity = meta(db, "identity")?;
    let public = B64.decode(meta(db, "public")?)?;
    let signer = SignatureKeyPair::read(p.storage(), &public, SUITE.signature_algorithm())
        .context("missing signer")?;
    if op.starts_with("enrollment_") {
        return enrollment::execute(db, p, req, &identity, &signer);
    }
    if op.starts_with("directory_") {
        return directory::execute(db, p, req, &identity, &signer);
    }
    if op.starts_with("onboarding_") {
        return onboarding::execute(db, req, &identity);
    }
    match op {
        "identity" => Ok(json!({"identity":identity,"public_key":B64.encode(public)})),
        "sign" => Ok(
            json!({"signature":B64.encode(signer.sign(&bytes(req,"payload")?).map_err(|_|anyhow!("signature failed"))?)}),
        ),
        "peer_key_status" => {
            let key = bytes(req, "public_key")?;
            ensure!(key.len() == 32, "bad key");
            let status = match pinned_key(db, s(req, "identity")?)? {
                None => "unknown",
                Some(existing) if existing == key => "matches",
                Some(_) => "changed",
            };
            Ok(json!({"status":status}))
        }
        "pin" => {
            // Only invoked after the human compares an out-of-band public fingerprint.
            ensure!(
                req["confirmed"].as_bool() == Some(true),
                "verification required"
            );
            let id = s(req, "identity")?;
            let key = bytes(req, "public_key")?;
            ensure!(key.len() == 32, "bad key");
            let old = pinned_key(db, id)?;
            ensure!(
                old.as_ref().is_none_or(|v| v == &key),
                "KEY_CHANGED_REJECTED"
            );
            db.execute("INSERT OR IGNORE INTO pins VALUES(?,?)", params![id, key])?;
            Ok(json!({"verified":true}))
        }
        "keypackage" => {
            let kp = KeyPackage::builder()
                .key_package_lifetime(Lifetime::new(7 * 24 * 3600))
                .build(SUITE, p, &signer, credential(&identity, &signer))?;
            Ok(json!({"keypackage":B64.encode(kp.key_package().tls_serialize_detached()?)}))
        }
        "create" => {
            let gid = s(req, "group")?;
            ensure!(
                MlsGroup::load(p.storage(), &GroupId::from_slice(gid.as_bytes()))?.is_none(),
                "group exists"
            );
            let config = MlsGroupCreateConfig::builder()
                .ciphersuite(SUITE)
                .use_ratchet_tree_extension(true)
                .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
                .build();
            let g = MlsGroup::new_with_group_id(
                p,
                &signer,
                &config,
                GroupId::from_slice(gid.as_bytes()),
                credential(&identity, &signer),
            )?;
            Ok(json!({"epoch":g.epoch().as_u64()}))
        }
        "add" => {
            let mut g = load_group(p, s(req, "group")?)?;
            let kp = KeyPackageIn::tls_deserialize_exact(&bytes(req, "keypackage")?)?
                .validate(p.crypto(), ProtocolVersion::Mls10)?;
            check_member(
                db,
                kp.leaf_node().credential(),
                kp.leaf_node().signature_key().as_slice(),
            )?;
            let (commit, welcome, _) = g.add_members(p, &signer, &[kp])?;
            g.merge_pending_commit(p)?;
            check_group(db, &g)?;
            Ok(
                json!({"commit":B64.encode(commit.tls_serialize_detached()?),"welcome":B64.encode(welcome.tls_serialize_detached()?),"epoch":g.epoch().as_u64()}),
            )
        }
        "join" => {
            let gid = s(req, "group")?;
            let digest = B64.encode(Sha256::digest(bytes(req, "welcome")?));
            if MlsGroup::load(p.storage(), &GroupId::from_slice(gid.as_bytes()))?.is_some() {
                ensure!(
                    meta(db, &format!("welcome:{gid}"))? == digest,
                    "group already exists"
                );
                return Ok(json!({"already_joined":true}));
            }
            let msg = MlsMessageIn::tls_deserialize_exact(&bytes(req, "welcome")?)?;
            let welcome = match msg.extract() {
                MlsMessageBodyIn::Welcome(w) => w,
                _ => bail!("not welcome"),
            };
            let config = MlsGroupJoinConfig::builder()
                .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
                .build();
            let g = StagedWelcome::new_from_welcome(p, &config, welcome, None)?.into_group(p)?;
            ensure!(
                g.group_id().as_slice() == s(req, "group")?.as_bytes(),
                "wrong group"
            );
            check_group(db, &g)?;
            if let Some(expected) = req["expected_members"].as_array() {
                let actual: std::collections::BTreeSet<_> = g
                    .members()
                    .map(|m| BasicCredential::try_from(m.credential).map(|c| c.identity().to_vec()))
                    .collect::<std::result::Result<_, _>>()?;
                let expected = expected
                    .iter()
                    .map(|v| {
                        v.as_str()
                            .map(|v| v.as_bytes().to_vec())
                            .context("invalid member")
                    })
                    .collect::<Result<std::collections::BTreeSet<_>>>()?;
                ensure!(actual == expected, "unexpected MLS participant");
            }
            set_meta(db, &format!("welcome:{gid}"), &digest)?;
            Ok(json!({"epoch":g.epoch().as_u64()}))
        }
        "remove" => {
            let mut g = load_group(p, s(req, "group")?)?;
            let target = s(req, "identity")?.as_bytes();
            let member = g
                .members()
                .find(|m| {
                    BasicCredential::try_from(m.credential.clone())
                        .is_ok_and(|c| c.identity() == target)
                })
                .context("no member")?;
            ensure!(member.index != g.own_leaf_index(), "use explicit leave");
            let (commit, _, _) = g.remove_members(p, &signer, &[member.index])?;
            g.merge_pending_commit(p)?;
            Ok(
                json!({"commit":B64.encode(commit.tls_serialize_detached()?),"epoch":g.epoch().as_u64()}),
            )
        }
        "stage_rekey" => {
            let gid = s(req, "group")?;
            let id = s(req, "id")?;
            uuid::Uuid::parse_str(id)?;
            let old: Option<String> = db
                .query_row(
                    "SELECT envelope FROM outgoing WHERE group_id=? AND id=?",
                    params![gid, id],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(old) = old {
                return Ok(serde_json::from_str(&old)?);
            }
            let mut group = load_group(p, gid)?;
            check_group(db, &group)?;
            let epoch = group.epoch().as_u64();
            let update = group.self_update(p, &signer, LeafNodeParameters::default())?;
            let envelope = json!({"group":gid,"id":id,"epoch":epoch,"kind":3,"ciphertext":B64.encode(update.commit().tls_serialize_detached()?)});
            db.execute(
                "INSERT INTO outgoing(group_id,id,envelope,status) VALUES(?,?,?,'queued')",
                params![gid, id, serde_json::to_string(&envelope)?],
            )?;
            set_meta(db, &format!("pending:{gid}"), id)?;
            Ok(envelope)
        }
        "saved" | "commit_saved" => save_outgoing(
            db,
            p,
            s(req, "group")?,
            s(req, "id")?,
            req["seq"].as_i64().context("sequence")?,
            op == "commit_saved",
        ),
        "commit_rejected" => {
            let gid = s(req, "group")?;
            let id = s(req, "id")?;
            ensure!(
                req["epoch_conflict_confirmed"].as_bool() == Some(true),
                "explicit conflict required"
            );
            ensure!(
                meta(db, &format!("pending:{gid}"))? == id,
                "pending commit mismatch"
            );
            let mut group = load_group(p, gid)?;
            group.clear_pending_commit(p.storage())?;
            db.execute(
                "UPDATE outgoing SET status='rejected' WHERE group_id=? AND id=?",
                params![gid, id],
            )?;
            set_meta(db, &format!("pending:{gid}"), "")?;
            Ok(json!({"epoch":group.epoch().as_u64()}))
        }
        "queue" => {
            let gid = s(req, "group")?;
            let id = s(req, "id")?;
            uuid::Uuid::parse_str(id)?;
            let old: Option<String> = db
                .query_row(
                    "SELECT envelope FROM outgoing WHERE group_id=? AND id=?",
                    params![gid, id],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(old) = old {
                return Ok(serde_json::from_str(&old)?);
            }
            let mut g = load_group(p, gid)?;
            check_group(db, &g)?;
            let text = s(req, "text")?;
            ensure!(text.chars().count() <= 4000, "text too large");
            let payload = json!({"id":id,"group":gid,"sender":identity,"text":text});
            let epoch = g.epoch().as_u64();
            let msg = g.create_message(p, &signer, &serde_json::to_vec(&payload)?)?;
            let result = json!({"id":id,"group":gid,"epoch":epoch,"kind":1,"ciphertext":B64.encode(msg.tls_serialize_detached()?)});
            db.execute(
                "INSERT INTO outgoing(group_id,id,envelope,status) VALUES(?,?,?,'queued')",
                params![gid, id, serde_json::to_string(&result)?],
            )?;
            db.execute(
                "INSERT INTO authored VALUES(?,?,?)",
                params![gid, id, serde_json::to_string(&payload)?],
            )?;
            Ok(result)
        }
        "process" => {
            let gid = s(req, "group")?;
            let mut g = load_group(p, gid)?;
            let raw = bytes(req, "ciphertext")?;
            let msg = MlsMessageIn::tls_deserialize_exact(&raw)?.try_into_protocol_message()?;
            let processed = g.process_message(p, msg)?;
            let sender = BasicCredential::try_from(processed.credential().clone())?;
            let sender_id = std::str::from_utf8(sender.identity())?.to_string();
            match processed.into_content() {
                ProcessedMessageContent::ApplicationMessage(app) => {
                    let event: Value = serde_json::from_slice(&app.into_bytes())?;
                    ensure!(
                        s(&event, "group")? == gid && s(&event, "sender")? == sender_id,
                        "binding mismatch"
                    );
                    if let Some(expected) = req["sender"].as_str() {
                        ensure!(expected == sender_id, "sender mismatch");
                    }
                    db.execute(
                        "INSERT INTO incoming(group_id,id,event) VALUES(?,?,?)",
                        params![gid, s(&event, "id")?, serde_json::to_string(&event)?],
                    )?;
                    Ok(event)
                }
                ProcessedMessageContent::StagedCommitMessage(commit) => {
                    g.merge_staged_commit(p, *commit)?;
                    check_group(db, &g)?;
                    Ok(json!({"epoch":g.epoch().as_u64(),"active":g.is_active()}))
                }
                _ => bail!("unsupported event"),
            }
        }
        "ingest" => {
            let gid = s(req, "group")?;
            let seq = req["seq"].as_i64().context("sequence")?;
            let last: Option<i64> = db
                .query_row(
                    "SELECT seq FROM local_cursors WHERE group_id=?",
                    [gid],
                    |r| r.get(0),
                )
                .optional()?;
            let last = last.unwrap_or(0);
            let raw = bytes(req, "ciphertext")?;
            let digest = if raw.is_empty() {
                bytes(req, "digest")?
            } else {
                Sha256::digest(&raw).to_vec()
            };
            ensure!(digest.len() == 32, "invalid digest");
            if req["digest"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
            {
                ensure!(bytes(req, "digest")? == digest, "digest mismatch");
            }
            let envelope = json!({"digest":B64.encode(&digest),"sender":s(req,"sender")?,"id":s(req,"id")?,"epoch":req["epoch"],"kind":req["kind"]});
            let canonical = serde_json::to_string(&envelope)?;
            if seq <= last {
                let old: String = db.query_row(
                    "SELECT envelope FROM received WHERE group_id=? AND seq=?",
                    params![gid, seq],
                    |r| r.get(0),
                )?;
                let mut old: Value = serde_json::from_str(&old)?;
                // Normalize records from the initial local storage format without consuming MLS again.
                if let Some(ciphertext) = old["ciphertext"].as_str() {
                    let previous = if ciphertext.is_empty() {
                        bytes(&old, "digest")?
                    } else {
                        Sha256::digest(B64.decode(ciphertext)?).to_vec()
                    };
                    old["digest"] = json!(B64.encode(previous));
                    old.as_object_mut()
                        .context("envelope")?
                        .remove("ciphertext");
                }
                ensure!(old == envelope, "sequence payload changed");
                if let Some(cursor) = req["cursor"].as_str().filter(|value| !value.is_empty()) {
                    db.execute(
                        "UPDATE local_cursors SET cursor=? WHERE group_id=?",
                        params![cursor, gid],
                    )?;
                }
                return Ok(json!({"duplicate":true,"seq":last}));
            }
            ensure!(seq == last + 1, "SYNC_GAP");
            ensure!(
                matches!(req["kind"].as_i64(), Some(1 | 3)),
                "unsupported ingest kind"
            );
            let result = if s(req, "sender")? == identity {
                let own: String = db.query_row(
                    "SELECT envelope FROM outgoing WHERE group_id=? AND id=?",
                    params![gid, s(req, "id")?],
                    |r| r.get(0),
                )?;
                let own: Value = serde_json::from_str(&own)?;
                ensure!(
                    own["epoch"] == req["epoch"] && own["kind"] == req["kind"],
                    "own envelope metadata mismatch"
                );
                if s(req, "ciphertext")?.is_empty() {
                    ensure!(
                        Sha256::digest(bytes(&own, "ciphertext")?).as_slice()
                            == bytes(req, "digest")?,
                        "own digest mismatch"
                    );
                } else {
                    ensure!(
                        s(&own, "ciphertext")? == s(req, "ciphertext")?,
                        "own ciphertext mismatch"
                    );
                }
                save_outgoing(db, p, gid, s(req, "id")?, seq, false)?;
                json!({"own":true})
            } else {
                let group = load_group(p, gid)?;
                ensure!(
                    req["epoch"].as_u64() == Some(group.epoch().as_u64()),
                    "epoch mismatch"
                );
                let mut process = req.clone();
                process["op"] = json!("process");
                let event = execute(db, p, &process)?;
                if req["kind"].as_i64() == Some(1) {
                    ensure!(s(&event, "id")? == s(req, "id")?, "message id mismatch");
                }
                event
            };
            db.execute(
                "INSERT INTO received VALUES(?,?,?)",
                params![gid, seq, canonical],
            )?;
            db.execute("INSERT INTO local_cursors VALUES(?,?,?) ON CONFLICT(group_id) DO UPDATE SET seq=excluded.seq,cursor=excluded.cursor",params![gid,seq,req["cursor"].as_str().unwrap_or("")])?;
            Ok(json!({"event":result,"seq":seq}))
        }
        "cursor" => {
            let value: Option<(i64, String)> = db
                .query_row(
                    "SELECT seq,cursor FROM local_cursors WHERE group_id=?",
                    [s(req, "group")?],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let (seq, cursor) = value.unwrap_or((0, String::new()));
            Ok(json!({"seq":seq,"cursor":cursor}))
        }
        "outbox" => {
            let mut q = db.prepare(
                "SELECT envelope FROM outgoing WHERE status='queued' ORDER BY rowid LIMIT 100",
            )?;
            let rows = q.query_map([], |r| r.get::<_, String>(0))?;
            let values = rows
                .map(|r| Ok(serde_json::from_str::<Value>(&r?)?))
                .collect::<Result<Vec<_>>>()?;
            Ok(json!({"messages":values}))
        }
        "history" => {
            let mut q = db
                .prepare("SELECT event FROM incoming WHERE group_id=? ORDER BY rowid LIMIT 1000")?;
            let rows = q.query_map([s(req, "group")?], |r| r.get::<_, String>(0))?;
            let values = rows
                .map(|r| Ok(serde_json::from_str::<Value>(&r?)?))
                .collect::<Result<Vec<_>>>()?;
            Ok(json!({"events":values}))
        }
        "profile_put" => {
            set_meta(
                db,
                "local_profile",
                &serde_json::to_string(&req["profile"])?,
            )?;
            Ok(json!({"saved":true}))
        }
        "profile" => Ok(serde_json::from_str(&meta(db, "local_profile")?)?),
        "timeline" => {
            let gid = s(req, "group")?;
            let mut entries = Vec::new();
            let mut q=db.prepare("SELECT a.event,o.status,o.seq FROM authored a JOIN outgoing o ON o.group_id=a.group_id AND o.id=a.id WHERE a.group_id=? ORDER BY a.rowid DESC LIMIT 1000")?;
            let rows = q.query_map([gid], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                ))
            })?;
            for row in rows {
                let (event, status, seq) = row?;
                let mut event: Value = serde_json::from_str(&event)?;
                event["status"] = json!(status);
                event["seq"] = json!(seq);
                event["own"] = json!(true);
                entries.push(event);
            }
            let mut q=db.prepare("SELECT i.event,r.seq FROM incoming i LEFT JOIN received r ON r.group_id=i.group_id AND json_extract(r.envelope,'$.id')=i.id WHERE i.group_id=? ORDER BY i.rowid DESC LIMIT 1000")?;
            let rows = q.query_map([gid], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?))
            })?;
            for row in rows {
                let (event, seq) = row?;
                let mut event: Value = serde_json::from_str(&event)?;
                event["status"] = json!("received");
                event["seq"] = json!(seq);
                event["own"] = json!(false);
                entries.push(event);
            }
            entries.sort_by_key(|event| event["seq"].as_i64().unwrap_or(i64::MAX));
            Ok(json!({"messages":entries}))
        }
        _ => bail!("unknown operation"),
    }
}

pub fn execute_json(path: &str, input: &str) -> Result<String> {
    ensure!(input.len() <= 262144, "input too large");
    let req: Value = serde_json::from_str(&input)?;
    let pass = s(&req, "passphrase")?;
    let db = open_store(path, pass)?;
    transact(&db, &req)
}

pub fn validate_keypackage(input: &str) -> Result<String> {
    Ok(serde_json::to_string(&directory::validate(
        &serde_json::from_str(input)?,
    )?)?)
}

pub(crate) fn open_store(path: &str, pass: &str) -> Result<Connection> {
    ensure!(pass.len() >= 16, "passphrase too short");
    let mut db = Connection::open(path)?;
    db.pragma_update(None, "key", pass)?;
    // Refuse a build where encryption support was accidentally omitted.
    let cipher: String = db.query_row("PRAGMA cipher_version", [], |r| r.get(0))?;
    ensure!(!cipher.is_empty(), "SQLCipher required");
    db.pragma_update(None, "journal_mode", "WAL")?;
    db.pragma_update(None, "synchronous", "FULL")?;
    db.busy_timeout(std::time::Duration::from_secs(5))?;
    SqliteStorageProvider::<JsonCodec, _>::new(&mut db).run_migrations()?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS pins(identity TEXT PRIMARY KEY,public_key BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS outgoing(group_id TEXT,id TEXT,envelope TEXT NOT NULL,status TEXT NOT NULL,seq INTEGER,PRIMARY KEY(group_id,id));
      CREATE TABLE IF NOT EXISTS incoming(group_id TEXT,id TEXT,event TEXT NOT NULL,PRIMARY KEY(group_id,id));
      CREATE TABLE IF NOT EXISTS received(group_id TEXT,seq INTEGER,envelope TEXT NOT NULL,PRIMARY KEY(group_id,seq));
      CREATE TABLE IF NOT EXISTS local_cursors(group_id TEXT PRIMARY KEY,seq INTEGER NOT NULL,cursor TEXT NOT NULL);")?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS authored(group_id TEXT,id TEXT,event TEXT NOT NULL,PRIMARY KEY(group_id,id));")?;
    Ok(db)
}

pub(crate) fn transact(db: &Connection, req: &Value) -> Result<String> {
    db.execute_batch("BEGIN IMMEDIATE")?;
    let p = Provider {
        crypto: RustCrypto::default(),
        storage: SqliteStorageProvider::new(db),
    };
    let result = match execute(db, &p, req) {
        Ok(value) => value,
        Err(error) => {
            db.execute_batch("ROLLBACK")?;
            return Err(error);
        }
    };
    if req["crash_before_commit"].as_bool() == Some(true) {
        std::process::abort();
    }
    db.execute_batch("COMMIT")?;
    Ok(serde_json::to_string(&result)?)
}
