use super::*;
use crate::Client;
use akd::ecvrf::{HardCodedAkdVRF, VrfError};
use async_trait::async_trait;
use std::{fs, process::Command};
use tempfile::tempdir;

const PASS: &str = "isolated writer fixture passphrase";
fn updates(value: u8) -> Vec<(AkdLabel, AkdValue)> {
    vec![(AkdLabel::from("demo/account"), AkdValue(vec![value; 32]))]
}

#[derive(Clone)]
struct OtherKey;
#[async_trait]
impl VRFKeyStorage for OtherKey {
    async fn retrieve(&self) -> Result<Vec<u8>, VrfError> {
        Ok(vec![9; 32])
    }
}

#[tokio::test]
async fn crash_worker() -> Result<()> {
    let Some(path) = std::env::var_os("SECUREMESH_AKD_WRITER_TEST_DB") else {
        return Ok(());
    };
    let writer = Writer::open(Path::new(&path), PASS, HardCodedAkdVRF).await?;
    match std::env::var("SECUREMESH_AKD_WRITER_TEST_PHASE")?.as_str() {
        "before" => {
            let tx = writer.session(true)?;
            let (tree, _) = writer.checked(&tx).await?;
            tree.publish(updates(7)).await?;
            std::process::exit(71); // Includes upstream's batch commit, before SQL COMMIT.
        }
        "after" => {
            writer
                .publish([7; 16], writer.checkpoint().await?, updates(7))
                .await?;
            std::process::exit(72); // Committed publish, no receipt delivered to caller.
        }
        _ => anyhow::bail!("unknown test phase"),
    }
}

#[tokio::test]
async fn recover_publication_and_verify_detached_proofs() -> Result<()> {
    let scratch = tempdir()?;
    let path = scratch.path().join("writer");
    assert!(Writer::open(&path, PASS, HardCodedAkdVRF).await.is_err());
    assert!(!path.exists());
    let writer = Writer::create(&path, PASS, HardCodedAkdVRF).await?;
    assert!(Writer::create(&path, PASS, OtherKey).await.is_err());
    assert!(Writer::open(&path, PASS, OtherKey).await.is_err());
    assert!(
        Writer::open(&path, "a different fixture passphrase", HardCodedAkdVRF)
            .await
            .is_err()
    );
    let genesis = writer.checkpoint().await?;
    assert_eq!(genesis.epoch, 0);
    let first = writer.publish([1; 16], genesis, updates(1)).await?;
    assert_eq!(first.epoch, 1);
    let (head, old_proof) = writer.lookup(AkdLabel::from("demo/account")).await?;
    assert_eq!(head, first);
    let key = *HardCodedAkdVRF
        .get_vrf_public_key()
        .await
        .unwrap()
        .as_bytes();
    let mut client = Client::from_pin(key, first);
    assert_eq!(
        client
            .lookup(AkdLabel::from("demo/account"), &old_proof)?
            .value,
        AkdValue(vec![1; 32])
    );
    drop(writer);
    for (phase, expected_exit) in [("before", 71), ("after", 72)] {
        let status = Command::new(std::env::current_exe()?)
            .args(["--exact", "writer::tests::crash_worker"])
            .env("SECUREMESH_AKD_WRITER_TEST_DB", &path)
            .env("SECUREMESH_AKD_WRITER_TEST_PHASE", phase)
            .status()?;
        assert_eq!(status.code(), Some(expected_exit));
        if phase == "before" {
            let writer = Writer::open(&path, PASS, HardCodedAkdVRF).await?;
            assert_eq!(writer.checkpoint().await?, first);
            assert_eq!(
                writer.lookup(AkdLabel::from("demo/account")).await?.1,
                old_proof
            );
        }
    }
    let reopened = Writer::open(&path, PASS, HardCodedAkdVRF).await?;
    let second = reopened.checkpoint().await?;
    assert_eq!(second.epoch, 2);
    assert_eq!(reopened.publish([7; 16], first, updates(7)).await?, second);
    assert!(reopened.publish([7; 16], first, updates(8)).await.is_err());
    assert!(reopened.publish([8; 16], first, updates(8)).await.is_err());
    assert_eq!(reopened.publish([9; 16], second, updates(7)).await?, second);
    let third = reopened.publish([10; 16], second, updates(3)).await?;
    for (old, new) in [(first, second), (second, third)] {
        client
            .advance(new, &reopened.consistency(old.epoch, new.epoch).await?)
            .await?;
    }
    assert_eq!(
        client
            .lookup(
                AkdLabel::from("demo/account"),
                &reopened.lookup(AkdLabel::from("demo/account")).await?.1
            )?
            .value,
        AkdValue(vec![3; 32])
    );
    assert_eq!(reopened.publish([7; 16], first, updates(7)).await?, second);
    assert_eq!(reopened.checkpoint().await?, third);
    // Check that durable user-state indexing retains intermediate updates.
    {
        let snapshot = reopened.session(false)?;
        let (tree, _) = reopened.checked(&snapshot).await?;
        let label = AkdLabel::from("demo/account");
        let (history, _) = tree
            .key_history(&label, akd::HistoryParams::default())
            .await?;
        let verified = akd::client::key_history_verify::<WhatsAppV1Configuration>(
            &key,
            third.root,
            third.epoch,
            label,
            history,
            akd::HistoryVerificationParams::default(),
        )
        .map_err(|_| anyhow::anyhow!("history proof rejected"))?;
        assert_eq!(
            verified.into_iter().map(|v| v.value).collect::<Vec<_>>(),
            vec![
                AkdValue(vec![3; 32]),
                AkdValue(vec![7; 32]),
                AkdValue(vec![1; 32])
            ]
        );
    }
    assert_ne!(&fs::read(&path)?[..16], b"SQLite format 3\0");
    Ok(())
}

#[tokio::test]
async fn lost_tree_metadata_cannot_initialize_a_replacement_directory() -> Result<()> {
    use akd::storage::Storable;
    let scratch = tempdir()?;
    let path = scratch.path().join("writer");
    let writer = Writer::create(&path, PASS, HardCodedAkdVRF).await?;
    let session = writer.session(true)?;
    let id = Azks::get_full_binary_key_id(&DEFAULT_AZKS_KEY);
    session
        .0
        .connection()?
        .execute("DELETE FROM akd_record WHERE id=?", [id.clone()])?;
    session.0.connection()?.execute_batch("COMMIT")?;
    drop(session);
    assert!(Writer::open(&path, PASS, HardCodedAkdVRF).await.is_err());
    assert!(writer.checkpoint().await.is_err());
    let session = writer.session(false)?;
    let found: bool = session.0.connection()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM akd_record WHERE id=?)",
        [id],
        |r| r.get(0),
    )?;
    assert!(!found);
    Ok(())
}

#[tokio::test]
async fn concurrent_writers_cannot_commit_two_successors_of_one_checkpoint() -> Result<()> {
    let scratch = tempdir()?;
    let path = scratch.path().join("writer");
    let writer = Writer::create(&path, PASS, HardCodedAkdVRF).await?;
    let prior = writer.checkpoint().await?;
    let start = Arc::new(std::sync::Barrier::new(2));
    let launch = |value: u8| {
        let path = path.clone();
        let start = start.clone();
        std::thread::spawn(move || -> Result<Checkpoint> {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            runtime.block_on(async {
                let writer = Writer::open(&path, PASS, HardCodedAkdVRF).await?;
                start.wait();
                writer.publish([value; 16], prior, updates(value)).await
            })
        })
    };
    let a = launch(1);
    let b = launch(2);
    let (one, two) = (a.join().unwrap(), b.join().unwrap());
    let winner = match (one, two) {
        (Ok(head), Err(e)) | (Err(e), Ok(head))
            if e.to_string().contains("stale writer checkpoint") =>
        {
            head
        }
        other => anyhow::bail!("unexpected competing writer results {other:?}"),
    };
    assert_eq!(writer.checkpoint().await?, winner);
    assert_eq!(winner.epoch, 1);
    Ok(())
}
