use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AkdLabel, AkdValue, AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use anyhow::Result;
use ed25519_dalek::SigningKey;
use securemesh_crypto::api::NativeClient;
use securemesh_key_directory::{
    encode_consistency,
    store::Store,
    witness::{Policy, Witness},
    Checkpoint,
};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Output, Stdio},
};

fn cli(at: &Path, args: &[&str], input: &[u8]) -> Result<Output> {
    let mut proc = Command::new(env!("CARGO_BIN_EXE_kt-witness"))
        .current_dir(at)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    proc.stdin.take().unwrap().write_all(input)?;
    Ok(proc.wait_with_output()?)
}

#[tokio::test]
async fn operator_and_client_reopen_separate_ledgers_and_exchange_public_votes() -> Result<()> {
    let root = tempfile::tempdir()?;
    let at = root.path();
    let dir = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let label = AkdLabel::from("fixture");
    let old = dir
        .publish(vec![(label.clone(), AkdValue(vec![1]))])
        .await?;
    let next = dir.publish(vec![(label, AkdValue(vec![2]))]).await?;
    let vrf = *dir.get_public_key().await?.as_bytes();
    let keys = [1, 2, 3, 4].map(|i| SigningKey::from_bytes(&[i; 32]));
    let cfg = format!(
        "{} {} {}",
        hex::encode([7; 32]),
        hex::encode(vrf),
        keys.iter()
            .map(|k| hex::encode(k.verifying_key().as_bytes()))
            .collect::<Vec<_>>()
            .join(" ")
    );
    fs::write(at.join("cfg"), cfg)?;
    for (name, p) in [("old", &old), ("next", &next)] {
        fs::write(
            at.join(name),
            format!("{} {}\n", p.epoch(), hex::encode(p.hash())),
        )?;
    }
    fs::write(
        at.join("proof"),
        encode_consistency(&dir.audit(old.epoch(), next.epoch()).await?)?,
    )?;
    fs::write(at.join("oversized-config"), vec![b' '; 1025])?;
    assert!(!cli(
        at,
        &["provision", "oversized-config", "unused-ledger", "0", "old"],
        &[]
    )?
    .status
    .success());
    assert!(!at.join("unused-ledger").exists());
    fs::write(
        at.join("oversized-proof"),
        vec![0; securemesh_key_directory::MAX_PROOF_BYTES + 1],
    )?;
    for (i, k) in keys.iter().take(3).enumerate() {
        let slot = i.to_string();
        let ledger = format!("ledger{i}");
        assert!(cli(at, &["provision", "cfg", &ledger, &slot, "old"], &[])?
            .status
            .success());
        let args = ["vote", "cfg", &ledger, &slot, "old", "next", "proof"];
        let short = cli(at, &args, &[0x78; 33])?;
        assert!(!short.status.success() && short.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&short.stderr).contains("xxxxxxxx"));
        assert!(!cli(at, &args, &keys[3].to_bytes())?.status.success());
        assert!(!cli(
            at,
            &[
                "vote",
                "cfg",
                &ledger,
                &slot,
                "old",
                "next",
                "oversized-proof"
            ],
            &k.to_bytes()
        )?
        .status
        .success());
        let vote = cli(at, &args, &k.to_bytes())?;
        assert!(vote.status.success());
        assert_eq!(vote.stdout, cli(at, &args, &k.to_bytes())?.stdout);
        fs::write(at.join(format!("v{i}")), vote.stdout)?;
    }
    let path = at.join("profile");
    let owner = "fixture-device";
    let pw = "test cli profile credential\n";
    let native = NativeClient::open(path.to_str().unwrap().into(), pw.into()).unwrap();
    native
        .execute(format!(r#"{{"op":"init","identity":"{owner}"}}"#))
        .unwrap();
    drop(native);
    Store::provision(
        &path,
        pw,
        owner,
        vrf,
        Checkpoint {
            epoch: old.epoch(),
            root: old.hash(),
        },
    )?;
    let enroll = ["enroll", "cfg", "profile", owner, "old"];
    assert!(!cli(at, &enroll, pw.trim_end().as_bytes())?.status.success());
    assert!(cli(at, &enroll, pw.as_bytes())?.status.success());
    let mut args = vec![
        "advance", "cfg", "profile", owner, "old", "next", "proof", "v0", "v1",
    ];
    assert!(!cli(at, &args, pw.as_bytes())?.status.success());
    args.push("v1");
    assert!(!cli(at, &args, pw.as_bytes())?.status.success());
    *args.last_mut().unwrap() = "v2";
    assert_eq!(cli(at, &args, pw.as_bytes())?.stdout, b"Committed\n");
    assert_eq!(cli(at, &args, pw.as_bytes())?.stdout, b"AlreadyCommitted\n");

    let policy = Policy::new(
        [7; 32],
        vrf,
        keys.each_ref().map(|key| key.verifying_key().to_bytes()),
    )?;
    let checkpoint = Checkpoint {
        epoch: next.epoch(),
        root: next.hash(),
    };
    let observations = (0..3)
        .map(|slot| {
            let witness = Witness::open(
                &at.join(format!("ledger{slot}")),
                policy.clone(),
                slot as u8,
            )?;
            witness.observe_current(&keys[slot])
        })
        .collect::<Result<Vec<_>>>()?;
    assert!(observations
        .iter()
        .all(|observation| observation.checkpoint() == checkpoint));
    let store = Store::open(&path, pw, owner, vrf)?;
    let accepted = store.accept_checkpoint_freshness(&policy, &observations)?;
    assert_eq!(accepted.checkpoint(), checkpoint);
    assert_eq!(store.current_checkpoint_freshness(&policy)?, accepted);
    drop(store);
    let reopened = Store::open(&path, pw, owner, vrf)?;
    assert_eq!(reopened.current_checkpoint_freshness(&policy)?, accepted);
    Ok(())
}
