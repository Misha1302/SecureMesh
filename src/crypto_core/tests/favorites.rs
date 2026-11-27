use rusqlite::{params, Connection};
use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use uuid::Uuid;

#[test]
fn saved_messages_use_original_local_rows_and_atomic_idempotent_selection() {
    let dir = std::env::temp_dir().join(Uuid::new_v4().to_string());
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("fav.db");
    let pass = "test-favorites-passphrase";
    let open = || NativeClient::open(path.to_str().unwrap().into(), pass.into()).unwrap();
    let call = |c: &NativeClient, req: Value| -> Value {
        serde_json::from_str(&c.execute(req.to_string()).unwrap()).unwrap()
    };
    let c = open();
    call(&c, json!({"op":"init","identity":"me"}));
    drop(c);
    let db = Connection::open(&path).unwrap();
    db.pragma_update(None, "key", pass).unwrap();
    db.execute(
        "INSERT INTO incoming VALUES('A','same',?)",
        [
            json!({"text":"incoming","attachment":{"name":"notes","key":"private-key-marker"}})
                .to_string(),
        ],
    )
    .unwrap();
    db.execute(
        "INSERT INTO authored VALUES('A','same',?)",
        [json!({"text":"outgoing"}).to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO incoming VALUES('B','same',?)",
        params![json!({"text":"other conversation"}).to_string()],
    )
    .unwrap();
    drop(db);
    let c = open();
    let received = json!({"id":"same","own":false});
    let sent = json!({"id":"same","own":true});
    let change = |group: &str, items: Value, saved: bool| json!({"op":"favorites_set","group":group,"items":items,"saved":saved});
    let list = json!({"op":"favorites_list"});
    assert!(c
        .execute(change("A", json!([received,{"id":"missing","own":true}]), true).to_string())
        .is_err());
    assert_eq!(call(&c, list.clone())["messages"], json!([]));
    call(&c, change("A", json!([received, sent]), true));
    call(&c, change("A", json!([received]), true));
    drop(c);
    let c = open();
    let result = call(&c, list.clone());
    assert_eq!(result["messages"].as_array().unwrap().len(), 2);
    assert_eq!(result["messages"][0]["text"], "outgoing");
    assert_eq!(result["messages"][1]["attachmentName"], "notes");
    assert!(!result.to_string().contains("private-key-marker"));
    call(&c, change("B", json!([received]), false));
    call(&c, change("A", json!([received]), false));
    assert_eq!(call(&c, list)["messages"].as_array().unwrap().len(), 1);
    let pin = |own: bool, pinned: bool| json!({"op":"pin_message_local","group":"A","id":"same","own":own,"pinned":pinned});
    call(&c, pin(false, true));
    call(&c, pin(true, true));
    call(&c, pin(false, false));
    drop(c);
    let c = open();
    assert_eq!(
        call(&c, json!({"op":"timeline","group":"A"}))["pinned"]["text"],
        "outgoing"
    );
    call(&c, pin(true, false));
    assert!(call(&c, json!({"op":"timeline","group":"A"}))["pinned"].is_null());
    drop(c);
    std::fs::remove_dir_all(dir).unwrap();
}
