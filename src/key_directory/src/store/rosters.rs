use super::Store;
use crate::{
    contact::{canonical_id, public_key, DeviceAddress},
    roster::{label, Roster, MAX_SIGNED_BYTES},
    Checkpoint,
};
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::VerifyingKey;
use rusqlite::{params, Transaction, TransactionBehavior};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

const MAX_INTERMEDIATE: usize = 32;
const MAX_KEYPACKAGE_BYTES: usize = 16 * 1024;

/// Untrusted package and inclusion evidence supplied for one active roster device.
#[derive(Clone)]
pub struct DeviceKeyPackageEvidence {
    pub device_id: String,
    pub keypackage: Vec<u8>,
    pub lookup_proof: Vec<u8>,
}

/// An MLS KeyPackage validated against one active account-roster credential.
pub struct VerifiedKeyPackage {
    device_id: Uuid,
    reference: [u8; 32],
    bytes: Vec<u8>,
}

impl VerifiedKeyPackage {
    pub fn device_id(&self) -> Uuid {
        self.device_id
    }

    pub fn reference(&self) -> &[u8; 32] {
        &self.reference
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

/// Exact package set proven for one account and one locally pinned AKD checkpoint.
/// This is a detached verification result, not a send authorization or freshness token.
pub struct VerifiedPackageSet {
    account: Uuid,
    checkpoint: Checkpoint,
    roster_version: u64,
    packages: Vec<VerifiedKeyPackage>,
}

impl VerifiedPackageSet {
    pub fn account_id(&self) -> Uuid {
        self.account
    }

    pub fn checkpoint(&self) -> Checkpoint {
        self.checkpoint
    }

    pub fn roster_version(&self) -> u64 {
        self.roster_version
    }

    pub fn packages(&self) -> &[VerifiedKeyPackage] {
        &self.packages
    }
}

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
    ///
    /// Success means that this owner-authorized roster state was accepted and saved.
    /// It does not authorize sending. A roster with zero active devices is valid state
    /// and represents an account for which device sends must remain blocked.
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

    /// Verify the exact non-empty active KeyPackage set under one SQLCipher snapshot.
    ///
    /// The current directory roster must exactly equal the already accepted owner-signed
    /// roster. Every active device must have exactly one supplied package and a distinct
    /// fresh AKD device-key inclusion proof. Each package is decoded and validated by the
    /// same OpenMLS validator used by the native API, with its identity and signing key
    /// bound to the roster. Any missing, extra, duplicate, revoked, stale, or malformed
    /// evidence rejects the entire set.
    ///
    /// The returned object identifies the account and checkpoint for the verified bytes.
    /// It is not authorization to send: callers must separately enforce checkpoint
    /// freshness, witness policy, and serialization with the transport handoff.
    pub fn verify_package_set(
        &self,
        account: &str,
        expected_checkpoint: Checkpoint,
        roster_proof: &[u8],
        evidence: &[DeviceKeyPackageEvidence],
    ) -> Result<VerifiedPackageSet> {
        let account = canonical_id(account)?;
        // Serialize with checkpoint/roster writers and keep every subsequent read on
        // this connection until all proofs and KeyPackages have been validated.
        let tx = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        let checkpoint = self.checkpoint()?;
        ensure!(
            checkpoint == expected_checkpoint,
            "stale directory checkpoint"
        );

        let (root, accepted) = self.pinned_roster(account)?;
        let accepted = accepted.context("account roster has not been accepted")?;
        let (head, found) = self.lookup(label(account), roster_proof)?;
        ensure!(head == checkpoint, "roster proof checkpoint changed");
        ensure!(
            found.value.0 == accepted,
            "roster proof is not the currently accepted roster"
        );
        let roster = Roster::verify(&found.value.0, account, &root)?;
        ensure!(
            self.pinned_roster(account)?.0 == root,
            "account root changed during package verification"
        );
        let active: Vec<(Uuid, [u8; 32])> = roster
            .active_devices()
            .map(|(device, key)| (device, *key))
            .collect();
        ensure!(!active.is_empty(), "account has no active devices");
        ensure!(
            evidence.len() == active.len(),
            "package set does not exactly cover active devices"
        );

        let mut supplied = BTreeMap::new();
        for item in evidence {
            let device = canonical_id(&item.device_id)?;
            ensure!(
                supplied.insert(device, item).is_none(),
                "duplicate device package"
            );
        }
        ensure!(
            supplied.len() == active.len(),
            "package set does not exactly cover active devices"
        );

        let account_text = account.hyphenated().to_string();
        let mut references = BTreeSet::new();
        let mut packages = Vec::with_capacity(active.len());
        for (device, roster_key) in active {
            let item = supplied
                .remove(&device)
                .context("missing active-device package")?;
            ensure!(
                (1..=MAX_KEYPACKAGE_BYTES).contains(&item.keypackage.len()),
                "invalid KeyPackage length"
            );
            let address = DeviceAddress::parse(&account_text, &device.hyphenated().to_string())?;
            let (proof_checkpoint, key) =
                self.lookup_device_signing_key(&address, &item.lookup_proof)?;
            ensure!(
                proof_checkpoint == checkpoint && key.to_bytes() == roster_key,
                "device record is stale or differs from accepted roster"
            );
            let request = serde_json::json!({
                "identity": device.hyphenated().to_string(),
                "public_key": B64.encode(roster_key),
                "keypackage": B64.encode(&item.keypackage),
            });
            let validated: serde_json::Value = serde_json::from_str(
                &securemesh_crypto::validate_keypackage(&request.to_string())?,
            )?;
            let reference: [u8; 32] = B64
                .decode(
                    validated["reference"]
                        .as_str()
                        .context("missing package reference")?,
                )?
                .try_into()
                .map_err(|_| anyhow::anyhow!("invalid package reference length"))?;
            ensure!(
                references.insert(reference),
                "duplicate KeyPackage reference"
            );
            packages.push(VerifiedKeyPackage {
                device_id: device,
                reference,
                bytes: item.keypackage.clone(),
            });
        }
        ensure!(supplied.is_empty(), "extra device package");
        tx.commit()?;
        Ok(VerifiedPackageSet {
            account,
            checkpoint,
            roster_version: roster.version(),
            packages,
        })
    }
}
