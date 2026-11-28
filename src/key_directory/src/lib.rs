//! AKD proof verification for an independently provisioned directory key and checkpoint.
use akd::proto::specs::types as wire;
use akd::{AkdLabel, AppendOnlyProof, Digest, LookupProof, VerifyResult, WhatsAppV1Configuration};
use anyhow::{ensure, Result};
use protobuf::Message;

/// A prototype response-size budget. Larger proofs require a different resource policy.
pub const MAX_PROOF_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Checkpoint {
    pub epoch: u64,
    pub root: Digest,
}

pub struct Client {
    vrf_key: [u8; 32],
    checkpoint: Checkpoint,
}

impl Client {
    /// The caller authenticates both inputs separately from lookup and audit replies.
    pub fn from_pin(vrf_key: [u8; 32], checkpoint: Checkpoint) -> Self {
        Self {
            vrf_key,
            checkpoint,
        }
    }

    pub fn checkpoint(&self) -> Checkpoint {
        self.checkpoint
    }

    pub fn lookup(&self, label: AkdLabel, response: &[u8]) -> Result<VerifyResult> {
        ensure!(response.len() <= MAX_PROOF_BYTES, "oversized lookup proof");
        let wire = wire::LookupProof::parse_from_bytes(response)?;
        let proof = LookupProof::try_from(&wire)
            .map_err(|_| anyhow::anyhow!("invalid lookup proof encoding"))?;
        ensure!(
            proof.version > 0
                && proof.version <= proof.epoch
                && proof.epoch <= self.checkpoint.epoch,
            "invalid record version or epoch"
        );
        akd::client::lookup_verify::<WhatsAppV1Configuration>(
            &self.vrf_key,
            self.checkpoint.root,
            self.checkpoint.epoch,
            label,
            proof,
        )
        .map_err(|_| anyhow::anyhow!("lookup proof rejected"))
    }

    /// Advance one epoch. Skipped epochs must be verified in order. A successful
    /// append-only proof establishes continuity; the caller authenticates the candidate.
    pub async fn advance(&mut self, candidate: Checkpoint, response: &[u8]) -> Result<()> {
        let previous = self.checkpoint;
        ensure!(
            previous.epoch.checked_add(1) == Some(candidate.epoch),
            "expected next epoch"
        );
        ensure!(
            response.len() <= MAX_PROOF_BYTES,
            "oversized consistency proof"
        );
        let wire = wire::AppendOnlyProof::parse_from_bytes(response)?;
        let proof = AppendOnlyProof::try_from(&wire)
            .map_err(|_| anyhow::anyhow!("invalid consistency proof encoding"))?;
        ensure!(
            proof.epochs.as_slice() == [previous.epoch] && proof.proofs.len() == 1,
            "invalid consistency interval"
        );
        akd::auditor::audit_verify::<WhatsAppV1Configuration>(
            vec![previous.root, candidate.root],
            proof,
        )
        .await?;
        self.checkpoint = candidate;
        Ok(())
    }
}

pub fn encode_lookup(proof: &LookupProof) -> Result<Vec<u8>> {
    Ok(wire::LookupProof::from(proof).write_to_bytes()?)
}

pub fn encode_consistency(proof: &AppendOnlyProof) -> Result<Vec<u8>> {
    Ok(wire::AppendOnlyProof::from(proof).write_to_bytes()?)
}

pub mod store;
