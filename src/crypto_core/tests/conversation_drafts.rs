use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use std::fs;
use uuid::Uuid;

fn call(client: &NativeClient, request: Value) -> Value {
    serde_json::from_str(&client.execute(request.to_string()).unwrap()).unwrap()
}

#[test]
fn drafts_survive_reopen_and_are_consumed_by_the_queue_transaction() {
    let dir = std::env::temp_dir().join(Uuid::new_v4().to_string());
    fs::create_dir(&dir).unwrap();
    let path = dir.join("store");
    let open = || {
        NativeClient::open(
            path.to_str().unwrap().to_string(),
            "long-enough-test-passphrase".to_string(),
        )
        .unwrap()
    };
    let client = open();
    call(&client, json!({"op":"init","identity":"alice"}));
    call(&client, json!({"op":"create","group":"A"}));
    for (group, text) in [("A", " local private draft "), ("B", "independent draft")] {
        call(&client, json!({"op":"draft_put","group":group,"text":text}));
    }
    drop(client);
    let raw = fs::read(&path).unwrap();
    assert!(!raw.windows(13).any(|s| s == b"private draft"));
    let client = open();
    let get = |group| call(&client, json!({"op":"draft_get","group":group}))["text"].clone();
    assert_eq!(get("A"), " local private draft ");
    assert_eq!(get("C"), "");
    let mut queue = json!({"op":"queue","group":"A","id":"bad","text":"local private draft","submittedDraft":" local private draft "});
    assert!(client.execute(queue.to_string()).is_err());
    assert_eq!(get("A"), " local private draft ");
    queue["id"] = json!(Uuid::new_v4().to_string());
    let envelope = call(&client, queue.clone());
    assert_eq!(get("A"), "");
    assert_eq!(get("B"), "independent draft");
    call(
        &client,
        json!({"op":"draft_put","group":"A","text":" local private draft "}),
    );
    assert_eq!(call(&client, queue), envelope);
    assert_eq!(get("A"), " local private draft ");
    drop(client);
    fs::remove_dir_all(dir).unwrap();
}
