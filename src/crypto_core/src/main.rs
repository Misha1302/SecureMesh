//! Local client process. No server keys, no plaintext fallback, no crypto primitives.
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
use std::io::{self, Read};

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
fn check_member(db: &Connection, cred: &Credential, key: &[u8]) -> Result<()> {
    let identity = BasicCredential::try_from(cred.clone())?;
    let id = std::str::from_utf8(identity.identity())?;
    let pin: Option<Vec<u8>> = db
        .query_row("SELECT public_key FROM pins WHERE identity=?", [id], |r| {
            r.get(0)
        })
        .optional()?;
    ensure!(pin.as_deref() == Some(key), "KEY_VERIFICATION_REQUIRED");
    Ok(())
}
fn check_group(db: &Connection, group: &MlsGroup) -> Result<()> {
    for m in group.members() {
        check_member(db, &m.credential, &m.signature_key)?;
    }
    Ok(())
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
        return Ok(json!({"identity":id,"public_key":B64.encode(signer.public())}));
    }
    let identity = meta(db, "identity")?;
    let public = B64.decode(meta(db, "public")?)?;
    let signer = SignatureKeyPair::read(p.storage(), &public, SUITE.signature_algorithm())
        .context("missing signer")?;
    match op {
        "identity" => Ok(json!({"identity":identity,"public_key":B64.encode(public)})),
        "sign" => Ok(
            json!({"signature":B64.encode(signer.sign(&bytes(req,"payload")?).map_err(|_|anyhow!("signature failed"))?)}),
        ),
        "pin" => {
            // Only invoked after the human compares an out-of-band public fingerprint.
            ensure!(
                req["confirmed"].as_bool() == Some(true),
                "verification required"
            );
            let id = s(req, "identity")?;
            let key = bytes(req, "public_key")?;
            ensure!(key.len() == 32, "bad key");
            let old: Option<Vec<u8>> = db
                .query_row("SELECT public_key FROM pins WHERE identity=?", [id], |r| {
                    r.get(0)
                })
                .optional()?;
            ensure!(
                old.as_ref().is_none_or(|v| v == &key),
                "KEY_CHANGED_REJECTED"
            );
            db.execute("INSERT OR IGNORE INTO pins VALUES(?,?)", params![id, key])?;
            Ok(json!({"verified":true}))
        }
        "keypackage" => {
            let kp =
                KeyPackage::builder().build(SUITE, p, &signer, credential(&identity, &signer))?;
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
        "saved" => {
            db.execute(
                "UPDATE outgoing SET status='saved',seq=? WHERE group_id=? AND id=?",
                params![
                    req["seq"].as_i64().context("seq")?,
                    s(req, "group")?,
                    s(req, "id")?
                ],
            )?;
            Ok(json!({"saved":true}))
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
        _ => bail!("unknown operation"),
    }
}

fn run() -> Result<Value> {
    let path = std::env::args().nth(1).context("DB path required")?;
    let mut input = String::new();
    io::stdin().take(262145).read_to_string(&mut input)?;
    ensure!(input.len() <= 262144, "input too large");
    let req: Value = serde_json::from_str(&input)?;
    let pass = s(&req, "passphrase")?;
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
      CREATE TABLE IF NOT EXISTS incoming(group_id TEXT,id TEXT,event TEXT NOT NULL,PRIMARY KEY(group_id,id));")?;
    db.execute_batch("BEGIN IMMEDIATE")?;
    let p = Provider {
        crypto: RustCrypto::default(),
        storage: SqliteStorageProvider::new(&db),
    };
    let result = execute(&db, &p, &req)?;
    if req["crash_before_commit"].as_bool() == Some(true) {
        std::process::abort();
    }
    db.execute_batch("COMMIT")?;
    Ok(result)
}
fn main() {
    match run() {
        Ok(v) => println!("{}", v),
        Err(_) => {
            eprintln!("CRYPTO_OR_STORE_REJECTED");
            std::process::exit(1);
        }
    }
}
