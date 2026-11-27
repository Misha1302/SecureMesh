use rusqlite::{params, Connection};
use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use uuid::Uuid;

fn call(client: &NativeClient, req: Value) -> Value {
    serde_json::from_str(&client.execute(req.to_string()).unwrap()).unwrap()
}

#[test]
fn encrypted_history_search_reaches_old_rows_and_scopes_unicode_and_literal_matches() {
    let dir = std::env::temp_dir().join(Uuid::new_v4().to_string());
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("search.db");
    let key = "search-history-test-key";
    let open = || NativeClient::open(path.to_str().unwrap().into(), key.into()).unwrap();
    let client = open();
    call(&client, json!({"op":"init","identity":"alice"}));
    drop(client);
    // A real legacy store can contain far more rows than the UI's timeline page.
    let mut db = Connection::open(&path).unwrap();
    db.pragma_update(None, "key", key).unwrap();
    let t = db.transaction().unwrap();
    let message = |group: &str, id: &str, text: &str, incoming: bool| {
        let stmt = if incoming {
            "INSERT INTO incoming(group_id,id,event) VALUES(?,?,?)"
        } else {
            "INSERT INTO authored(group_id,id,event) VALUES(?,?,?)"
        };
        t.execute(stmt, params![group, id, json!({"text":text}).to_string()])
            .unwrap();
    };
    let old = format!("{} — ЁЖ и 100%_ платёж", "д".repeat(300));
    message("A", "old", &old, false);
    message("A", "reply", "всё про ёжА", true);
    message("A", "spoiler", "||Ёж внутри||", true);
    message("B", "private", "ЁЖ в другом чате", true);
    for n in 0..1250 {
        message("A", &n.to_string(), "обычное сообщение", false);
    }
    t.commit().unwrap();
    drop(db);
    let client = open();
    let search =
        |g: &str, q: &str| call(&client, json!({"op":"search_history","group":g,"query":q}));
    let hits = search("A", "  ёЖ  ");
    let rows = hits["messages"].as_array().unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!(hits["more"], false);
    let ancient = rows.iter().find(|r| r["id"] == "old").unwrap();
    assert_eq!(ancient["own"], true);
    assert!(ancient["snippet"].as_str().unwrap().contains("ЁЖ"));
    let hidden = rows.iter().find(|r| r["id"] == "spoiler").unwrap();
    assert_eq!(hidden["spoiler"], true);
    assert!(hidden["snippet"].is_null());
    assert_eq!(search("B", "ЁЖ")["messages"].as_array().unwrap().len(), 1);
    assert_eq!(search("A", "%_")["messages"][0]["id"], "old");
    let frequent = search("A", "ОБЫЧНОЕ");
    assert_eq!(frequent["messages"].as_array().unwrap().len(), 50);
    assert_eq!(frequent["more"], true);
    assert!(client
        .execute(json!({"op":"search_history","group":"A","query":" ".repeat(3)}).to_string())
        .is_err());
    assert!(client
        .execute(json!({"op":"search_history","group":"A","query":"ё".repeat(129)}).to_string())
        .is_err());
    drop(client);
    std::fs::remove_dir_all(dir).unwrap();
}
