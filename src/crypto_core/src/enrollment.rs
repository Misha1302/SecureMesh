//! Device trust transcripts, not a new cryptographic protocol. Ed25519 is provided by OpenMLS.
//! Approvers must compare the candidate transcript through an independent QR/channel first.
use super::*;
use openmls_traits::crypto::OpenMlsCrypto;
use std::time::{SystemTime, UNIX_EPOCH};

struct Request {
    account: String,
    device: String,
    key: Vec<u8>,
    id: String,
    raw: Vec<u8>,
}

fn parse(req: &Value) -> Result<Request> {
    let raw = bytes(req, "payload")?;
    ensure!(raw.len() <= 1024, "invalid enrollment size");
    let parts: Vec<_> = std::str::from_utf8(&raw)?.split('\n').collect();
    ensure!(
        parts.len() == 8 && parts[0] == "SecureMesh/enrollment-request/v1",
        "invalid transcript"
    );
    for index in [1, 2, 4] {
        ensure!(
            uuid::Uuid::parse_str(parts[index])?.to_string() == parts[index],
            "noncanonical UUID"
        );
    }
    let key = B64.decode(parts[3])?;
    ensure!(
        key.len() == 32 && B64.encode(&key) == parts[3],
        "invalid device key"
    );
    ensure!(
        parts[5].len() == 64
            && parts[5]
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
        "invalid nonce"
    );
    let issued: u64 = parts[6].parse()?;
    let expires: u64 = parts[7].parse()?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    ensure!(
        issued <= now + 60 && expires > now && expires > issued && expires - issued <= 300,
        "expired enrollment"
    );
    ensure!(parts[1] == s(req, "account")?, "account binding mismatch");
    Ok(Request {
        account: parts[1].to_owned(),
        device: parts[2].to_owned(),
        key,
        id: parts[4].to_owned(),
        raw,
    })
}

fn grant_payload(approver: &str, raw: &[u8], proof: &[u8]) -> Vec<u8> {
    format!(
        "SecureMesh/enrollment-grant/v1\n{approver}\n{}\n{}",
        B64.encode(raw),
        B64.encode(proof)
    )
    .into_bytes()
}

pub(super) fn execute(
    db: &Connection,
    p: &Provider,
    req: &Value,
    identity: &str,
    signer: &SignatureKeyPair,
) -> Result<Value> {
    let request = parse(req)?;
    let fingerprint = B64.encode(Sha256::digest(&request.raw));
    match s(req, "op")? {
        "enrollment_proof" => {
            ensure!(
                request.device == identity && request.key == signer.public(),
                "candidate binding mismatch"
            );
            let signature = signer
                .sign(&request.raw)
                .map_err(|_| anyhow!("signature rejected"))?;
            let key = format!("enrollment-request:{}", request.id);
            let existing = db
                .query_row("SELECT value FROM app_meta WHERE key=?", [&key], |r| {
                    r.get::<_, String>(0)
                })
                .optional()?;
            ensure!(
                existing.as_ref().is_none_or(|old| old == &fingerprint),
                "request changed"
            );
            set_meta(db, &key, &fingerprint)?;
            Ok(
                json!({"signature":B64.encode(signature),"fingerprint":fingerprint,"device":request.device}),
            )
        }
        "enrollment_approve" => {
            ensure!(
                req["confirmed"].as_bool() == Some(true),
                "explicit QR confirmation required"
            );
            ensure!(request.device != identity, "self enrollment forbidden");
            let proof = bytes(req, "candidate_signature")?;
            p.crypto().verify_signature(
                SignatureScheme::ED25519,
                &request.raw,
                &request.key,
                &proof,
            )?;
            let consumed = format!("enrollment-approved:{}", request.id);
            ensure!(
                db.query_row(
                    "SELECT count(*) FROM app_meta WHERE key=?",
                    [&consumed],
                    |r| r.get::<_, i64>(0)
                )? == 0,
                "grant already signed"
            );
            // Existing pins cannot be replaced, even after the user confirms a new request.
            execute_pin(db, &request.device, &request.key)?;
            let signature = signer
                .sign(&grant_payload(identity, &request.raw, &proof))
                .map_err(|_| anyhow!("signature rejected"))?;
            set_meta(db, &consumed, &fingerprint)?;
            Ok(
                json!({"signature":B64.encode(signature),"approver":identity,"account":request.account,"fingerprint":fingerprint}),
            )
        }
        "enrollment_accept" => {
            ensure!(
                request.device == identity && request.key == signer.public(),
                "candidate binding mismatch"
            );
            ensure!(
                meta(db, &format!("enrollment-request:{}", request.id))? == fingerprint,
                "unsolicited grant"
            );
            let approver = s(req, "approver")?;
            ensure!(
                approver != identity && uuid::Uuid::parse_str(approver)?.to_string() == approver,
                "invalid approver"
            );
            let key: Vec<u8> = db.query_row(
                "SELECT public_key FROM pins WHERE identity=?",
                [approver],
                |r| r.get(0),
            )?;
            let proof = bytes(req, "candidate_signature")?;
            p.crypto().verify_signature(
                SignatureScheme::ED25519,
                &request.raw,
                &request.key,
                &proof,
            )?;
            p.crypto().verify_signature(
                SignatureScheme::ED25519,
                &grant_payload(approver, &request.raw, &proof),
                &key,
                &bytes(req, "grant_signature")?,
            )?;
            // Store only the public trust certificate. This does not join MLS or import old secrets.
            set_meta(db, "enrollment-certificate", &serde_json::to_string(req)?)?;
            Ok(
                json!({"verified":true,"account":request.account,"device":identity,"mls_joined":false}),
            )
        }
        _ => bail!("unsupported enrollment operation"),
    }
}

fn execute_pin(db: &Connection, identity: &str, key: &[u8]) -> Result<()> {
    let old = db
        .query_row(
            "SELECT public_key FROM pins WHERE identity=?",
            [identity],
            |r| r.get::<_, Vec<u8>>(0),
        )
        .optional()?;
    ensure!(
        old.as_ref().is_none_or(|old| old == key),
        "device key changed"
    );
    db.execute(
        "INSERT OR IGNORE INTO pins VALUES(?,?)",
        params![identity, key],
    )?;
    Ok(())
}
