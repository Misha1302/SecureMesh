//! One-to-one, opt-in control messages inside an authenticated MLS application message.
//! The active negotiation and its plaintext descriptions live only in this unlocked connection.
use super::*;
use serde::Deserialize;

const TYPE: &str = "securemesh.call.v1";
const TTL: i64 = 60;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Media {
    Audio,
    Video,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
enum Signal {
    Invite {
        media: Media,
    },
    Accept {},
    Offer {
        sdp: String,
    },
    Answer {
        sdp: String,
    },
    Ice {
        candidate: String,
        mid: String,
        line: u16,
    },
    End {},
}

impl Signal {
    fn valid(&self) -> bool {
        match self {
            Self::Offer { sdp } | Self::Answer { sdp } => {
                // Native WebRTC must parse SDP, verify its fingerprint and enforce its transport policy.
                sdp.len() <= 16384 && sdp.starts_with("v=0\r\n") && !sdp.contains('\0')
            }
            Self::Ice {
                candidate,
                mid,
                line,
            } => {
                candidate.starts_with("candidate:")
                    && candidate.len() <= 1536
                    && !candidate.chars().any(char::is_control)
                    && !mid.is_empty()
                    && mid.len() <= 32
                    && !mid.chars().any(char::is_control)
                    && *line < 16
            }
            _ => true,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Wire {
    call: String,
    to: String,
    at: i64,
    signal: Signal,
}

pub(super) fn reset(db: &Connection, gid: &str) -> Result<()> {
    db.execute("DELETE FROM call_events WHERE g=?", [gid])?;
    db.execute("DELETE FROM call_sessions WHERE g=?", [gid])?;
    Ok(())
}

pub(super) fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("PRAGMA temp_store=MEMORY;
        CREATE TEMP TABLE call_sessions(g TEXT PRIMARY KEY, call TEXT, peer TEXT, caller TEXT, epoch INTEGER, phase TEXT, until INTEGER, n INTEGER, video INTEGER);
        CREATE TEMP TABLE call_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,g TEXT, call TEXT, event TEXT, until INTEGER);
        CREATE TABLE IF NOT EXISTS call_signal_ids(g TEXT,id TEXT,call TEXT,outbound INTEGER,digest BLOB,until INTEGER,PRIMARY KEY(g,id));
        CREATE INDEX IF NOT EXISTS call_signal_session ON call_signal_ids(g,call,outbound,until);
        CREATE INDEX IF NOT EXISTS call_signal_expiry ON call_signal_ids(outbound,until);")?;
    Ok(())
}

fn canonical_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}

fn direct(db: &Connection, group: &MlsGroup, local: &str, remote: &str) -> Result<bool> {
    if remote == local || !group.is_active() {
        return Ok(false);
    }
    let mut members = group.members();
    let mut ids = vec![];
    for m in &mut members {
        let cred = BasicCredential::try_from(m.credential.clone())?;
        let id = std::str::from_utf8(cred.identity())?;
        if ids.len() == 2 || pinned_key(db, id)?.as_deref() != Some(&m.signature_key) {
            return Ok(false);
        }
        ids.push(id.to_string());
    }
    Ok(ids.len() == 2 && ids.iter().any(|i| i == local) && ids.iter().any(|i| i == remote))
}

// Narrow preflight for this application's consented A/V tracks. The media engine
// remains responsible for complete SDP parsing and DTLS peer verification.
fn allowed_media(sdp: &str, video: bool) -> bool {
    let mut audio = false;
    let mut fingerprint = false;
    for line in sdp.split("\r\n") {
        if line.chars().any(char::is_control) || line.starts_with("a=crypto:") {
            return false;
        }
        if let Some(value) = line.strip_prefix("a=fingerprint:sha-256 ") {
            let bytes: Vec<_> = value.split(':').collect();
            fingerprint |= bytes.len() == 32
                && bytes
                    .iter()
                    .all(|b| b.len() == 2 && b.bytes().all(|ch| ch.is_ascii_hexdigit()));
        }
        if let Some(value) = line.strip_prefix("m=") {
            let fields: Vec<_> = value.split_ascii_whitespace().collect();
            if fields.len() < 4 || fields[2] != "UDP/TLS/RTP/SAVPF" {
                return false;
            }
            match fields[0] {
                "audio" => audio = true,
                "video" if video => {}
                _ => return false,
            }
        }
    }
    audio && fingerprint
}

fn clock(db: &Connection) -> Result<i64> {
    Ok(db.query_row("SELECT unixepoch()", [], |r| r.get(0))?)
}

fn maintain(db: &Connection, now: i64) -> Result<()> {
    db.execute("DELETE FROM call_events WHERE until<=?", [now])?;
    db.execute("DELETE FROM call_sessions WHERE until<=?", [now])?;
    db.execute(
        "DELETE FROM call_signal_ids WHERE outbound=0 AND until<=?",
        [now],
    )?;
    Ok(())
}

// Sender role, epoch and peer bind every transition. Only the invited peer can accept.
// Returning false discards invalid authenticated control traffic without blocking the delivery cursor.
struct Session {
    call: String,
    peer: String,
    caller: String,
    epoch: i64,
    phase: String,
    count: i64,
    video: bool,
}

fn transition(
    db: &Connection,
    group: &MlsGroup,
    gid: &str,
    local: &str,
    sender: &str,
    wire: &Wire,
    now: i64,
) -> Result<bool> {
    let peer = if local == sender {
        wire.to.as_str()
    } else {
        sender
    };
    if !canonical_uuid(&wire.call)
        || !direct(db, group, local, peer)?
        || (sender != local && wire.to != local)
        || wire.at > now + 5
        || wire.at <= now - TTL
        || !wire.signal.valid()
    {
        return Ok(false);
    }
    let epoch = i64::try_from(group.epoch().as_u64())?;
    let state: Option<Session> = db
        .query_row(
            "SELECT call,peer,caller,epoch,phase,n,video FROM call_sessions WHERE g=?",
            [gid],
            |r| {
                Ok(Session {
                    call: r.get(0)?,
                    peer: r.get(1)?,
                    caller: r.get(2)?,
                    epoch: r.get(3)?,
                    phase: r.get(4)?,
                    count: r.get(5)?,
                    video: r.get(6)?,
                })
            },
        )
        .optional()?;
    if let Signal::Invite { media } = &wire.signal {
        if state.is_some_and(|s| s.phase != "ended" && s.epoch == epoch) {
            return Ok(false);
        }
        let reused: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM call_signal_ids WHERE g=? AND call=? AND until>?)",
            params![gid, wire.call, now],
            |r| r.get(0),
        )?;
        if reused {
            return Ok(false);
        }
        db.execute("DELETE FROM call_events WHERE g=?", [gid])?;
        db.execute(
            "INSERT OR REPLACE INTO call_sessions VALUES(?,?,?,?,?,'invited',?,1,?)",
            params![
                gid,
                wire.call,
                peer,
                sender,
                epoch,
                wire.at + TTL,
                matches!(media, Media::Video)
            ],
        )?;
        return Ok(true);
    }
    let Some(session) = state else {
        return Ok(false);
    };
    if session.call != wire.call
        || session.peer != peer
        || session.epoch != epoch
        || session.phase == "ended"
    {
        return Ok(false);
    }
    if let Signal::Offer { sdp } | Signal::Answer { sdp } = &wire.signal {
        if !allowed_media(sdp, session.video) {
            return Ok(false);
        }
    }
    let phase = session.phase.as_str();
    let caller = session.caller.as_str();
    let next = match &wire.signal {
        Signal::Accept {} if phase == "invited" && sender != caller => "accepted",
        Signal::Offer { .. } if phase == "accepted" && sender == caller => "offered",
        Signal::Answer { .. } if phase == "offered" && sender != caller => "answered",
        Signal::Ice { .. }
            if session.count < 128 && (phase == "offered" || phase == "answered") =>
        {
            phase
        }
        Signal::End {} => "ended",
        _ => return Ok(false),
    };
    if next == "ended" {
        db.execute(
            "UPDATE call_signal_ids SET until=? WHERE g=? AND call=? AND outbound=1",
            params![now, gid, wire.call],
        )?;
        db.execute("DELETE FROM call_events WHERE g=?", [gid])?;
    }
    let expiry = if next == "answered" {
        now + 4 * 3600
    } else {
        wire.at + TTL
    };
    db.execute(
        "UPDATE call_sessions SET phase=?,until=?,n=n+1 WHERE g=?",
        params![next, expiry, gid],
    )?;
    Ok(true)
}

fn record(
    db: &Connection,
    gid: &str,
    id: &str,
    wire: &Wire,
    digest: &[u8],
    outbound: bool,
) -> Result<()> {
    db.execute(
        "INSERT INTO call_signal_ids VALUES(?,?,?,?,?,?)",
        params![gid, id, wire.call, outbound, digest, wire.at + TTL],
    )?;
    Ok(())
}

pub(super) fn execute(
    db: &Connection,
    p: &Provider,
    req: &Value,
    identity: &str,
    signer: &SignatureKeyPair,
) -> Result<Value> {
    let now = clock(db)?;
    maintain(db, now)?;
    let gid = s(req, "group")?;
    let group = load_group(p, gid)?;
    if s(req, "op")? == "call_events" {
        // Only the currently unlocked session can observe received descriptions.
        let after = req["after"].as_i64().unwrap_or(0);
        let mut stmt=db.prepare("SELECT e.rowid,e.event FROM call_events e JOIN call_sessions s ON e.g=s.g AND e.call=s.call WHERE e.g=? AND s.epoch=? AND e.rowid>? ORDER BY e.rowid LIMIT 128")?;
        let entries = stmt.query_map(
            params![gid, i64::try_from(group.epoch().as_u64())?, after],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
        )?;
        let mut events = vec![];
        for e in entries {
            let (seq, raw) = e?;
            events.push(json!({"seq":seq,"event":serde_json::from_str::<Value>(&raw)?}));
        }
        let session: Option<(String, String)> = db
            .query_row(
                "SELECT call,phase FROM call_sessions WHERE g=? AND epoch=? AND until>?",
                params![gid, i64::try_from(group.epoch().as_u64())?, now],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        return Ok(
            json!({"events":events,"session":session.as_ref().map(|s|&s.0),"phase":session.as_ref().map(|s|&s.1)}),
        );
    }
    ensure!(s(req, "op")? == "call_queue", "unsupported call operation");
    let id = s(req, "id")?;
    ensure!(canonical_uuid(id), "invalid signal id");
    let wire = Wire {
        call: s(req, "call")?.to_owned(),
        to: s(req, "peer")?.to_owned(),
        at: now,
        signal: serde_json::from_value(req["signal"].clone())?,
    };
    if matches!(wire.signal, Signal::Invite { .. } | Signal::Accept {}) {
        ensure!(req["confirmed"] == true, "local consent required");
    }
    let digest = Sha256::digest(serde_json::to_vec(&json!([
        identity,
        gid,
        id,
        wire.call,
        wire.to,
        wire.signal
    ]))?);
    let old:Option<(Vec<u8>,i64,String)>=db.query_row(
      "SELECT c.digest,c.until,o.envelope FROM call_signal_ids c JOIN outgoing o ON o.group_id=c.g AND o.id=c.id JOIN call_sessions s ON s.g=c.g AND s.call=c.call WHERE c.g=? AND c.id=? AND c.outbound=1",params![gid,id],
      |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    if let Some((original, expires, envelope)) = old {
        ensure!(
            original == digest.as_slice() && expires > now,
            "signal id reused or expired"
        );
        return Ok(serde_json::from_str(&envelope)?);
    }
    ensure!(
        transition(db, &group, gid, identity, identity, &wire, now)?,
        "call transition rejected"
    );
    let fallback = if matches!(wire.signal, Signal::Invite { .. }) {
        "Call invitation (compatible client required)"
    } else {
        "Call event"
    };
    let payload =
        json!({"id":id,"group":gid,"sender":identity,"text":fallback,"type":TYPE,"control":wire});
    let mut group = group;
    let msg = group.create_message(p, signer, &serde_json::to_vec(&payload)?)?;
    let envelope = json!({"id":id,"group":gid,"epoch":group.epoch().as_u64(),"kind":1,"ciphertext":B64.encode(msg.tls_serialize_detached()?)});
    db.execute(
        "INSERT INTO outgoing(group_id,id,envelope,status) VALUES(?,?,?,'queued')",
        params![gid, id, envelope.to_string()],
    )?;
    record(db, gid, id, &wire, &digest, true)?;
    Ok(envelope)
}

pub(super) fn is_control(event: &Value) -> bool {
    event["type"]
        .as_str()
        .is_some_and(|t| t.starts_with("securemesh.call."))
}

pub(super) fn receive(
    db: &Connection,
    group: &MlsGroup,
    gid: &str,
    identity: &str,
    sender: &str,
    event: &Value,
) -> Result<Value> {
    let id = s(event, "id")?;
    let now = clock(db)?;
    maintain(db, now)?;
    let ignored = json!({"id":id,"type":"call_control","accepted":false});
    if event["type"] != TYPE || !canonical_uuid(id) {
        return Ok(ignored);
    }
    let Ok(wire) = serde_json::from_value::<Wire>(event["control"].clone()) else {
        return Ok(ignored);
    };
    let duplicate: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM call_signal_ids WHERE g=? AND id=?)",
        params![gid, id],
        |r| r.get(0),
    )?;
    if duplicate || !transition(db, group, gid, identity, sender, &wire, now)? {
        return Ok(ignored);
    }
    record(db, gid, id, &wire, &[], false)?;
    let clean = json!({"id":id,"sender":sender,"call":wire.call,"signal":wire.signal});
    db.execute(
        "INSERT INTO call_events(g,call,event,until) VALUES(?,?,?,?)",
        params![gid, wire.call, clean.to_string(), wire.at + TTL],
    )?;
    Ok(json!({"id":id,"type":"call_control","accepted":true}))
}
