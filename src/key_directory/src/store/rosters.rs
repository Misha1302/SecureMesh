use super::Store;
use crate::{
    contact::{canonical_id, public_key},
    roster::{label, Roster, MAX_SIGNED_BYTES},
    Checkpoint,
};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::VerifyingKey;
use rusqlite::{params, Transaction, TransactionBehavior};
use uuid::Uuid;

const MAX_INTERMEDIATE: usize = 32;

impl Store {
    /// Explicit independent provisioning. Repeating the same pin never resets its history.
    pub fn pin_account_root(&mut self, account: &str, root: [u8; 32]) -> Result<()> {
        let account = canonical_id(account)?;
        public_key(&root)?;
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS kt_account_roster(
            owner TEXT NOT NULL, vrf BLOB NOT NULL CHECK(length(vrf)=32),
            account BLOB NOT NULL CHECK(length(account)=16),
            root BLOB NOT NULL CHECK(length(root)=32), signed_roster BLOB,
            PRIMARY KEY(owner,vrf,account)
        ) STRICT;",
        )?;
        tx.execute(
            "INSERT INTO kt_account_roster(owner,vrf,account,root) VALUES(?,?,?,?)
          ON CONFLICT(owner,vrf,account) DO NOTHING",
            params![self.owner, self.vrf_key, account.as_bytes(), root],
        )?;
        let actual: [u8; 32] = tx.query_row(
            "SELECT root FROM kt_account_roster WHERE owner=? AND vrf=? AND account=?",
            params![self.owner, self.vrf_key, account.as_bytes()],
            |r| r.get(0),
        )?;
        ensure!(actual == root, "account root differs from stored pin");
        tx.commit()?;
        Ok(())
    }

    fn pinned_roster(&self, account: Uuid) -> Result<(VerifyingKey, Option<Vec<u8>>)> {
        let (root, bytes): ([u8;32],Option<Vec<u8>>) = self.db.query_row(
          "SELECT root,signed_roster FROM kt_account_roster WHERE owner=? AND vrf=? AND account=?",
          params![self.owner,self.vrf_key,account.as_bytes()],|r|Ok((r.get(0)?,r.get(1)?)))
          .context("missing account root pin")?;
        Ok((public_key(&root)?, bytes))
    }

    /// Historical local authorization; this read alone makes no freshness or dispatch decision.
    pub fn saved_roster(&self, account: &str) -> Result<Option<Roster>> {
        let account = canonical_id(account)?;
        let (root, saved) = self.pinned_roster(account)?;
        saved
            .map(|b| Roster::verify(&b, account, &root))
            .transpose()
    }

    /// Verify a bounded signature chain ending in an AKD lookup at the durable head,
    /// and commit only if both the directory head and local account history still match.
    pub fn accept_roster(
        &self,
        account: &str,
        intermediates: &[Vec<u8>],
        proof: &[u8],
    ) -> Result<(Checkpoint, Roster)> {
        ensure!(
            intermediates.len() <= MAX_INTERMEDIATE
                && intermediates.iter().all(|b| b.len() <= MAX_SIGNED_BYTES),
            "roster chain exceeds limits"
        );
        let account = canonical_id(account)?;
        let (root, saved) = self.pinned_roster(account)?;
        let (head, found) = self.lookup(label(account), proof)?;
        let next = Roster::verify(&found.value.0, account, &root)?;
        let replay = saved.as_deref() == Some(found.value.0.as_slice());
        let mut prior = if replay {
            None
        } else {
            saved
                .as_ref()
                .map(|raw| Roster::verify(raw, account, &root))
                .transpose()?
        };
        for (i, raw) in intermediates.iter().enumerate() {
            let entry = Roster::verify(raw, account, &root)?;
            if !replay || i != 0 {
                entry.follows(prior.as_ref())?;
            }
            prior = Some(entry);
        }
        if !replay || !intermediates.is_empty() {
            next.follows(prior.as_ref())?;
        }
        let tx = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        ensure!(
            self.checkpoint()? == head,
            "directory checkpoint advanced concurrently"
        );
        let (current_root, current) = self.pinned_roster(account)?;
        ensure!(current_root == root, "account root changed concurrently");
        if current.as_deref() != Some(found.value.0.as_slice()) {
            ensure!(current == saved, "roster advanced concurrently");
            let rows = tx.execute("UPDATE kt_account_roster SET signed_roster=? WHERE owner=? AND vrf=? AND account=? AND root=?",
              params![found.value.0,self.owner,self.vrf_key,account.as_bytes(),root.to_bytes()])?;
            ensure!(rows == 1, "missing account pin");
        }
        tx.commit()?;
        Ok((head, next))
    }
}
