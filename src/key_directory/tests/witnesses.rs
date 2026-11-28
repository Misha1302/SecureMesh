use anyhow::Result;
use ed25519_dalek::{Signer, SigningKey};
use securemesh_key_directory::{
    witness::{Policy, Vote},
    Checkpoint,
};

#[test]
fn three_distinct_pinned_signers_bind_the_entire_transition() -> Result<()> {
    let keys = [1, 2, 3, 4].map(|i| SigningKey::from_bytes(&[i; 32]));
    let roster = keys.each_ref().map(|k| k.verifying_key().to_bytes());
    let vrf = SigningKey::from_bytes(&[9; 32]).verifying_key().to_bytes();
    let other_vrf = SigningKey::from_bytes(&[7; 32]).verifying_key().to_bytes();
    let policy = Policy::new([8; 32], vrf, roster)?;
    let old = Checkpoint {
        epoch: 12,
        root: [10; 32],
    };
    let new = Checkpoint {
        epoch: 13,
        root: [11; 32],
    };
    let bytes = policy.statement(old, new)?;
    let votes: Vec<_> = keys
        .iter()
        .take(3)
        .enumerate()
        .map(|(i, k)| Vote {
            slot: i as u8,
            signature: k.sign(&bytes).to_bytes(),
        })
        .collect();
    policy.verify(old, new, &votes)?;
    let mut wrong = votes.clone();
    wrong[2].slot = 4;
    assert!(policy.verify(old, new, &wrong).is_err());
    wrong[2].slot = 3;
    assert!(policy.verify(old, new, &wrong).is_err());
    let mut weak = roster;
    weak[0] = [0; 32];
    assert!(Policy::new([8; 32], vrf, weak).is_err());
    assert!(policy.verify(old, new, &votes[..2]).is_err());
    assert!(policy
        .verify(old, new, &[votes[0], votes[0], votes[1]])
        .is_err());
    assert!(policy
        .verify(
            old,
            Checkpoint {
                root: [44; 32],
                ..new
            },
            &votes
        )
        .is_err());
    assert!(policy
        .verify(
            Checkpoint {
                root: [44; 32],
                ..old
            },
            new,
            &votes
        )
        .is_err());
    assert!(Policy::new([7; 32], vrf, roster)?
        .verify(old, new, &votes)
        .is_err());
    assert!(Policy::new([8; 32], other_vrf, roster)?
        .verify(old, new, &votes)
        .is_err());
    let mut changed = roster;
    changed.swap(0, 3);
    assert!(Policy::new([8; 32], vrf, changed)?
        .verify(old, new, &votes)
        .is_err());
    changed[2] = changed[3];
    assert!(Policy::new([8; 32], vrf, changed).is_err());
    assert!(policy.statement(new, old).is_err());
    Ok(())
}

use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AkdLabel, AkdValue, AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use securemesh_crypto::api::NativeClient;
use securemesh_key_directory::{
    encode_consistency,
    store::{Advancement, Store},
    witness::Witness,
};
use std::{
    fs,
    path::Path,
    process::{Child, Command},
};

async fn branch(value: u8) -> Result<([u8; 32], Checkpoint, Checkpoint, Vec<u8>)> {
    let tree = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let label = AkdLabel::from("account");
    let a = tree
        .publish(vec![(label.clone(), AkdValue(vec![0]))])
        .await?;
    let b = tree.publish(vec![(label, AkdValue(vec![value]))]).await?;
    Ok((
        *tree.get_public_key().await?.as_bytes(),
        Checkpoint {
            epoch: a.epoch(),
            root: a.hash(),
        },
        Checkpoint {
            epoch: b.epoch(),
            root: b.hash(),
        },
        encode_consistency(&tree.audit(a.epoch(), b.epoch()).await?)?,
    ))
}

fn public_policy(vrf: [u8; 32]) -> Result<Policy> {
    Policy::new(
        [8; 32],
        vrf,
        [1, 2, 3, 4].map(|i| SigningKey::from_bytes(&[i; 32]).verifying_key().to_bytes()),
    )
}

fn worker(dir: &Path, fork: usize) -> Result<Child> {
    Ok(Command::new(std::env::current_exe()?)
        .args(["--exact", "witness_child"])
        .env("SECUREMESH_WITNESS_FIXTURE", dir)
        .env("SECUREMESH_WITNESS_FORK", fork.to_string())
        .spawn()?)
}

#[tokio::test]
async fn witness_child() -> Result<()> {
    let Some(dir) = std::env::var_os("SECUREMESH_WITNESS_FIXTURE") else {
        return Ok(());
    };
    let dir = Path::new(&dir);
    let fork = std::env::var("SECUREMESH_WITNESS_FORK")?;
    let read_root =
        |name: &str| -> [u8; 32] { fs::read(dir.join(name)).unwrap().try_into().unwrap() };
    let mut witness = Witness::open(&dir.join("w0"), public_policy(read_root("vrf"))?, 0)?;
    let outcome = witness
        .cosign(
            &SigningKey::from_bytes(&[1; 32]),
            Checkpoint {
                epoch: 1,
                root: read_root("pin"),
            },
            Checkpoint {
                epoch: 2,
                root: read_root(&format!("{fork}.root")),
            },
            &fs::read(dir.join(format!("{fork}.pb")))?,
        )
        .await;
    match outcome {
        // Simulate losing the vote before it reaches the requester. Skip destructors.
        Ok(_) => std::process::exit(0),
        Err(e) if e.to_string().contains("conflicting or stale") => std::process::exit(42),
        Err(e) => Err(e),
    }
}

#[tokio::test]
async fn two_valid_forks_cannot_both_receive_one_witness_vote_and_client_refuses_downgrade(
) -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path();
    let left = branch(1).await?;
    let right = branch(2).await?;
    assert_eq!((left.0, left.1), (right.0, right.1));
    assert_ne!(left.2, right.2);
    let policy = public_policy(left.0)?;
    fs::write(path.join("vrf"), left.0)?;
    fs::write(path.join("pin"), left.1.root)?;
    for (i, b) in [&left, &right].iter().enumerate() {
        fs::write(path.join(format!("{i}.root")), b.2.root)?;
        fs::write(path.join(format!("{i}.pb")), &b.3)?;
    }
    drop(Witness::provision(
        &path.join("w0"),
        policy.clone(),
        0,
        left.1,
    )?);
    assert!(Witness::provision(&path.join("w0"), policy.clone(), 0, right.2).is_err());
    let mut a = worker(path, 0)?;
    let mut b = worker(path, 1)?;
    let (winner, loser) = match (a.wait()?.code(), b.wait()?.code()) {
        (Some(0), Some(42)) => (&left, &right),
        (Some(42), Some(0)) => (&right, &left),
        status => panic!("unexpected witness worker exits {status:?}"),
    };
    let (_, before, after, proof) = winner;
    let mut votes = vec![];
    for slot in 0..3u8 {
        let ledger = path.join(format!("w{slot}"));
        let mut w = if slot == 0 {
            Witness::open(&ledger, policy.clone(), slot)?
        } else {
            Witness::provision(&ledger, policy.clone(), slot, *before)?
        };
        let key = SigningKey::from_bytes(&[slot + 1; 32]);
        assert!(w.cosign(&key, *before, *after, &[]).await.is_err());
        let vote = w.cosign(&key, *before, *after, proof).await?;
        votes.push(vote);
        assert!(w.cosign(&key, loser.1, loser.2, &loser.3).await.is_err());
        assert_eq!(w.checkpoint()?, *after);
    }
    policy
        .verify_advance(*before, *after, proof, &votes)
        .await?;
    let db = path.join("profile.db");
    let password = "test witness policy passphrase";
    let owner = "eb83d2fc-11d8-4a65-81f3-66ccd61d2a77";
    let native = NativeClient::open(db.to_str().unwrap().into(), password.into()).unwrap();
    native
        .execute(format!(r#"{{"op":"init","identity":"{owner}"}}"#))
        .unwrap();
    drop(native);
    let mut store = Store::provision(&db, password, owner, left.0, *before)?;
    assert!(store
        .advance_witnessed(*before, *after, proof, &policy, &votes)
        .await
        .is_err());
    // Existing schema-v1 connection and its actual CAS predicate from commit 9748d2f.
    let legacy = rusqlite::Connection::open(&db)?;
    legacy.pragma_update(None, "key", password)?;
    let _: i64 = legacy.query_row(
        "SELECT epoch FROM kt_checkpoint WHERE schema_version=1",
        [],
        |r| r.get(0),
    )?;
    store.enroll_witnesses(*before, &policy)?;
    assert_eq!(
        legacy.execute(
            "UPDATE kt_checkpoint SET previous_root=root,epoch=?1,root=?2
        WHERE slot=1 AND schema_version=1 AND owner=?3 AND vrf=?4 AND epoch=?5 AND root=?6",
            rusqlite::params![
                i64::try_from(after.epoch)?,
                after.root,
                owner,
                left.0,
                i64::try_from(before.epoch)?,
                before.root
            ]
        )?,
        0
    );
    store.enroll_witnesses(*before, &policy)?;
    let other = Policy::new(
        [7; 32],
        left.0,
        [1, 2, 3, 4].map(|i| SigningKey::from_bytes(&[i; 32]).verifying_key().to_bytes()),
    )?;
    assert!(store.enroll_witnesses(*before, &other).is_err());
    drop(store);
    let mut store = Store::open(&db, password, owner, left.0)?;
    assert!(store.advance(*before, *after, proof).await.is_err());
    assert!(store
        .advance_witnessed(*before, *after, proof, &policy, &votes[0..2])
        .await
        .is_err());
    assert_eq!(store.checkpoint()?, *before);
    assert_eq!(
        store
            .advance_witnessed(*before, *after, proof, &policy, &votes)
            .await?,
        Advancement::Committed
    );
    assert_eq!(
        store
            .advance_witnessed(*before, *after, proof, &policy, &votes)
            .await?,
        Advancement::AlreadyCommitted
    );
    Ok(())
}
