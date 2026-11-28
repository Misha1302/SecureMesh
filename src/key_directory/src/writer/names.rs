//! Fetch paired name evidence inside one writer read transaction.
use super::Writer;
use crate::{
    encode_lookup,
    names::{account_label, claim_account, encode_history, name_label, MAX_HISTORY_RECORDS},
    witness::Policy,
    Checkpoint, MAX_PROOF_BYTES,
};
use akd::{ecvrf::VRFKeyStorage, HistoryParams};
use anyhow::{ensure, Result};

pub struct NameEvidence {
    pub checkpoint: Checkpoint,
    pub forward: Vec<u8>,
    pub reverse: Vec<u8>,
    pub history: Option<Vec<u8>>,
}

impl<V: VRFKeyStorage> Writer<V> {
    /// Request history for directory discovery. A pinned contact needs only the current pair.
    pub async fn name_evidence(
        &self,
        policy: &Policy,
        name: &str,
        include_history: bool,
    ) -> Result<NameEvidence> {
        let session = self.session(false)?;
        let (tree, checkpoint) = self.checked(&session).await?;
        ensure!(
            policy.matches_vrf(tree.get_public_key().await?.as_bytes()),
            "directory VRF mismatch"
        );
        let (f, _) = tree.lookup(name_label(policy, name)?).await?;
        let account = claim_account(policy, &f.value)?;
        let label = account_label(policy, account);
        let (r, _) = tree.lookup(label.clone()).await?;
        let forward = encode_lookup(&f)?;
        let reverse = encode_lookup(&r)?;
        ensure!(
            forward.len() <= MAX_PROOF_BYTES && reverse.len() <= MAX_PROOF_BYTES,
            "oversized name evidence"
        );
        let history = if include_history && r.version > 1 {
            ensure!(
                r.version <= MAX_HISTORY_RECORDS,
                "account history exceeds verification budget"
            );
            let (h, _) = tree.key_history(&label, HistoryParams::Complete).await?;
            let bytes = encode_history(&h)?;
            ensure!(bytes.len() <= MAX_PROOF_BYTES, "oversized account history");
            Some(bytes)
        } else {
            None
        };
        Ok(NameEvidence {
            checkpoint,
            forward,
            reverse,
            history,
        })
    }
}
