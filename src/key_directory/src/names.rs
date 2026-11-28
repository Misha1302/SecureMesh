//! Owner-authorized name and reverse-account records for one fixed witness policy.
use crate::{
    contact::{canonical_id, public_key},
    witness::Policy,
    Checkpoint, Client,
};
use akd::{proto::specs::types as wire, HistoryProof, VerifyResult, WhatsAppV1Configuration};
use akd::{AkdLabel, AkdValue};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::{Signature, Signer, SigningKey};
use protobuf::Message;
use uuid::Uuid;

pub(crate) const MAX_HISTORY_RECORDS: u64 = 32;
const CLAIM: &[u8] = b"SecureMesh/AKD/account-name/claim/v1\0";
const NAME: &[u8] = b"SecureMesh/AKD/account-name/forward/v1\0";
const REVERSE: &[u8] = b"SecureMesh/AKD/account-name/reverse/v1\0";

fn check_name(name: &str) -> Result<()> {
    ensure!(
        (3..=32).contains(&name.len())
            && name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
        "expected canonical username"
    );
    Ok(())
}

pub fn name_label(policy: &Policy, name: &str) -> Result<AkdLabel> {
    check_name(name)?;
    Ok(AkdLabel(
        [NAME, &policy.fingerprint(), name.as_bytes()].concat(),
    ))
}

pub fn account_label(policy: &Policy, account: Uuid) -> AkdLabel {
    AkdLabel([REVERSE, &policy.fingerprint(), account.as_bytes()].concat())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AccountPin {
    account: Uuid,
    root: [u8; 32],
}

impl AccountPin {
    pub fn new(account: &str, root: [u8; 32]) -> Result<Self> {
        public_key(&root)?;
        Ok(Self {
            account: canonical_id(account)?,
            root,
        })
    }
    pub fn account(&self) -> Uuid {
        self.account
    }
    pub fn root(&self) -> [u8; 32] {
        self.root
    }
}

/// Root owner signs both next AKD label versions. Submit the returned pair in one publish.
pub fn publication(
    policy: &Policy,
    name: &str,
    account: &str,
    root: &SigningKey,
    name_version: u64,
    account_version: u64,
) -> Result<Vec<(AkdLabel, AkdValue)>> {
    let forward = name_label(policy, name)?;
    let pin = AccountPin::new(account, root.verifying_key().to_bytes())?;
    ensure!(
        name_version > 0 && account_version > 0,
        "expected positive AKD versions"
    );
    let mut value = [
        CLAIM,
        &policy.fingerprint(),
        pin.account.as_bytes(),
        &pin.root,
        &name_version.to_be_bytes(),
        &account_version.to_be_bytes(),
        name.as_bytes(),
    ]
    .concat();
    let signature = root.sign(&value);
    value.extend_from_slice(&signature.to_bytes());
    Ok(vec![
        (forward, AkdValue(value.clone())),
        (account_label(policy, pin.account), AkdValue(value)),
    ])
}

#[derive(Debug)]
pub struct Resolution {
    pub checkpoint: Checkpoint,
    pub pin: AccountPin,
}

/// Protobuf encoding for complete reverse-account history supplied by the directory.
pub fn encode_history(proof: &HistoryProof) -> Result<Vec<u8>> {
    Ok(wire::HistoryProof::from(proof).write_to_bytes()?)
}

struct Claim<'a> {
    pin: AccountPin,
    name: &'a str,
    name_version: u64,
}

fn verify_claim<'a>(policy: &Policy, record: &'a VerifyResult) -> Result<Claim<'a>> {
    let prefix = [CLAIM, &policy.fingerprint()].concat();
    let body = record
        .value
        .0
        .strip_prefix(&prefix[..])
        .context("invalid name claim domain")?;
    ensure!(
        (131..=160).contains(&body.len()),
        "invalid name claim length"
    );
    let account = Uuid::from_slice(&body[..16])?;
    let root = body[16..48].try_into()?;
    let name_version = u64::from_be_bytes(body[48..56].try_into()?);
    let account_version = u64::from_be_bytes(body[56..64].try_into()?);
    ensure!(
        !account.is_nil() && name_version > 0 && account_version == record.version,
        "invalid reverse claim version or account"
    );
    let name = std::str::from_utf8(&body[64..body.len() - 64])?;
    check_name(name)?;
    let (statement, sig) = record.value.0.split_at(record.value.0.len() - 64);
    public_key(&root)?.verify_strict(statement, &Signature::from_slice(sig)?)?;
    Ok(Claim {
        pin: AccountPin { account, root },
        name,
        name_version,
    })
}

pub(crate) fn claim_account(policy: &Policy, value: &AkdValue) -> Result<Uuid> {
    let prefix = [CLAIM, &policy.fingerprint()].concat();
    let body = value
        .0
        .strip_prefix(&prefix[..])
        .context("invalid name claim domain")?;
    Ok(Uuid::from_slice(
        body.get(..16).context("missing account UUID")?,
    )?)
}

impl Client {
    fn current_name(
        &self,
        policy: &Policy,
        name: &str,
        forward: &[u8],
        reverse: &[u8],
    ) -> Result<(Resolution, VerifyResult)> {
        ensure!(policy.matches_vrf(&self.vrf_key), "directory VRF mismatch");
        let f = self.lookup(name_label(policy, name)?, forward)?;
        let account = claim_account(policy, &f.value)?;
        let r = self.lookup(account_label(policy, account), reverse)?;
        ensure!(
            r.value == f.value && r.epoch == f.epoch,
            "unpaired account claim"
        );
        let claim = verify_claim(policy, &r)?;
        ensure!(
            claim.name == name && claim.name_version == f.version,
            "wrong username or stale forward claim"
        );
        Ok((
            Resolution {
                checkpoint: self.checkpoint,
                pin: claim.pin,
            },
            r,
        ))
    }

    /// Ordinary first contact requires the initial reverse record or its complete signed history.
    pub fn discover_name(
        &self,
        policy: &Policy,
        name: &str,
        forward: &[u8],
        reverse: &[u8],
        history: Option<&[u8]>,
    ) -> Result<Resolution> {
        let (result, current) = self.current_name(policy, name, forward, reverse)?;
        if current.version == 1 {
            return Ok(result);
        }
        let bytes = history.context("missing reverse account history")?;
        ensure!(
            current.version <= MAX_HISTORY_RECORDS && bytes.len() <= crate::MAX_PROOF_BYTES,
            "account history exceeds verification budget"
        );
        let wire = wire::HistoryProof::parse_from_bytes(bytes)?;
        let proof = HistoryProof::try_from(&wire)
            .map_err(|_| anyhow::anyhow!("invalid account history encoding"))?;
        ensure!(
            proof.update_proofs.len() as u64 == current.version,
            "incomplete account history"
        );
        for (idx, item) in proof.update_proofs.iter().enumerate() {
            ensure!(
                item.version == current.version - idx as u64
                    && item.epoch >= item.version
                    && item.epoch <= self.checkpoint.epoch,
                "invalid history version or epoch"
            );
        }
        let records = akd::client::key_history_verify::<WhatsAppV1Configuration>(
            &self.vrf_key,
            self.checkpoint.root,
            self.checkpoint.epoch,
            account_label(policy, result.pin.account),
            proof,
            akd::HistoryVerificationParams::default(),
        )
        .map_err(|_| anyhow::anyhow!("account history proof rejected"))?;
        ensure!(records.first() == Some(&current), "history lookup mismatch");
        for record in &records {
            ensure!(
                verify_claim(policy, record)?.pin == result.pin,
                "account root changed in directory history"
            );
        }
        Ok(result)
    }
    /// Resolve an existing or independently verified contact. Never changes its pin.
    pub fn verify_pinned_name(
        &self,
        policy: &Policy,
        expected: &AccountPin,
        name: &str,
        forward: &[u8],
        reverse: &[u8],
    ) -> Result<Resolution> {
        let (result, _) = self.current_name(policy, name, forward, reverse)?;
        ensure!(
            result.pin == *expected,
            "account or root differs from contact pin"
        );
        Ok(result)
    }
}
