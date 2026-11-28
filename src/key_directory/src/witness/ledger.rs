use super::{unix_time_seconds, Observation, Policy, Vote};
use crate::{Checkpoint, Client};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::{Signer, SigningKey};
use rusqlite::{params, Connection, OpenFlags, Transaction, TransactionBehavior};
use std::{path::Path, time::Duration};

/// Only public checkpoints are stored here. The signing key belongs to the operator.
pub struct Witness {
    db: Connection,
    policy: Policy,
    slot: u8,
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;
    use rusqlite::Transaction;

    #[test]
    fn observation_serializes_with_concurrent_durable_advance() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("witness.db");
        let keys = [21, 24, 25, 26].map(|seed| SigningKey::from_bytes(&[seed; 32]));
        let signing = keys[0].clone();
        let vrf = SigningKey::from_bytes(&[22; 32]).verifying_key().to_bytes();
        let policy = Policy::new(
            [23; 32],
            vrf,
            keys.each_ref().map(|key| key.verifying_key().to_bytes()),
        )?;
        let old = Checkpoint {
            epoch: 5,
            root: [27; 32],
        };
        let next = Checkpoint {
            epoch: 6,
            root: [28; 32],
        };
        Witness::provision(&path, policy.clone(), 0, old)?;

        let blocker = Connection::open(&path)?;
        let tx = Transaction::new_unchecked(&blocker, TransactionBehavior::Immediate)?;
        tx.execute(
            "UPDATE witness_head SET epoch=?,parent=root,root=? WHERE singleton=1",
            params![i64::try_from(next.epoch)?, next.root],
        )?;
        let thread_path = path.clone();
        let thread_policy = policy.clone();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let observer = std::thread::spawn(move || -> Result<Observation> {
            let witness = Witness::open(&thread_path, thread_policy, 0)?;
            started_tx.send(()).unwrap();
            witness.observe_current(&signing)
        });
        started_rx.recv()?;
        // Let observe_current contend on BEGIN IMMEDIATE while the advancement
        // remains uncommitted. It must read only after the durable commit.
        std::thread::sleep(Duration::from_millis(100));
        tx.commit()?;
        let observation = observer.join().expect("observer thread panicked")?;
        assert_eq!(observation.checkpoint(), next);
        Ok(())
    }
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

    /// Sign a fresh observation only for this witness's durable current checkpoint.
    /// Each real operator obtains its own observation; callers cannot use this method
    /// to manufacture a quorum from a single witness.
    pub fn observe_current(&self, key: &SigningKey) -> Result<Observation> {
        ensure!(
            key.verifying_key() == self.policy.keys[usize::from(self.slot)],
            "wrong signing key"
        );
        // Serialize the read, timestamp, and signature with durable checkpoint
        // advancement so an observation cannot race an in-flight cosign commit.
        let tx = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        let checkpoint = self.checkpoint()?;
        let observed_at = unix_time_seconds()?;
        let observation = Observation::sign(&self.policy, self.slot, checkpoint, observed_at, key)?;
        tx.commit()?;
        Ok(observation)
    }
}
