//! AKD leaf for the existing SecureMesh Ed25519 device signing credential.
use crate::{store::Store, Checkpoint};
use akd::{AkdLabel, AkdValue};
use anyhow::{ensure, Context, Result};
use ed25519_dalek::VerifyingKey;
use uuid::Uuid;

const LABEL: &[u8] = b"SecureMesh/AKD/device-signing-key/label/v1\0";
const VALUE: &[u8] = b"SecureMesh/AKD/device-signing-key/value/v1\0";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceAddress {
    account: Uuid,
    device: Uuid,
}

fn canonical_id(text: &str) -> Result<Uuid> {
    let id = Uuid::parse_str(text)?;
    ensure!(
        !id.is_nil() && id.hyphenated().to_string() == text,
        "expected full lowercase nonzero UUID"
    );
    Ok(id)
}

fn public_key(raw: &[u8; 32]) -> Result<VerifyingKey> {
    let key = VerifyingKey::from_bytes(raw)?;
    let point = key.to_edwards();
    ensure!(
        !key.is_weak() && point.is_torsion_free() && point.compress().to_bytes() == *raw,
        "invalid MLS signing public key"
    );
    Ok(key)
}

impl DeviceAddress {
    pub fn parse(account: &str, device: &str) -> Result<Self> {
        Ok(Self {
            account: canonical_id(account)?,
            device: canonical_id(device)?,
        })
    }

    fn coordinate(&self, prefix: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(prefix.len() + 32);
        bytes.extend_from_slice(prefix);
        bytes.extend_from_slice(self.account.as_bytes());
        bytes.extend_from_slice(self.device.as_bytes());
        bytes
    }

    pub fn label(&self) -> AkdLabel {
        AkdLabel(self.coordinate(LABEL))
    }

    /// Publish using the directory account UUID and the complete BasicCredential
    /// identity and signature key obtained from the device's validated MLS leaf.
    pub fn publication(
        &self,
        identity: &[u8],
        signature_key: &[u8; 32],
    ) -> Result<(AkdLabel, AkdValue)> {
        self.check_identity(identity)?;
        public_key(signature_key)?;
        let mut value = self.coordinate(VALUE);
        value.extend_from_slice(signature_key);
        Ok((self.label(), AkdValue(value)))
    }

    fn check_identity(&self, identity: &[u8]) -> Result<()> {
        ensure!(
            self.device.hyphenated().to_string().as_bytes() == identity,
            "MLS BasicCredential device differs"
        );
        Ok(())
    }

    fn decode(&self, value: &AkdValue) -> Result<VerifyingKey> {
        let prefix = self.coordinate(VALUE);
        let suffix = value
            .0
            .strip_prefix(prefix.as_slice())
            .context("wrong device record purpose, version or address")?;
        public_key(suffix.try_into().context("invalid signing key length")?)
    }
}

impl Store {
    /// Inclusion of this device record at the local SQLCipher checkpoint.
    /// No device pin or roster trust decision is modified by reading it.
    pub fn lookup_device_signing_key(
        &self,
        address: &DeviceAddress,
        proof: &[u8],
    ) -> Result<(Checkpoint, VerifyingKey)> {
        let (head, found) = self.lookup(address.label(), proof)?;
        Ok((head, address.decode(&found.value)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;

    const ACCOUNT: &str = "00112233-4455-6677-8899-aabbccddeeff";
    const DEVICE: &str = "ffeeddcc-bbaa-9988-7766-554433221100";

    #[test]
    fn record_roundtrip_uses_exact_ids_and_domain() -> Result<()> {
        let address = DeviceAddress::parse(ACCOUNT, DEVICE)?;
        let key = SigningKey::from_bytes(&[13; 32]).verifying_key().to_bytes();
        let (label, value) = address.publication(DEVICE.as_bytes(), &key)?;
        let suffix =
            hex::decode("00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100")?;
        assert_eq!(label.0, [LABEL, &suffix].concat());
        assert_eq!(value.0, [VALUE, &suffix, &key].concat());
        assert_eq!(address.decode(&value)?.to_bytes(), key);
        for invalid in [
            ACCOUNT.replace('-', ""),
            ACCOUNT.to_uppercase(),
            Uuid::nil().to_string(),
        ] {
            assert!(DeviceAddress::parse(&invalid, DEVICE).is_err());
            assert!(DeviceAddress::parse(ACCOUNT, &invalid).is_err());
        }
        assert!(address.publication(ACCOUNT.as_bytes(), &key).is_err());
        assert!(DeviceAddress::parse(DEVICE, ACCOUNT)?
            .decode(&value)
            .is_err());
        for invalid in [
            [LABEL, &suffix, &key].concat(),
            [VALUE, &suffix, &key[..31]].concat(),
            [VALUE, &suffix, &key, &[0]].concat(),
            [VALUE, &suffix, &[0u8; 32]].concat(),
            [VALUE, &suffix, &[0xffu8; 32]].concat(),
        ] {
            assert!(address.decode(&AkdValue(invalid)).is_err());
        }
        Ok(())
    }
}
