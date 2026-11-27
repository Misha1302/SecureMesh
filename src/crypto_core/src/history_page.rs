//! Read-only pages prior to the live window, inside the unlocked profile.
//! Row-id ceilings freeze both directions while delivery continues. Device-local
//! event times are immutable. Legacy rows have no time; their stable tie break
//! preserves insertion order within each direction without inventing a date.
use super::{s, Connection, Result, Value};
use anyhow::{ensure, Context};
use rusqlite::params;
use serde_json::json;

const PAGE: usize = 48;
// The cursor expression matches its SQLite indices, including the fallback
// for old rows or unrecognized optional event fields.
const LOCAL_MS: &str = "CASE WHEN json_type(event,'$.localTimeMs')='integer'
    AND json_extract(event,'$.localTimeMs') BETWEEN 1 AND 8640000000000000
    THEN json_extract(event,'$.localTimeMs') ELSE 0 END";

pub(super) fn create_indices(db: &Connection) -> Result<()> {
    db.execute_batch(&format!(
        "CREATE INDEX IF NOT EXISTS authored_history_local ON authored(group_id,{LOCAL_MS});
         CREATE INDEX IF NOT EXISTS incoming_history_local ON incoming(group_id,{LOCAL_MS});
         CREATE INDEX IF NOT EXISTS received_history_id ON received(group_id,json_extract(envelope,'$.id'),seq);"
    ))?;
    Ok(())
}

pub(super) fn read(db: &Connection, req: &Value) -> Result<Value> {
    let group = s(req, "group")?;
    let cursor = &req["cursor"];
    ensure!(
        s(cursor, "group")? == group,
        "history cursor belongs to another chat"
    );
    let through = |field: &str| {
        cursor[field]
            .as_i64()
            .filter(|n| *n >= 0)
            .context("invalid history boundary")
    };
    let (own, incoming) = (through("ownThrough")?, through("incomingThrough")?);
    let after = match cursor.get("before") {
        None => (i64::MAX, i64::MAX, true),
        Some(value) => {
            let [Some(ms), Some(row), Some(direction)] = [value.get(0), value.get(1), value.get(2)]
            else {
                anyhow::bail!("invalid history position")
            };
            (
                ms.as_i64()
                    .filter(|n| *n >= 0)
                    .context("invalid history time")?,
                row.as_i64()
                    .filter(|n| *n > 0)
                    .context("invalid history row")?,
                direction.as_bool().context("invalid history direction")?,
            )
        }
    };
    let mut page = Vec::new();
    for (table, limit, is_own) in [("authored", own, true), ("incoming", incoming, false)] {
        if limit == 0 {
            continue;
        }
        // Both table names are fixed literals. Only display fields cross the bridge.
        let sql = format!("SELECT {LOCAL_MS} AS ms,rowid,id,
            CASE WHEN json_type(event,'$.text')='text' THEN json_extract(event,'$.text') END,
            CASE WHEN json_type(event,'$.attachment.name')='text' THEN json_extract(event,'$.attachment.name') END FROM {table}
            WHERE group_id=?1 AND rowid<=?2 AND ({LOCAL_MS},rowid,?3)<(?4,?5,?6)
            ORDER BY ms DESC,rowid DESC LIMIT ?7");
        let mut statement = db.prepare(&sql)?;
        let mut rows = statement.query(params![
            group,
            limit,
            is_own,
            after.0,
            after.1,
            after.2,
            PAGE as i64 + 1
        ])?;
        while let Some(row) = rows.next()? {
            let ms: i64 = row.get(0)?;
            let local_row: i64 = row.get(1)?;
            let value = json!({"id":row.get::<_,String>(2)?,"own":is_own,
                "text":row.get::<_,Option<String>>(3)?.unwrap_or_default(),
                "attachmentName":row.get::<_,Option<String>>(4)?,
                "localTimeMs":(ms>0).then_some(ms)});
            page.push(((ms, local_row, is_own), value));
        }
    }
    page.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    let more = page.len() > PAGE;
    page.truncate(PAGE);
    let next = page.last().filter(|_| more).map(|(key, _)| {
        json!({
            "group":group,"ownThrough":own,"incomingThrough":incoming,"before":key
        })
    });
    Ok(json!({"messages":page.into_iter().map(|(_,v)|v).collect::<Vec<_>>(),"next":next}))
}
