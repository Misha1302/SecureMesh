use base64::{engine::general_purpose::STANDARD, Engine};
use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
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

#[test]
fn replacing_session_tokens_preserves_queued_ciphertext_across_reopen() {
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
    let identity = call(&client, json!({"op":"init","identity":"alice"}));
    call(&client, json!({"op":"create","group":"A"}));
    let mut profile =
        json!({"deviceId":"alice","accessToken":"previous","refreshToken":"previous"});
    call(&client, json!({"op":"profile_put","profile":profile}));
    let queue =
        json!({"op":"queue","group":"A","id":Uuid::new_v4().to_string(),"text":"keep queued"});
    let envelope = call(&client, queue.clone());
    drop(client);

    let client = open();
    assert_eq!(call(&client, json!({"op":"identity"})), identity);
    profile["accessToken"] = json!("replacement-access");
    profile["refreshToken"] = json!("replacement-refresh");
    call(&client, json!({"op":"profile_put","profile":profile}));
    drop(client);

    let client = open();
    assert_eq!(call(&client, json!({"op":"profile"})), profile);
    assert_eq!(call(&client, json!({"op":"identity"})), identity);
    assert_eq!(
        call(&client, json!({"op":"outbox", "dispatch":true}))["messages"],
        json!([envelope])
    );
    assert_eq!(call(&client, queue), envelope);

    let mut echo = envelope.clone();
    echo["op"] = json!("ingest");
    echo["sender"] = json!("alice");
    echo["seq"] = json!(1);
    // The sync service returns only the digest for a device's own envelope.
    echo["ciphertext"] = json!("");
    echo["digest"] = json!(STANDARD.encode([0; 32]));
    assert!(client.execute(echo.to_string()).is_err());
    assert_eq!(
        call(&client, json!({"op":"outbox_pending"}))["pending"],
        true
    );
    let ciphertext = STANDARD
        .decode(envelope["ciphertext"].as_str().unwrap())
        .unwrap();
    echo["digest"] = json!(STANDARD.encode(Sha256::digest(ciphertext)));
    assert_eq!(call(&client, echo.clone())["event"]["own"], true);
    assert_eq!(call(&client, echo)["duplicate"], true);
    assert_eq!(
        call(&client, json!({"op":"outbox_pending"}))["pending"],
        false
    );
    drop(client);
    fs::remove_dir_all(dir).unwrap();
}
