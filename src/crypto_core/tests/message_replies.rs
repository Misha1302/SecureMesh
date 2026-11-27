use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use std::{fs, path::Path};
use uuid::Uuid;

fn open(root: &Path, name: &str) -> NativeClient {
    NativeClient::open(
        root.join(name).to_str().unwrap().into(),
        "reply-test-store-passphrase".into(),
    )
    .unwrap()
}

fn command(client: &NativeClient, request: Value) -> Value {
    serde_json::from_str(&client.execute(request.to_string()).unwrap()).unwrap()
}

#[test]
fn two_devices_exchange_reply_after_reopening_the_draft() {
    let root = std::env::temp_dir().join(Uuid::new_v4().to_string());
    fs::create_dir(&root).unwrap();
    let alice = open(&root, "alice");
    let bob = open(&root, "bob");
    let ak = command(&alice, json!({"op":"init","identity":"alice"}));
    let bk = command(&bob, json!({"op":"init","identity":"bob"}));
    command(
        &alice,
        json!({"op":"pin","identity":"bob","public_key":bk["public_key"],"confirmed":true}),
    );
    command(
        &bob,
        json!({"op":"pin","identity":"alice","public_key":ak["public_key"],"confirmed":true}),
    );
    command(&alice, json!({"op":"create","group":"AB"}));
    let package = command(&bob, json!({"op":"keypackage"}));
    let welcome = command(
        &alice,
        json!({"op":"add","group":"AB","keypackage":package["keypackage"]}),
    );
    command(
        &bob,
        json!({"op":"join","group":"AB","welcome":welcome["welcome"]}),
    );
    let id = Uuid::new_v4().to_string();
    let original = command(
        &alice,
        json!({"op":"queue","group":"AB","id":id,"text":"original"}),
    );
    let normal = command(
        &bob,
        json!({"op":"process","group":"AB","ciphertext":original["ciphertext"]}),
    );
    assert!(normal.get("replyTo").is_none());
    let target = json!({"id":id,"sender":"alice"});
    let draft = json!({"op":"draft_put","group":"AB","text":"my answer","replyTo":target});
    command(&bob, draft.clone());
    let mut wrong = draft.clone();
    wrong["group"] = json!("other");
    assert!(bob.execute(wrong.to_string()).is_err());
    wrong = draft.clone();
    wrong["replyTo"]["sender"] = json!("bob");
    assert!(bob.execute(wrong.to_string()).is_err());
    drop(bob);
    let bob = open(&root, "bob");
    assert_eq!(
        command(&bob, json!({"op":"draft_get","group":"AB"})),
        json!({"text":"my answer","replyTo":target})
    );
    let request = json!({"op":"queue","group":"AB","id":Uuid::new_v4().to_string(),"text":"my answer","submittedDraft":"my answer","replyTo":target});
    let reply = command(&bob, request.clone());
    assert!(reply.get("replyTo").is_none());
    assert_eq!(command(&bob, request), reply);
    assert_eq!(
        command(&bob, json!({"op":"draft_get","group":"AB"})),
        json!({"text":""})
    );
    let read = command(
        &alice,
        json!({"op":"process","group":"AB","ciphertext":reply["ciphertext"]}),
    );
    assert_eq!(read["replyTo"], target);
    assert_eq!(read["text"], "my answer");
    for client in [&alice, &bob] {
        let timeline = command(client, json!({"op":"timeline","group":"AB"}));
        let row = timeline["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == reply["id"])
            .unwrap();
        assert_eq!(row["replyTo"], target);
    }
    drop((alice, bob));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn opening_an_existing_two_column_draft_preserves_text() {
    let root = std::env::temp_dir().join(Uuid::new_v4().to_string());
    fs::create_dir(&root).unwrap();
    let client = open(&root, "legacy");
    command(&client, json!({"op":"init","identity":"legacy"}));
    drop(client);
    let conn = rusqlite::Connection::open(root.join("legacy")).unwrap();
    conn.pragma_update(None, "key", "reply-test-store-passphrase")
        .unwrap();
    conn.execute_batch(
        "DROP TABLE conversation_drafts;
        CREATE TABLE conversation_drafts(group_id TEXT PRIMARY KEY, body TEXT NOT NULL);
        INSERT INTO conversation_drafts VALUES('old-chat', 'before replies');",
    )
    .unwrap();
    drop(conn);
    let client = open(&root, "legacy");
    assert_eq!(
        command(&client, json!({"op":"draft_get","group":"old-chat"})),
        json!({"text":"before replies"})
    );
    drop(client);
    fs::remove_dir_all(root).unwrap();
}
