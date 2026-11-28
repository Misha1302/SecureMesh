//! Local single-database AKD publisher. All records and receipts are server data.
mod records;

use crate::{encode_consistency, encode_lookup, Checkpoint};
use akd::{
    append_only_zks::DEFAULT_AZKS_KEY,
    ecvrf::VRFKeyStorage,
    storage::{Database, StorageManager},
    AkdLabel, AkdValue, Azks, AzksParallelismConfig, Directory, EpochHash, WhatsAppV1Configuration,
};
use anyhow::{ensure, Context, Result};
use records::Records;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use sha2::{Digest as _, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use zeroize::Zeroizing;

type Tree<V> = Directory<WhatsAppV1Configuration, Records, V>;

pub struct Writer<V> {
    path: PathBuf,
    password: Zeroizing<String>,
    vrf: V,
}

// If a future is cancelled or a return path fails, roll back even if an AKD
// background task briefly retains the connection. No other operation reuses it.
struct Session(Records);

impl Drop for Session {
    fn drop(&mut self) {
        if let Ok(db) = self.0.connection() {
            if !db.is_autocommit() {
                let _ = db.execute_batch("ROLLBACK");
            }
        }
    }
}

fn checkpoint(epoch: i64, root: [u8; 32]) -> Result<Checkpoint> {
    Ok(Checkpoint {
        epoch: epoch.try_into()?,
        root,
    })
}

impl<V: VRFKeyStorage> Writer<V> {
    fn handle(path: &Path, password: &str, vrf: V) -> Result<Self> {
        ensure!(password.len() >= 16, "writer database password too short");
        Ok(Self {
            path: path.to_owned(),
            password: Zeroizing::new(password.to_owned()),
            vrf,
        })
    }

    fn session(&self, write: bool) -> Result<Session> {
        let db = Connection::open_with_flags(&self.path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        db.pragma_update(None, "key", self.password.as_str())?;
        let version: String = db.query_row("PRAGMA cipher_version", [], |r| r.get(0))?;
        ensure!(
            version.split_whitespace().next() == Some("4.20.0"),
            "unsupported writer cipher"
        );
        db.busy_timeout(Duration::from_secs(5))?;
        db.pragma_update(None, "synchronous", "FULL")?;
        db.execute_batch(if write { "BEGIN IMMEDIATE" } else { "BEGIN" })?;
        Ok(Session(Records(Arc::new(Mutex::new(db)))))
    }

    async fn tree(&self, records: &Records) -> Result<Tree<V>> {
        Ok(Directory::new(
            StorageManager::new_no_cache(records.clone()),
            self.vrf.clone(),
            AzksParallelismConfig::disabled(),
        )
        .await?)
    }

    async fn checked(&self, session: &Session) -> Result<(Tree<V>, Checkpoint)> {
        let vrf = self
            .vrf
            .get_vrf_public_key()
            .await
            .map_err(|_| anyhow::anyhow!("VRF provider unavailable"))?;
        let (epoch, root) = session
            .0
            .connection()?
            .query_row(
                "SELECT epoch,root FROM akd_writer WHERE id=1 AND format=1 AND vrf=?",
                [vrf.as_bytes()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .context("wrong writer schema or VRF key")?;
        let stored = checkpoint(epoch, root)?;
        // Directory::new initializes an absent AZKS; only create() may do that.
        session.0.get::<Azks>(&DEFAULT_AZKS_KEY).await?;
        let tree = self.tree(&session.0).await?;
        let EpochHash(epoch, root) = tree.get_epoch_hash().await?;
        ensure!(
            stored == Checkpoint { epoch, root },
            "stored writer checkpoint mismatch"
        );
        Ok((tree, stored))
    }

    pub async fn create(path: &Path, password: &str, vrf: V) -> Result<Self> {
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let temporary = tempfile::NamedTempFile::new_in(parent)?;
        let mut writer = Self::handle(temporary.path(), password, vrf)?;
        {
            let session = writer.session(true)?;
            session.0.connection()?.execute_batch("
                CREATE TABLE akd_record(id BLOB PRIMARY KEY,data BLOB NOT NULL,label BLOB,epoch INTEGER,version INTEGER) STRICT;
                CREATE UNIQUE INDEX akd_record_epoch ON akd_record(label,epoch) WHERE label IS NOT NULL;
                CREATE UNIQUE INDEX akd_record_version ON akd_record(label,version) WHERE label IS NOT NULL;
                CREATE TABLE akd_writer(id INTEGER PRIMARY KEY CHECK(id=1),format INTEGER NOT NULL,vrf BLOB NOT NULL,
                    epoch INTEGER NOT NULL CHECK(epoch>=0),root BLOB NOT NULL CHECK(length(root)=32)) STRICT;
                CREATE TABLE akd_publication(id BLOB PRIMARY KEY,prior_epoch INTEGER NOT NULL,prior_root BLOB NOT NULL,
                    batch_hash BLOB NOT NULL,epoch INTEGER NOT NULL,root BLOB NOT NULL) STRICT;")?;
            let tree = writer.tree(&session.0).await?;
            let EpochHash(epoch, root) = tree.get_epoch_hash().await?;
            let key = tree.get_public_key().await?;
            let db = session.0.connection()?;
            db.execute(
                "INSERT INTO akd_writer VALUES(1,1,?,?,?)",
                params![key.as_bytes(), i64::try_from(epoch)?, root],
            )?;
            db.execute_batch("COMMIT")?;
        }
        temporary.as_file().sync_all()?;
        temporary.persist_noclobber(path)?;
        #[cfg(unix)]
        std::fs::File::open(parent)?.sync_all()?;
        writer.path = path.to_owned();
        Ok(writer)
    }

    pub async fn open(path: &Path, password: &str, vrf: V) -> Result<Self> {
        let writer = Self::handle(path, password, vrf)?;
        writer.checkpoint().await?;
        Ok(writer)
    }

    pub async fn checkpoint(&self) -> Result<Checkpoint> {
        let session = self.session(false)?;
        Ok(self.checked(&session).await?.1)
    }

    /// A caller supplies its independently retained last head and a stable operation ID.
    /// Reusing an ID returns its original result only for the identical ordered batch.
    pub async fn publish(
        &self,
        id: [u8; 16],
        prior: Checkpoint,
        updates: Vec<(AkdLabel, AkdValue)>,
    ) -> Result<Checkpoint> {
        ensure!(!updates.is_empty(), "empty publication");
        let fingerprint: [u8; 32] = Sha256::digest(serde_json::to_vec(&updates)?).into();
        let session = self.session(true)?;
        let (tree, current) = self.checked(&session).await?;
        {
            let db = session.0.connection()?;
            let receipt=db.query_row("SELECT prior_epoch,prior_root,batch_hash,epoch,root FROM akd_publication WHERE id=?",[id],
                |r|Ok((r.get::<_,i64>(0)?,r.get::<_,[u8;32]>(1)?,r.get::<_,[u8;32]>(2)?,r.get::<_,i64>(3)?,r.get::<_,[u8;32]>(4)?))).optional()?;
            if let Some((epoch, root, hash, done, done_root)) = receipt {
                ensure!(
                    checkpoint(epoch, root)? == prior && hash == fingerprint,
                    "publication ID binding changed"
                );
                return checkpoint(done, done_root);
            }
        }
        ensure!(current == prior, "stale writer checkpoint");
        let EpochHash(epoch, root) = tree.publish(updates).await?;
        let result = Checkpoint { epoch, root };
        // Upstream preserves the current epoch for an unchanged publication.
        ensure!(
            result == prior || prior.epoch.checked_add(1) == Some(epoch),
            "unexpected AKD epoch"
        );
        let db = session.0.connection()?;
        db.execute(
            "UPDATE akd_writer SET epoch=?,root=? WHERE id=1",
            params![i64::try_from(epoch)?, root],
        )?;
        db.execute(
            "INSERT INTO akd_publication VALUES(?,?,?,?,?,?)",
            params![
                id,
                i64::try_from(prior.epoch)?,
                prior.root,
                fingerprint,
                i64::try_from(epoch)?,
                root
            ],
        )?;
        db.execute_batch("COMMIT")?;
        Ok(result)
    }

    pub async fn lookup(&self, label: AkdLabel) -> Result<(Checkpoint, Vec<u8>)> {
        let session = self.session(false)?;
        let (tree, head) = self.checked(&session).await?;
        let (proof, _) = tree.lookup(label).await?;
        Ok((head, encode_lookup(&proof)?))
    }

    pub async fn consistency(&self, from: u64, to: u64) -> Result<Vec<u8>> {
        ensure!(
            from.checked_add(1) == Some(to),
            "expected consecutive epochs"
        );
        let session = self.session(false)?;
        let (tree, head) = self.checked(&session).await?;
        ensure!(to <= head.epoch, "future checkpoint");
        encode_consistency(&tree.audit(from, to).await?)
    }
}

#[cfg(test)]
mod tests;
