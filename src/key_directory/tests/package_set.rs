use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use anyhow::Result;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use securemesh_crypto::api::NativeClient;
use securemesh_key_directory::{
    contact::DeviceAddress,
    encode_consistency, encode_lookup,
    roster::{Device, Roster},
    store::{DeviceKeyPackageEvidence, Store, VerifiedPackageSet},
    Checkpoint,
};
use std::path::Path;

const ACCOUNT: &str = "00000000-0000-4000-8000-000000000001";
const D1: &str = "00000000-0000-4000-8000-000000000002";
const D2: &str = "00000000-0000-4000-8000-000000000003";
const D3: &str = "00000000-0000-4000-8000-000000000004";
const PASSWORD: &str = "package set integration password";

struct NativeDevice {
    id: &'static str,
    key: [u8; 32],
    package: Vec<u8>,
}

fn native_device(path: &Path, id: &'static str) -> Result<NativeDevice> {
    let native = NativeClient::open(path.to_string_lossy().into_owned(), PASSWORD.into())
        .map_err(anyhow::Error::msg)?;
    let init: serde_json::Value = serde_json::from_str(
        &native
            .execute(serde_json::json!({"op":"init","identity":id}).to_string())
            .map_err(anyhow::Error::msg)?,
    )?;
    let generated: serde_json::Value = serde_json::from_str(
        &native
            .execute(serde_json::json!({"op":"keypackage"}).to_string())
            .map_err(anyhow::Error::msg)?,
    )?;
    Ok(NativeDevice {
        id,
        key: B64
            .decode(init["public_key"].as_str().unwrap())?
            .try_into()
            .unwrap(),
        package: B64.decode(generated["keypackage"].as_str().unwrap())?,
    })
}

fn evidence(device: &NativeDevice, proof: Vec<u8>) -> DeviceKeyPackageEvidence {
    DeviceKeyPackageEvidence {
        device_id: device.id.to_owned(),
        keypackage: device.package.clone(),
        lookup_proof: proof,
    }
}

fn assert_set(set: &VerifiedPackageSet, checkpoint: Checkpoint, version: u64, ids: &[&str]) {
    assert_eq!(set.account_id().to_string(), ACCOUNT);
    assert_eq!(set.checkpoint(), checkpoint);
    assert_eq!(set.roster_version(), version);
    assert_eq!(
        set.packages()
            .iter()
            .map(|package| package.device_id().to_string())
            .collect::<Vec<_>>(),
        ids.iter().map(|id| id.to_string()).collect::<Vec<_>>()
    );
    assert!(set
        .packages()
        .iter()
        .all(|package| package.bytes().len() <= 16 * 1024));
}

#[tokio::test]
async fn exact_active_package_set_is_verified_at_one_pinned_checkpoint() -> Result<()> {
    let root = SigningKey::from_bytes(&[21; 32]);
    let tree = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let vrf = *tree.get_public_key().await?.as_bytes();
    let temp = tempfile::tempdir()?;
    let d1 = native_device(&temp.path().join("d1"), D1)?;
    let d2 = native_device(&temp.path().join("d2"), D2)?;
    let _d3 = native_device(&temp.path().join("d3"), D3)?;
    let first = Roster::new(
        ACCOUNT,
        1,
        [0; 32],
        vec![
            Device::new(D1, d1.key, false)?,
            Device::new(D2, d2.key, false)?,
        ],
    )?;
    let (roster_label, roster_value) = first.publication(&root)?;
    let addr1 = DeviceAddress::parse(ACCOUNT, D1)?;
    let addr2 = DeviceAddress::parse(ACCOUNT, D2)?;
    let (device_label1, device_value1) = addr1.publication(D1.as_bytes(), &d1.key)?;
    let (device_label2, device_value2) = addr2.publication(D2.as_bytes(), &d2.key)?;
    let head = tree
        .publish(vec![
            (roster_label.clone(), roster_value),
            (device_label1.clone(), device_value1),
            (device_label2.clone(), device_value2),
        ])
        .await?;
    let checkpoint = Checkpoint {
        epoch: head.epoch(),
        root: head.hash(),
    };
    let roster_proof = encode_lookup(&tree.lookup(roster_label.clone()).await?.0)?;
    let d1_proof = encode_lookup(&tree.lookup(device_label1.clone()).await?.0)?;
    let d2_proof = encode_lookup(&tree.lookup(device_label2.clone()).await?.0)?;
    let path = temp.path().join("reader");
    let owner_native = NativeClient::open(path.to_string_lossy().into_owned(), PASSWORD.into())
        .map_err(anyhow::Error::msg)?;
    owner_native
        .execute(serde_json::json!({"op":"init","identity":D1}).to_string())
        .map_err(anyhow::Error::msg)?;
    drop(owner_native);
    let mut store = Store::provision(&path, PASSWORD, D1, vrf, checkpoint)?;
    store.pin_account_root(ACCOUNT, root.verifying_key().to_bytes())?;

    let all = vec![
        evidence(&d1, d1_proof.clone()),
        evidence(&d2, d2_proof.clone()),
    ];
    // Race first accepted-state initialization against the snapshot reader. The
    // reader either sees no accepted roster and rejects, or sees the whole commit.
    let peer = Store::open(&path, PASSWORD, D1, vrf)?;
    let accept_store = Store::open(&path, PASSWORD, D1, vrf)?;
    let barrier = std::sync::Barrier::new(2);
    let proof_ref = &roster_proof;
    let all_ref = &all;
    let initialization = std::thread::scope(|scope| {
        let gate = &barrier;
        let proof = proof_ref;
        let accepted = scope.spawn(move || {
            gate.wait();
            accept_store.accept_roster(ACCOUNT, &[], proof)
        });
        let gate = &barrier;
        let package_evidence = all_ref;
        let proof = proof_ref;
        let read = scope.spawn(move || {
            gate.wait();
            peer.verify_package_set(ACCOUNT, checkpoint, proof, package_evidence)
        });
        (accepted.join().unwrap(), read.join().unwrap())
    });
    assert_eq!(initialization.0?.1.version(), 1);
    match initialization.1 {
        Ok(set) => assert_set(&set, checkpoint, 1, &[D1, D2]),
        Err(_) => {
            let retry = store.verify_package_set(ACCOUNT, checkpoint, &roster_proof, &all)?;
            assert_set(&retry, checkpoint, 1, &[D1, D2]);
        }
    }
    let accepted = store.verify_package_set(ACCOUNT, checkpoint, &roster_proof, &all)?;
    assert_set(&accepted, checkpoint, 1, &[D1, D2]);

    assert!(store
        .verify_package_set(ACCOUNT, checkpoint, &roster_proof, &all[..1])
        .is_err()); // missing
    let duplicate = vec![all[0].clone(), all[0].clone()];
    assert!(store
        .verify_package_set(ACCOUNT, checkpoint, &roster_proof, &duplicate)
        .is_err()); // duplicate
    let extra = vec![
        all[0].clone(),
        DeviceKeyPackageEvidence {
            device_id: D3.into(),
            keypackage: _d3.package.clone(),
            lookup_proof: vec![],
        },
    ];
    assert!(store
        .verify_package_set(ACCOUNT, checkpoint, &roster_proof, &extra)
        .is_err()); // extra
    let wrong_identity = vec![
        all[0].clone(),
        DeviceKeyPackageEvidence {
            device_id: D2.into(),
            keypackage: d1.package.clone(),
            lookup_proof: d2_proof.clone(),
        },
    ];
    assert!(store
        .verify_package_set(ACCOUNT, checkpoint, &roster_proof, &wrong_identity)
        .is_err()); // package is not the advertised native identity
    let missing_record = vec![
        all[0].clone(),
        DeviceKeyPackageEvidence {
            device_id: D2.into(),
            keypackage: d2.package.clone(),
            lookup_proof: vec![],
        },
    ];
    assert!(store
        .verify_package_set(ACCOUNT, checkpoint, &roster_proof, &missing_record)
        .is_err()); // missing AKD device record proof

    // The owner revokes D2. The old checkpoint cannot be used, and the new
    // checkpoint accepts only D1's exact active package set.
    let second = Roster::new(
        ACCOUNT,
        2,
        first.digest(),
        vec![
            Device::new(D1, d1.key, false)?,
            Device::new(D2, d2.key, true)?,
        ],
    )?;
    let (_, second_value) = second.publication(&root)?;
    let next = tree
        .publish(vec![(roster_label.clone(), second_value)])
        .await?;
    let next_checkpoint = Checkpoint {
        epoch: next.epoch(),
        root: next.hash(),
    };
    store
        .advance(
            checkpoint,
            next_checkpoint,
            &encode_consistency(&tree.audit(checkpoint.epoch, next_checkpoint.epoch).await?)?,
        )
        .await?;
    let second_proof = encode_lookup(&tree.lookup(roster_label.clone()).await?.0)?;
    let d1_proof_next = encode_lookup(&tree.lookup(device_label1.clone()).await?.0)?;
    let d2_proof_next = encode_lookup(&tree.lookup(device_label2.clone()).await?.0)?;
    assert!(store
        .verify_package_set(ACCOUNT, checkpoint, &roster_proof, &all)
        .is_err()); // stale local checkpoint
    assert!(store
        .verify_package_set(ACCOUNT, next_checkpoint, &roster_proof, &all[..1])
        .is_err()); // stale roster proof
    store.accept_roster(ACCOUNT, &[], &second_proof)?;
    let current = vec![evidence(&d1, d1_proof_next.clone())];
    let set = store.verify_package_set(ACCOUNT, next_checkpoint, &second_proof, &current)?;
    assert_set(&set, next_checkpoint, 2, &[D1]);
    let stale_device = vec![evidence(&d1, d1_proof)];
    assert!(store
        .verify_package_set(ACCOUNT, next_checkpoint, &second_proof, &stale_device)
        .is_err()); // old device-key lookup proof
    assert!(store
        .verify_package_set(ACCOUNT, next_checkpoint, &second_proof, &all)
        .is_err()); // revoked D2 is extra
    let revoked_only = vec![evidence(&d2, d2_proof_next)];
    assert!(store
        .verify_package_set(ACCOUNT, next_checkpoint, &second_proof, &revoked_only)
        .is_err()); // revoked D2 cannot substitute for active D1

    let third = Roster::new(
        ACCOUNT,
        3,
        second.digest(),
        vec![
            Device::new(D1, d1.key, true)?,
            Device::new(D2, d2.key, true)?,
        ],
    )?;
    let (_, third_value) = third.publication(&root)?;
    let last_head = tree
        .publish(vec![(roster_label.clone(), third_value)])
        .await?;
    let last_checkpoint = Checkpoint {
        epoch: last_head.epoch(),
        root: last_head.hash(),
    };
    store
        .advance(
            next_checkpoint,
            last_checkpoint,
            &encode_consistency(
                &tree
                    .audit(next_checkpoint.epoch, last_checkpoint.epoch)
                    .await?,
            )?,
        )
        .await?;
    let third_proof = encode_lookup(&tree.lookup(roster_label).await?.0)?;
    store.accept_roster(ACCOUNT, &[], &third_proof)?;
    assert!(store
        .verify_package_set(ACCOUNT, last_checkpoint, &third_proof, &[])
        .is_err()); // valid zero-active roster is not a verified send package set

    Ok(())
}
