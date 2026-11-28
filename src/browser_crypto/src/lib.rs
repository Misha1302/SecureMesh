//! Browser MLS transactions. The caller must durably commit each encrypted
//! snapshot together with the corresponding delivery state.
use anyhow::{anyhow, bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto as Provider;
use openmls_traits::{
    crypto::OpenMlsCrypto, signatures::Signer, storage::StorageProvider as _, types::AeadType,
    OpenMlsProvider,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};
use wasm_bindgen::prelude::*;

#[path = "../../crypto_core/src/server_credential.rs"]
mod server_credential;

#[wasm_bindgen]
pub fn derive_server_credential_v2(
    endpoint: &str,
    username: &str,
    password: &str,
) -> std::result::Result<String, String> {
    server_credential::derive_server_credential(endpoint, username, password)
        .map_err(|error| error.to_string())
}

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const ATTACHMENT_LIMIT: usize = 4 * 1024 * 1024;
const ATTACHMENT_TAG: usize = 16;
type Store = Vec<(Vec<u8>, Vec<u8>)>;
type Roster = BTreeMap<String, Vec<u8>>;

#[derive(Serialize, Deserialize)]
struct Consent {
    sender: String,
    key: Vec<u8>,
    reference: String,
    keypackage: String,
    group: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Profile {
    version: u8,
    identity: String,
    public: Vec<u8>,
    pins: Roster,
    store: Store,
    pending: BTreeMap<String, Value>,
    #[serde(default)]
    consents: BTreeMap<String, Consent>,
    joined: BTreeMap<String, [u8; 32]>,
}

fn field<'a>(req: &'a Value, name: &str) -> Result<&'a str> {
    req[name]
        .as_str()
        .with_context(|| format!("missing {name}"))
}

fn coordinate<'a>(req: &'a Value, name: &str) -> Result<&'a str> {
    let value = field(req, name)?;
    let id = uuid::Uuid::parse_str(value)?;
    ensure!(!id.is_nil() && id.to_string() == value, "invalid {name}");
    Ok(value)
}

fn bytes(req: &Value, name: &str, limit: usize) -> Result<Vec<u8>> {
    let value = field(req, name)?;
    ensure!(value.len() <= limit.div_ceil(3) * 4, "{name} too large");
    let decoded = B64.decode(value)?;
    ensure!(decoded.len() <= limit, "{name} too large");
    Ok(decoded)
}

fn canonical_uuid(value: &str) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(value)?.to_string() == value,
        "invalid identifier"
    );
    Ok(())
}

fn attachment_size(info: &Value) -> Result<usize> {
    ensure!(info["v"] == 1, "unsupported attachment descriptor");
    canonical_uuid(field(info, "blobId")?)?;
    let size = info["size"].as_u64().context("missing attachment size")?;
    ensure!(
        (1..=ATTACHMENT_LIMIT as u64).contains(&size),
        "invalid attachment size"
    );
    let name = field(info, "name")?;
    ensure!(!name.trim().is_empty() && name.len() <= 255 && name != "." && name != ".."
        && !name.chars().any(|c| c.is_control() || matches!(c, '/' | '\\' | ':' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')),
        "invalid attachment name");
    ensure!(
        matches!(field(info, "media")?, "file" | "photo" | "voice" | "video"),
        "invalid attachment media"
    );
    if let Some(caption) = info.get("caption") {
        ensure!(
            caption.as_str().is_some_and(|text| text.len() <= 2048),
            "invalid attachment caption"
        );
    }
    let key = B64.decode(field(info, "key")?)?;
    let nonce = B64.decode(field(info, "nonce")?)?;
    ensure!(
        key.len() == 32 && nonce.len() == 12,
        "invalid attachment key material"
    );
    ensure!(
        B64.encode(&key) == field(info, "key")? && B64.encode(&nonce) == field(info, "nonce")?,
        "noncanonical attachment key material"
    );
    Ok(size as usize)
}

fn attachment_aad(group: &str, id: &str, info: &Value) -> Result<Vec<u8>> {
    Ok(serde_json::to_vec(&json!([
        "SecureMesh/attachment/v1",
        group,
        id,
        info["blobId"],
        info["name"],
        info["media"],
        info["size"]
    ]))?)
}

fn open_attachment(provider: &Provider, req: &Value) -> Result<Value> {
    let group = field(req, "group")?;
    let id = field(req, "id")?;
    canonical_uuid(group)?;
    canonical_uuid(id)?;
    let info = &req["attachment"];
    let size = attachment_size(info)?;
    ensure!(
        field(info, "media")? == "photo",
        "unsupported attachment media"
    );
    let key = B64.decode(field(info, "key")?)?;
    let nonce = B64.decode(field(info, "nonce")?)?;
    let sealed = bytes(req, "ciphertext", ATTACHMENT_LIMIT + ATTACHMENT_TAG)?;
    ensure!(
        sealed.len() == size + ATTACHMENT_TAG,
        "invalid sealed attachment length"
    );
    let plain = provider.crypto().aead_decrypt(
        AeadType::Aes256Gcm,
        &key,
        &sealed,
        &nonce,
        &attachment_aad(group, id, info)?,
    )?;
    ensure!(plain.len() == size, "invalid attachment plaintext length");
    Ok(json!({"name":info["name"],"media":"photo","size":size,"data":B64.encode(plain)}))
}

fn read_profile(snapshot: Option<&str>, req: &Value, provider: &Provider) -> Result<Profile> {
    if let Some(snapshot) = snapshot {
        ensure!(field(req, "op")? != "init", "already initialized");
        let mut profile: Profile = serde_json::from_str(snapshot)?;
        ensure!(
            [1, 2].contains(&profile.version),
            "unsupported profile version"
        );
        profile.version = 2;
        ensure!(
            profile.pins.get(&profile.identity) == Some(&profile.public),
            "identity pin mismatch"
        );
        provider
            .storage()
            .values
            .write()
            .map_err(|_| anyhow!("MLS storage lock"))?
            .extend(std::mem::take(&mut profile.store));
        return Ok(profile);
    }
    ensure!(field(req, "op")? == "init", "profile unavailable");
    let identity = coordinate(req, "identity")?.to_owned();
    let signer = SignatureKeyPair::new(SUITE.signature_algorithm())?;
    signer.store(provider.storage())?;
    let public = signer.public().to_vec();
    Ok(Profile {
        version: 2,
        pins: [(identity.clone(), public.clone())].into(),
        identity,
        public,
        store: Vec::new(),
        pending: BTreeMap::new(),
        consents: BTreeMap::new(),
        joined: BTreeMap::new(),
    })
}

// Failed operations cannot alter the caller's private snapshot.
#[wasm_bindgen]
pub fn execute(snapshot: Option<String>, request: &str) -> std::result::Result<String, String> {
    transaction(snapshot.as_deref(), request).map_err(|error| {
        if error.is::<serde_json::Error>() {
            "invalid JSON data".to_owned()
        } else {
            error.to_string()
        }
    })
}

fn transaction(snapshot: Option<&str>, request: &str) -> Result<String> {
    let req = serde_json::from_str(request)?;
    let provider = Provider::default();
    let mut profile = read_profile(snapshot, &req, &provider)?;
    let result = operation(&provider, &mut profile, &req)?;
    profile.store = provider
        .storage()
        .values
        .write()
        .map_err(|_| anyhow!("MLS storage lock"))?
        .drain()
        .collect();
    Ok(json!({"snapshot":serde_json::to_string(&profile)?,"result":result}).to_string())
}

fn credential(identity: &str, signer: &SignatureKeyPair) -> CredentialWithKey {
    CredentialWithKey {
        credential: BasicCredential::new(identity.as_bytes().to_vec()).into(),
        signature_key: signer.public().into(),
    }
}

fn group(provider: &Provider, gid: &str) -> Result<MlsGroup> {
    let group = MlsGroup::load(provider.storage(), &GroupId::from_slice(gid.as_bytes()))?
        .context("unknown conversation")?;
    ensure!(group.ciphersuite() == SUITE, "unexpected ciphersuite");
    Ok(group)
}

fn check_pin(profile: &Profile, identity: &str, key: &[u8]) -> Result<()> {
    ensure!(
        profile.pins.get(identity).map(Vec::as_slice) == Some(key),
        "KEY_VERIFICATION_REQUIRED"
    );
    Ok(())
}

fn roster(profile: &Profile, group: &MlsGroup) -> Result<Roster> {
    let mut result = Roster::new();
    for member in group.members() {
        let cred = BasicCredential::try_from(member.credential)?;
        let id = std::str::from_utf8(cred.identity())?;
        check_pin(profile, id, &member.signature_key)?;
        ensure!(
            result.insert(id.to_owned(), member.signature_key).is_none(),
            "duplicate member"
        );
    }
    Ok(result)
}

// Interoperates with the native SecureMesh/conversation-establish/v1 transcript.
fn transcript(req: &Value, welcome: &[u8]) -> Result<Vec<u8>> {
    let reference = bytes(req, "reference", 32)?;
    ensure!(reference.len() == 32, "invalid package reference");
    let MlsMessageBodyIn::Welcome(parsed) = MlsMessageIn::tls_deserialize_exact(welcome)?.extract()
    else {
        bail!("expected MLS Welcome");
    };
    let [secret] = parsed.secrets() else {
        bail!("expected one Welcome recipient");
    };
    ensure!(
        secret.new_member().as_slice() == reference,
        "Welcome KeyPackage reference mismatch"
    );
    Ok(format!(
        "SecureMesh/conversation-establish/v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n1",
        coordinate(req, "group")?,
        coordinate(req, "invitation")?,
        coordinate(req, "lease")?,
        coordinate(req, "sender")?,
        coordinate(req, "recipient")?,
        B64.encode(reference),
        B64.encode(Sha256::digest(welcome)),
    )
    .into_bytes())
}

fn prepare(
    provider: &Provider,
    profile: &mut Profile,
    signer: &SignatureKeyPair,
    req: &Value,
) -> Result<Value> {
    let invitation = coordinate(req, "invitation")?;
    let lease = coordinate(req, "lease")?;
    let recipient = coordinate(req, "recipient")?;
    let reference = bytes(req, "reference", 32)?;
    ensure!(recipient != profile.identity, "invalid recipient");
    if let Some(old) = profile.pending.get(invitation) {
        ensure!(
            old["binding"]["lease"] == lease
                && old["binding"]["recipient"] == recipient
                && old["binding"]["reference"] == B64.encode(&reference),
            "bootstrap input changed"
        );
        return Ok(old.clone());
    }
    let kp = KeyPackageIn::tls_deserialize_exact(&bytes(req, "keypackage", 16384)?)?
        .validate(provider.crypto(), ProtocolVersion::Mls10)?;
    ensure!(kp.ciphersuite() == SUITE, "unexpected ciphersuite");
    ensure!(
        kp.hash_ref(provider.crypto())?.as_slice() == reference,
        "package reference mismatch"
    );
    let leaf = kp.leaf_node();
    ensure!(
        BasicCredential::try_from(leaf.credential().clone())?.identity() == recipient.as_bytes(),
        "package recipient mismatch"
    );
    check_pin(profile, recipient, leaf.signature_key().as_slice())?;

    let gid = uuid::Uuid::new_v4().to_string();
    let config = MlsGroupCreateConfig::builder()
        .ciphersuite(SUITE)
        .use_ratchet_tree_extension(true)
        .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .build();
    let mut group = MlsGroup::new_with_group_id(
        provider,
        signer,
        &config,
        GroupId::from_slice(gid.as_bytes()),
        credential(&profile.identity, signer),
    )?;
    let (_, welcome, _) = group.add_members(provider, signer, &[kp])?;
    group.merge_pending_commit(provider)?;
    ensure!(
        group.epoch().as_u64() == 1 && roster(profile, &group)?.len() == 2,
        "invalid initial group"
    );

    let welcome = welcome.tls_serialize_detached()?;
    ensure!(welcome.len() <= 32768, "welcome too large");
    let binding = json!({"op":"directory_sign","group":gid,"invitation":invitation,"lease":lease,
        "sender":profile.identity,"recipient":recipient,"reference":B64.encode(reference),"welcome":B64.encode(&welcome)});
    let signature = signer
        .sign(&transcript(&binding, &welcome)?)
        .map_err(|_| anyhow!("signature failed"))?;
    let result = json!({"id":gid,"invitationId":invitation,"leaseId":lease,"welcome":binding["welcome"],
        "signature":B64.encode(signature), "binding":binding});
    profile
        .pending
        .insert(invitation.to_owned(), result.clone());
    Ok(result)
}

fn join(provider: &Provider, profile: &mut Profile, req: &Value) -> Result<Value> {
    let gid = coordinate(req, "group")?;
    let sender = coordinate(req, "sender")?;
    ensure!(
        coordinate(req, "recipient")? == profile.identity && sender != profile.identity,
        "invalid invitation participants"
    );
    let welcome = bytes(req, "welcome", 32768)?;
    let data = transcript(req, &welcome)?;
    let key = profile
        .pins
        .get(sender)
        .context("KEY_VERIFICATION_REQUIRED")?;
    provider.crypto().verify_signature(
        SignatureScheme::ED25519,
        &data,
        key,
        &bytes(req, "signature", 64)?,
    )?;
    let digest: [u8; 32] = Sha256::digest(data).into();
    if let Some(old) = profile.joined.get(gid) {
        ensure!(*old == digest, "group already exists");
        return Ok(json!({"already_joined":true,"epoch":group(provider,gid)?.epoch().as_u64()}));
    }
    ensure!(
        MlsGroup::load(provider.storage(), &GroupId::from_slice(gid.as_bytes()))?.is_none(),
        "group already exists"
    );
    let invitation = coordinate(req, "invitation")?;
    let receipt = profile
        .consents
        .get(invitation)
        .context("local invitation consent required")?;
    ensure!(
        receipt.sender == sender
            && receipt.key == *key
            && receipt.reference == field(req, "reference")?
            && receipt.group.is_none(),
        "invitation consent mismatch"
    );
    let welcome = match MlsMessageIn::tls_deserialize_exact(&welcome)?.extract() {
        MlsMessageBodyIn::Welcome(welcome) => welcome,
        _ => bail!("expected MLS Welcome"),
    };
    let config = MlsGroupJoinConfig::builder()
        .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .build();
    let group =
        StagedWelcome::new_from_welcome(provider, &config, welcome, None)?.into_group(provider)?;
    ensure!(
        group.group_id().as_slice() == gid.as_bytes()
            && group.ciphersuite() == SUITE
            && group.epoch().as_u64() == 1,
        "unexpected initial MLS group"
    );
    let members = roster(profile, &group)?;
    ensure!(
        members.len() == 2
            && members.contains_key(sender)
            && members.contains_key(&profile.identity),
        "unexpected MLS participant"
    );
    profile
        .consents
        .get_mut(invitation)
        .context("missing consent")?
        .group = Some(gid.to_owned());
    profile.joined.insert(gid.to_owned(), digest);
    Ok(json!({"epoch":group.epoch().as_u64()}))
}

fn operation(provider: &Provider, profile: &mut Profile, req: &Value) -> Result<Value> {
    let op = field(req, "op")?;
    let signer = SignatureKeyPair::read(
        provider.storage(),
        &profile.public,
        SUITE.signature_algorithm(),
    )
    .context("missing signer")?;
    match op {
        "init" | "identity" => {
            Ok(json!({"identity":profile.identity,"public_key":B64.encode(&profile.public)}))
        }
        "attachment_open" => open_attachment(provider, req),
        "sign" => {
            let signature = signer
                .sign(&bytes(req, "payload", 16384)?)
                .map_err(|_| anyhow!("signature failed"))?;
            Ok(json!({"signature":B64.encode(signature)}))
        }
        "pin" | "peer_key_status" => {
            let id = coordinate(req, "identity")?;
            let key = bytes(req, "public_key", 32)?;
            ensure!(key.len() == 32, "bad key");
            let status = match profile.pins.get(id) {
                Some(saved) if saved == &key => "matches",
                Some(_) => "changed",
                None => "unknown",
            };
            if op == "peer_key_status" {
                return Ok(json!({"status":status}));
            }
            ensure!(req["confirmed"] == true, "verification required");
            ensure!(status != "changed", "KEY_CHANGED_REJECTED");
            profile.pins.insert(id.to_owned(), key);
            Ok(json!({"verified":true}))
        }
        "keypackage" => {
            let package = KeyPackage::builder()
                .key_package_lifetime(Lifetime::new(7 * 24 * 3600))
                .build(
                    SUITE,
                    provider,
                    &signer,
                    credential(&profile.identity, &signer),
                )?;
            let kp = package.key_package();
            Ok(
                json!({"keypackage":B64.encode(kp.tls_serialize_detached()?),
                "reference":B64.encode(kp.hash_ref(provider.crypto())?.as_slice())}),
            )
        }
        "directory_consent" => {
            let invitation = coordinate(req, "invitation")?;
            let sender = coordinate(req, "sender")?;
            let key = bytes(req, "senderKey", 32)?;
            ensure!(
                req["confirmed"] == true && sender != profile.identity,
                "explicit recipient consent required"
            );
            check_pin(profile, sender, &key)?;
            ensure!(
                req.get("keypackage").is_some() == req.get("reference").is_some(),
                "incomplete consent package"
            );
            if let Some(existing) = profile.consents.get(invitation) {
                ensure!(
                    existing.sender == sender
                        && existing.key == key
                        && (req.get("keypackage").is_none()
                            || (req["keypackage"] == existing.keypackage
                                && req["reference"] == existing.reference)),
                    "invitation consent mismatch"
                );
                return Ok(
                    json!({"keypackage":existing.keypackage,"reference":existing.reference}),
                );
            }
            let offered = if req.get("keypackage").is_some() {
                // An older vault stores the public package alongside its local invitation.
                // The user has independently re-confirmed this contact before this operation.
                let raw = bytes(req, "keypackage", 16384)?;
                let kp = KeyPackageIn::tls_deserialize_exact(&raw)?
                    .validate(provider.crypto(), ProtocolVersion::Mls10)?;
                let leaf = kp.leaf_node();
                let hash = kp.hash_ref(provider.crypto())?;
                ensure!(
                    kp.ciphersuite() == SUITE
                        && BasicCredential::try_from(leaf.credential().clone())?.identity()
                            == profile.identity.as_bytes()
                        && leaf.signature_key().as_slice() == profile.public
                        && hash.as_slice() == bytes(req, "reference", 32)?,
                    "legacy consent package mismatch"
                );
                let local: Option<KeyPackageBundle> = provider.storage().key_package(&hash)?;
                ensure!(local.is_some(), "legacy local package unavailable");
                json!({"keypackage":B64.encode(raw),"reference":field(req,"reference")?})
            } else {
                operation(provider, profile, &json!({"op":"keypackage"}))?
            };
            let reference = field(&offered, "reference")?.to_owned();
            ensure!(
                !profile.consents.values().any(|r| r.reference == reference),
                "package already bound"
            );
            profile.consents.insert(
                invitation.to_owned(),
                Consent {
                    sender: sender.to_owned(),
                    key,
                    reference,
                    keypackage: field(&offered, "keypackage")?.to_owned(),
                    group: None,
                },
            );
            Ok(offered)
        }
        "directory_pending" => match profile.pending.get(coordinate(req, "invitation")?) {
            Some(result) => Ok(json!({"prepared":true,"request":result})),
            None => Ok(json!({"prepared":false})),
        },
        "directory_prepare" => prepare(provider, profile, &signer, req),
        "directory_join" => join(provider, profile, req),
        "queue" => {
            let gid = coordinate(req, "group")?;
            let id = coordinate(req, "id")?;
            let text = field(req, "text")?;
            ensure!(
                !text.is_empty() && text.chars().count() <= 4000,
                "invalid message text"
            );
            let mut group = group(provider, gid)?;
            ensure!(group.is_active(), "inactive conversation");
            roster(profile, &group)?;
            let payload = json!({"id":id,"group":gid,"sender":profile.identity,"text":text});
            let message =
                group.create_message(provider, &signer, &serde_json::to_vec(&payload)?)?;
            Ok(
                json!({"id":id,"group":gid,"epoch":group.epoch().as_u64(),"kind":1,
                "ciphertext":B64.encode(message.tls_serialize_detached()?)}),
            )
        }
        "process" => process(provider, profile, req),
        _ => bail!("unsupported crypto operation"),
    }
}

fn process(provider: &Provider, profile: &Profile, req: &Value) -> Result<Value> {
    let gid = coordinate(req, "group")?;
    let sender = coordinate(req, "sender")?;
    let mut group = group(provider, gid)?;
    let before = roster(profile, &group)?;
    ensure!(
        group.is_active() && before.contains_key(sender),
        "sender outside active group"
    );
    let message = MlsMessageIn::tls_deserialize_exact(&bytes(req, "ciphertext", 32768)?)?
        .try_into_protocol_message()?;
    ensure!(
        message.group_id().as_slice() == gid.as_bytes(),
        "MLS conversation mismatch"
    );
    ensure!(
        req["epoch"].as_u64() == Some(message.epoch().as_u64()),
        "MLS envelope epoch mismatch"
    );
    let processed = group.process_message(provider, message)?;
    let credential = BasicCredential::try_from(processed.credential().clone())?;
    ensure!(
        credential.identity() == sender.as_bytes(),
        "sender mismatch"
    );
    match processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(app) => {
            ensure!(req["kind"] == 1, "wrong envelope kind");
            let message: Value = serde_json::from_slice(&app.into_bytes())?;
            ensure!(
                coordinate(&message, "group")? == gid
                    && coordinate(&message, "sender")? == sender
                    && coordinate(&message, "id")? == coordinate(req, "id")?,
                "message binding mismatch"
            );
            if !message["type"].is_null() {
                // The ratchet advances, but private call/control payloads remain unsupported.
                return Ok(
                    json!({"id":message["id"],"group":gid,"sender":sender,"unsupported":true}),
                );
            }
            if !message["attachment"].is_null() {
                let attachment = &message["attachment"];
                if attachment_size(attachment).is_ok()
                    && attachment["media"].as_str() == Some("photo")
                {
                    return Ok(json!({"id":message["id"],"group":gid,"sender":sender,
                        "attachment":attachment}));
                }
                return Ok(
                    json!({"id":message["id"],"group":gid,"sender":sender,"unsupported":true}),
                );
            }
            Ok(
                json!({"id":message["id"],"group":gid,"sender":sender,"text":field(&message, "text")?}),
            )
        }
        ProcessedMessageContent::StagedCommitMessage(commit) => {
            ensure!(req["kind"] == 3, "wrong envelope kind");
            group.merge_staged_commit(provider, *commit)?;
            if group.is_active() {
                ensure!(
                    roster(profile, &group)? == before,
                    "GROUP_ROSTER_APPROVAL_REQUIRED"
                );
            }
            Ok(json!({"epoch":group.epoch().as_u64(),"active":group.is_active()}))
        }
        _ => bail!("unsupported MLS delivery"),
    }
}
