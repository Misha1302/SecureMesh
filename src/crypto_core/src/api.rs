/// Executes one atomic local crypto/store operation. Errors never contain input or key material.
pub fn command(path: String, request: String) -> Result<String, String> {
    crate::execute_json(&path, &request).map_err(|_| "CRYPTO_OR_STORE_REJECTED".to_owned())
}

/// One unlocked store per client. Database access is serialized; keys never leave the client.
#[flutter_rust_bridge::frb(opaque)]
pub struct NativeClient {
    db: std::sync::Mutex<rusqlite::Connection>,
}

/// Live local MLS membership bound to exactly one encrypted queued envelope.
/// It is not a standalone send authorization.
#[flutter_rust_bridge::frb(ignore)]
pub struct QueuedDispatchSnapshot {
    pub group_id: String,
    pub message_id: String,
    /// Canonical JSON envelope bytes as stored in the encrypted outbox.
    pub envelope: String,
    pub current_epoch: u64,
    pub envelope_epoch: u64,
    pub members: Vec<DispatchMember>,
}

#[flutter_rust_bridge::frb(ignore)]
pub struct DispatchMember {
    pub device_id: String,
    pub signing_key: Vec<u8>,
}

impl NativeClient {
    pub fn open(path: String, passphrase: String) -> Result<NativeClient, String> {
        crate::open_store(&path, &passphrase)
            .map(|db| NativeClient {
                db: std::sync::Mutex::new(db),
            })
            .map_err(|_| "STORE_UNLOCK_FAILED".to_owned())
    }

    pub fn execute(&self, request: String) -> Result<String, String> {
        let action = || -> anyhow::Result<String> {
            let req = crate::attachments::parse_command(&request)?;
            let db = self
                .db
                .lock()
                .map_err(|_| anyhow::anyhow!("store unavailable"))?;
            crate::transact(&db, &req)
        };
        action().map_err(|_| "CRYPTO_OR_STORE_REJECTED".to_owned())
    }

    /// Run a synchronous, transaction-local callback against one current queued
    /// message while all writes to this SQLCipher profile are serialized. This
    /// is a trusted Rust-only interface; the callback receives the raw profile
    /// connection. Until a typed KT gate is integrated, callbacks must not do
    /// network or other external side effects. Any callback error rolls back all
    /// local DB writes; monotonic safety evidence must be committed by a separate
    /// typed observation step before rejectable handoff staging.
    ///
    /// This method does not implement that gate and is intentionally not exposed
    /// to Flutter's ordinary delivery pump.
    #[flutter_rust_bridge::frb(ignore)]
    pub fn with_queued_dispatch_snapshot<T>(
        &self,
        group_id: &str,
        message_id: &str,
        enqueue: impl FnOnce(&rusqlite::Connection, &QueuedDispatchSnapshot) -> anyhow::Result<T>,
    ) -> Result<T, String> {
        let action = || -> anyhow::Result<T> {
            let db = self
                .db
                .lock()
                .map_err(|_| anyhow::anyhow!("store unavailable"))?;
            let tx = rusqlite::Transaction::new_unchecked(
                &db,
                rusqlite::TransactionBehavior::Immediate,
            )?;
            let snapshot = crate::queued_dispatch_snapshot(&tx, group_id, message_id)?;
            let result = enqueue(&tx, &snapshot)?;
            tx.commit()?;
            Ok(result)
        };
        action().map_err(|_| "PROTECTED_HANDOFF_REJECTED".to_owned())
    }
}
