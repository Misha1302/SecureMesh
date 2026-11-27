use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use std::fs;
use uuid::Uuid;

#[test]
fn reopened_profiles_list_and_open_an_authenticated_attachment() {
    let root = std::env::temp_dir().join(Uuid::new_v4().to_string());
    fs::create_dir(&root).unwrap();
    let open = |name| {
        NativeClient::open(
            root.join(name).to_str().unwrap().into(),
            "test-media-directory-passphrase".into(),
        )
        .unwrap()
    };
    let run = |client: &NativeClient, command: Value| -> Value {
        serde_json::from_str(&client.execute(command.to_string()).unwrap()).unwrap()
    };
    let group = Uuid::new_v4().to_string();
    let id = Uuid::new_v4().to_string();
    let a = open("alice");
    let b = open("bob");
    let ak = run(&a, json!({"op":"init","identity":"alice"}));
    let bk = run(&b, json!({"op":"init","identity":"bob"}));
    run(
        &a,
        json!({"op":"pin","identity":"bob","public_key":bk["public_key"],"confirmed":true}),
    );
    run(
        &b,
        json!({"op":"pin","identity":"alice","public_key":ak["public_key"],"confirmed":true}),
    );
    run(&a, json!({"op":"create","group":group}));
    let pkg = run(&b, json!({"op":"keypackage"}));
    let welcome = run(
        &a,
        json!({"op":"add","group":group,"keypackage":pkg["keypackage"]}),
    );
    run(
        &b,
        json!({"op":"join","group":group,"welcome":welcome["welcome"]}),
    );
    let staged = run(
        &a,
        json!({"op":"attachment_prepare","group":group,"id":id,"name":"memo.mp3","media":"file","data":"QUJD"}),
    );
    let sealed = run(
        &a,
        json!({"op":"attachment_ciphertext","group":group,"id":id}),
    );
    let envelope = run(&a, json!({"op":"attachment_queue","group":group,"id":id}));
    run(
        &b,
        json!({"op":"process","group":group,"ciphertext":envelope["ciphertext"]}),
    );
    drop(a);
    drop(b);
    for name in ["alice", "bob"] {
        let client = open(name);
        let listing = run(
            &client,
            json!({"op":"conversation_media","group":group,"category":"audio"}),
        );
        assert_eq!(
            listing["items"],
            json!([{"id":id,"attachment":{"blobId":staged["blobId"],"name":"memo.mp3","media":"file","size":3}}])
        );
        let opened = run(
            &client,
            json!({"op":"attachment_open","group":group,"id":listing["items"][0]["id"],"ciphertext":sealed["ciphertext"]}),
        );
        assert_eq!(opened["data"], "QUJD");
    }
    fs::remove_dir_all(root).unwrap();
}
