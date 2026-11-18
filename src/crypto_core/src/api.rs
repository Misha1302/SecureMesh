/// Executes one atomic local crypto/store operation. Errors never contain input or key material.
pub fn command(path: String, request: String) -> Result<String, String> {
    crate::execute_json(&path, &request).map_err(|_| "CRYPTO_OR_STORE_REJECTED".to_owned())
}

/// One unlocked store per client. Database access is serialized; keys never leave the client.
#[flutter_rust_bridge::frb(opaque)]
pub struct NativeClient {
    db: std::sync::Mutex<rusqlite::Connection>,
}

impl NativeClient {
    pub fn open(path: String, passphrase: String) -> Result<NativeClient, String> {
        crate::open_store(&path, &passphrase)
            .map(|db| NativeClient { db: std::sync::Mutex::new(db) })
            .map_err(|_| "STORE_UNLOCK_FAILED".to_owned())
    }

    pub fn execute(&self, request: String) -> Result<String, String> {
        let action = || -> anyhow::Result<String> {
            anyhow::ensure!(request.len() <= 262144, "input too large");
            let req = serde_json::from_str(&request)?;
            let db = self.db.lock().map_err(|_|anyhow::anyhow!("store unavailable"))?;
            crate::transact(&db, &req)
        };
        action().map_err(|_|"CRYPTO_OR_STORE_REJECTED".to_owned())
    }
}
