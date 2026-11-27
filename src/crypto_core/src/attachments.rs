//! Single-use attachment keys. Only sealed bytes leave the client outside MLS.
use super::*;
use openmls_traits::{crypto::OpenMlsCrypto, random::OpenMlsRand, types::AeadType};

const LIMIT: usize = 4 * 1024 * 1024;
const TAG: usize = 16;
pub(crate) const MAX_REQUEST: usize = (LIMIT + TAG).div_ceil(3) * 4 + 4096;

pub(super) fn parse_command(input: &str) -> Result<Value> {
    ensure!(input.len() <= MAX_REQUEST, "input too large");
    let req: Value = serde_json::from_str(input)?;
    ensure!(
        input.len() <= 262144 || matches!(s(&req, "op")?, "attachment_prepare" | "attachment_open"),
        "input too large"
    );
    Ok(req)
}

fn canonical_uuid(value: &str) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(value)?.to_string() == value,
        "invalid id"
    );
    Ok(())
}

fn validate_info(info: &Value) -> Result<usize> {
    ensure!(info["v"] == 1, "unsupported file descriptor");
    canonical_uuid(s(info, "blobId")?)?;
    let size = info["size"].as_u64().context("size")?;
    ensure!((1..=LIMIT as u64).contains(&size), "invalid file size");
    if let Some(caption) = info.get("caption") {
        ensure!(
            caption.as_str().is_some_and(|v| v.len() <= 2048),
            "invalid caption"
        );
    }
    let name = s(info, "name")?;
    ensure!(!name.trim().is_empty() && name.len() <= 255 && name != "." && name != ".." &&
        !name.chars().any(|c| c.is_control() || matches!(c, '/' | '\\' | ':' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')),
        "invalid filename");
    ensure!(
        matches!(s(info, "media")?, "file" | "photo" | "voice" | "video"),
        "invalid media"
    );
    ensure!(
        bytes(info, "key")?.len() == 32 && bytes(info, "nonce")?.len() == 12,
        "invalid file key"
    );
    Ok(size as usize)
}

fn aad(group: &str, id: &str, info: &Value) -> Result<Vec<u8>> {
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

fn public_info(info: &Value) -> Value {
    let mut result = json!({"blobId":info["blobId"],"name":info["name"],"media":info["media"],"size":info["size"]});
    if let Some(caption) = info["caption"]
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 2048)
    {
        result["caption"] = json!(caption);
    }
    result
}

fn upload_info(id: &str, info: &Value) -> Value {
    json!({"id":id,"blobId":info["blobId"],"ciphertextBytes":info["size"].as_u64().unwrap_or(0) + TAG as u64})
}

pub(super) fn descriptor(db: &Connection, group: &str, id: &str) -> Result<Value> {
    // A previous client may have processed a new MLS attachment and stored
    // the complete authenticated event in its encrypted incoming table.
    let raw: String = db.query_row(
        "SELECT descriptor FROM private_files WHERE group_id=?1 AND id=?2
         UNION ALL SELECT json_extract(event,'$.attachment') FROM incoming
         WHERE group_id=?1 AND id=?2 AND json_type(event,'$.attachment.key')='text' LIMIT 1",
        params![group, id],
        |r| r.get(0),
    )?;
    Ok(serde_json::from_str(&raw)?)
}

pub(super) fn view(mut event: Value) -> Value {
    if event["attachment"].get("key").is_some() {
        let info = event.as_object_mut().unwrap().remove("attachment").unwrap();
        if validate_info(&info).is_ok() {
            hide_key(&mut event, &info);
        }
    }
    event
}

pub(super) fn hide_key(event: &mut Value, info: &Value) {
    event["attachment"] = public_info(info);
}

// Authenticated input from a peer. Invalid optional metadata must not stall text sync.
pub(super) fn receive(db: &Connection, group: &str, event: &mut Value) -> Result<()> {
    let Some(info) = event.as_object_mut().and_then(|o| o.remove("attachment")) else {
        return Ok(());
    };
    let id = s(event, "id")?;
    if canonical_uuid(id).is_err() || validate_info(&info).is_err() {
        return Ok(());
    }
    let saved = db.execute(
        "INSERT INTO private_files(group_id,id,descriptor) VALUES(?,?,?) ON CONFLICT DO NOTHING",
        params![group, id, serde_json::to_string(&info)?],
    )?;
    if saved == 1 {
        hide_key(event, &info);
    }
    Ok(())
}

pub(super) fn execute(db: &Connection, p: &Provider, req: &Value) -> Result<Value> {
    let op = s(req, "op")?;
    let group = s(req, "group")?;
    canonical_uuid(group)?;
    if op == "attachment_pending" {
        let mut stmt=db.prepare("SELECT id,descriptor FROM private_files WHERE group_id=? AND sealed IS NOT NULL ORDER BY rowid")?;
        let mut rows = stmt.query([group])?;
        let mut uploads = Vec::new();
        while let Some(row) = rows.next()? {
            let info = serde_json::from_str(&row.get::<_, String>(1)?)?;
            uploads.push(upload_info(&row.get::<_, String>(0)?, &info));
        }
        return Ok(json!({"uploads":uploads}));
    }
    let id = s(req, "id")?;
    canonical_uuid(id)?;
    match op {
        "attachment_prepare" => {
            let g = load_group(p, group)?;
            check_group(db, &g)?;
            ensure!(
                g.is_active() && g.members().count() >= 2,
                "inactive conversation"
            );
            let data = bytes(req, "data")?;
            ensure!((1..=LIMIT).contains(&data.len()), "invalid file size");
            let caption = req["caption"].as_str().unwrap_or("");
            ensure!(caption.len() <= 2048, "caption too large");
            let digest = Sha256::digest(&data);
            let existing: Option<(String, Option<Vec<u8>>)> = db
                .query_row(
                    "SELECT descriptor,source_digest FROM private_files WHERE group_id=? AND id=?",
                    params![group, id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if let Some((raw, source)) = existing {
                let info: Value = serde_json::from_str(&raw)?;
                ensure!(
                    source.as_deref() == Some(digest.as_slice())
                        && info["name"] == req["name"]
                        && info["media"] == req["media"]
                        && info["caption"].as_str().unwrap_or("") == caption,
                    "attachment id conflict"
                );
                return Ok(upload_info(id, &info));
            }
            let used: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM authored WHERE group_id=?1 AND id=?2 UNION ALL SELECT 1 FROM incoming WHERE group_id=?1 AND id=?2)",params![group,id],|r|r.get(0))?;
            ensure!(!used, "message id in use");
            let (count,total):(i64,i64)=db.query_row("SELECT count(*),coalesce(sum(length(sealed)),0) FROM private_files WHERE sealed IS NOT NULL",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
            ensure!(
                count < 64 && total + (data.len() + TAG) as i64 <= 64 * 1024 * 1024,
                "local attachment quota"
            );
            let key = p.rand().random_array::<32>()?;
            let nonce = p.rand().random_array::<12>()?;
            let mut info = json!({"v":1,"blobId":uuid::Uuid::new_v4().to_string(),"size":data.len(),"name":s(req,"name")?,"media":s(req,"media")?,"key":B64.encode(key),"nonce":B64.encode(nonce)});
            if !caption.is_empty() {
                info["caption"] = json!(caption);
            }
            validate_info(&info)?;
            let sealed = p.crypto().aead_encrypt(
                AeadType::Aes256Gcm,
                &key,
                &data,
                &nonce,
                &aad(group, id, &info)?,
            )?;
            db.execute("INSERT INTO private_files(group_id,id,descriptor,sealed,source_digest) VALUES(?,?,?,?,?)",params![group,id,serde_json::to_string(&info)?,sealed,digest.as_slice()])?;
            Ok(upload_info(id, &info))
        }
        "attachment_ciphertext" => {
            let sealed: Vec<u8> = db.query_row(
                "SELECT sealed FROM private_files WHERE group_id=? AND id=? AND sealed IS NOT NULL",
                params![group, id],
                |r| r.get(0),
            )?;
            Ok(json!({"ciphertext":B64.encode(sealed)}))
        }
        "attachment_cancel" => {
            let cancelled = db.execute(
                "DELETE FROM private_files WHERE group_id=? AND id=? AND sealed IS NOT NULL",
                params![group, id],
            )?;
            Ok(json!({"cancelled":cancelled==1}))
        }
        "attachment_download_prefix" => {
            let info = descriptor(db, group, id)?;
            validate_info(&info)?;
            db.execute(
                "DELETE FROM private_downloads WHERE updated < unixepoch()-86400",
                [],
            )?;
            let prefix: Option<Vec<u8>> = db
                .query_row(
                    "SELECT prefix FROM private_downloads WHERE group_id=? AND id=?",
                    params![group, id],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(json!({"ciphertext":B64.encode(prefix.unwrap_or_default())}))
        }
        "attachment_download_part" => {
            let info = descriptor(db, group, id)?;
            let size = validate_info(&info)? + TAG;
            let offset = req["offset"].as_u64().context("missing download offset")?;
            ensure!(
                offset < size as u64 && offset % 32768 == 0,
                "invalid download offset"
            );
            let chunk = bytes(req, "ciphertext")?;
            ensure!(
                chunk.len() == (size - offset as usize).min(32768),
                "invalid download length"
            );
            db.execute(
                "DELETE FROM private_downloads WHERE updated < unixepoch()-86400",
                [],
            )?;
            if offset == 0 {
                // Discard the least recently used partial download when reserving another slot.
                // Each reservation fits a bounded attachment, so eight rows take at most 32 MiB + tags.
                db.execute(
                    "DELETE FROM private_downloads WHERE rowid IN (
                    SELECT rowid FROM private_downloads WHERE NOT(group_id=? AND id=?)
                    ORDER BY updated DESC,rowid DESC LIMIT -1 OFFSET 7)",
                    params![group, id],
                )?;
                db.execute("INSERT INTO private_downloads VALUES(?,?,?,X'',unixepoch()) ON CONFLICT DO NOTHING",
                    params![group,id,size as i64])?;
            }
            let written = db.execute(
                "UPDATE private_downloads SET prefix=CAST(prefix || ? AS BLOB),
                updated=unixepoch() WHERE group_id=? AND id=? AND size=? AND length(prefix)=?",
                params![chunk, group, id, size as i64, offset as i64],
            )?;
            ensure!(written == 1, "download offset conflict");
            Ok(json!({"offset":offset + chunk.len() as u64}))
        }
        "attachment_download_reset" => {
            db.execute(
                "DELETE FROM private_downloads WHERE group_id=? AND id=?",
                params![group, id],
            )?;
            Ok(json!({}))
        }
        "attachment_open" => {
            let info = descriptor(db, group, id)?;
            let size = validate_info(&info)?;
            let sealed = bytes(req, "ciphertext")?;
            ensure!(sealed.len() == size + TAG, "invalid file length");
            let data = p.crypto().aead_decrypt(
                AeadType::Aes256Gcm,
                &bytes(&info, "key")?,
                &sealed,
                &bytes(&info, "nonce")?,
                &aad(group, id, &info)?,
            )?;
            db.execute(
                "DELETE FROM private_downloads WHERE group_id=? AND id=?",
                params![group, id],
            )?;
            let mut result = public_info(&info);
            result["data"] = json!(B64.encode(data));
            Ok(result)
        }
        _ => bail!("unknown attachment operation"),
    }
}
