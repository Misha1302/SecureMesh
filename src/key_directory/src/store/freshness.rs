use super::{check_policy, Store};
use crate::{
    witness::{
        unix_time_seconds, FreshnessReceipt, Observation, Policy, MAX_LOCAL_CLOCK_ROLLBACK_SECS,
    },
    Checkpoint,
};
use anyhow::{ensure, Result};
use rusqlite::{params, OptionalExtension, Transaction, TransactionBehavior};

impl Store {
    fn persist_clock_floor(
        tx: &Transaction<'_>,
        owner: &str,
        vrf: &[u8; 32],
        now: u64,
    ) -> Result<(bool, u64)> {
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS kt_checkpoint_clock (
                owner TEXT NOT NULL, vrf BLOB NOT NULL CHECK(length(vrf)=32),
                local_time INTEGER NOT NULL CHECK(local_time>0), PRIMARY KEY(owner,vrf)
            ) STRICT;",
        )?;
        let prior: Option<i64> = tx
            .query_row(
                "SELECT local_time FROM kt_checkpoint_clock WHERE owner=? AND vrf=?",
                params![owner, vrf],
                |row| row.get(0),
            )
            .optional()?;
        let prior = prior.map(u64::try_from).transpose()?;
        // Upgrade the high-water mark used by the initial freshness version.
        let legacy_exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='kt_checkpoint_freshness')",
            [],
            |row| row.get(0),
        )?;
        let legacy = if legacy_exists {
            tx.query_row(
                "SELECT local_time FROM kt_checkpoint_freshness WHERE owner=? AND vrf=?",
                params![owner, vrf],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(u64::try_from)
            .transpose()?
        } else {
            None
        };
        let prior = prior.into_iter().chain(legacy).max();
        let within_skew = prior
            .map(|prior| now.saturating_add(MAX_LOCAL_CLOCK_ROLLBACK_SECS) >= prior)
            .unwrap_or(true);
        let floor = prior.unwrap_or(0).max(now);
        tx.execute(
            "INSERT INTO kt_checkpoint_clock(owner,vrf,local_time) VALUES(?,?,?)
             ON CONFLICT(owner,vrf) DO UPDATE SET local_time=excluded.local_time",
            params![owner, vrf, i64::try_from(floor)?],
        )?;
        Ok((within_skew, floor))
    }

    /// Verify and persist a 3-of-4 fresh observation quorum for the current pinned head.
    /// This records a freshness decision; it does not authorize transport dispatch.
    pub fn accept_checkpoint_freshness(
        &self,
        policy: &Policy,
        observations: &[Observation],
    ) -> Result<FreshnessReceipt> {
        self.accept_checkpoint_freshness_at(policy, observations, None)
    }

    fn accept_checkpoint_freshness_at(
        &self,
        policy: &Policy,
        observations: &[Observation],
        now: Option<u64>,
    ) -> Result<FreshnessReceipt> {
        ensure!(policy.matches_vrf(&self.vrf_key), "directory VRF mismatch");
        let tx = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        let now = match now {
            Some(now) => now,
            None => unix_time_seconds()?,
        };
        let (clock_ok, effective_now) =
            Self::persist_clock_floor(&tx, &self.owner, &self.vrf_key, now)?;
        if !clock_ok {
            tx.commit()?;
            anyhow::bail!("local clock moved backward");
        }
        let checkpoint =
            match check_policy(&tx, Some(policy.fingerprint())).and_then(|_| self.checkpoint()) {
                Ok(checkpoint) => checkpoint,
                Err(error) => {
                    tx.commit()?;
                    return Err(error);
                }
            };
        // Check future skew against actual wall time, then age against the durable
        // high-water so a small tolerated rollback cannot revive old evidence.
        let receipt = match policy
            .verify_freshness_at(checkpoint, now, observations)
            .and_then(|_| policy.verify_freshness_at(checkpoint, effective_now, observations))
        {
            Ok(receipt) => receipt,
            Err(error) => {
                // Preserve the observed system time even when evidence is invalid.
                tx.commit()?;
                return Err(error);
            }
        };
        ensure!(
            receipt.policy_fingerprint() == policy.fingerprint(),
            "freshness policy mismatch"
        );
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS kt_checkpoint_freshness (
                owner TEXT NOT NULL,
                vrf BLOB NOT NULL CHECK(length(vrf)=32),
                policy BLOB NOT NULL CHECK(length(policy)=32),
                epoch INTEGER NOT NULL CHECK(epoch>=0),
                root BLOB NOT NULL CHECK(length(root)=32),
                observed_at INTEGER NOT NULL CHECK(observed_at>0),
                valid_until INTEGER NOT NULL CHECK(valid_until>=observed_at),
                local_time INTEGER NOT NULL CHECK(local_time>0),
                observations BLOB NOT NULL,
                PRIMARY KEY(owner,vrf)
            ) STRICT;",
        )?;
        let prior: Result<Option<(i64, [u8; 32], [u8; 32], i64, i64, i64)>> = tx
            .query_row(
                "SELECT epoch,root,policy,observed_at,valid_until,local_time
                 FROM kt_checkpoint_freshness WHERE owner=? AND vrf=?",
                params![self.owner, self.vrf_key],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .optional()
            .map_err(anyhow::Error::from);
        let prior = match prior {
            Ok(prior) => prior,
            Err(error) => {
                tx.commit()?;
                return Err(error);
            }
        };
        let validated_local_time = (|| -> Result<u64> {
            let mut local_time = effective_now;
            if let Some((epoch, root, prior_policy, observed_at, _, prior_local_time)) = prior {
                let previous = Checkpoint {
                    epoch: epoch.try_into()?,
                    root,
                };
                ensure!(
                    prior_policy == policy.fingerprint(),
                    "freshness policy changed"
                );
                ensure!(
                    checkpoint.epoch > previous.epoch
                        || (checkpoint.epoch == previous.epoch && checkpoint.root == previous.root),
                    "checkpoint freshness rollback"
                );
                ensure!(
                    i64::try_from(receipt.observed_at_unix_secs())? >= observed_at,
                    "witness observation time rollback"
                );
                let prior_local_time: u64 = prior_local_time.try_into()?;
                ensure!(
                    now.saturating_add(MAX_LOCAL_CLOCK_ROLLBACK_SECS) >= prior_local_time,
                    "local clock moved backward"
                );
                local_time = local_time.max(prior_local_time);
            }
            Ok(local_time)
        })();
        let local_time = match validated_local_time {
            Ok(local_time) => local_time,
            Err(error) => {
                tx.commit()?;
                return Err(error);
            }
        };
        let observations = Observation::encode_set(observations)?;
        tx.execute(
            "INSERT INTO kt_checkpoint_freshness(owner,vrf,policy,epoch,root,observed_at,valid_until,local_time,observations)
             VALUES(?,?,?,?,?,?,?,?,?)
             ON CONFLICT(owner,vrf) DO UPDATE SET policy=excluded.policy,epoch=excluded.epoch,
             root=excluded.root,observed_at=excluded.observed_at,valid_until=excluded.valid_until,
             local_time=excluded.local_time,observations=excluded.observations",
            params![
                self.owner,
                self.vrf_key,
                policy.fingerprint(),
                i64::try_from(checkpoint.epoch)?,
                checkpoint.root,
                i64::try_from(receipt.observed_at_unix_secs())?,
                i64::try_from(receipt.valid_until_unix_secs())?,
                i64::try_from(local_time)?,
                observations,
            ],
        )?;
        tx.commit()?;
        Ok(receipt)
    }

    /// Recheck the stored signed observations against the current pin and local clock.
    /// The receipt expires after the fixed prototype age window.
    pub fn current_checkpoint_freshness(&self, policy: &Policy) -> Result<FreshnessReceipt> {
        self.current_checkpoint_freshness_at(policy, None)
    }

    fn current_checkpoint_freshness_at(
        &self,
        policy: &Policy,
        now: Option<u64>,
    ) -> Result<FreshnessReceipt> {
        ensure!(policy.matches_vrf(&self.vrf_key), "directory VRF mismatch");
        let tx = Transaction::new_unchecked(&self.db, TransactionBehavior::Immediate)?;
        let now = match now {
            Some(now) => now,
            None => unix_time_seconds()?,
        };
        let (clock_ok, effective_now) =
            Self::persist_clock_floor(&tx, &self.owner, &self.vrf_key, now)?;
        if !clock_ok {
            tx.commit()?;
            anyhow::bail!("local clock moved backward");
        }
        let precheck =
            check_policy(&tx, Some(policy.fingerprint())).and_then(|_| self.checkpoint());
        let checkpoint = match precheck {
            Ok(checkpoint) => checkpoint,
            Err(error) => {
                tx.commit()?;
                return Err(error);
            }
        };
        let row: Result<Option<(i64, [u8; 32], [u8; 32], i64, i64, i64, Vec<u8>)>> = tx
            .query_row(
                "SELECT epoch,root,policy,observed_at,valid_until,local_time,observations
                 FROM kt_checkpoint_freshness WHERE owner=? AND vrf=?",
                params![self.owner, self.vrf_key],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                    ))
                },
            )
            .optional()
            .map_err(anyhow::Error::from);
        let row = match row {
            Ok(Some(row)) => row,
            Ok(None) => {
                tx.commit()?;
                anyhow::bail!("no accepted checkpoint freshness quorum");
            }
            Err(error) => {
                tx.commit()?;
                return Err(error);
            }
        };
        let (epoch, root, stored_policy, observed_at, valid_until, local_time, raw) = row;
        let stored_checkpoint = Checkpoint {
            epoch: epoch.try_into()?,
            root,
        };
        if stored_checkpoint != checkpoint || stored_policy != policy.fingerprint() {
            tx.commit()?;
            anyhow::bail!("checkpoint freshness anchor mismatch");
        }
        let prior_local_time: u64 = local_time.try_into()?;
        let observations = match Observation::decode_set(&raw) {
            Ok(observations) => observations,
            Err(error) => {
                tx.commit()?;
                return Err(error);
            }
        };
        let receipt = match policy
            .verify_freshness_at(checkpoint, now, &observations)
            .and_then(|_| policy.verify_freshness_at(checkpoint, effective_now, &observations))
        {
            Ok(receipt) => receipt,
            Err(error) => {
                tx.commit()?;
                return Err(error);
            }
        };
        if i64::try_from(receipt.observed_at_unix_secs())? != observed_at
            || i64::try_from(receipt.valid_until_unix_secs())? != valid_until
        {
            tx.commit()?;
            anyhow::bail!("stored freshness metadata differs from witness evidence");
        }
        if effective_now > receipt.valid_until_unix_secs() {
            tx.commit()?;
            anyhow::bail!("checkpoint freshness expired");
        }
        tx.execute(
            "UPDATE kt_checkpoint_freshness SET local_time=? WHERE owner=? AND vrf=?",
            params![
                i64::try_from(effective_now.max(prior_local_time))?,
                self.owner,
                self.vrf_key
            ],
        )?;
        tx.commit()?;
        Ok(receipt)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::witness::{unix_time_seconds, Observation, MAX_LOCAL_CLOCK_ROLLBACK_SECS};
    use ed25519_dalek::{Signer, SigningKey};
    use securemesh_crypto::api::NativeClient;
    use std::path::Path;

    const OWNER: &str = "10000000-0000-4000-8000-000000000001";
    const PASSWORD: &str = "freshness test profile password";

    fn fixture() -> (Policy, [SigningKey; 4], [u8; 32], Checkpoint) {
        let keys = [1, 2, 3, 4].map(|i| SigningKey::from_bytes(&[i; 32]));
        let vrf = SigningKey::from_bytes(&[9; 32]).verifying_key().to_bytes();
        let policy = Policy::new(
            [8; 32],
            vrf,
            keys.each_ref().map(|key| key.verifying_key().to_bytes()),
        )
        .unwrap();
        (
            policy,
            keys,
            vrf,
            Checkpoint {
                epoch: 12,
                root: [10; 32],
            },
        )
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
                Observation::from_signature(
                    slot as u8,
                    checkpoint,
                    time,
                    keys[slot]
                        .sign(&policy.observation_statement(checkpoint, time))
                        .to_bytes(),
                )
            })
            .collect()
    }

    fn provision(path: &Path, vrf: [u8; 32], checkpoint: Checkpoint) -> Result<Store> {
        let native = NativeClient::open(path.to_string_lossy().into_owned(), PASSWORD.into())
            .map_err(anyhow::Error::msg)?;
        native
            .execute(serde_json::json!({"op":"init","identity":OWNER}).to_string())
            .map_err(anyhow::Error::msg)?;
        drop(native);
        Store::provision(path, PASSWORD, OWNER, vrf, checkpoint)
    }

    #[test]
    fn freshness_requires_enrolled_policy_and_persists_signed_current_head() -> Result<()> {
        let (policy, keys, vrf, checkpoint) = fixture();
        let temp = tempfile::tempdir()?;
        let mut store = provision(&temp.path().join("profile"), vrf, checkpoint)?;
        let now = unix_time_seconds()?;
        let signed = observations(
            &policy,
            &keys,
            checkpoint,
            [
                now.saturating_sub(3),
                now.saturating_sub(2),
                now.saturating_sub(1),
            ],
        );
        assert!(store.accept_checkpoint_freshness(&policy, &signed).is_err());
        store.enroll_witnesses(checkpoint, &policy)?;
        let receipt = store.accept_checkpoint_freshness(&policy, &signed)?;
        assert_eq!(receipt.checkpoint(), checkpoint);
        assert_eq!(store.current_checkpoint_freshness(&policy)?, receipt);
        // Replaying the same signed observations must never renew their expiry.
        let replayed = store.accept_checkpoint_freshness(&policy, &signed)?;
        assert_eq!(
            replayed.valid_until_unix_secs(),
            receipt.valid_until_unix_secs()
        );
        let next_time = now.saturating_sub(4);
        let rollback = observations(&policy, &keys, checkpoint, [next_time; 3]);
        assert!(store
            .accept_checkpoint_freshness(&policy, &rollback)
            .is_err());
        Ok(())
    }

    #[test]
    fn freshness_anchor_rejects_checkpoint_and_local_clock_rollback() -> Result<()> {
        let (policy, keys, vrf, checkpoint) = fixture();
        let temp = tempfile::tempdir()?;
        let mut store = provision(&temp.path().join("profile"), vrf, checkpoint)?;
        store.enroll_witnesses(checkpoint, &policy)?;
        let now = unix_time_seconds()?;
        let signed = observations(
            &policy,
            &keys,
            checkpoint,
            [
                now.saturating_sub(3),
                now.saturating_sub(2),
                now.saturating_sub(1),
            ],
        );
        store.accept_checkpoint_freshness(&policy, &signed)?;

        let rolled_back = Checkpoint {
            epoch: checkpoint.epoch - 1,
            root: checkpoint.root,
        };
        store.db.execute(
            "UPDATE kt_checkpoint SET epoch=? WHERE slot=1",
            [i64::try_from(rolled_back.epoch)?],
        )?;
        let stale_signed = observations(&policy, &keys, rolled_back, [now; 3]);
        assert!(store
            .accept_checkpoint_freshness(&policy, &stale_signed)
            .is_err());
        store.db.execute(
            "UPDATE kt_checkpoint SET epoch=?,root=? WHERE slot=1",
            params![i64::try_from(checkpoint.epoch)?, checkpoint.root],
        )?;

        let future_clock = now.saturating_add(MAX_LOCAL_CLOCK_ROLLBACK_SECS + 120);
        store.db.execute(
            "UPDATE kt_checkpoint_freshness SET local_time=? WHERE owner=? AND vrf=?",
            params![i64::try_from(future_clock)?, OWNER, vrf],
        )?;
        assert!(store.current_checkpoint_freshness(&policy).is_err());
        assert!(store.accept_checkpoint_freshness(&policy, &signed).is_err());
        Ok(())
    }

    #[test]
    fn rejected_proof_and_expired_read_still_pin_forward_system_time() -> Result<()> {
        let (policy, keys, vrf, checkpoint) = fixture();
        let temp = tempfile::tempdir()?;
        let mut store = provision(&temp.path().join("profile"), vrf, checkpoint)?;
        store.enroll_witnesses(checkpoint, &policy)?;
        let base = unix_time_seconds()?;
        let signed = observations(
            &policy,
            &keys,
            checkpoint,
            [
                base.saturating_sub(3),
                base.saturating_sub(2),
                base.saturating_sub(1),
            ],
        );
        store.accept_checkpoint_freshness_at(&policy, &signed, Some(base))?;

        // An invalid quorum at a large forward time still updates only the local
        // clock floor; a later rollback cannot make old evidence valid again.
        let far_future = base + 10_000;
        assert!(store
            .accept_checkpoint_freshness_at(&policy, &signed, Some(far_future))
            .is_err());
        assert!(store
            .accept_checkpoint_freshness_at(&policy, &signed, Some(base))
            .is_err());

        // The same rule applies when a read rejects an expired receipt.
        let mut second = provision(&temp.path().join("second-profile"), vrf, checkpoint)?;
        second.enroll_witnesses(checkpoint, &policy)?;
        second.accept_checkpoint_freshness_at(&policy, &signed, Some(base))?;
        assert!(second
            .current_checkpoint_freshness_at(&policy, Some(far_future))
            .is_err());
        assert!(second
            .current_checkpoint_freshness_at(&policy, Some(base))
            .is_err());

        // A semantically rejected but otherwise fresh observation (older than the
        // last accepted witness time) must also retain its forward wall-clock floor.
        let mut third = provision(&temp.path().join("third-profile"), vrf, checkpoint)?;
        third.enroll_witnesses(checkpoint, &policy)?;
        third.accept_checkpoint_freshness_at(&policy, &signed, Some(base))?;
        let older = observations(&policy, &keys, checkpoint, [base.saturating_sub(4); 3]);
        assert!(third
            .accept_checkpoint_freshness_at(&policy, &older, Some(base + 200))
            .is_err());
        assert!(third
            .accept_checkpoint_freshness_at(&policy, &signed, Some(base))
            .is_err());
        Ok(())
    }

    #[test]
    fn first_clock_anchor_migrates_legacy_local_time() -> Result<()> {
        let (policy, keys, vrf, checkpoint) = fixture();
        let temp = tempfile::tempdir()?;
        let mut store = provision(&temp.path().join("profile"), vrf, checkpoint)?;
        store.enroll_witnesses(checkpoint, &policy)?;
        let now = unix_time_seconds()?;
        let signed = observations(
            &policy,
            &keys,
            checkpoint,
            [
                now.saturating_sub(3),
                now.saturating_sub(2),
                now.saturating_sub(1),
            ],
        );
        store.accept_checkpoint_freshness_at(&policy, &signed, Some(now))?;
        let legacy_floor = now + 10_000;
        store.db.execute("DROP TABLE kt_checkpoint_clock", [])?;
        store.db.execute(
            "UPDATE kt_checkpoint_freshness SET local_time=? WHERE owner=? AND vrf=?",
            params![i64::try_from(legacy_floor)?, OWNER, vrf],
        )?;

        assert!(store
            .current_checkpoint_freshness_at(&policy, Some(now))
            .is_err());
        let migrated: i64 = store.db.query_row(
            "SELECT local_time FROM kt_checkpoint_clock WHERE owner=? AND vrf=?",
            params![OWNER, vrf],
            |row| row.get(0),
        )?;
        assert_eq!(u64::try_from(migrated)?, legacy_floor);
        Ok(())
    }
}
