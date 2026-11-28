use super::{Policy, Vote};
use crate::{Checkpoint, Client};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::{Signer, SigningKey};
use rusqlite::{params, Connection, OpenFlags, TransactionBehavior};
use std::{path::Path, time::Duration};

/// Only public checkpoints are stored here. The signing key belongs to the operator.
pub struct Witness {
    db: Connection,
    policy: Policy,
    slot: u8,
}

impl Witness {
    pub fn provision(path: &Path, policy: Policy, slot: u8, pin: Checkpoint) -> Result<Self> {
        ensure!(usize::from(slot) < policy.keys.len(), "unknown slot");
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let temporary = tempfile::NamedTempFile::new_in(parent)?;
        {
            let mut db = Connection::open(temporary.path())?;
            db.pragma_update(None, "synchronous", "FULL")?;
            let tx = db.transaction()?;
            tx.execute_batch(
                "CREATE TABLE witness_head(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), policy BLOB NOT NULL,
                slot INTEGER NOT NULL, epoch INTEGER NOT NULL CHECK(epoch>=0),
                root BLOB NOT NULL CHECK(length(root)=32), parent BLOB CHECK(length(parent)=32)
            ) STRICT;",
            )?;
            tx.execute(
                "INSERT INTO witness_head VALUES(1,?,?,?,?,NULL)",
                params![policy.id, slot, i64::try_from(pin.epoch)?, pin.root],
            )?;
            tx.commit()?;
        }
        temporary.as_file().sync_all()?;
        temporary.persist_noclobber(path)?;
        #[cfg(unix)]
        std::fs::File::open(parent)?.sync_all()?;
        Self::open(path, policy, slot)
    }

    pub fn open(path: &Path, policy: Policy, slot: u8) -> Result<Self> {
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        db.busy_timeout(Duration::from_secs(5))?;
        let journal: String = db.pragma_query_value(None, "journal_mode", |r| r.get(0))?;
        ensure!(
            matches!(journal.as_str(), "delete" | "persist" | "truncate" | "wal"),
            "unsafe witness journal mode"
        );
        db.pragma_update(None, "synchronous", "FULL")?;
        ensure!(usize::from(slot) < policy.keys.len(), "unknown slot");
        let witness = Self { db, policy, slot };
        witness.checkpoint()?;
        Ok(witness)
    }

    pub fn checkpoint(&self) -> Result<Checkpoint> {
        let (epoch, root): (i64, [u8; 32]) = self
            .db
            .query_row(
                "SELECT epoch,root FROM witness_head WHERE singleton=1 AND policy=? AND slot=?",
                params![self.policy.id, self.slot],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .context("missing or incompatible witness pin")?;
        Ok(Checkpoint {
            epoch: epoch.try_into()?,
            root,
        })
    }

    pub async fn cosign(
        &mut self,
        key: &SigningKey,
        previous: Checkpoint,
        next: Checkpoint,
        proof: &[u8],
    ) -> Result<Vote> {
        ensure!(
            key.verifying_key() == self.policy.keys[usize::from(self.slot)],
            "wrong signing key"
        );
        let statement = self.policy.statement(previous, next)?;
        let current = self.checkpoint()?;
        ensure!(
            current == previous || current == next,
            "conflicting or stale witness checkpoint"
        );
        Client::from_pin(self.policy.vrf, previous)
            .advance(next, proof)
            .await?;
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let epoch = i64::try_from(next.epoch)?;
        let changed = tx.execute(
            "UPDATE witness_head SET epoch=?,parent=root,root=?
            WHERE singleton=1 AND policy=? AND slot=? AND epoch=? AND root=?",
            params![
                epoch,
                next.root,
                self.policy.id,
                self.slot,
                i64::try_from(previous.epoch)?,
                previous.root
            ],
        )?;
        if changed == 0 {
            let identical: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM witness_head
                WHERE singleton=1 AND policy=? AND slot=? AND epoch=? AND root=? AND parent=?)",
                params![self.policy.id, self.slot, epoch, next.root, previous.root],
                |r| r.get(0),
            )?;
            ensure!(identical, "conflicting or stale witness checkpoint");
        }
        tx.commit()?;
        Ok(Vote {
            slot: self.slot,
            signature: key.sign(&statement).to_bytes(),
        })
    }
}
