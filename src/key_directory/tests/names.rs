use akd::{
    ecvrf::HardCodedAkdVRF,
    storage::{memory::AsyncInMemoryDatabase, StorageManager},
    AzksParallelismConfig, Directory, WhatsAppV1Configuration,
};
use anyhow::Result;
use ed25519_dalek::SigningKey;
use securemesh_crypto::api::NativeClient;
use securemesh_key_directory::{
    encode_lookup,
    names::{publication, AccountPin},
    store::Store,
    witness::Policy,
    Checkpoint, Client,
};

const A: &str = "00000000-0000-4000-8000-000000000001";
const B: &str = "00000000-0000-4000-8000-000000000002";
fn key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32])
}

#[tokio::test]
async fn names_require_paired_current_owner_claims_and_immutable_prior_identity() -> Result<()> {
    let tree = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let vrf = *tree.get_public_key().await?.as_bytes();
    let witnesses = [1, 2, 3, 4].map(|n| key(n).verifying_key().to_bytes());
    let policy = Policy::new([42; 32], vrf, witnesses)?;
    let other = Policy::new([43; 32], vrf, witnesses)?;
    let root = key(10);
    let pin = AccountPin::new(A, root.verifying_key().to_bytes())?;
    for name in ["ALICE", "@alice", " alice", "a", "аlice"] {
        assert!(publication(&policy, name, A, &root, 1, 1).is_err());
    }
    let alice = publication(&policy, "alice", A, &root, 1, 1)?;
    macro_rules! head {
        ($h:expr) => {{
            let h = $h;
            Checkpoint {
                epoch: h.epoch(),
                root: h.hash(),
            }
        }};
    }
    macro_rules! proof {
        ($l:expr) => {
            encode_lookup(&tree.lookup($l.clone()).await?.0)?
        };
    }
    macro_rules! history {
        ($l:expr) => {
            securemesh_key_directory::names::encode_history(
                &tree.key_history(&$l, akd::HistoryParams::Complete).await?.0,
            )?
        };
    }
    let first = head!(tree.publish(alice.clone()).await?);
    let old_forward = proof!(alice[0].0);
    let old_reverse = proof!(alice[1].0);
    let tmp = tempfile::tempdir()?;
    let path = tmp.path().join("profile");
    let pw = "names integration credential";
    let native = NativeClient::open(path.to_string_lossy().into_owned(), pw.into()).unwrap();
    native
        .execute(format!(r#"{{"op":"init","identity":"{B}"}}"#))
        .unwrap();
    drop(native);
    let mut store = Store::provision(&path, pw, B, vrf, first)?;
    assert!(store
        .discover_name(&policy, "alice", &old_forward, &old_reverse, None)
        .is_err());
    store.enroll_witnesses(first, &policy)?;
    assert_eq!(
        store
            .discover_name(&policy, "alice", &old_forward, &old_reverse, None)?
            .pin,
        pin
    );
    assert!(store
        .verify_pinned_name(&policy, A, "alice", &old_forward, &old_reverse)
        .is_err());
    store.pin_account_root(A, pin.root())?;
    assert_eq!(
        Store::open(&path, pw, B, vrf)?
            .verify_pinned_name(&policy, A, "alice", &old_forward, &old_reverse)?
            .pin,
        pin
    );
    assert!(store
        .discover_name(&other, "alice", &old_forward, &old_reverse, None)
        .is_err());

    let renamed = publication(&policy, "alice_2", A, &root, 1, 2)?;
    let next = head!(tree.publish(renamed.clone()).await?);
    let client = Client::from_pin(vrf, next);
    let new_forward = proof!(renamed[0].0);
    let new_reverse = proof!(renamed[1].0);
    assert_eq!(
        client
            .verify_pinned_name(&policy, &pin, "alice_2", &new_forward, &new_reverse)?
            .pin,
        pin
    );
    assert!(client
        .discover_name(&policy, "alice_2", &new_forward, &old_reverse, None)
        .is_err());
    assert!(client
        .discover_name(&policy, "alice", &proof!(alice[0].0), &new_reverse, None)
        .is_err());

    assert_eq!(
        client
            .discover_name(
                &policy,
                "alice_2",
                &new_forward,
                &new_reverse,
                Some(&history!(renamed[1].0))
            )?
            .pin,
        pin
    );
    let recycled = publication(&policy, "alice", B, &key(11), 2, 1)?;
    let next = head!(tree.publish(recycled.clone()).await?);
    let client = Client::from_pin(vrf, next);
    let f = proof!(recycled[0].0);
    let r = proof!(recycled[1].0);
    assert!(client
        .verify_pinned_name(&policy, &pin, "alice", &f, &r)
        .is_err());
    assert_eq!(
        client
            .discover_name(&policy, "alice", &f, &r, None)?
            .pin
            .account()
            .to_string(),
        B
    );

    let replay = head!(tree.publish(alice.clone()).await?);
    assert!(Client::from_pin(vrf, replay)
        .discover_name(
            &policy,
            "alice",
            &proof!(alice[0].0),
            &proof!(alice[1].0),
            None
        )
        .is_err());
    let changed = publication(&policy, "alice", A, &key(20), 4, 4)?;
    let next = head!(tree.publish(changed.clone()).await?);
    let client = Client::from_pin(vrf, next);
    let f = proof!(changed[0].0);
    let r = proof!(changed[1].0);
    assert!(client
        .discover_name(&policy, "alice", &f, &r, None)
        .is_err());
    assert!(client
        .discover_name(&policy, "alice", &f, &r, Some(&history!(changed[1].0)))
        .is_err());
    assert!(client
        .verify_pinned_name(&policy, &pin, "alice", &f, &r)
        .is_err());
    let mut forged = publication(&policy, "alice", A, &root, 5, 5)?;
    for (_, value) in &mut forged {
        *value.0.last_mut().unwrap() ^= 1;
    }
    let next = head!(tree.publish(forged.clone()).await?);
    assert!(Client::from_pin(vrf, next)
        .discover_name(
            &policy,
            "alice",
            &proof!(forged[0].0),
            &proof!(forged[1].0),
            None
        )
        .is_err());
    // B's only earlier claim is valid and authenticated under B's original root.
    let replacement = publication(&policy, "bob", B, &key(20), 1, 2)?;
    let next = head!(tree.publish(replacement.clone()).await?);
    let f = proof!(replacement[0].0);
    let r = proof!(replacement[1].0);
    let history = history!(replacement[1].0);
    assert!(Client::from_pin(vrf, next)
        .discover_name(&policy, "bob", &f, &r, Some(&history))
        .is_err());
    Ok(())
}

#[tokio::test]
async fn durable_writer_publishes_and_serves_name_history_after_restart() -> Result<()> {
    use akd::ecvrf::VRFKeyStorage;
    use securemesh_key_directory::writer::Writer;
    let vrf = *HardCodedAkdVRF
        .get_vrf_public_key()
        .await
        .unwrap()
        .as_bytes();
    let policy = Policy::new(
        [1; 32],
        vrf,
        [1, 2, 3, 4].map(|i| key(i).verifying_key().to_bytes()),
    )?;
    let tmp = tempfile::tempdir()?;
    let path = tmp.path().join("directory");
    let pw = "name writer fixture passphrase";
    let writer = Writer::create(&path, pw, HardCodedAkdVRF).await?;
    let root = key(7);
    let first = writer
        .publish(
            [1; 16],
            writer.checkpoint().await?,
            publication(&policy, "alice", A, &root, 1, 1)?,
        )
        .await?;
    let next = writer
        .publish(
            [2; 16],
            first,
            publication(&policy, "alice2", A, &root, 1, 2)?,
        )
        .await?;
    drop(writer);
    let writer = Writer::open(&path, pw, HardCodedAkdVRF).await?;
    let evidence = writer.name_evidence(&policy, "alice2", true).await?;
    assert_eq!(next, evidence.checkpoint);
    let found = Client::from_pin(vrf, next).discover_name(
        &policy,
        "alice2",
        &evidence.forward,
        &evidence.reverse,
        evidence.history.as_deref(),
    )?;
    assert_eq!(
        found.pin,
        AccountPin::new(A, root.verifying_key().to_bytes())?
    );
    Ok(())
}

#[tokio::test]
async fn discovery_enforces_record_and_wire_history_limits() -> Result<()> {
    use akd::{proto::specs::types as wire, HistoryParams};
    use protobuf::Message;
    use securemesh_key_directory::{names::encode_history, MAX_PROOF_BYTES};
    let tree = Directory::<WhatsAppV1Configuration, _, _>::new(
        StorageManager::new_no_cache(AsyncInMemoryDatabase::new()),
        HardCodedAkdVRF,
        AzksParallelismConfig::disabled(),
    )
    .await?;
    let vrf = *tree.get_public_key().await?.as_bytes();
    let policy = Policy::new(
        [1; 32],
        vrf,
        [1, 2, 3, 4].map(|i| key(i).verifying_key().to_bytes()),
    )?;
    let root = key(7);
    let pin = AccountPin::new(A, root.verifying_key().to_bytes())?;
    for version in 1..=33 {
        let name = format!("contact_{version:02}");
        let batch = publication(&policy, &name, A, &root, 1, version)?;
        let forward_label = batch[0].0.clone();
        let reverse_label = batch[1].0.clone();
        let head = tree.publish(batch).await?;
        if version < 32 {
            continue;
        }
        let client = Client::from_pin(
            vrf,
            Checkpoint {
                epoch: head.epoch(),
                root: head.hash(),
            },
        );
        let forward = encode_lookup(&tree.lookup(forward_label).await?.0)?;
        let reverse = encode_lookup(&tree.lookup(reverse_label.clone()).await?.0)?;
        let history = encode_history(
            &tree
                .key_history(&reverse_label, HistoryParams::Complete)
                .await?
                .0,
        )?;
        assert_eq!(
            client
                .verify_pinned_name(&policy, &pin, &name, &forward, &reverse)?
                .pin,
            pin
        );
        let discover = |evidence: Option<&[u8]>| {
            client.discover_name(&policy, &name, &forward, &reverse, evidence)
        };
        assert!(discover(None).is_err());
        if version == 32 {
            eprintln!("32-record AKD history encodes to {} bytes", history.len());
            assert!(history.len() <= MAX_PROOF_BYTES);
            assert_eq!(discover(Some(&history))?.pin, pin);
            // Keep the original valid proof and pad an ignored protobuf field.
            // Field 1000 uses a two-byte key and a three-byte length at these sizes.
            let pad_to = |size: usize| -> Result<Vec<u8>> {
                let mut padded = wire::HistoryProof::parse_from_bytes(&history)?;
                padded
                    .mut_unknown_fields()
                    .add_length_delimited(1000, vec![0; size - history.len() - 5]);
                let bytes = padded.write_to_bytes()?;
                assert_eq!(bytes.len(), size);
                Ok(bytes)
            };
            assert_eq!(discover(Some(&pad_to(MAX_PROOF_BYTES)?))?.pin, pin);
            let oversized = pad_to(MAX_PROOF_BYTES + 1)?;
            assert!(discover(Some(&oversized))
                .unwrap_err()
                .to_string()
                .contains("exceeds verification budget"));
            let incomplete = encode_history(
                &tree
                    .key_history(&reverse_label, HistoryParams::MostRecent(31))
                    .await?
                    .0,
            )?;
            assert!(discover(Some(&incomplete)).is_err());
        } else {
            assert!(history.len() < MAX_PROOF_BYTES);
            assert!(discover(Some(&history))
                .unwrap_err()
                .to_string()
                .contains("exceeds verification budget"));
        }
    }
    Ok(())
}
