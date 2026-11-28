//! Fixed four-witness policy. Keys and directory identity are independently provisioned.
use crate::{Checkpoint, Client};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_CHECKPOINT_AGE_SECS: u64 = 300;
pub const MAX_WITNESS_FUTURE_SKEW_SECS: u64 = 30;
pub const MAX_WITNESS_SPREAD_SECS: u64 = 60;
pub const MAX_LOCAL_CLOCK_ROLLBACK_SECS: u64 = 60;

const OBSERVATION_DOMAIN: &[u8] = b"SecureMesh/AKD/3-of-4/freshness/v1\0";
const OBSERVATION_BYTES: usize = 1 + 8 + 32 + 8 + 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Observation {
    slot: u8,
    checkpoint: Checkpoint,
    observed_at: u64,
    signature: [u8; 64],
}

impl Observation {
    pub fn from_signature(
        slot: u8,
        checkpoint: Checkpoint,
        observed_at_unix_secs: u64,
        signature: [u8; 64],
    ) -> Self {
        Self {
            slot,
            checkpoint,
            observed_at: observed_at_unix_secs,
            signature,
        }
    }

    pub fn slot(&self) -> u8 {
        self.slot
    }

    pub fn checkpoint(&self) -> Checkpoint {
        self.checkpoint
    }

    pub fn observed_at_unix_secs(&self) -> u64 {
        self.observed_at
    }

    fn sign(
        policy: &Policy,
        slot: u8,
        checkpoint: Checkpoint,
        observed_at: u64,
        key: &SigningKey,
    ) -> Result<Self> {
        let index = usize::from(slot);
        ensure!(index < policy.keys.len(), "unknown witness slot");
        ensure!(
            key.verifying_key() == policy.keys[index],
            "wrong witness signing key"
        );
        let signature = key
            .sign(&policy.observation_statement(checkpoint, observed_at))
            .to_bytes();
        Ok(Self::from_signature(
            slot,
            checkpoint,
            observed_at,
            signature,
        ))
    }

    pub(crate) fn encode_set(observations: &[Self]) -> Result<Vec<u8>> {
        ensure!(
            (3..=4).contains(&observations.len()),
            "invalid observation count"
        );
        let mut output = Vec::with_capacity(1 + observations.len() * OBSERVATION_BYTES);
        output.push(observations.len() as u8);
        for observation in observations {
            output.push(observation.slot);
            output.extend_from_slice(&observation.checkpoint.epoch.to_be_bytes());
            output.extend_from_slice(&observation.checkpoint.root);
            output.extend_from_slice(&observation.observed_at.to_be_bytes());
            output.extend_from_slice(&observation.signature);
        }
        Ok(output)
    }

    pub(crate) fn decode_set(input: &[u8]) -> Result<Vec<Self>> {
        ensure!(!input.is_empty(), "missing witness observations");
        let count = usize::from(input[0]);
        ensure!((3..=4).contains(&count), "invalid observation count");
        ensure!(
            input.len() == 1 + count * OBSERVATION_BYTES,
            "invalid observation encoding"
        );
        let mut cursor = 1;
        let mut observations = Vec::with_capacity(count);
        for _ in 0..count {
            let slot = take::<1>(input, &mut cursor)?[0];
            let epoch = u64::from_be_bytes(take(input, &mut cursor)?);
            let root = take(input, &mut cursor)?;
            let observed_at = u64::from_be_bytes(take(input, &mut cursor)?);
            let signature = take(input, &mut cursor)?;
            observations.push(Self::from_signature(
                slot,
                Checkpoint { epoch, root },
                observed_at,
                signature,
            ));
        }
        Ok(observations)
    }
}

fn take<const N: usize>(input: &[u8], cursor: &mut usize) -> Result<[u8; N]> {
    let end = cursor
        .checked_add(N)
        .context("observation length overflow")?;
    let bytes = input
        .get(*cursor..end)
        .context("truncated witness observation")?;
    *cursor = end;
    Ok(bytes.try_into()?)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FreshnessReceipt {
    checkpoint: Checkpoint,
    policy: [u8; 32],
    observed_at: u64,
    valid_until: u64,
}

impl FreshnessReceipt {
    pub fn checkpoint(&self) -> Checkpoint {
        self.checkpoint
    }
    pub fn policy_fingerprint(&self) -> [u8; 32] {
        self.policy
    }
    pub fn observed_at_unix_secs(&self) -> u64 {
        self.observed_at
    }
    pub fn valid_until_unix_secs(&self) -> u64 {
        self.valid_until
    }
}

pub(crate) fn unix_time_seconds() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock precedes Unix epoch")?
        .as_secs())
}

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
        akd::ecvrf::VRFPublicKey::try_from(vrf.as_slice())
            .map_err(|_| anyhow::anyhow!("invalid directory VRF key"))?;
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

    pub fn observation_statement(&self, checkpoint: Checkpoint, observed_at: u64) -> Vec<u8> {
        let mut bytes = OBSERVATION_DOMAIN.to_vec();
        bytes.extend_from_slice(&self.id);
        bytes.extend_from_slice(&checkpoint.epoch.to_be_bytes());
        bytes.extend_from_slice(&checkpoint.root);
        bytes.extend_from_slice(&observed_at.to_be_bytes());
        bytes
    }

    pub(crate) fn verify_freshness_at(
        &self,
        checkpoint: Checkpoint,
        now: u64,
        observations: &[Observation],
    ) -> Result<FreshnessReceipt> {
        ensure!(now > 0, "invalid local time");
        ensure!(
            (3..=4).contains(&observations.len()),
            "expected three or four witness observations"
        );
        let mut slots = [false; 4];
        let mut times = Vec::with_capacity(observations.len());
        for observation in observations {
            ensure!(
                observation.checkpoint == checkpoint,
                "witness observed a different checkpoint"
            );
            ensure!(observation.observed_at > 0, "invalid witness time");
            ensure!(
                observation.observed_at <= now.saturating_add(MAX_WITNESS_FUTURE_SKEW_SECS),
                "witness time is too far in the future"
            );
            ensure!(
                now.saturating_sub(observation.observed_at) <= MAX_CHECKPOINT_AGE_SECS,
                "witness observation is stale"
            );
            let index = usize::from(observation.slot);
            ensure!(
                index < slots.len() && !slots[index],
                "unknown or duplicate witness"
            );
            let statement = self.observation_statement(checkpoint, observation.observed_at);
            self.keys[index]
                .verify_strict(&statement, &Signature::from_bytes(&observation.signature))?;
            slots[index] = true;
            times.push(observation.observed_at);
        }
        times.sort_unstable();
        let earliest = times[0];
        let latest = *times.last().expect("quorum is non-empty");
        ensure!(
            latest - earliest <= MAX_WITNESS_SPREAD_SECS,
            "witness clock spread is too large"
        );
        let valid_until = earliest
            .checked_add(MAX_CHECKPOINT_AGE_SECS)
            .context("freshness expiry overflow")?;
        Ok(FreshnessReceipt {
            checkpoint,
            policy: self.id,
            observed_at: earliest,
            valid_until,
        })
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

#[cfg(test)]
mod freshness_tests {
    use super::*;

    fn fixture() -> (Policy, [SigningKey; 4], Checkpoint) {
        let keys = [1, 2, 3, 4].map(|i| SigningKey::from_bytes(&[i; 32]));
        let policy = Policy::new(
            [8; 32],
            SigningKey::from_bytes(&[9; 32]).verifying_key().to_bytes(),
            keys.each_ref().map(|key| key.verifying_key().to_bytes()),
        )
        .unwrap();
        let checkpoint = Checkpoint {
            epoch: 17,
            root: [10; 32],
        };
        (policy, keys, checkpoint)
    }

    fn observations(
        policy: &Policy,
        keys: &[SigningKey; 4],
        checkpoint: Checkpoint,
        times: [u64; 3],
    ) -> Vec<Observation> {
        times
            .into_iter()
            .enumerate()
            .map(|(slot, time)| {
                Observation::sign(policy, slot as u8, checkpoint, time, &keys[slot]).unwrap()
            })
            .collect()
    }

    #[test]
    fn freshness_requires_distinct_same_checkpoint_recent_signatures() -> Result<()> {
        let (policy, keys, checkpoint) = fixture();
        let values = observations(&policy, &keys, checkpoint, [9_990, 9_995, 10_010]);
        let receipt = policy.verify_freshness_at(checkpoint, 10_000, &values)?;
        assert_eq!(receipt.checkpoint(), checkpoint);
        assert_eq!(receipt.policy_fingerprint(), policy.fingerprint());
        assert_eq!(receipt.observed_at_unix_secs(), 9_990);
        assert_eq!(
            receipt.valid_until_unix_secs(),
            9_990 + MAX_CHECKPOINT_AGE_SECS
        );
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &values[..2])
            .is_err());

        let mut duplicate = values.clone();
        duplicate[2] = duplicate[1];
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &duplicate)
            .is_err());
        let mut wrong_head = values.clone();
        wrong_head[0] = Observation::sign(
            &policy,
            0,
            Checkpoint {
                epoch: 18,
                ..checkpoint
            },
            9_990,
            &keys[0],
        )?;
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &wrong_head)
            .is_err());
        let mut invalid = values;
        let mut signature = invalid[0].signature;
        signature[0] ^= 1;
        invalid[0] = Observation::from_signature(0, checkpoint, 9_990, signature);
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &invalid)
            .is_err());
        Ok(())
    }

    #[test]
    fn freshness_rejects_old_future_and_skewed_witness_times() -> Result<()> {
        let (policy, keys, checkpoint) = fixture();
        let old = observations(&policy, &keys, checkpoint, [9_699, 9_700, 9_700]);
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &old)
            .is_err());
        let future = observations(&policy, &keys, checkpoint, [10_031, 10_031, 10_031]);
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &future)
            .is_err());
        let skewed = observations(&policy, &keys, checkpoint, [9_940, 10_000, 10_010]);
        assert!(policy
            .verify_freshness_at(checkpoint, 10_000, &skewed)
            .is_err());
        let accepted = observations(&policy, &keys, checkpoint, [9_700, 9_700, 9_700]);
        policy.verify_freshness_at(checkpoint, 10_000, &accepted)?;
        Ok(())
    }

    #[test]
    fn stored_observations_have_a_bounded_unambiguous_encoding() -> Result<()> {
        let (policy, keys, checkpoint) = fixture();
        let values = observations(&policy, &keys, checkpoint, [9_990, 9_995, 10_000]);
        let encoded = Observation::encode_set(&values)?;
        assert_eq!(Observation::decode_set(&encoded)?, values);
        let mut trailing = encoded.clone();
        trailing.push(0);
        assert!(Observation::decode_set(&trailing).is_err());
        assert!(Observation::decode_set(&encoded[..encoded.len() - 1]).is_err());
        Ok(())
    }
}

mod ledger;
pub use ledger::Witness;
