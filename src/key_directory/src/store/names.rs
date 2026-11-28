use super::Store;
use crate::{
    contact::canonical_id,
    names::{AccountPin, Resolution},
    witness::Policy,
    Checkpoint, Client,
};
use anyhow::{Context, Result};
use rusqlite::params;

impl Store {
    fn name_snapshot(&self, policy: &Policy) -> Result<Client> {
        let (epoch,root): (i64,[u8;32]) = self.db.query_row(
            "SELECT epoch,root FROM kt_checkpoint WHERE slot=1 AND schema_version=2 AND owner=? AND vrf=? AND policy=?",
            params![self.owner,self.vrf_key,policy.fingerprint()], |row| Ok((row.get(0)?,row.get(1)?))
        ).context("missing checkpoint enrolled with this witness policy")?;
        Ok(Client::from_pin(
            self.vrf_key,
            Checkpoint {
                epoch: epoch.try_into()?,
                root,
            },
        ))
    }

    /// Detached directory identity at one enrolled local checkpoint. Does not provision a pin.
    pub fn discover_name(
        &self,
        policy: &Policy,
        name: &str,
        forward: &[u8],
        reverse: &[u8],
        history: Option<&[u8]>,
    ) -> Result<Resolution> {
        self.name_snapshot(policy)?
            .discover_name(policy, name, forward, reverse, history)
    }

    /// Caller supplies the account of the existing conversation. Load its immutable local root.
    pub fn verify_pinned_name(
        &self,
        policy: &Policy,
        account: &str,
        name: &str,
        forward: &[u8],
        reverse: &[u8],
    ) -> Result<Resolution> {
        let (root, _) = self.pinned_roster(canonical_id(account)?)?;
        let pin = AccountPin::new(account, root.to_bytes())?;
        self.name_snapshot(policy)?
            .verify_pinned_name(policy, &pin, name, forward, reverse)
    }
}
