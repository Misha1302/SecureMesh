//! Device-local list metadata. The MLS payload never includes local activity times.
use super::*;

pub(super) fn record(db: &Connection, event: &mut Value, own: bool) -> Result<()> {
    let group = s(event, "group")?;
    let id = s(event, "id")?;
    let time: i64 = db.query_row(
        "SELECT CAST(unixepoch('subsec') * 1000 AS INTEGER)",
        [],
        |r| r.get(0),
    )?;
    // An untrusted event can omit optional display text. Do not block its receipt.
    let text = event["text"].as_str().unwrap_or("");
    let preview: String = if text.contains("||") {
        "||".into()
    } else {
        text.chars().take(160).collect()
    };
    db.execute(
        "INSERT INTO conversation_previews(group_id,preview,own,local_ms,unread,last_incoming)
         VALUES(?1,?2,?3,?4,NOT ?3,CASE WHEN NOT ?3 THEN ?5 END)
         ON CONFLICT(group_id) DO UPDATE SET preview=excluded.preview,own=excluded.own,
         local_ms=excluded.local_ms,unread=unread+excluded.unread,
         last_incoming=coalesce(excluded.last_incoming,last_incoming)",
        params![group, preview, own, time, id],
    )?;
    event["localTimeMs"] = json!(time);
    Ok(())
}

pub(super) fn list(db: &Connection) -> Result<Value> {
    let mut q =
        db.prepare("SELECT group_id,preview,own,local_ms,unread FROM conversation_previews")?;
    let mut rows = q.query([])?;
    let mut previews = serde_json::Map::new();
    while let Some(r) = rows.next()? {
        previews.insert(r.get(0)?, json!({"text":r.get::<_,String>(1)?, "own":r.get::<_,bool>(2)?, "localTimeMs":r.get::<_,i64>(3)?, "unread":r.get::<_,i64>(4)?}));
    }
    Ok(json!({"previews":previews}))
}
