use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AkdLabel, AkdValue, AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use anyhow::Result;
use securemesh_key_directory::{encode_consistency, encode_lookup, Checkpoint, Client};

#[tokio::test]
async fn verified_entries_follow_independently_pinned_checkpoints() -> Result<()> {
    let directory = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let pin = *directory.get_public_key().await?.as_bytes();
    let name = AkdLabel::from("example/username/alice");
    let account = AkdLabel::from("example/account/123");
    let account_id = AkdValue::from("123");
    let root1 = AkdValue(vec![1; 32]);
    let root2 = AkdValue(vec![2; 32]);
    let initial = directory
        .publish(vec![
            (name.clone(), account_id.clone()),
            (account.clone(), root1.clone()),
        ])
        .await?;
    let initial = Checkpoint {
        epoch: initial.epoch(),
        root: initial.hash(),
    };
    let (proof, _) = directory.lookup(account.clone()).await?;
    let before = encode_lookup(&proof)?;
    let mut client = Client::from_pin(pin, initial);
    assert_eq!(client.lookup(account.clone(), &before)?.value, root1);
    assert!(client.lookup(name.clone(), &before).is_err());
    let mut other_key = pin;
    other_key[0] ^= 1;
    assert!(Client::from_pin(other_key, initial)
        .lookup(account.clone(), &before)
        .is_err());

    let updated = directory
        .publish(vec![(account.clone(), root2.clone())])
        .await?;
    let updated = Checkpoint {
        epoch: updated.epoch(),
        root: updated.hash(),
    };
    let (after, _) = directory.lookup(account.clone()).await?;
    let mut altered = after.clone();
    altered.value = root1;
    let after = encode_lookup(&after)?;
    assert!(client.lookup(account.clone(), &after).is_err());

    let audit = directory.audit(initial.epoch, updated.epoch).await?;
    let valid = encode_consistency(&audit)?;
    let mut wrong_root = updated;
    wrong_root.root[0] ^= 1;
    assert!(client.advance(wrong_root, &valid).await.is_err());
    let mut wrong_interval = audit;
    wrong_interval.epochs[0] = updated.epoch;
    assert!(client
        .advance(updated, &encode_consistency(&wrong_interval)?)
        .await
        .is_err());
    assert!(client
        .advance(
            Checkpoint {
                epoch: updated.epoch + 1,
                ..updated
            },
            &valid
        )
        .await
        .is_err());
    assert_eq!(client.checkpoint(), initial);

    client.advance(updated, &valid).await?;
    assert!(client.advance(initial, &valid).await.is_err());
    assert!(client.advance(updated, &valid).await.is_err());
    assert_eq!(client.checkpoint(), updated);
    let (name_proof, _) = directory.lookup(name.clone()).await?;
    assert_eq!(
        client.lookup(name, &encode_lookup(&name_proof)?)?.value,
        account_id
    );
    assert!(client.lookup(account.clone(), &before).is_err());
    assert!(client
        .lookup(account.clone(), &encode_lookup(&altered)?)
        .is_err());
    assert!(client
        .lookup(account.clone(), &after[..after.len() / 2])
        .is_err());
    let verified = client.lookup(account, &after)?;
    assert_eq!((verified.version, verified.value), (2, root2));
    Ok(())
}
