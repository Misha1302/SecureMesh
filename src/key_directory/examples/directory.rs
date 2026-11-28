//! Local proof publisher and independent CLI verifier for one synthetic record.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use securemesh_key_directory::{contact::DeviceAddress, store::Store};
use std::{
    env, fs,
    io::{IsTerminal, Read},
    path::Path,
};

use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AkdLabel, AkdValue, AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use anyhow::{bail, ensure, Context, Result};
use securemesh_key_directory::{
    encode_consistency, encode_lookup, Checkpoint, Client, MAX_PROOF_BYTES,
};
use zeroize::Zeroizing;

const LABEL: &str = "securemesh-demo/account/alice";

async fn publish(out: &Path) -> Result<()> {
    fs::create_dir(out)?;
    let dir = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let label = AkdLabel::from(LABEL);
    let first = dir
        .publish(vec![(label.clone(), AkdValue(vec![1; 32]))])
        .await?;
    let (proof, _) = dir.lookup(label.clone()).await?;
    fs::write(out.join("first.pb"), encode_lookup(&proof)?)?;
    let second = dir
        .publish(vec![(label.clone(), AkdValue(vec![2; 32]))])
        .await?;
    let (proof, _) = dir.lookup(label).await?;
    fs::write(out.join("second.pb"), encode_lookup(&proof)?)?;
    let audit = dir.audit(first.epoch(), second.epoch()).await?;
    fs::write(out.join("advance.pb"), encode_consistency(&audit)?)?;
    println!(
        "Demo VRF key and epoch 1 and 2 roots (hex):\n{} {} {}",
        hex::encode(dir.get_public_key().await?.as_bytes()),
        hex::encode(first.hash()),
        hex::encode(second.hash())
    );
    Ok(())
}

fn digest(value: &str) -> Result<[u8; 32]> {
    hex::decode(value)?
        .try_into()
        .ok()
        .context("expected 32-byte hex")
}

fn read_proof(path: &Path) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(MAX_PROOF_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= MAX_PROOF_BYTES, "proof exceeds size budget");
    Ok(bytes)
}

// Current native v2 credentials permit 4096 UTF-8 bytes. Opening an existing
// profile does not reapply the grapheme-count policy to legacy local secrets.
const MAX_PASSPHRASE_BYTES: usize = 4096;

fn read_passphrase(input: impl Read) -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_PASSPHRASE_BYTES + 1));
    input
        .take((MAX_PASSPHRASE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    ensure!(
        (16..=MAX_PASSPHRASE_BYTES).contains(&bytes.len()),
        "invalid profile passphrase length"
    );
    ensure!(!bytes.contains(&0), "invalid profile passphrase");
    let text = std::str::from_utf8(&bytes).context("profile passphrase must be UTF-8")?;
    Ok(Zeroizing::new(text.to_owned()))
}

fn passphrase() -> Result<Zeroizing<String>> {
    ensure!(
        !std::io::stdin().is_terminal(),
        "supply the native profile passphrase through redirected stdin"
    );
    read_passphrase(std::io::stdin().lock())
}

fn point(epoch: &str, root: &str) -> Result<Checkpoint> {
    Ok(Checkpoint {
        epoch: epoch.parse()?,
        root: digest(root)?,
    })
}

fn check_device(
    store: &Store,
    account: &str,
    device: &str,
    package: &[u8],
    proof: &[u8],
) -> Result<Checkpoint> {
    let address = DeviceAddress::parse(account, device)?;
    let (head, key) = store.lookup_device_signing_key(&address, proof)?;
    // Reuse the same OpenMLS decoder and identity/key checks as the API's public validator.
    securemesh_crypto::validate_keypackage(&serde_json::json!({
        "identity": device, "public_key": B64.encode(key.as_bytes()), "keypackage": B64.encode(package)
    }).to_string())?;
    Ok(head)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    match args.as_slice() {
        [mode, dir] if mode == "publish" => publish(Path::new(dir)).await,
        [mode, dir, key, first, second] if mode == "verify" => {
            let dir = Path::new(dir);
            let mut client = Client::from_pin(digest(key)?, Checkpoint {epoch:1, root:digest(first)?});
            let old = client.lookup(AkdLabel::from(LABEL), &read_proof(&dir.join("first.pb"))?)?;
            client.advance(Checkpoint {epoch:2, root:digest(second)?}, &read_proof(&dir.join("advance.pb"))?).await?;
            let new = client.lookup(AkdLabel::from(LABEL), &read_proof(&dir.join("second.pb"))?)?;
            println!("verified record versions {} and {}, current value {}",old.version,new.version,hex::encode(new.value.0));
            Ok(())
        }
        [mode, profile, owner, key, epoch, root] if mode=="pin" => {
            Store::provision(Path::new(profile),passphrase()?.as_str(),owner,digest(key)?,point(epoch,root)?)?;
            println!("directory checkpoint provisioned");
            Ok(())
        }
        [mode, profile, owner, key, old_epoch, old_root, new_epoch, new_root, proof] if mode=="advance" => {
            let mut store = Store::open(Path::new(profile),passphrase()?.as_str(),owner,digest(key)?)?;
            let outcome = store.advance(point(old_epoch,old_root)?,point(new_epoch,new_root)?,&read_proof(Path::new(proof))?).await?;
            println!("{outcome:?}");
            Ok(())
        }
        [mode, profile, owner, key, label, proof] if mode=="read" => {
            let store = Store::open(Path::new(profile),passphrase()?.as_str(),owner,digest(key)?)?;
            let (checkpoint,verified) = store.lookup(AkdLabel::from(label.as_str()),&read_proof(Path::new(proof))?)?;
            println!("checkpoint {} record version {} value {}",checkpoint.epoch,verified.version,hex::encode(verified.value.0));
            Ok(())
        }
        [mode, profile, owner, vrf, account, device, keypackage, proof] if mode == "check-device" => {
            let mut package = Vec::new();
            fs::File::open(keypackage)?.take(16385).read_to_end(&mut package)?;
            ensure!((1..=16384).contains(&package.len()), "invalid KeyPackage length");
            let store = Store::open(Path::new(profile), passphrase()?.as_str(), owner, digest(vrf)?)?;
            let head = check_device(&store, account, device, &package, &read_proof(Path::new(proof))?)?;
            println!("MLS KeyPackage matches directory device record at epoch {} root {}", head.epoch, hex::encode(head.root));
            Ok(())
        }
        [mode, profile, owner, vrf, account, root] if mode == "pin-account-root" => {
            let mut store = Store::open(Path::new(profile), passphrase()?.as_str(), owner, digest(vrf)?)?;
            store.pin_account_root(account, digest(root)?)?;
            println!("account root pinned");
            Ok(())
        }
        [mode, profile, owner, vrf, account, proof, prior @ ..] if mode == "accept-roster" => {
            ensure!(prior.len() <= 32, "too many intermediate rosters");
            let mut chain = Vec::new();
            for path in prior {
                let mut bytes = Vec::new();
                const MAX: usize = securemesh_key_directory::roster::MAX_SIGNED_BYTES;
                fs::File::open(path)?.take(MAX as u64 + 1).read_to_end(&mut bytes)?;
                ensure!(bytes.len() <= MAX, "oversized roster");
                chain.push(bytes);
            }
            let store = Store::open(Path::new(profile), passphrase()?.as_str(), owner, digest(vrf)?)?;
            let (head, roster) = store.accept_roster(account, &chain, &read_proof(Path::new(proof))?)?;
            println!("accepted account roster version {} at directory epoch {} root {}", roster.version(), head.epoch, hex::encode(head.root));
            Ok(())
        }
        _ => bail!("usage: directory publish NEW_DIR | directory verify DIR VRF_KEY_HEX EPOCH_1_ROOT_HEX EPOCH_2_ROOT_HEX | directory pin PROFILE OWNER VRF EPOCH ROOT | directory advance PROFILE OWNER VRF OLD_EPOCH OLD_ROOT NEW_EPOCH NEW_ROOT PROOF | directory read PROFILE OWNER VRF LABEL PROOF | directory check-device PROFILE OWNER VRF ACCOUNT DEVICE KEYPACKAGE PROOF | directory pin-account-root PROFILE OWNER VRF ACCOUNT ROOT | directory accept-roster PROFILE OWNER VRF ACCOUNT LOOKUP_PROOF [INTERMEDIATE_SIGNED_ROSTER ...]"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use securemesh_crypto::api::NativeClient;

    #[test]
    fn stdin_preserves_the_complete_native_credential_including_final_lf() -> Result<()> {
        // Fifteen x graphemes (the final one has combining marks) and one LF.
        // This is exactly 16 graphemes and 4096 UTF-8 bytes.
        let password = Zeroizing::new(format!("{}{}\n", "x".repeat(15), "\u{301}".repeat(2040)));
        assert_eq!(password.len(), MAX_PASSPHRASE_BYTES);
        let decoded = read_passphrase(password.as_bytes())?;
        assert_eq!(decoded.as_bytes(), password.as_bytes());
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("profile");
        let native = NativeClient::open(path.to_str().unwrap().into(), password.to_string())
            .map_err(anyhow::Error::msg)?;
        native
            .execute(r#"{"op":"init","identity":"test-device"}"#.into())
            .map_err(anyhow::Error::msg)?;
        drop(native);
        let key = digest("f6ec49c8085f4d4be69db8e248bf11ce288026f5b8c5f6599defe58303d0702d")?;
        Store::provision(
            &path,
            decoded.as_str(),
            "test-device",
            key,
            Checkpoint {
                epoch: 1,
                root: [1; 32],
            },
        )?;
        assert!(Store::open(
            &path,
            password.strip_suffix('\n').unwrap(),
            "test-device",
            key
        )
        .is_err());
        Ok(())
    }

    #[tokio::test]
    async fn directory_proof_matches_real_native_keypackage_only_at_expected_address() -> Result<()>
    {
        const ACCOUNT: &str = "aaaa1111-2222-4333-8444-555555555555";
        const DEVICE: &str = "bbbb2222-3333-4444-8555-666666666666";
        const OTHER: &str = "cccc3333-4444-4555-8666-777777777777";
        let tmp = tempfile::tempdir()?;
        let make_device = |path: &Path, id: &str| -> Result<([u8; 32], Vec<u8>)> {
            let native = NativeClient::open(
                path.to_str().unwrap().into(),
                "synthetic device password".into(),
            )
            .map_err(anyhow::Error::msg)?;
            let run = |req: serde_json::Value| -> Result<serde_json::Value> {
                Ok(serde_json::from_str(
                    &native
                        .execute(req.to_string())
                        .map_err(anyhow::Error::msg)?,
                )?)
            };
            let init = run(serde_json::json!({"op":"init","identity":id}))?;
            let kp = run(serde_json::json!({"op":"keypackage"}))?;
            Ok((
                B64.decode(init["public_key"].as_str().unwrap())?
                    .try_into()
                    .unwrap(),
                B64.decode(kp["keypackage"].as_str().unwrap())?,
            ))
        };
        let path = tmp.path().join("native");
        let (key, package) = make_device(&path, DEVICE)?;
        let (_, replacement) = make_device(&tmp.path().join("replacement"), DEVICE)?;
        let (_, other) = make_device(&tmp.path().join("other"), OTHER)?;
        let tree = Directory::<WhatsAppV1Configuration, _, _>::new(
            StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
            HardCodedAkdVRF,
            AzksParallelismConfig::disabled(),
        )
        .await?;
        let address = DeviceAddress::parse(ACCOUNT, DEVICE)?;
        let (label, value) = address.publication(DEVICE.as_bytes(), &key)?;
        // A second valid proof includes identical value bytes at another account's label.
        let unrelated = DeviceAddress::parse(OTHER, DEVICE)?.label();
        let head = tree
            .publish(vec![
                (label.clone(), value.clone()),
                (unrelated.clone(), value),
            ])
            .await?;
        let checkpoint = Checkpoint {
            epoch: head.epoch(),
            root: head.hash(),
        };
        let store = Store::provision(
            &path,
            "synthetic device password",
            DEVICE,
            *tree.get_public_key().await?.as_bytes(),
            checkpoint,
        )?;
        let proof = encode_lookup(&tree.lookup(label).await?.0)?;
        let wrong_value = encode_lookup(&tree.lookup(unrelated).await?.0)?;
        assert_eq!(
            check_device(&store, ACCOUNT, DEVICE, &package, &proof)?,
            checkpoint
        );
        assert!(check_device(&store, OTHER, DEVICE, &package, &proof).is_err());
        assert!(check_device(&store, OTHER, DEVICE, &package, &wrong_value).is_err());
        assert!(check_device(&store, ACCOUNT, OTHER, &package, &proof).is_err());
        assert!(check_device(&store, ACCOUNT, DEVICE, &replacement, &proof).is_err());
        assert!(check_device(&store, ACCOUNT, DEVICE, &other, &proof).is_err());
        let mut trailing = package;
        trailing.push(0);
        assert!(check_device(&store, ACCOUNT, DEVICE, &trailing, &proof).is_err());
        assert_eq!(store.checkpoint()?, checkpoint);
        Ok(())
    }

    #[test]
    fn stdin_rejects_oversize_short_nul_and_invalid_utf8() {
        assert!(read_passphrase(&vec![b'x'; MAX_PASSPHRASE_BYTES + 1][..]).is_err());
        for invalid in [&[b'x'; 15][..], &[0; 16], &[0xff; 16]] {
            assert!(read_passphrase(invalid).is_err());
        }
        let whitespace = b"  preserve me   \r\n";
        assert_eq!(
            read_passphrase(&whitespace[..]).unwrap().as_bytes(),
            whitespace
        );
    }
}
