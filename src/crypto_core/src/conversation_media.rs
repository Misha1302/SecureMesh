//! Local-only media directory. Explicitly project display fields so legacy
//! attachment keys and nonces are never included in list results.
use super::{s, Connection, Result, Value};
use anyhow::{ensure, Context};
use rusqlite::params;
use serde_json::json;

const PAGE: usize = 40;

pub(super) fn list(db: &Connection, req: &Value) -> Result<Value> {
    let group = s(req, "group")?;
    let category = s(req, "category")?;
    ensure!(
        matches!(
            category,
            "photo" | "video" | "file" | "links" | "audio" | "voice"
        ),
        "invalid media category"
    );
    let cursor = &req["cursor"];
    let (own_max, incoming_max, before) = if cursor.is_null() {
        let (own, incoming) = db.query_row(
            "SELECT (SELECT coalesce(max(rowid),0) FROM authored WHERE group_id=?1),
                    (SELECT coalesce(max(rowid),0) FROM incoming WHERE group_id=?1)",
            [group],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?;
        (own, incoming, (i64::MAX, i64::MAX, true))
    } else {
        ensure!(
            cursor["group"] == group && cursor["category"] == category,
            "invalid media cursor scope"
        );
        let n = |field: &str| {
            cursor[field]
                .as_i64()
                .filter(|v| *v >= 0)
                .context("invalid media cursor position")
        };
        (
            n("ownMax")?,
            n("incomingMax")?,
            (
                n("time")?,
                n("row")?,
                cursor["own"]
                    .as_bool()
                    .context("invalid media cursor direction")?,
            ),
        )
    };

    // Row ceilings make paging stable if new events arrive. The time is the
    // local commit time. Historical events with no time use row/direction order.
    let mut statement = db.prepare(
        "WITH events AS (
            SELECT rowid AS pos,id,1 AS own,event FROM authored WHERE group_id=?1 AND rowid<=?2
            UNION ALL SELECT rowid AS pos,id,0 AS own,event FROM incoming WHERE group_id=?1 AND rowid<=?3
         ), items AS (
            SELECT pos,id,own,
              CASE WHEN json_type(event,'$.localTimeMs')='integer' AND json_extract(event,'$.localTimeMs') BETWEEN 1 AND 8640000000000000 THEN json_extract(event,'$.localTimeMs') ELSE 0 END AS ms,
              CASE WHEN json_type(event,'$.text')='text' THEN json_extract(event,'$.text') ELSE '' END AS body,
              json_extract(event,'$.attachment.name') AS name,
              json_extract(event,'$.attachment.media') AS media,
              json_extract(event,'$.attachment.blobId') AS blob,
              json_extract(event,'$.attachment.size') AS size,
              json_extract(event,'$.attachment.caption') AS caption
            FROM events
         ) SELECT pos,id,own,ms,
              CASE WHEN ?4='links' THEN substr(body,1,4000) END,
              CASE WHEN ?4!='links' THEN name END,
              CASE WHEN ?4!='links' THEN media END,
              CASE WHEN ?4!='links' THEN blob END,
              CASE WHEN ?4!='links' THEN size END,
              CASE WHEN ?4!='links' AND typeof(caption)='text' THEN caption END
            FROM items WHERE (ms,pos,own)<(?5,?6,?7) AND (
              (?4='links' AND instr(body,'||')=0 AND (body LIKE '%http://%' OR body LIKE '%https://%')) OR
              (?4!='links' AND typeof(name)='text' AND length(name) BETWEEN 1 AND 255 AND typeof(blob)='text'
               AND length(blob)=36 AND typeof(size)='integer' AND size BETWEEN 1 AND 4194304 AND
               CASE
                WHEN media='file' AND (lower(name) GLOB '*.mp3' OR lower(name) GLOB '*.ogg' OR lower(name) GLOB '*.wav'
                  OR lower(name) GLOB '*.flac' OR lower(name) GLOB '*.m4a' OR lower(name) GLOB '*.aac' OR lower(name) GLOB '*.opus') THEN 'audio'
                WHEN media='file' AND (lower(name) GLOB '*.mp4' OR lower(name) GLOB '*.webm' OR lower(name) GLOB '*.mov'
                  OR lower(name) GLOB '*.mkv' OR lower(name) GLOB '*.m4v') THEN 'video'
                ELSE media END=?4)
            ) ORDER BY ms DESC,pos DESC,own DESC LIMIT ?8")?;
    let mut rows = statement.query(params![
        group,
        own_max,
        incoming_max,
        category,
        before.0,
        before.1,
        before.2,
        (PAGE + 1) as i64
    ])?;
    let mut items = Vec::new();
    let mut position = None;
    let mut next = None;
    while let Some(row) = rows.next()? {
        if items.len() == PAGE {
            next = position;
            break;
        }
        let own: bool = row.get(2)?;
        let time: i64 = row.get(3)?;
        position = Some(
            json!({"group":group,"category":category,"ownMax":own_max,"incomingMax":incoming_max,
            "time":time,"row":row.get::<_,i64>(0)?,"own":own}),
        );
        let mut item = if category == "links" {
            json!({"id":row.get::<_,String>(1)?, "body":row.get::<_,String>(4)?})
        } else {
            json!({"id":row.get::<_,String>(1)?, "attachment":{"name":row.get::<_,String>(5)?,"media":row.get::<_,String>(6)?,
                "blobId":row.get::<_,String>(7)?, "size":row.get::<_,i64>(8)?}})
        };
        if let Some(caption) = row.get::<_, Option<String>>(9)? {
            item["attachment"]["caption"] = json!(caption);
        }
        items.push(item);
    }
    Ok(json!({"items":items,"next":next}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cursor_is_scoped_and_stable_and_metadata_is_redacted() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE incoming(group_id TEXT,id TEXT,event TEXT); CREATE TABLE authored(group_id TEXT,id TEXT,event TEXT);").unwrap();
        let attach = json!({"attachment":{"name":"book.mp3","key":"secret","blobId":"b3ec393b-2da8-40de-9321-31d344cd2cfe","media":"file","size":128}});
        for i in 0..43 {
            db.execute(
                "INSERT INTO incoming VALUES('x',?,?)",
                params![i.to_string(), attach.to_string()],
            )
            .unwrap();
        }
        let query = |scope, category, cursor| {
            list(
                &db,
                &json!({"group":scope,"category":category,"cursor":cursor}),
            )
        };
        let first = query("x", "audio", Value::Null).unwrap();
        assert_eq!(first["items"].as_array().unwrap().len(), PAGE);
        assert!(!first.to_string().contains("secret"));
        db.execute(
            "INSERT INTO authored VALUES('x','later',?)",
            [attach.to_string()],
        )
        .unwrap();
        let next = query("x", "audio", first["next"].clone()).unwrap();
        assert_eq!(next["items"].as_array().unwrap().len(), 3);
        assert!(next["next"].is_null());
        assert!(query("other", "audio", first["next"].clone()).is_err());
        assert!(query("x", "file", first["next"].clone()).is_err());
        for (group, text) in [
            ("x", "safe https://example.org"),
            ("x", "||https://secret.example||"),
            ("other", "https://other.example"),
        ] {
            db.execute(
                "INSERT INTO incoming VALUES(?,'link',?)",
                params![group, json!({"text":text}).to_string()],
            )
            .unwrap();
        }
        let links = query("x", "links", Value::Null).unwrap();
        assert_eq!(links["items"].as_array().unwrap().len(), 1);
        assert_eq!(links["items"][0]["body"], "safe https://example.org");
    }
}
