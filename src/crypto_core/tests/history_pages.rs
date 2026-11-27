use rusqlite::{params, Connection};
use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use std::collections::HashSet;
use uuid::Uuid;

fn query(client: &NativeClient, request: Value) -> Value {
    serde_json::from_str(&client.execute(request.to_string()).unwrap()).unwrap()
}

#[test]
fn pages_survive_new_inserts_and_reopen_and_cover_old_rows_once() {
    let dir = std::env::temp_dir().join(Uuid::new_v4().to_string());
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("history.db");
    let pass = "history-paging-test-passphrase";
    let open = || NativeClient::open(path.to_str().unwrap().into(), pass.into()).unwrap();
    let client = open();
    query(&client, json!({"op":"init","identity":"test"}));
    drop(client);
    let insert = |group: &str, start: i32, end: i32| {
        let mut db = Connection::open(&path).unwrap();
        db.pragma_update(None, "key", pass).unwrap();
        let tx = db.transaction().unwrap();
        for i in start..end {
            let id = format!("{group}-{i}");
            let mut event = json!({"id":id,"sender":if i%2==0 {"self"} else {"peer"}, "text":id});
            if i >= 35 {
                event["localTimeMs"] = json!(58 + i / 9);
            }
            let own = i % 2 == 0;
            if own {
                tx.execute(
                    "INSERT INTO outgoing VALUES(?,?,?,'saved',?)",
                    params![group, id, "{}", i + 1],
                )
                .unwrap();
                tx.execute(
                    "INSERT INTO authored VALUES(?,?,?)",
                    params![group, id, event.to_string()],
                )
                .unwrap();
            } else {
                tx.execute(
                    "INSERT INTO incoming VALUES(?,?,?)",
                    params![group, id, event.to_string()],
                )
                .unwrap();
                tx.execute(
                    "INSERT INTO received VALUES(?,?,?)",
                    params![group, i + 1, json!({"id":id}).to_string()],
                )
                .unwrap();
            }
        }
        tx.commit().unwrap();
    };
    insert("a", 0, 175);
    insert("b", 0, 11);
    let client = open();
    let head = query(&client, json!({"op":"timeline","group":"a","limit":12}));
    let mut ids: HashSet<String> = head["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["id"].as_str().unwrap().into())
        .collect();
    assert_eq!(ids.len(), 24);
    let mut cursor = head["older"].clone();
    assert!(client
        .execute(json!({"op":"history_page","group":"b","cursor":cursor}).to_string())
        .is_err());
    drop(client);
    insert("a", 175, 197);
    let client = open();
    let mut pages = 0;
    let mut previous = i64::MAX;
    while !cursor.is_null() {
        let result = query(
            &client,
            json!({"op":"history_page","group":"a","cursor":cursor}),
        );
        let rows = result["messages"].as_array().unwrap();
        assert!(!rows.is_empty() && rows.len() <= 48);
        for entry in rows {
            let id = entry["id"].as_str().unwrap();
            let n = id.strip_prefix("a-").unwrap().parse::<i32>().unwrap();
            assert!(n < 175 && ids.insert(id.into()));
            let time = entry["localTimeMs"].as_i64().unwrap_or(0);
            assert!(time <= previous);
            assert_eq!(time == 0, n < 35);
            previous = time;
        }
        pages += 1;
        cursor = result["next"].clone();
    }
    assert_eq!(ids.len(), 175);
    assert_eq!(pages, 4);
    assert!(query(&client, json!({"op":"timeline","group":"b","limit":12}))["older"].is_null());
    drop(client);
    std::fs::remove_dir_all(dir).unwrap();
}
