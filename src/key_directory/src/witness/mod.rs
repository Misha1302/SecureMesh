//! Fixed four-witness policy. Keys and directory identity are independently provisioned.
use crate::{Checkpoint, Client};
use anyhow::{ensure, Result};
use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy)]
pub struct Vote {
    pub slot: u8,
    pub signature: [u8; 64],
}

#[derive(Clone)]
pub struct Policy {
    id: [u8; 32],
    vrf: [u8; 32],
    keys: [VerifyingKey; 4],
}

impl Policy {
    pub fn new(directory: [u8; 32], vrf: [u8; 32], roster: [[u8; 32]; 4]) -> Result<Self> {
        let mut keys = Vec::with_capacity(4);
        let mut hash = Sha256::new();
        hash.update(b"SecureMesh/AKD/3-of-4/config/v1\0");
        hash.update(directory);
        hash.update(vrf);
        for raw in roster {
            let key = VerifyingKey::from_bytes(&raw)?;
            let point = key.to_edwards();
            ensure!(
                !key.is_weak() && point.is_torsion_free() && point.compress().to_bytes() == raw,
                "invalid witness key"
            );
            ensure!(!keys.contains(&key), "duplicate witness key");
            keys.push(key);
            hash.update(raw);
        }
        Ok(Self {
            id: hash.finalize().into(),
            vrf,
            keys: keys.try_into().expect("four witness slots"),
        })
    }

    pub(crate) fn matches_vrf(&self, vrf: &[u8; 32]) -> bool {
        &self.vrf == vrf
    }

    pub fn fingerprint(&self) -> [u8; 32] {
        self.id
    }

    pub fn statement(&self, previous: Checkpoint, next: Checkpoint) -> Result<Vec<u8>> {
        ensure!(
            previous.epoch.checked_add(1) == Some(next.epoch),
            "expected next epoch"
        );
        let mut bytes = b"SecureMesh/AKD/3-of-4/transition/v1\0".to_vec();
        bytes.extend_from_slice(&self.id);
        for head in [previous, next] {
            bytes.extend_from_slice(&head.epoch.to_be_bytes());
            bytes.extend_from_slice(&head.root);
        }
        Ok(bytes)
    }

    pub fn verify(&self, previous: Checkpoint, next: Checkpoint, votes: &[Vote]) -> Result<()> {
        ensure!(
            (3..=4).contains(&votes.len()),
            "expected three or four votes"
        );
        let statement = self.statement(previous, next)?;
        let mut counted = [false; 4];
        for vote in votes {
            let i = usize::from(vote.slot);
            ensure!(
                i < counted.len() && !counted[i],
                "unknown or duplicate witness"
            );
            self.keys[i].verify_strict(&statement, &Signature::from_bytes(&vote.signature))?;
            counted[i] = true;
        }
        Ok(())
    }

    /// Verifies the pinned witness threshold and the actual AKD consistency proof.
    pub async fn verify_advance(
        &self,
        previous: Checkpoint,
        next: Checkpoint,
        proof: &[u8],
        votes: &[Vote],
    ) -> Result<()> {
        self.verify(previous, next, votes)?;
        Client::from_pin(self.vrf, previous)
            .advance(next, proof)
            .await
    }
}

mod ledger;
pub use ledger::Witness;
