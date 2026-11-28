//! Canonical v1 account-root authorization for the full device roster.
use crate::contact::{canonical_id, public_key};
use akd::{AkdLabel, AkdValue};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use uuid::Uuid;

const DOMAIN: &[u8] = b"SecureMesh/AKD/account-device-roster/signed/v1\0";
const LABEL: &[u8] = b"SecureMesh/AKD/account-device-roster/label/v1\0";
const ENTRY_BYTES: usize = 16 + 1 + 1 + 32;
pub const MAX_DEVICES: usize = 64;
pub const MAX_SIGNED_BYTES: usize = DOMAIN.len() + 16 + 8 + 32 + 2 + MAX_DEVICES * ENTRY_BYTES + 64;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Device {
    id: Uuid,
    signing_key: [u8; 32],
    revoked: bool,
}

impl Device {
    pub fn new(id: &str, signing_key: [u8; 32], revoked: bool) -> Result<Self> {
        public_key(&signing_key)?;
        Ok(Self {
            id: canonical_id(id)?,
            signing_key,
            revoked,
        })
    }
}

#[derive(Clone, Debug)]
pub struct Roster {
    account: Uuid,
    version: u64,
    previous: [u8; 32],
    devices: Vec<Device>,
}

impl Roster {
    pub fn new(
        account: &str,
        version: u64,
        previous: [u8; 32],
        devices: Vec<Device>,
    ) -> Result<Self> {
        let record = Self {
            account: canonical_id(account)?,
            version,
            previous,
            devices,
        };
        record.validate()?;
        Ok(record)
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.version > 0 && ((self.version == 1) == (self.previous == [0; 32])),
            "invalid version or predecessor"
        );
        ensure!(
            self.devices.len() <= MAX_DEVICES
                && self.devices.iter().filter(|d| !d.revoked).count() <= 20,
            "roster exceeds device limits"
        );
        let mut keys = BTreeSet::new();
        ensure!(
            self.devices.windows(2).all(|w| w[0].id < w[1].id),
            "device identifiers must be unique and sorted"
        );
        for d in &self.devices {
            ensure!(
                !d.id.is_nil() && keys.insert(d.signing_key),
                "duplicate key or empty device ID"
            );
        }
        Ok(())
    }

    fn body(&self) -> Vec<u8> {
        let mut out = DOMAIN.to_vec();
        out.extend(self.account.as_bytes());
        out.extend(self.version.to_be_bytes());
        out.extend(self.previous);
        out.extend((self.devices.len() as u16).to_be_bytes());
        for device in &self.devices {
            out.extend(device.id.as_bytes());
            out.push(1); // Ed25519 signing key for the SecureMesh MLS suite
            out.push(u8::from(device.revoked));
            out.extend(device.signing_key);
        }
        out
    }

    pub fn version(&self) -> u64 {
        self.version
    }
    pub fn digest(&self) -> [u8; 32] {
        Sha256::digest(self.body()).into()
    }
    pub fn contains_active_key(&self, device: &str, signing_key: &[u8; 32]) -> Result<bool> {
        let id = canonical_id(device)?;
        Ok(self
            .devices
            .iter()
            .any(|d| d.id == id && !d.revoked && &d.signing_key == signing_key))
    }
    pub fn publication(&self, root: &SigningKey) -> Result<(AkdLabel, AkdValue)> {
        ensure!(
            self.devices
                .iter()
                .all(|d| d.signing_key != root.verifying_key().to_bytes()),
            "account root reused as device key"
        );
        let mut body = self.body();
        body.extend(root.sign(&body).to_bytes());
        Ok((label(self.account), AkdValue(body)))
    }

    pub(crate) fn verify(raw: &[u8], account: Uuid, root: &VerifyingKey) -> Result<Self> {
        ensure!(
            raw.len() <= MAX_SIGNED_BYTES && raw.len() >= DOMAIN.len() + 16 + 8 + 32 + 2 + 64,
            "invalid signed roster length"
        );
        let (body, sig) = raw.split_at(raw.len() - 64);
        root.verify_strict(body, &Signature::from_slice(sig)?)?;
        let mut fields = body
            .strip_prefix(DOMAIN)
            .context("wrong signed roster purpose or version")?;
        let published = Uuid::from_bytes(take(&mut fields)?);
        ensure!(published == account, "wrong roster account");
        let version = u64::from_be_bytes(take(&mut fields)?);
        let previous = take(&mut fields)?;
        let count = usize::from(u16::from_be_bytes(take(&mut fields)?));
        ensure!(
            count <= MAX_DEVICES && fields.len() == count * ENTRY_BYTES,
            "invalid roster entry count"
        );
        let mut devices = Vec::with_capacity(count);
        for _ in 0..count {
            let id = Uuid::from_bytes(take(&mut fields)?);
            let [purpose, status] = take(&mut fields)?;
            ensure!(
                purpose == 1 && status <= 1,
                "unknown device purpose or state"
            );
            let signing_key = take(&mut fields)?;
            public_key(&signing_key)?;
            ensure!(
                &signing_key != root.as_bytes(),
                "account root reused as device key"
            );
            devices.push(Device {
                id,
                signing_key,
                revoked: status == 1,
            });
        }
        let record = Self {
            account,
            version,
            previous,
            devices,
        };
        record.validate()?;
        Ok(record)
    }

    pub(crate) fn follows(&self, old: Option<&Self>) -> Result<()> {
        let Some(old) = old else {
            ensure!(self.version == 1, "missing genesis");
            return Ok(());
        };
        ensure!(
            old.version.checked_add(1) == Some(self.version) && self.previous == old.digest(),
            "broken roster chain"
        );
        for prior in &old.devices {
            let index = self
                .devices
                .binary_search_by_key(&prior.id, |d| d.id)
                .map_err(|_| anyhow::anyhow!("missing device or revocation tombstone"))?;
            let next = &self.devices[index];
            ensure!(
                next.signing_key == prior.signing_key && (!prior.revoked || next.revoked),
                "device key substitution or reactivation"
            );
        }
        Ok(())
    }
}

pub(crate) fn label(account: Uuid) -> AkdLabel {
    AkdLabel([LABEL, account.as_bytes()].concat())
}

fn take<const N: usize>(input: &mut &[u8]) -> Result<[u8; N]> {
    let (field, rest) = input.split_at_checked(N).context("truncated roster")?;
    *input = rest;
    Ok(field.try_into()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    const ACCOUNT: &str = "a0b1c2d3-0000-4000-8000-000000000001";
    const DEVICE: &str = "a0b1c2d3-0000-4000-8000-000000000002";
    fn signed(mut body: Vec<u8>, root: &SigningKey) -> Vec<u8> {
        body.extend(root.sign(&body).to_bytes());
        body
    }
    #[test]
    fn signed_encodings_have_one_interpretation() -> Result<()> {
        let account = canonical_id(ACCOUNT)?;
        let root = SigningKey::from_bytes(&[3; 32]);
        let device = Device::new(
            DEVICE,
            SigningKey::from_bytes(&[4; 32]).verifying_key().to_bytes(),
            false,
        )?;
        assert!(Roster::new(ACCOUNT, 1, [1; 32], vec![]).is_err());
        assert!(Roster::new(ACCOUNT, 2, [0; 32], vec![]).is_err());
        assert!(Roster::new(ACCOUNT, 1, [0; 32], vec![device.clone(), device.clone()]).is_err());
        let r = Roster::new(ACCOUNT, 1, [0; 32], vec![device])?;
        let body = r.body();
        let key = root.verifying_key();
        let offset = DOMAIN.len() + 16 + 8 + 32 + 2 + 16;
        let (_, val) = r.publication(&root)?;
        assert_eq!(Roster::verify(&val.0, account, &key)?.digest(), r.digest());
        assert!(Roster::verify(&val.0, canonical_id(DEVICE)?, &key).is_err());
        let mut weak = body.clone();
        weak[offset + 2..].fill(0);
        let mut root_is_device = body.clone();
        root_is_device[offset + 2..].copy_from_slice(key.as_bytes());
        let mut purpose = body.clone();
        purpose[offset] = 2;
        let mut status = body.clone();
        status[offset + 1] = 2;
        let mut foreign = body.clone();
        foreign[0] ^= 1;
        let mut bad_count = body.clone();
        bad_count[DOMAIN.len() + 16 + 8 + 32 + 1] = 0;
        for invalid in [
            weak,
            root_is_device,
            purpose,
            status,
            foreign,
            bad_count,
            [body.as_slice(), &[0]].concat(),
            body[..body.len() - 1].to_vec(),
        ] {
            assert!(Roster::verify(&signed(invalid, &root), account, &key).is_err());
        }
        let mut invalid_sig = val.0;
        *invalid_sig.last_mut().unwrap() ^= 1;
        assert!(Roster::verify(&invalid_sig, account, &key).is_err());
        Ok(())
    }
}
