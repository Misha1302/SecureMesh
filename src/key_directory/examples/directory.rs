//! Local proof publisher and independent CLI verifier for one synthetic record.
use securemesh_key_directory::store::Store;
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

fn passphrase() -> Result<String> {
    ensure!(
        !std::io::stdin().is_terminal(),
        "supply the native profile passphrase through redirected stdin"
    );
    let mut secret = String::new();
    std::io::stdin().take(1025).read_to_string(&mut secret)?;
    ensure!(secret.len() <= 1024, "passphrase input too large");
    if secret.ends_with('\n') {
        secret.pop();
    }
    Ok(secret)
}

fn point(epoch: &str, root: &str) -> Result<Checkpoint> {
    Ok(Checkpoint {
        epoch: epoch.parse()?,
        root: digest(root)?,
    })
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
            Store::provision(Path::new(profile),&passphrase()?,owner,digest(key)?,point(epoch,root)?)?;
            println!("directory checkpoint provisioned");
            Ok(())
        }
        [mode, profile, owner, key, old_epoch, old_root, new_epoch, new_root, proof] if mode=="advance" => {
            let mut store = Store::open(Path::new(profile),&passphrase()?,owner,digest(key)?)?;
            let outcome = store.advance(point(old_epoch,old_root)?,point(new_epoch,new_root)?,&read_proof(Path::new(proof))?).await?;
            println!("{outcome:?}");
            Ok(())
        }
        [mode, profile, owner, key, label, proof] if mode=="read" => {
            let store = Store::open(Path::new(profile),&passphrase()?,owner,digest(key)?)?;
            let (checkpoint,verified) = store.lookup(AkdLabel::from(label.as_str()),&read_proof(Path::new(proof))?)?;
            println!("checkpoint {} record version {} value {}",checkpoint.epoch,verified.version,hex::encode(verified.value.0));
            Ok(())
        }
        _ => bail!("usage: directory publish NEW_DIR | directory verify DIR VRF_KEY_HEX EPOCH_1_ROOT_HEX EPOCH_2_ROOT_HEX | directory pin PROFILE OWNER VRF EPOCH ROOT | directory advance PROFILE OWNER VRF OLD_EPOCH OLD_ROOT NEW_EPOCH NEW_ROOT PROOF | directory read PROFILE OWNER VRF LABEL PROOF"),
    }
}
