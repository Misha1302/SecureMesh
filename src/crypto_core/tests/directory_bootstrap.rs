use securemesh_crypto::{api::NativeClient, validate_keypackage};
use serde_json::{json, Value};
use std::fs;
use uuid::Uuid;

fn call(client: &NativeClient, req: &Value) -> Value {
    serde_json::from_str(&client.execute(req.to_string()).unwrap()).unwrap()
}

#[test]
fn directory_checks_package_and_persists_the_accepted_context() {
    let dir = std::env::temp_dir().join(Uuid::new_v4().to_string());
    fs::create_dir(&dir).unwrap();
    let open = |name| {
        NativeClient::open(
            dir.join(name).to_str().unwrap().into(),
            "test-only-passphrase".into(),
        )
        .unwrap()
    };
    let sender = open("sender");
    let recipient = open("recipient");
    let init = |c| {
        call(
            c,
            &json!({"op":"init","identity":Uuid::new_v4().to_string()}),
        )
    };
    let a = init(&sender);
    let b = init(&recipient);
    for (client, peer) in [(&sender, &b), (&recipient, &a)] {
        call(
            client,
            &json!({"op":"pin","identity":peer["identity"],"public_key":peer["public_key"],"confirmed":true}),
        );
    }
    let package = || {
        let kp = call(&recipient, &json!({"op":"keypackage"}))["keypackage"].clone();
        let validation =
            json!({"keypackage":kp,"identity":b["identity"],"public_key":b["public_key"]});
        let validated: Value =
            serde_json::from_str(&validate_keypackage(&validation.to_string()).unwrap()).unwrap();
        (kp, validated["reference"].clone())
    };
    let (kp, reference) = package();
    let (other_kp, other_reference) = package();
    let prepared = call(
        &sender,
        &json!({"op":"directory_prepare","invitation":Uuid::new_v4().to_string(),"lease":Uuid::new_v4().to_string(),"recipient":b["identity"],"keypackage":kp,"reference":reference}),
    );
    let mut binding = prepared["binding"].clone();
    binding["reference"] = other_reference.clone();
    assert!(sender.execute(binding.to_string()).is_err());

    let mut join = prepared["binding"].clone();
    join["op"] = json!("directory_join");
    join["signature"] = prepared["signature"].clone();
    assert!(recipient.execute(join.to_string()).is_err());
    let approval = json!({"op":"directory_consent","confirmed":true,"invitation":join["invitation"],"sender":a["identity"],"senderKey":a["public_key"],"username":"alice"});
    let mut wrong = approval.clone();
    wrong["senderKey"] = b["public_key"].clone();
    assert!(recipient.execute(wrong.to_string()).is_err());
    let mut denied = approval.clone();
    denied["confirmed"] = json!(false);
    assert!(recipient.execute(denied.to_string()).is_err());
    assert_eq!(call(&recipient, &approval)["accepted"], true);
    call(
        &recipient,
        &json!({"op":"directory_withdraw_consent","invitation":join["invitation"]}),
    );
    assert!(recipient.execute(join.to_string()).is_err());
    call(&recipient, &approval);
    let publish = json!({"op":"directory_consent_package","invitation":join["invitation"]});
    let package = call(&recipient, &publish);
    drop(recipient);
    let recipient = open("recipient");
    assert_eq!(call(&recipient, &publish), package);
    assert_eq!(call(&recipient, &join)["epoch"], 1);
    drop(recipient);
    let recipient = open("recipient");
    assert_eq!(call(&recipient, &join)["already_joined"], true);
    let mut changed = prepared["binding"].clone();
    changed["invitation"] = json!(Uuid::new_v4().to_string());
    changed["signature"] = call(&sender, &changed)["signature"].clone();
    changed["op"] = json!("directory_join");
    assert!(recipient.execute(changed.to_string()).is_err());
    assert_eq!(call(&recipient, &join)["already_joined"], true);
    // A group joined through an older path has no record of the signed context.
    let older = call(
        &sender,
        &json!({"op":"directory_prepare","invitation":Uuid::new_v4().to_string(),"lease":Uuid::new_v4().to_string(),"recipient":b["identity"],"keypackage":other_kp,"reference":other_reference}),
    );
    let mut second = older["binding"].clone();
    second["invitation"] = join["invitation"].clone();
    second["signature"] = call(&sender, &second)["signature"].clone();
    second["op"] = json!("directory_join");
    assert!(recipient.execute(second.to_string()).is_err());
    call(
        &recipient,
        &json!({"op":"join","group":older["id"],"welcome":older["welcome"]}),
    );
    let mut legacy = approval.clone();
    legacy["invitation"] = older["binding"]["invitation"].clone();
    call(&recipient, &legacy);
    let mut unrecorded = older["binding"].clone();
    unrecorded["op"] = json!("directory_join");
    unrecorded["signature"] = older["signature"].clone();
    assert!(recipient.execute(unrecorded.to_string()).is_err());
    drop((sender, recipient));
    fs::remove_dir_all(dir).unwrap();
}
