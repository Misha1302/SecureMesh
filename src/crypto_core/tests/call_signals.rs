use securemesh_crypto::api::NativeClient;
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
};
use uuid::Uuid;

const G: &str = "test-direct";
const PASS: &str = "test-call-store-passphrase";
fn uuid() -> String {
    Uuid::new_v4().to_string()
}
fn cmd(c: &NativeClient, value: Value) -> Value {
    serde_json::from_str(&c.execute(value.to_string()).unwrap()).unwrap()
}
fn open(dir: &Path, name: &str) -> NativeClient {
    NativeClient::open(dir.join(name).to_str().unwrap().into(), PASS.into()).unwrap()
}
fn pair() -> (PathBuf, NativeClient, NativeClient) {
    let dir = std::env::temp_dir().join(uuid());
    fs::create_dir(&dir).unwrap();
    let a = open(&dir, "a");
    let b = open(&dir, "b");
    let ak = cmd(&a, json!({"op":"init","identity":"a"}));
    let bk = cmd(&b, json!({"op":"init","identity":"b"}));
    for (c, peer, pk) in [(&a, "b", &bk), (&b, "a", &ak)] {
        cmd(
            c,
            json!({"op":"pin","identity":peer,"public_key":pk["public_key"],"confirmed":true}),
        );
    }
    cmd(&a, json!({"op":"create","group":G}));
    let kp = cmd(&b, json!({"op":"keypackage"}));
    let w = cmd(
        &a,
        json!({"op":"add","group":G,"keypackage":kp["keypackage"]}),
    );
    cmd(&b, json!({"op":"join","group":G,"welcome":w["welcome"]}));
    (dir, a, b)
}
fn signal(call: &str, peer: &str, body: Value) -> Value {
    json!({"op":"call_queue","group":G,"id":uuid(),"call":call,"peer":peer,"signal":body,"confirmed":true})
}
fn deliver(c: &NativeClient, msg: &Value, sender: &str, seq: i64) -> Value {
    let mut v = msg.clone();
    v["op"] = json!("ingest");
    v["sender"] = json!(sender);
    v["seq"] = json!(seq);
    v["cursor"] = json!(format!("cursor-{seq}"));
    cmd(c, v)
}
fn sdp() -> String {
    format!(
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fingerprint:sha-256 {}\r\n",
        vec!["AB"; 32].join(":")
    )
}
fn ice() -> Value {
    json!({"kind":"ice","candidate":"candidate:1 1 UDP 1 192.0.2.1 40000 typ host","mid":"0","line":0})
}
fn events(c: &NativeClient) -> Value {
    cmd(c, json!({"op":"call_events","group":G}))["events"].clone()
}
fn outbox(c: &NativeClient) -> Value {
    cmd(c, json!({"op":"outbox"}))["messages"].clone()
}

#[test]
fn two_pinned_devices_gate_and_exchange_typed_signals_without_chat_history() {
    let (dir, a, b) = pair();
    let call = uuid();
    let invite = signal(&call, "b", json!({"kind":"invite","media":"audio"}));
    let mut no = invite.clone();
    no["confirmed"] = false.into();
    assert!(a.execute(no.to_string()).is_err());
    let mut third = invite.clone();
    third["peer"] = "third".into();
    assert!(a.execute(third.to_string()).is_err());
    let mut leak = invite.clone();
    leak["signal"]["sdp"] = "private".into();
    assert!(a.execute(leak.to_string()).is_err());
    let m = cmd(&a, invite.clone());
    assert_eq!(m, cmd(&a, invite));
    assert!(m.get("signal").is_none());
    assert!(m.get("peer").is_none());
    assert_eq!(deliver(&b, &m, "a", 1)["event"]["accepted"], true);
    assert_eq!(deliver(&b, &m, "a", 1)["duplicate"], true);
    assert_eq!(events(&b).as_array().unwrap().len(), 1);
    let described = json!({"kind":"offer","sdp":sdp()});
    assert!(a
        .execute(signal(&call, "b", described.clone()).to_string())
        .is_err());
    assert!(a.execute(signal(&call, "b", ice()).to_string()).is_err());
    assert!(b.execute(signal(&call, "a", ice()).to_string()).is_err());
    assert!(a
        .execute(signal(&call, "b", json!({"kind":"accept"})).to_string())
        .is_err());
    let accept = cmd(&b, signal(&call, "a", json!({"kind":"accept"})));
    assert_eq!(deliver(&a, &accept, "b", 1)["event"]["accepted"], true);
    assert!(b
        .execute(signal(&call, "a", described.clone()).to_string())
        .is_err());
    let unexpected_video = signal(
        &call,
        "b",
        json!({"kind":"offer","sdp":sdp()+"m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"}),
    );
    assert!(a.execute(unexpected_video.to_string()).is_err());
    let insecure = signal(
        &call,
        "b",
        json!({"kind":"offer","sdp":sdp().replace("UDP/TLS/RTP/SAVPF","RTP/AVP")}),
    );
    assert!(a.execute(insecure.to_string()).is_err());
    let offer = cmd(&a, signal(&call, "b", described));
    let ice1 = cmd(&a, signal(&call, "b", ice()));
    // Concurrent delivery pumps expose at most the earliest unsaved signal.
    assert_eq!(outbox(&a).as_array().unwrap().len(), 1);
    assert_eq!(outbox(&a)[0]["id"], m["id"]);
    cmd(&a, json!({"op":"saved","group":G,"id":m["id"],"seq":1}));
    assert_eq!(outbox(&a)[0]["id"], offer["id"]);
    assert_eq!(deliver(&b, &offer, "a", 2)["event"]["accepted"], true);
    assert_eq!(deliver(&b, &ice1, "a", 3)["event"]["accepted"], true);
    let answer = cmd(&b, signal(&call, "a", json!({"kind":"answer","sdp":sdp()})));
    assert_eq!(deliver(&a, &answer, "b", 2)["event"]["accepted"], true);
    assert_eq!(events(&b)[2]["event"]["signal"], ice());
    for c in [&a, &b] {
        assert_eq!(
            cmd(c, json!({"op":"timeline","group":G}))["messages"],
            json!([])
        );
        assert_eq!(
            cmd(c, json!({"op":"history","group":G}))["events"],
            json!([])
        );
    }
    let end = cmd(&a, signal(&call, "b", json!({"kind":"end"})));
    assert_eq!(outbox(&a)[0]["id"], end["id"]);
    assert_eq!(deliver(&b, &end, "a", 4)["event"]["accepted"], true);
    assert_eq!(events(&b).as_array().unwrap().len(), 1);
    assert_eq!(events(&b)[0]["event"]["signal"]["kind"], "end");
    assert!(a.execute(signal(&call, "b", ice()).to_string()).is_err());
    let text = cmd(
        &a,
        json!({"op":"queue","group":G,"id":uuid(),"text":"ordinary chat still works"}),
    );
    assert_eq!(
        deliver(&b, &text, "a", 5)["event"]["text"],
        "ordinary chat still works"
    );
    drop((a, b));
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn expiry_unlock_and_membership_changes_remove_pending_control_state() {
    let (dir, a, b) = pair();
    let call = uuid();
    let invite = cmd(
        &a,
        signal(&call, "b", json!({"kind":"invite","media":"audio"})),
    );
    assert_eq!(deliver(&b, &invite, "a", 1)["event"]["accepted"], true);
    let sqlite = rusqlite::Connection::open(dir.join("a")).unwrap();
    sqlite.pragma_update(None, "key", PASS).unwrap();
    sqlite
        .execute("UPDATE call_signal_ids SET until=unixepoch()-1", [])
        .unwrap();
    assert_eq!(outbox(&a), json!([]));
    drop(sqlite);
    drop(b);
    let b = open(&dir, "b");
    assert_eq!(events(&b), json!([]));
    assert!(b
        .execute(signal(&call, "a", json!({"kind":"accept"})).to_string())
        .is_err());
    drop(a);
    let a = open(&dir, "a");
    let next = uuid();
    cmd(
        &a,
        signal(&next, "b", json!({"kind":"invite","media":"audio"})),
    );
    assert_eq!(outbox(&a).as_array().unwrap().len(), 1);
    cmd(&a, json!({"op":"remove","group":G,"identity":"b"}));
    assert_eq!(outbox(&a), json!([]));
    assert!(a
        .execute(signal(&uuid(), "b", json!({"kind":"invite","media":"audio"})).to_string())
        .is_err());
    drop((a, b));
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn offer_received_after_relock_is_consumed_without_reviving_consent() {
    let (dir, a, b) = pair();
    let call = uuid();
    let invitation = cmd(
        &a,
        signal(&call, "b", json!({"kind":"invite","media":"video"})),
    );
    deliver(&b, &invitation, "a", 1);
    let consent = cmd(&b, signal(&call, "a", json!({"kind":"accept"})));
    deliver(&a, &consent, "b", 1);
    drop(b);
    let b = open(&dir, "b");
    let offer = cmd(
        &a,
        signal(
            &call,
            "b",
            json!({"kind":"offer","sdp":sdp()+"m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"}),
        ),
    );
    let ignored = deliver(&b, &offer, "a", 2);
    assert_eq!(ignored["seq"], 2);
    assert_eq!(ignored["event"]["accepted"], false);
    assert_eq!(events(&b), json!([]));
    let chat = cmd(
        &a,
        json!({"op":"queue","group":G,"id":uuid(),"text":"next"}),
    );
    assert_eq!(deliver(&b, &chat, "a", 3)["event"]["text"], "next");
    drop((a, b));
    fs::remove_dir_all(dir).unwrap();
}
