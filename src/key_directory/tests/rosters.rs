use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use anyhow::Result;
use ed25519_dalek::SigningKey;
use securemesh_crypto::api::NativeClient;
use securemesh_key_directory::{
    encode_consistency, encode_lookup,
    roster::{Device, Roster},
    store::Store,
    Checkpoint,
};

const A: &str = "00000000-0000-4000-8000-000000000001";
const D1: &str = "00000000-0000-4000-8000-000000000002";
const D2: &str = "00000000-0000-4000-8000-000000000003";
const PW: &str = "roster integration credential";
fn key(i: u8) -> [u8; 32] {
    SigningKey::from_bytes(&[i; 32]).verifying_key().to_bytes()
}

#[tokio::test]
async fn durable_signed_history_and_revocation_survive_reopen_and_retry() -> Result<()> {
    let root = SigningKey::from_bytes(&[8; 32]);
    let tree = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let vrf = *tree.get_public_key().await?.as_bytes();
    let dev1 = Device::new(D1, key(1), false)?;
    let dev2 = Device::new(D2, key(2), false)?;
    let revoked = Device::new(D1, key(1), true)?;
    let first = Roster::new(A, 1, [0; 32], vec![dev1.clone()])?;
    let second = Roster::new(A, 2, first.digest(), vec![revoked.clone(), dev2.clone()])?;
    let third = Roster::new(A, 3, second.digest(), vec![revoked.clone(), dev2.clone()])?;
    let (label, genesis) = first.publication(&root)?;
    let head = tree.publish(vec![(label.clone(), genesis)]).await?;
    let pin = Checkpoint {
        epoch: head.epoch(),
        root: head.hash(),
    };
    let first_proof = encode_lookup(&tree.lookup(label.clone()).await?.0)?;
    let temp = tempfile::tempdir()?;
    let path = temp.path().join("profile");
    let native = NativeClient::open(path.to_string_lossy().into_owned(), PW.into()).unwrap();
    native
        .execute(format!(r#"{{"op":"init","identity":"{D1}"}}"#))
        .unwrap();
    drop(native);
    let mut store = Store::provision(&path, PW, D1, vrf, pin)?;
    assert!(store.accept_roster(A, &[], &first_proof).is_err());
    store.pin_account_root(A, root.verifying_key().to_bytes())?;
    assert!(store.pin_account_root(A, key(9)).is_err());
    let (_, accepted) = store.accept_roster(A, &[], &first_proof)?;
    assert!(accepted.contains_active_key(D1, &key(1))?);
    let (_, middle) = second.publication(&root)?;
    let second_head = tree.publish(vec![(label.clone(), middle.clone())]).await?;
    let third_value = third.publication(&root)?;
    let last = tree.publish(vec![third_value]).await?;
    for epoch in head.epoch()..last.epoch() {
        let previous = store.checkpoint()?;
        let end = if epoch + 1 == last.epoch() {
            last.hash()
        } else {
            second_head.hash()
        };
        store
            .advance(
                previous,
                Checkpoint {
                    epoch: epoch + 1,
                    root: end,
                },
                &encode_consistency(&tree.audit(epoch, epoch + 1).await?)?,
            )
            .await?;
    }
    let proof = encode_lookup(&tree.lookup(label.clone()).await?.0)?;
    assert!(store.accept_roster(A, &[], &proof).is_err());
    let wrong = second.publication(&SigningKey::from_bytes(&[6; 32]))?.1 .0;
    assert!(store.accept_roster(A, &[wrong], &proof).is_err());
    let chain = [middle.0];
    // Two independently reopened SQLCipher connections accept the identical proof.
    let peer_store = Store::open(&path, PW, D1, vrf)?;
    let barrier = std::sync::Barrier::new(2);
    let (_, accepted) = std::thread::scope(|scope| -> Result<_> {
        let chain_ref = &chain;
        let proof_ref = &proof;
        let gate = &barrier;
        let peer = scope.spawn(move || {
            gate.wait();
            peer_store.accept_roster(A, chain_ref, proof_ref)
        });
        barrier.wait();
        let ours = store.accept_roster(A, &chain, &proof)?;
        assert_eq!(peer.join().unwrap()?.1.digest(), ours.1.digest());
        Ok(ours)
    })?;
    assert!(
        !accepted.contains_active_key(D1, &key(1))? && accepted.contains_active_key(D2, &key(2))?
    );
    drop(store);
    let mut store = Store::open(&path, PW, D1, vrf)?;
    store.pin_account_root(A, root.verifying_key().to_bytes())?;
    assert_eq!(store.accept_roster(A, &chain, &proof)?.1.version(), 3);
    assert!(store.accept_roster(A, &[vec![0]], &proof).is_err());
    assert_eq!(store.saved_roster(A)?.unwrap().digest(), third.digest());
    for candidate in [
        Roster::new(A, 4, third.digest(), vec![dev1.clone(), dev2.clone()])?, // resurrection
        Roster::new(A, 4, third.digest(), vec![dev2.clone()])?,               // erasing a tombstone
        Roster::new(
            A,
            4,
            third.digest(),
            vec![revoked.clone(), Device::new(D2, key(3), false)?],
        )?,
        Roster::new(A, 4, [1; 32], vec![revoked.clone(), dev2.clone()])?, // alternate predecessor
        Roster::new(A, 1, [0; 32], vec![dev1.clone()])?,                  // rollback
    ] {
        let head = tree.publish(vec![candidate.publication(&root)?]).await?;
        let prev = store.checkpoint()?;
        store
            .advance(
                prev,
                Checkpoint {
                    epoch: head.epoch(),
                    root: head.hash(),
                },
                &encode_consistency(&tree.audit(prev.epoch, head.epoch()).await?)?,
            )
            .await?;
        let proof = encode_lookup(&tree.lookup(label.clone()).await?.0)?;
        assert!(store.accept_roster(A, &[], &proof).is_err());
        assert_eq!(store.saved_roster(A)?.unwrap().digest(), third.digest());
    }

    // Revoking the last two devices is valid owner-authorized state, but has no
    // recipient that a future delivery gate may treat as send-ready.
    let no_active = Roster::new(
        A,
        4,
        third.digest(),
        vec![revoked.clone(), Device::new(D2, key(2), true)?],
    )?;
    let locked_head = tree.publish(vec![no_active.publication(&root)?]).await?;
    let previous = store.checkpoint()?;
    store
        .advance(
            previous,
            Checkpoint {
                epoch: locked_head.epoch(),
                root: locked_head.hash(),
            },
            &encode_consistency(&tree.audit(previous.epoch, locked_head.epoch()).await?)?,
        )
        .await?;
    let locked_proof = encode_lookup(&tree.lookup(label).await?.0)?;
    let (_, locked) = store.accept_roster(A, &[], &locked_proof)?;
    assert_eq!(locked.active_device_count(), 0);
    assert!(locked.active_devices().next().is_none());
    assert!(!locked.contains_active_key(D1, &key(1))?);
    assert!(!locked.contains_active_key(D2, &key(2))?);
    assert_eq!(store.saved_roster(A)?.unwrap().digest(), no_active.digest());
    Ok(())
}
