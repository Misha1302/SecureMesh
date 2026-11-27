use rusqlite::{params, Connection};
use securemesh_crypto::api::NativeClient;
use securemesh_crypto::execute_json;
use serde_json::{json, Value};
use uuid::Uuid;

#[test]
fn closed_snapshot_projects_history_without_touching_identity_or_queue() {
    let root = std::env::temp_dir().join(Uuid::new_v4().to_string());
    std::fs::create_dir(&root).unwrap();
    let path = root.join("closed.db");
    let path = path.to_str().unwrap();
    let pass = "fixture-only-archive-password";
    let client = NativeClient::open(path.into(), pass.into()).unwrap();
    client
        .execute(json!({"op":"init","identity":"fixture-reader"}).to_string())
        .unwrap();
    client.execute(json!({"op":"profile_put","profile":{"username":"reader","peerName":"old-contact","group":"g","accessToken":"fixture-access-secret"}}).to_string()).unwrap();
    drop(client);
    let db = Connection::open(path).unwrap();
    db.pragma_update(None, "key", pass).unwrap();
    db.execute(
        "INSERT INTO incoming(group_id,id,event) VALUES('g','in',?)",
        params![json!({"text":"Привет","localTimeMs":500}).to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO authored(group_id,id,event) VALUES('g','out',?)",
        params![json!({"text":"Offline draft","localTimeMs":501}).to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO outgoing VALUES('g','out','queued-test-envelope','queued',NULL)",
        [],
    )
    .unwrap();
    drop(db);
    let before = std::fs::read(path).unwrap();
    let read = |args: Value| -> Value {
        serde_json::from_str(&execute_json(path, &args.to_string()).unwrap()).unwrap()
    };
    let index = read(json!({"op":"archive_read","passphrase":pass}));
    assert_eq!(index["username"], "reader");
    assert_eq!(index["chats"][0]["name"], "old-contact");
    assert!(!index.to_string().contains("fixture-access-secret"));
    let messages = read(
        json!({"op":"archive_read","passphrase":pass,"group":"g","cursor":index["chats"][0]["cursor"]}),
    );
    assert_eq!(messages["messages"][0]["text"], "Offline draft");
    assert_eq!(messages["messages"][1]["text"], "Привет");
    assert!(!messages.to_string().contains("queued-test-envelope"));
    assert!(execute_json(
        path,
        &json!({"op":"archive_read","passphrase":"wrong-archive-password"}).to_string()
    )
    .is_err());
    assert_eq!(std::fs::read(path).unwrap(), before);
    std::fs::remove_dir_all(root).unwrap();
}
