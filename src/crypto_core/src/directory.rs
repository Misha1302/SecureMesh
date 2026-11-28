use super::*;
use openmls_traits::crypto::OpenMlsCrypto;

/// Public-only AS validation. It never opens a store or accepts a private key.
pub(crate) fn validate(req: &Value) -> Result<Value> {
    let raw = bytes(req, "keypackage")?;
    ensure!(raw.len() <= 16384, "keypackage too large");
    let crypto = RustCrypto::default();
    let kp =
        KeyPackageIn::tls_deserialize_exact(&raw)?.validate(&crypto, ProtocolVersion::Mls10)?;
    ensure!(kp.ciphersuite() == SUITE, "unsupported suite");
    let identity = BasicCredential::try_from(kp.leaf_node().credential().clone())?;
    ensure!(
        identity.identity() == s(req, "identity")?.as_bytes(),
        "identity binding mismatch"
    );
    ensure!(
        kp.leaf_node().signature_key().as_slice() == bytes(req, "public_key")?,
        "key binding mismatch"
    );
    Ok(json!({"reference":B64.encode(kp.hash_ref(&crypto)?.as_slice())}))
}

fn transcript(req: &Value, welcome: &[u8]) -> Result<Vec<u8>> {
    for field in ["group", "invitation", "lease", "sender", "recipient"] {
        let value = s(req, field)?;
        ensure!(
            uuid::Uuid::parse_str(value)?.to_string() == value,
            "invalid binding"
        );
    }
    let reference = bytes(req, "reference")?;
    ensure!(
        reference.len() == 32 && welcome.len() <= 32768,
        "invalid welcome binding"
    );
    ensure!(
        s(req, "sender")? != s(req, "recipient")?,
        "distinct devices required"
    );
    let message = MlsMessageIn::tls_deserialize_exact(welcome)?;
    let MlsMessageBodyIn::Welcome(parsed) = message.extract() else {
        bail!("not welcome");
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
        s(req, "group")?,
        s(req, "invitation")?,
        s(req, "lease")?,
        s(req, "sender")?,
        s(req, "recipient")?,
        B64.encode(reference),
        B64.encode(Sha256::digest(welcome))
    )
    .into_bytes())
}

fn check_initial_group(
    db: &Connection,
    group: &MlsGroup,
    sender: &str,
    recipient: &str,
) -> Result<()> {
    check_group(db, group)?;
    let members = roster::members(group)?;
    ensure!(
        group.is_active()
            && group.epoch().as_u64() == 1
            && members.len() == 2
            && members.contains_key(sender)
            && members.contains_key(recipient),
        "invalid initial group"
    );
    Ok(())
}

pub(super) fn execute(
    db: &Connection,
    p: &Provider,
    req: &Value,
    identity: &str,
    signer: &SignatureKeyPair,
) -> Result<Value> {
    if s(req, "op")? == "directory_pending" {
        let key = format!("bootstrap:{}", s(req, "invitation")?);
        let saved = db
            .query_row("SELECT value FROM app_meta WHERE key=?", [key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?;
        return Ok(match saved {
            Some(saved) => {
                json!({"prepared":true,"request":serde_json::from_str::<Value>(&saved)?})
            }
            None => json!({"prepared":false}),
        });
    }
    if s(req, "op")? == "directory_prepare" {
        let invitation = s(req, "invitation")?;
        let meta_key = format!("bootstrap:{invitation}");
        let old = db
            .query_row("SELECT value FROM app_meta WHERE key=?", [&meta_key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?;
        if let Some(old) = old {
            let old: Value = serde_json::from_str(&old)?;
            ensure!(
                old["binding"]["lease"] == req["lease"]
                    && old["binding"]["reference"] == req["reference"]
                    && old["binding"]["recipient"] == req["recipient"],
                "bootstrap input changed"
            );
            return Ok(old);
        }
        let kp = KeyPackageIn::tls_deserialize_exact(&bytes(req, "keypackage")?)?
            .validate(p.crypto(), ProtocolVersion::Mls10)?;
        ensure!(
            kp.hash_ref(p.crypto())?.as_slice() == bytes(req, "reference")?,
            "package reference mismatch"
        );
        let peer = BasicCredential::try_from(kp.leaf_node().credential().clone())?;
        ensure!(
            peer.identity() == s(req, "recipient")?.as_bytes(),
            "package recipient mismatch"
        );
        check_member(
            db,
            kp.leaf_node().credential(),
            kp.leaf_node().signature_key().as_slice(),
        )?;
        let group = uuid::Uuid::new_v4().to_string();
        super::execute(db, p, &json!({"op":"create","group":group}))?;
        let added = super::execute(
            db,
            p,
            &json!({"op":"add","group":group,"keypackage":s(req,"keypackage")?}),
        )?;
        let binding = json!({"op":"directory_sign","group":group,"invitation":invitation,"lease":s(req,"lease")?,"sender":identity,"recipient":s(req,"recipient")?,"reference":s(req,"reference")?,"welcome":added["welcome"]});
        let signed = execute(db, p, &binding, identity, signer)?;
        let result = json!({"id":group,"invitationId":invitation,"leaseId":s(req,"lease")?,"welcome":added["welcome"],"signature":signed["signature"],"binding":binding});
        set_meta(db, &meta_key, &serde_json::to_string(&result)?)?;
        return Ok(result);
    }
    let welcome = bytes(req, "welcome")?;
    let data = transcript(req, &welcome)?;
    match s(req, "op")? {
        "directory_sign" => {
            ensure!(s(req, "sender")? == identity, "sender mismatch");
            let group = load_group(p, s(req, "group")?)?;
            check_initial_group(db, &group, identity, s(req, "recipient")?)?;
            let signature = signer
                .sign(&data)
                .map_err(|_| anyhow!("signature rejected"))?;
            Ok(json!({"signature":B64.encode(signature)}))
        }
        "directory_join" => {
            ensure!(s(req, "recipient")? == identity, "recipient mismatch");
            let sender = s(req, "sender")?;
            let key: Vec<u8> = db.query_row(
                "SELECT public_key FROM pins WHERE identity=?",
                [sender],
                |r| r.get(0),
            )?;
            p.crypto().verify_signature(
                SignatureScheme::ED25519,
                &data,
                &key,
                &bytes(req, "signature")?,
            )?;
            let gid = s(req, "group")?;
            let slot = format!("directory-join:{gid}");
            let binding = B64.encode(Sha256::digest(&data));
            if let Some(saved) = db
                .query_row("SELECT value FROM app_meta WHERE key=?", [&slot], |r| {
                    r.get::<_, String>(0)
                })
                .optional()?
            {
                ensure!(saved == binding, "directory join context changed");
                return Ok(json!({"already_joined":true}));
            }
            // Older stores only recorded the Welcome digest. It cannot prove which
            // invitation and lease were accepted for an already established group.
            ensure!(
                MlsGroup::load(p.storage(), &GroupId::from_slice(gid.as_bytes()))?.is_none(),
                "missing directory join context for existing group"
            );
            let mut join = req.clone();
            join["op"] = json!("join");
            join["expected_members"] = json!([sender, identity]);
            let result = super::execute(db, p, &join)?;
            check_initial_group(db, &load_group(p, gid)?, sender, identity)?;
            set_meta(db, &slot, &binding)?;
            Ok(result)
        }
        _ => bail!("unsupported directory operation"),
    }
}
