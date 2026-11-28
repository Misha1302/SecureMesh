use super::*;
use crate::{encode_consistency, encode_lookup};
use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AkdValue, AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use securemesh_crypto::api::NativeClient;
use std::{
    fs,
    process::{Child, Command},
    time::Instant,
};
use tempfile::tempdir;

const PASSWORD: &str = "a fixture passphrase for SQLCipher";
const OWNER: &str = "6b859246-197d-4afc-91e6-ece1db4d70bb";

fn initialize_profile(path: &Path) {
    let native = NativeClient::open(path.to_str().unwrap().into(), PASSWORD.into()).unwrap();
    native
        .execute(format!(r#"{{"op":"init","identity":"{OWNER}"}}"#))
        .unwrap();
}

async fn branch(dir: &Path, name: &str, value: u8) -> Result<([u8; 32], Checkpoint, Checkpoint)> {
    let server = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let label = AkdLabel::from("test-account");
    let first = server
        .publish(vec![(label.clone(), AkdValue(vec![0; 32]))])
        .await?;
    let second = server
        .publish(vec![(label.clone(), AkdValue(vec![value; 32]))])
        .await?;
    fs::write(
        dir.join(format!("{name}.pb")),
        encode_consistency(&server.audit(1, 2).await?)?,
    )?;
    fs::write(
        dir.join(format!("{name}.lookup")),
        encode_lookup(&server.lookup(label).await?.0)?,
    )?;
    fs::write(dir.join(format!("{name}.root")), second.hash())?;
    Ok((
        *server.get_public_key().await?.as_bytes(),
        Checkpoint {
            epoch: 1,
            root: first.hash(),
        },
        Checkpoint {
            epoch: 2,
            root: second.hash(),
        },
    ))
}

fn worker(dir: &Path, mode: &str, branch: &str) -> Result<Child> {
    Ok(Command::new(std::env::current_exe()?)
        .args(["--exact", "store::tests::subprocess_worker"])
        .env("SMESH_KT_TEST_DIR", dir)
        .env("SMESH_KT_TEST_MODE", mode)
        .env("SMESH_KT_TEST_BRANCH", branch)
        .spawn()?)
}

fn array(dir: &Path, name: &str) -> [u8; 32] {
    fs::read(dir.join(name)).unwrap().try_into().unwrap()
}

#[tokio::test]
async fn subprocess_worker() -> Result<()> {
    let Some(dir) = std::env::var_os("SMESH_KT_TEST_DIR") else {
        return Ok(());
    };
    let dir = Path::new(&dir);
    let mode = std::env::var("SMESH_KT_TEST_MODE")?;
    let name = std::env::var("SMESH_KT_TEST_BRANCH")?;
    let key = array(dir, "vrf");
    let first = Checkpoint {
        epoch: 1,
        root: array(dir, "first"),
    };
    let next = Checkpoint {
        epoch: 2,
        root: array(dir, &format!("{name}.root")),
    };
    let proof = fs::read(dir.join(format!("{name}.pb")))?;
    let mut store = Store::open(&dir.join("profile"), PASSWORD, OWNER, key)?;
    if mode == "precommit" {
        Client::from_pin(key, first).advance(next, &proof).await?;
        let tx = store
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        assert_eq!(
            record(&tx, OWNER, &key, first, next)?,
            Advancement::Committed
        );
        std::process::exit(71); // Exit with the real update uncommitted; no Rust destructors run.
    }
    fs::write(dir.join(format!("{name}.ready")), [])?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while !dir.join("start").exists() {
        ensure!(Instant::now() < deadline, "worker timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
    match store.advance(first, next, &proof).await {
        Ok(Advancement::Committed) => std::process::exit(73), // Caller receives no success response.
        Err(e) if e.to_string().contains("checkpoint changed concurrently") => {
            std::process::exit(74)
        }
        other => anyhow::bail!("unexpected commit outcome {other:?}"),
    }
}

#[tokio::test]
async fn durable_profile_cas_survives_process_loss_and_competing_valid_branches() -> Result<()> {
    let scratch = tempdir()?;
    let dir = scratch.path();
    let path = dir.join("profile");
    let (key, first, a) = branch(dir, "a", 1).await?;
    let (_, same, b) = branch(dir, "b", 2).await?;
    assert_eq!(first, same);
    assert_ne!(a, b);
    assert!(Store::provision(&path, PASSWORD, OWNER, key, first).is_err());
    assert!(!path.exists());
    initialize_profile(&path);
    assert!(Store::open(&path, PASSWORD, OWNER, key).is_err());
    assert!(Store::provision(&path, PASSWORD, OWNER, [0; 32], first).is_err());
    assert!(Store::provision(
        &path,
        PASSWORD,
        OWNER,
        key,
        Checkpoint {
            epoch: u64::MAX,
            ..first
        }
    )
    .is_err());
    Store::provision(&path, PASSWORD, OWNER, key, first)?;
    assert!(Store::provision(&path, PASSWORD, OWNER, key, b).is_err());
    assert!(Store::open(&path, "a different passphrase", OWNER, key).is_err());
    assert!(Store::open(&path, PASSWORD, "wrong local device", key).is_err());
    assert!(Store::open(&path, PASSWORD, OWNER, [0; 32]).is_err());
    fs::write(dir.join("vrf"), key)?;
    fs::write(dir.join("first"), first.root)?;
    assert_eq!(worker(dir, "precommit", "a")?.wait()?.code(), Some(71));
    assert_eq!(
        Store::open(&path, PASSWORD, OWNER, key)?.checkpoint()?,
        first
    );
    let mut left = worker(dir, "race", "a")?;
    let mut right = worker(dir, "race", "b")?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while !(dir.join("a.ready").exists() && dir.join("b.ready").exists()) {
        ensure!(Instant::now() < deadline, "workers did not reach barrier");
        std::thread::sleep(Duration::from_millis(10));
    }
    fs::write(dir.join("start"), [])?;
    let outcomes = (left.wait()?.code(), right.wait()?.code());
    let (winner, loser, good, bad) = match outcomes {
        (Some(73), Some(74)) => ("a", "b", a, b),
        (Some(74), Some(73)) => ("b", "a", b, a),
        _ => anyhow::bail!("unexpected worker exit codes {outcomes:?}"),
    };
    let mut reopened = Store::open(&path, PASSWORD, OWNER, key)?;
    assert_eq!(reopened.checkpoint()?, good);
    let audit = fs::read(dir.join(format!("{winner}.pb")))?;
    assert_eq!(
        reopened.advance(first, good, &audit).await?,
        Advancement::AlreadyCommitted
    );
    assert!(reopened
        .advance(first, bad, &fs::read(dir.join(format!("{loser}.pb")))?)
        .await
        .is_err());
    assert!(reopened.advance(good, first, &audit).await.is_err());
    assert!(reopened.advance(first, good, &[]).await.is_err());
    let (snapshot, entry) = reopened.lookup(
        AkdLabel::from("test-account"),
        &fs::read(dir.join(format!("{winner}.lookup")))?,
    )?;
    assert_eq!(snapshot, good);
    assert_eq!(entry.version, 2);
    assert_ne!(&fs::read(&path)?[..16], b"SQLite format 3\0");
    // Ensure the next native open can still read its identity and migration ledger.
    let native = NativeClient::open(path.to_str().unwrap().into(), PASSWORD.into()).unwrap();
    assert!(native
        .execute(r#"{"op":"identity"}"#.into())
        .unwrap()
        .contains(OWNER));
    Ok(())
}

#[test]
fn incompatible_profile_or_checkpoint_schema_never_bootstraps() -> Result<()> {
    let scratch = tempdir()?;
    let path = scratch.path().join("profile");
    initialize_profile(&path);
    let db = Connection::open(&path)?;
    db.pragma_update(None, "key", PASSWORD)?;
    db.execute_batch("CREATE TABLE kt_checkpoint(obsolete BLOB)")?;
    let key: [u8; 32] =
        hex::decode("f6ec49c8085f4d4be69db8e248bf11ce288026f5b8c5f6599defe58303d0702d")?
            .try_into()
            .unwrap();
    let initial = Checkpoint {
        epoch: 1,
        root: [1; 32],
    };
    assert!(Store::open(&path, PASSWORD, OWNER, key).is_err());
    assert!(Store::provision(&path, PASSWORD, OWNER, key, initial).is_err());
    db.execute_batch(
        "DROP TABLE kt_checkpoint; DELETE FROM openmls_sqlite_storage_migrations WHERE version=6",
    )?;
    assert!(Store::provision(&path, PASSWORD, OWNER, key, initial).is_err());
    Ok(())
}
