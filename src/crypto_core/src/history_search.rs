//! Read-only literal search within the unlocked SQLCipher store.
use anyhow::{ensure, Result};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::collections::VecDeque;

const LIMIT: usize = 50;

// Folded strings and original UTF-8 offsets can differ (e.g. İ -> i plus a
// combining dot). Walk original characters to select context without splitting UTF-8.
fn snippet(body: &str, folded_byte_offset: usize) -> String {
    let mut prior = VecDeque::with_capacity(25);
    let mut folded_bytes = 0;
    let mut offset = 0;
    for (byte, ch) in body.char_indices() {
        offset = byte;
        let width: usize = ch.to_lowercase().map(char::len_utf8).sum();
        if folded_bytes + width > folded_byte_offset {
            break;
        }
        if prior.len() == 24 {
            prior.pop_front();
        }
        prior.push_back(byte);
        folded_bytes += width;
    }
    let start = prior.front().copied().unwrap_or(offset);
    let mut result: String = body[start..].chars().take(160).collect();
    if start + result.len() < body.len() {
        result.push('…');
    }
    if start > 0 {
        result.insert(0, '…');
    }
    result
}

pub(super) fn search(db: &Connection, group: &str, query: &str) -> Result<Value> {
    let query = query.trim();
    ensure!(
        !query.is_empty() && query.chars().count() <= 128,
        "invalid search length"
    );
    let query = query.to_lowercase();
    // SQLite's built-in lower() and LIKE are ASCII-only. Apply Unicode lowercase
    // in Rust, streaming only this group's rows. The two tables have independent
    // row ids, so their merged order is not a server delivery order.
    let mut sql = db.prepare(
        "SELECT rowid AS local_id,id,1 AS own,json_extract(event,'$.text') AS body
         FROM authored WHERE group_id=?1 AND json_type(event,'$.text')='text'
         UNION ALL
         SELECT rowid AS local_id,id,0 AS own,json_extract(event,'$.text') AS body
         FROM incoming WHERE group_id=?1 AND json_type(event,'$.text')='text'
         ORDER BY local_id DESC",
    )?;
    let mut rows = sql.query([group])?;
    let mut results = Vec::new();
    let mut more = false;
    while let Some(row) = rows.next()? {
        let body: String = row.get(3)?;
        let Some(offset) = body.to_lowercase().find(&query) else {
            continue;
        };
        if results.len() == LIMIT {
            more = true;
            break;
        }
        // Older or incompatible clients may have sent nonstandard oversized
        // events. Bound bridge output even when searching those rows.
        let spoiler = body.contains("||");
        let text: String = body.chars().take(4000).collect();
        results.push(json!({
            "id":row.get::<_,String>(1)?, "own":row.get::<_,bool>(2)?,
            "snippet":if spoiler { None } else { Some(snippet(&body, offset)) },
            "text":text, "spoiler":spoiler, "truncated":text.len() < body.len()
        }));
    }
    Ok(json!({"messages":results,"more":more}))
}
