//! A single explicitly provisioned directory for an existing native SQLCipher profile.
use crate::{
    witness::{Policy, Vote},
    Checkpoint, Client,
};
use akd::{AkdLabel, VerifyResult};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection, OpenFlags, Transaction, TransactionBehavior};
use std::{path::Path, time::Duration};

pub struct Store {
    db: Connection,
    owner: String,
    vrf_key: [u8; 32],
}

#[derive(Debug, PartialEq, Eq)]
pub enum Advancement {
    Committed,
    AlreadyCommitted,
}

impl Store {
    fn profile(path: &Path, password: &str, owner: &str, vrf_key: [u8; 32]) -> Result<Self> {
        ensure!(password.len() >= 16, "profile passphrase required");
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        db.pragma_update(None, "key", password)?;
        let cipher: String = db.query_row("PRAGMA cipher_version", [], |row| row.get(0))?;
        ensure!(
            cipher.split_whitespace().next() == Some("4.20.0"),
            "unsupported profile cipher"
        );
        db.busy_timeout(Duration::from_secs(5))?;
        let compatible: bool = db.query_row(
            "SELECT count(*)=6 AND min(version)=1 AND max(version)=6 FROM openmls_sqlite_storage_migrations",
            [], |row| row.get(0),
        )?;
        ensure!(compatible, "unsupported native profile schema");
        let identity: String = db.query_row(
            "SELECT value FROM app_meta WHERE key='identity'",
            [],
            |row| row.get(0),
        )?;
        ensure!(identity == owner, "profile identity mismatch");
        db.pragma_update(None, "synchronous", "FULL")?;
        Ok(Self {
            db,
            owner: identity,
            vrf_key,
        })
    }

    /// Explicit first-use action. Refuses to replace any existing checkpoint table.
    pub fn provision(
        path: &Path,
        password: &str,
        owner: &str,
        vrf_key: [u8; 32],
        initial: Checkpoint,
    ) -> Result<Self> {
        akd::ecvrf::VRFPublicKey::try_from(vrf_key.as_slice())
            .map_err(|_| anyhow::anyhow!("invalid VRF public key"))?;
        let mut store = Self::profile(path, password, owner, vrf_key)?;
        let tx = store
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "CREATE TABLE kt_checkpoint (
            slot INTEGER PRIMARY KEY CHECK(slot=1),
            schema_version INTEGER NOT NULL CHECK(schema_version=1),
            owner TEXT NOT NULL, vrf BLOB NOT NULL CHECK(length(vrf)=32),
            epoch INTEGER NOT NULL CHECK(epoch>=0), root BLOB NOT NULL CHECK(length(root)=32),
            previous_root BLOB CHECK(previous_root IS NULL OR length(previous_root)=32)
        ) STRICT;",
        )?;
        tx.execute("INSERT INTO kt_checkpoint(slot,schema_version,owner,vrf,epoch,root) VALUES(1,1,?,?,?,?)",
            params![owner,vrf_key,i64::try_from(initial.epoch)?,initial.root])?;
        tx.commit()?;
        Ok(store)
    }

    /// Opens an existing pinned state, checking the independently expected owner and VRF key.
    pub fn open(path: &Path, password: &str, owner: &str, vrf_key: [u8; 32]) -> Result<Self> {
        let store = Self::profile(path, password, owner, vrf_key)?;
        store.checkpoint()?;
        Ok(store)
    }

    pub fn checkpoint(&self) -> Result<Checkpoint> {
        let (epoch, root): (i64, [u8; 32]) = self
            .db
            .query_row(
                "SELECT epoch,root FROM kt_checkpoint WHERE slot=1 AND schema_version IN (1,2)
             AND owner=? AND vrf=? AND (previous_root IS NULL OR length(previous_root)=32)",
                params![self.owner, self.vrf_key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .context("missing or incompatible directory pin")?;
        Ok(Checkpoint {
            epoch: epoch.try_into()?,
            root,
        })
    }

    /// Verifies against the named SQL snapshot. Another process may subsequently advance it.
    pub fn lookup(&self, label: AkdLabel, proof: &[u8]) -> Result<(Checkpoint, VerifyResult)> {
        let checkpoint = self.checkpoint()?;
        let verified = Client::from_pin(self.vrf_key, checkpoint).lookup(label, proof)?;
        Ok((checkpoint, verified))
    }

    /// Explicitly enroll a separately authenticated witness configuration at the
    /// caller's known head. Ordinary proof-only advancement is then disabled.
    pub fn enroll_witnesses(&mut self, expected: Checkpoint, policy: &Policy) -> Result<()> {
        ensure!(policy.matches_vrf(&self.vrf_key), "directory VRF mismatch");
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let matches: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM kt_checkpoint
            WHERE slot=1 AND schema_version IN (1,2) AND owner=? AND vrf=? AND epoch=? AND root=?)",
            params![
                self.owner,
                self.vrf_key,
                i64::try_from(expected.epoch)?,
                expected.root
            ],
            |r| r.get(0),
        )?;
        ensure!(matches, "checkpoint changed before witness enrollment");
        let version: i64 = tx.query_row(
            "SELECT schema_version FROM kt_checkpoint WHERE slot=1",
            [],
            |r| r.get(0),
        )?;
        if version == 1 {
            tx.execute_batch("CREATE TABLE kt_checkpoint_v2 (
                slot INTEGER PRIMARY KEY CHECK(slot=1),schema_version INTEGER NOT NULL CHECK(schema_version=2),
                owner TEXT NOT NULL,vrf BLOB NOT NULL CHECK(length(vrf)=32),
                epoch INTEGER NOT NULL CHECK(epoch>=0),root BLOB NOT NULL CHECK(length(root)=32),
                previous_root BLOB CHECK(previous_root IS NULL OR length(previous_root)=32),
                policy BLOB NOT NULL CHECK(length(policy)=32)) STRICT;")?;
            tx.execute(
                "INSERT INTO kt_checkpoint_v2 SELECT slot,2,owner,vrf,epoch,root,previous_root,?
                FROM kt_checkpoint WHERE slot=1 AND schema_version=1",
                [policy.fingerprint()],
            )?;
            tx.execute_batch(
                "DROP TABLE kt_checkpoint; ALTER TABLE kt_checkpoint_v2 RENAME TO kt_checkpoint;",
            )?;
        }
        check_policy(&tx, Some(policy.fingerprint()))?;
        tx.commit()?;
        Ok(())
    }

    pub async fn advance_witnessed(
        &mut self,
        expected: Checkpoint,
        candidate: Checkpoint,
        proof: &[u8],
        policy: &Policy,
        votes: &[Vote],
    ) -> Result<Advancement> {
        ensure!(policy.matches_vrf(&self.vrf_key), "directory VRF mismatch");
        policy
            .verify_advance(expected, candidate, proof, votes)
            .await?;
        self.commit_advance(expected, candidate, Some(policy.fingerprint()))
    }

    pub async fn advance(
        &mut self,
        expected: Checkpoint,
        candidate: Checkpoint,
        proof: &[u8],
    ) -> Result<Advancement> {
        // No write lock is held during CPU-intensive proof verification.
        Client::from_pin(self.vrf_key, expected)
            .advance(candidate, proof)
            .await?;
        self.commit_advance(expected, candidate, None)
    }

    fn commit_advance(
        &mut self,
        expected: Checkpoint,
        candidate: Checkpoint,
        policy: Option<[u8; 32]>,
    ) -> Result<Advancement> {
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        check_policy(&tx, policy)?;
        let outcome = record(&tx, &self.owner, &self.vrf_key, expected, candidate)?;
        tx.commit()?;
        Ok(outcome)
    }
}

fn check_policy(tx: &Transaction<'_>, expected: Option<[u8; 32]>) -> Result<()> {
    let version: i64 = tx.query_row(
        "SELECT schema_version FROM kt_checkpoint WHERE slot=1",
        [],
        |r| r.get(0),
    )?;
    let actual = match version {
        1 => None,
        2 => Some(
            tx.query_row("SELECT policy FROM kt_checkpoint WHERE slot=1", [], |r| {
                r.get::<_, [u8; 32]>(0)
            })?,
        ),
        _ => anyhow::bail!("unsupported checkpoint version"),
    };
    ensure!(actual == expected, "witness policy required or mismatched");
    Ok(())
}

fn record(
    tx: &Transaction<'_>,
    owner: &str,
    key: &[u8; 32],
    expected: Checkpoint,
    candidate: Checkpoint,
) -> Result<Advancement> {
    let next_epoch = i64::try_from(candidate.epoch)?;
    let changed = tx.execute(
        "UPDATE kt_checkpoint SET previous_root=root,epoch=?1,root=?2
        WHERE slot=1 AND schema_version IN (1,2) AND owner=?3 AND vrf=?4 AND epoch=?5 AND root=?6",
        params![
            next_epoch,
            candidate.root,
            owner,
            key,
            i64::try_from(expected.epoch)?,
            expected.root
        ],
    )?;
    if changed == 1 {
        return Ok(Advancement::Committed);
    }
    let exact: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM kt_checkpoint WHERE slot=1 AND schema_version IN (1,2)
        AND owner=? AND vrf=? AND epoch=? AND root=? AND previous_root=?)",
        params![owner, key, next_epoch, candidate.root, expected.root],
        |row| row.get(0),
    )?;
    ensure!(
        exact,
        "checkpoint changed concurrently or pin is incompatible"
    );
    Ok(Advancement::AlreadyCommitted)
}

mod rosters;
pub use rosters::{DeviceKeyPackageEvidence, VerifiedKeyPackage, VerifiedPackageSet};
#[cfg(test)]
mod tests;
