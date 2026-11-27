//! A closed SQLCipher snapshot is opened separately from the live MLS store.
use super::{history_page, meta, s, Connection, Result, Value};
use anyhow::ensure;
use rusqlite::OpenFlags;
use serde_json::json;

pub(super) fn read(path: &str, request: &Value) -> Result<String> {
    let pass = s(request, "passphrase")?;
    ensure!(pass.len() >= 16, "passphrase too short");
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.pragma_update(None, "key", pass)?;
    db.execute_batch("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; PRAGMA temp_store=MEMORY;")?;
    let version: String = db.query_row("PRAGMA cipher_version", [], |r| r.get(0))?;
    ensure!(!version.is_empty(), "SQLCipher required");
    if request.get("cursor").is_some() {
        return Ok(history_page::read(&db, request)?.to_string());
    }
    let profile: Value = serde_json::from_str(&meta(&db, "local_profile")?)?;
    let mut chats = Vec::new();
    let mut query = db.prepare(
        "SELECT group_id, max(own), max(incoming) FROM (
        SELECT group_id,max(rowid) AS own,0 AS incoming FROM authored GROUP BY group_id
        UNION ALL SELECT group_id,0,max(rowid) FROM incoming GROUP BY group_id
        ) GROUP BY group_id ORDER BY group_id",
    )?;
    let mut rows = query.query([])?;
    while let Some(row) = rows.next()? {
        let group: String = row.get(0)?;
        let name = profile["verifiedChats"][&group]["name"]
            .as_str()
            .or_else(|| {
                (profile["group"].as_str() == Some(&group))
                    .then(|| profile["peerName"].as_str())
                    .flatten()
            });
        chats.push(json!({"name":name, "cursor":{"group":group, "ownThrough":row.get::<_,i64>(1)?, "incomingThrough":row.get::<_,i64>(2)?}}));
    }
    Ok(json!({"username": profile["username"].as_str(), "chats":chats}).to_string())
}
