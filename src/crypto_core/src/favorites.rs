//! Local SQLCipher references to the original messages. No operation in this
//! module emits an envelope, duplicates attachment keys, or changes a message.
use super::{s, Connection, Result, Value};
use anyhow::{ensure, Context};
use rusqlite::{params, OptionalExtension};
use serde_json::json;

pub(super) fn set(db: &Connection, req: &Value) -> Result<Value> {
    let group = s(req, "group")?;
    let saved = req["saved"].as_bool().context("missing favorite state")?;
    let items = req["items"].as_array().context("invalid favorites list")?;
    ensure!(
        !items.is_empty() && items.len() <= 256,
        "invalid number of favorites"
    );
    for item in items {
        let own = item["own"].as_bool().context("missing direction")?;
        let id = s(item, "id")?;
        if saved {
            require_message(db, group, id, own)?;
            db.execute(
                "INSERT INTO message_favorites(group_id,own,message_id) VALUES(?,?,?)
                ON CONFLICT(group_id,own,message_id) DO NOTHING",
                params![group, own, id],
            )?;
        } else {
            db.execute(
                "DELETE FROM message_favorites WHERE group_id=? AND own=? AND message_id=?",
                params![group, own, id],
            )?;
        }
    }
    Ok(json!({"saved":saved}))
}

pub(super) fn list(db: &Connection, req: &Value) -> Result<Value> {
    const PAGE: usize = 48;
    let before = match req.get("before") {
        None => i64::MAX,
        Some(v) => v
            .as_i64()
            .filter(|n| *n > 0)
            .context("invalid favorites position")?,
    };
    let mut q = db.prepare("SELECT f.position,f.group_id,f.own,f.message_id,coalesce(a.event,i.event)
        FROM message_favorites f
        LEFT JOIN authored a ON f.own=1 AND a.group_id=f.group_id AND a.id=f.message_id
        LEFT JOIN incoming i ON f.own=0 AND i.group_id=f.group_id AND i.id=f.message_id
        WHERE f.position<? AND (a.id IS NOT NULL OR i.id IS NOT NULL) ORDER BY f.position DESC LIMIT ?")?;
    let mut rows = q.query(params![before, PAGE as i64 + 1])?;
    let mut items = Vec::new();
    let mut next = None;
    let mut position = None;
    while let Some(row) = rows.next()? {
        if items.len() == PAGE {
            next = position;
            break;
        }
        position = Some(row.get::<_, i64>(0)?);
        let event: Value = serde_json::from_str(&row.get::<_, String>(4)?)?;
        items.push(
            json!({"group":row.get::<_,String>(1)?,"own":row.get::<_,bool>(2)?,
            "id":row.get::<_,String>(3)?,"text":event["text"].as_str().unwrap_or_default(),
            "attachmentName":event["attachment"]["name"].as_str()}),
        );
    }
    Ok(json!({"messages":items,"next":next}))
}

fn require_message(db: &Connection, group: &str, id: &str, own: bool) -> Result<()> {
    let source = if own { "authored" } else { "incoming" };
    let present: bool = db.query_row(
        &format!("SELECT EXISTS(SELECT 1 FROM {source} WHERE group_id=? AND id=?)"),
        params![group, id],
        |r| r.get(0),
    )?;
    ensure!(present, "message unavailable");
    Ok(())
}

pub(super) fn pin(db: &Connection, req: &Value) -> Result<Value> {
    let group = s(req, "group")?;
    let id = s(req, "id")?;
    let own = req["own"].as_bool().context("missing direction")?;
    let pin = req["pinned"].as_bool().context("missing pin state")?;
    if pin {
        require_message(db, group, id, own)?;
        db.execute(
            "INSERT INTO chat_message_pin(group_id,message_id,own) VALUES(?,?,?)
            ON CONFLICT(group_id) DO UPDATE SET message_id=excluded.message_id,own=excluded.own",
            params![group, id, own],
        )?;
    } else {
        // A stale tap cannot remove a different message pinned in the meantime.
        db.execute(
            "DELETE FROM chat_message_pin WHERE group_id=? AND message_id=? AND own=?",
            params![group, id, own],
        )?;
    }
    Ok(json!({"pinned":pin}))
}

pub(super) fn pinned(db: &Connection, group: &str) -> Result<Option<Value>> {
    let result = db
        .query_row(
            "SELECT p.message_id,p.own,coalesce(a.event,i.event) FROM chat_message_pin p
        LEFT JOIN authored a ON p.own=1 AND a.group_id=p.group_id AND a.id=p.message_id
        LEFT JOIN incoming i ON p.own=0 AND i.group_id=p.group_id AND i.id=p.message_id
        WHERE p.group_id=? AND (a.id IS NOT NULL OR i.id IS NOT NULL)",
            [group],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, bool>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .optional()?;
    result.map(|(id,own,raw)|{
        let event:Value=serde_json::from_str(&raw)?;
        Ok(json!({"group":group,"id":id,"own":own,"text":event["text"].as_str().unwrap_or_default(),
            "attachmentName":event["attachment"]["name"].as_str()}))
    }).transpose()
}
