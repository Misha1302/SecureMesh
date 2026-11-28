use openmls::prelude::SenderRatchetConfiguration;
use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::{mpsc, Arc},
    time::Duration,
};
use uuid::Uuid;

fn call(client: &NativeClient, value: Value) -> Value {
    serde_json::from_str(&client.execute(value.to_string()).unwrap()).unwrap()
}

fn profile() -> (PathBuf, String, Arc<NativeClient>) {
    let dir = std::env::temp_dir().join(format!("securemesh-dispatch-{}", Uuid::new_v4()));
    fs::create_dir(&dir).unwrap();
    let path = dir.join("profile.db");
    let client = Arc::new(
        NativeClient::open(
            path.to_string_lossy().into_owned(),
            "dispatch snapshot test passphrase".into(),
        )
        .unwrap(),
    );
    call(&client, json!({"op":"init","identity":"alice"}));
    call(&client, json!({"op":"create","group":"group-a"}));
    (dir, path.to_string_lossy().into_owned(), client)
}

fn queue(client: &NativeClient, text: &str) -> Value {
    call(
        client,
        json!({"op":"queue","group":"group-a","id":Uuid::new_v4().to_string(),"text":text}),
    )
}

fn two_member_profile() -> (PathBuf, String, Arc<NativeClient>, NativeClient, String) {
    let dir = std::env::temp_dir().join(format!("securemesh-dispatch-pair-{}", Uuid::new_v4()));
    fs::create_dir(&dir).unwrap();
    let path = dir.join("sender.db");
    let a = Arc::new(
        NativeClient::open(
            path.to_string_lossy().into_owned(),
            "dispatch snapshot test passphrase".into(),
        )
        .unwrap(),
    );
    let b = NativeClient::open(
        dir.join("receiver.db").to_string_lossy().into_owned(),
        "dispatch snapshot test passphrase".into(),
    )
    .unwrap();
    let aid = call(
        &a,
        json!({"op":"init","identity":Uuid::new_v4().to_string()}),
    );
    let bid = call(
        &b,
        json!({"op":"init","identity":Uuid::new_v4().to_string()}),
    );
    call(
        &a,
        json!({"op":"pin","identity":bid["identity"],"public_key":bid["public_key"],"confirmed":true}),
    );
    call(
        &b,
        json!({"op":"pin","identity":aid["identity"],"public_key":aid["public_key"],"confirmed":true}),
    );
    let group = "direct-group".to_owned();
    call(&a, json!({"op":"create","group":group}));
    let package = call(&b, json!({"op":"keypackage"}));
    let welcome = call(
        &a,
        json!({"op":"add","group":group,"keypackage":package["keypackage"]}),
    );
    call(
        &b,
        json!({"op":"join","group":group,"welcome":welcome["welcome"]}),
    );
    (dir, path.to_string_lossy().into_owned(), a, b, group)
}

#[test]
fn snapshot_is_current_and_handoff_callback_is_fail_closed_and_retryable() {
    let (dir, _path, client) = profile();
    let queued = queue(&client, "private queued text");
    let id = queued["id"].as_str().unwrap().to_owned();
    let mut accepted: Option<String> = None;
    client
        .with_queued_dispatch_snapshot("group-a", &id, |db, snapshot| -> anyhow::Result<()> {
            assert!(!db.is_autocommit());
            assert_eq!(snapshot.group_id, "group-a");
            assert_eq!(snapshot.message_id, id);
            assert_eq!(snapshot.envelope, queued.to_string());
            assert_eq!(snapshot.current_epoch, 0);
            assert_eq!(snapshot.envelope_epoch, 0);
            assert_eq!(snapshot.members.len(), 1);
            assert_eq!(snapshot.members[0].device_id, "alice");
            assert_eq!(snapshot.members[0].signing_key.len(), 32);
            accepted = Some(snapshot.envelope.clone());
            Ok(())
        })
        .unwrap();
    let expected = queued.to_string();
    assert_eq!(accepted.as_deref(), Some(expected.as_str()));

    // Callback failure rolls back its staged state and keeps ciphertext retryable.
    assert!(client
        .with_queued_dispatch_snapshot("group-a", &id, |db, _snapshot| -> anyhow::Result<()> {
            db.execute(
                "INSERT INTO app_meta(key,value) VALUES('test-partial-enqueue','must roll back')",
                [],
            )?;
            anyhow::bail!("local gate rejected")
        })
        .is_err());
    client
        .with_queued_dispatch_snapshot("group-a", &id, |_db, snapshot| -> anyhow::Result<()> {
            assert_eq!(snapshot.message_id, id);
            Ok(())
        })
        .unwrap();
    client
        .with_queued_dispatch_snapshot("group-a", &id, |db, _snapshot| -> anyhow::Result<()> {
            let staged: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM app_meta WHERE key='test-partial-enqueue')",
                [],
                |row| row.get(0),
            )?;
            assert!(!staged);
            Ok(())
        })
        .unwrap();
    // A stale queued epoch is rejected before the callback can enqueue it.
    let mut stale = queued.clone();
    stale["epoch"] = json!(1);
    client
        .with_queued_dispatch_snapshot("group-a", &id, |db, _snapshot| -> anyhow::Result<()> {
            db.execute(
                "UPDATE outgoing SET envelope=? WHERE group_id=? AND id=?",
                rusqlite::params![stale.to_string(), "group-a", id],
            )?;
            Ok(())
        })
        .unwrap();
    let mut called = false;
    assert!(client
        .with_queued_dispatch_snapshot("group-a", &id, |_db, _snapshot| -> anyhow::Result<()> {
            called = true;
            Ok(())
        })
        .is_err());
    assert!(!called);
    assert!(client
        .with_queued_dispatch_snapshot(
            "group-a",
            &Uuid::new_v4().to_string(),
            |_db, _snapshot| -> anyhow::Result<()> { Ok(()) }
        )
        .is_err());
    drop(client);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn local_writers_serialize_only_for_the_bounded_enqueue_callback() {
    let (dir, path, client) = profile();
    let message = queue(&client, "one");
    let id = message["id"].as_str().unwrap().to_owned();
    let other =
        Arc::new(NativeClient::open(path, "dispatch snapshot test passphrase".into()).unwrap());
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let callback_client = client.clone();
    let callback_id = id.clone();
    let handoff = std::thread::spawn(move || {
        callback_client.with_queued_dispatch_snapshot(
            &"group-a",
            &callback_id,
            |_db, snapshot| -> anyhow::Result<()> {
                entered_tx.send(snapshot.message_id.clone()).unwrap();
                release_rx.recv().unwrap();
                Ok(())
            },
        )
    });
    assert_eq!(entered_rx.recv_timeout(Duration::from_secs(3)).unwrap(), id);

    let (write_done_tx, write_done_rx) = mpsc::channel();
    let writer = std::thread::spawn(move || {
        let result = queue(&other, "writer waits behind enqueue");
        write_done_tx.send(result).unwrap();
    });
    assert!(write_done_rx
        .recv_timeout(Duration::from_millis(100))
        .is_err());
    release_tx.send(()).unwrap();
    handoff.join().unwrap().unwrap();
    assert!(write_done_rx.recv_timeout(Duration::from_secs(3)).is_ok());
    writer.join().unwrap();
    drop(client);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn membership_advance_cannot_be_hidden_by_rewriting_outer_epoch() {
    let (dir, path, sender, receiver, group) = two_member_profile();
    let queued = call(
        &sender,
        json!({"op":"queue","group":group,"id":Uuid::new_v4().to_string(),"text":"queued before removal"}),
    );
    let id = queued["id"].as_str().unwrap().to_owned();
    sender
        .with_queued_dispatch_snapshot(&group, &id, |_db, snapshot| -> anyhow::Result<()> {
            assert_eq!(snapshot.current_epoch, 1);
            assert_eq!(snapshot.members.len(), 2);
            Ok(())
        })
        .unwrap();
    let receiver_id = call(&receiver, json!({"op":"identity"}))["identity"]
        .as_str()
        .unwrap()
        .to_owned();
    call(
        &sender,
        json!({"op":"remove","group":group,"identity":receiver_id}),
    );

    // Corrupt only the untrusted wrapper epoch to the new epoch. The encoded
    // MLS ciphertext remains at epoch 1 and must still be rejected.
    let mut rewritten = queued;
    rewritten["epoch"] = json!(2);
    let db = rusqlite::Connection::open(&path).unwrap();
    db.pragma_update(None, "key", "dispatch snapshot test passphrase")
        .unwrap();
    db.execute(
        "UPDATE outgoing SET envelope=? WHERE group_id=? AND id=?",
        rusqlite::params![rewritten.to_string(), group, id],
    )
    .unwrap();
    drop(db);
    let mut callback_ran = false;
    assert!(sender
        .with_queued_dispatch_snapshot(&group, &id, |_db, _snapshot| -> anyhow::Result<()> {
            callback_ran = true;
            Ok(())
        })
        .is_err());
    assert!(!callback_ran);
    let mut wrong_group_callback = false;
    assert!(sender
        .with_queued_dispatch_snapshot("wrong-group", &id, |_db, _snapshot| -> anyhow::Result<()> {
            wrong_group_callback = true;
            Ok(())
        })
        .is_err());
    assert!(!wrong_group_callback);
    drop((sender, receiver));
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn pending_commit_and_saved_rows_never_reach_enqueue_callback() {
    let (dir, _path, client) = profile();
    let queued = queue(&client, "pending commit barrier");
    let id = queued["id"].as_str().unwrap();
    call(
        &client,
        json!({"op":"saved","group":"group-a","id":id,"seq":1}),
    );
    let mut callback_ran = false;
    assert!(client
        .with_queued_dispatch_snapshot("group-a", id, |_db, _snapshot| -> anyhow::Result<()> {
            callback_ran = true;
            Ok(())
        })
        .is_err());
    assert!(!callback_ran);
    let pending_message = queue(&client, "queued before local commit");
    let pending_id = pending_message["id"].as_str().unwrap();
    let rekey_id = Uuid::new_v4().to_string();
    call(
        &client,
        json!({"op":"stage_rekey","group":"group-a","id":rekey_id}),
    );
    assert!(client
        .with_queued_dispatch_snapshot(
            "group-a",
            pending_id,
            |_db, _snapshot| -> anyhow::Result<()> {
                callback_ran = true;
                Ok(())
            }
        )
        .is_err());
    assert!(!callback_ran);
    drop(client);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn sender_ratchet_window_matches_outbox_dispatch_eligibility() {
    let (dir, _path, client) = profile();
    let tolerance =
        usize::try_from(SenderRatchetConfiguration::default().out_of_order_tolerance()).unwrap();
    let mut last_id = String::new();
    for index in 0..=tolerance {
        let message = queue(&client, &format!("window message {index}"));
        last_id = message["id"].as_str().unwrap().to_owned();
    }
    let mut callback_ran = false;
    assert!(client
        .with_queued_dispatch_snapshot(
            "group-a",
            &last_id,
            |_db, _snapshot| -> anyhow::Result<()> {
                callback_ran = true;
                Ok(())
            }
        )
        .is_err());
    assert!(!callback_ran);
    drop(client);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn call_control_ciphertext_is_not_eligible_for_private_message_handoff() {
    let (dir, _path, sender, receiver, group) = two_member_profile();
    let receiver_id = call(&receiver, json!({"op":"identity"}))["identity"]
        .as_str()
        .unwrap()
        .to_owned();
    let signal = call(
        &sender,
        json!({
            "op":"call_queue","group":group,"id":Uuid::new_v4().to_string(),
            "call":Uuid::new_v4().to_string(),"peer":receiver_id,
            "signal":{"kind":"invite","media":"audio"},"confirmed":true
        }),
    );
    let mut callback_ran = false;
    assert!(sender
        .with_queued_dispatch_snapshot(
            &group,
            signal["id"].as_str().unwrap(),
            |_db, _snapshot| -> anyhow::Result<()> {
                callback_ran = true;
                Ok(())
            }
        )
        .is_err());
    assert!(!callback_ran);
    drop((sender, receiver));
    fs::remove_dir_all(dir).unwrap();
}
