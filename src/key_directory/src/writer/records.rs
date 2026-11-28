use akd::{
    errors::StorageError,
    storage::{
        types::{DbRecord, KeyData, ValueState, ValueStateRetrievalFlag},
        Database, DbSetState, Storable,
    },
    AkdLabel, AkdValue,
};
use async_trait::async_trait;
use rusqlite::{params, Connection, OptionalExtension};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, MutexGuard},
};

/// A fresh connection and AKD manager for one operation. The outer SQL transaction
/// covers every upstream batch, the checkpoint and the publication receipt.
#[derive(Clone)]
pub(super) struct Records(pub Arc<Mutex<Connection>>);

fn storage(_: impl std::fmt::Display) -> StorageError {
    StorageError::Other("AKD record storage or encoding failure".into())
}

fn missing() -> StorageError {
    StorageError::NotFound("AKD record missing".into())
}

impl Records {
    pub fn connection(&self) -> Result<MutexGuard<'_, Connection>, StorageError> {
        self.0.lock().map_err(storage)
    }
}

fn value_state(bytes: Vec<u8>) -> Result<ValueState, StorageError> {
    match serde_json::from_slice(&bytes).map_err(storage)? {
        DbRecord::ValueState(state) => Ok(state),
        _ => Err(storage("unexpected record type")),
    }
}

#[async_trait]
impl Database for Records {
    async fn set(&self, record: DbRecord) -> Result<(), StorageError> {
        self.batch_set(vec![record], DbSetState::General).await
    }

    async fn batch_set(&self, records: Vec<DbRecord>, _: DbSetState) -> Result<(), StorageError> {
        let conn = self.connection()?;
        if conn.is_autocommit() {
            return Err(storage("write outside transaction"));
        }
        let mut statement = conn
            .prepare_cached(
                "INSERT INTO akd_record(id,data,label,epoch,version) VALUES(?,?,?,?,?)
             ON CONFLICT(id) DO UPDATE SET data=excluded.data, label=excluded.label,
                 epoch=excluded.epoch, version=excluded.version",
            )
            .map_err(storage)?;
        for record in records {
            let (label, epoch, version) = match &record {
                DbRecord::ValueState(state) => (
                    Some(&state.username.0),
                    Some(i64::try_from(state.epoch).map_err(storage)?),
                    Some(i64::try_from(state.version).map_err(storage)?),
                ),
                _ => (None, None, None),
            };
            statement
                .execute(params![
                    record.get_full_binary_id(),
                    serde_json::to_vec(&record).map_err(storage)?,
                    label,
                    epoch,
                    version
                ])
                .map_err(storage)?;
        }
        Ok(())
    }

    async fn get<St: Storable>(&self, id: &St::StorageKey) -> Result<DbRecord, StorageError> {
        self.batch_get::<St>(std::slice::from_ref(id))
            .await?
            .pop()
            .ok_or_else(missing)
    }

    async fn batch_get<St: Storable>(
        &self,
        ids: &[St::StorageKey],
    ) -> Result<Vec<DbRecord>, StorageError> {
        let conn = self.connection()?;
        let mut query = conn
            .prepare_cached("SELECT data FROM akd_record WHERE id=?")
            .map_err(storage)?;
        let mut out = Vec::new();
        for id in ids {
            let id = St::get_full_binary_key_id(id);
            let found: Option<Vec<u8>> = query
                .query_row([&id], |row| row.get(0))
                .optional()
                .map_err(storage)?;
            if let Some(raw) = found {
                let record: DbRecord = serde_json::from_slice(&raw).map_err(storage)?;
                if record.get_full_binary_id() != id {
                    return Err(storage("wrong stored record id"));
                }
                out.push(record);
            }
        }
        Ok(out)
    }

    async fn get_user_data(&self, label: &AkdLabel) -> Result<KeyData, StorageError> {
        let conn = self.connection()?;
        let mut query = conn
            .prepare_cached("SELECT data FROM akd_record WHERE label=? ORDER BY epoch")
            .map_err(storage)?;
        let rows = query
            .query_map([&label.0], |row| row.get::<_, Vec<u8>>(0))
            .map_err(storage)?;
        let states: Vec<_> = rows
            .map(|row| value_state(row.map_err(storage)?))
            .collect::<Result<_, _>>()?;
        if states.is_empty() {
            return Err(missing());
        }
        Ok(KeyData { states })
    }

    async fn get_user_state(
        &self,
        label: &AkdLabel,
        flag: ValueStateRetrievalFlag,
    ) -> Result<ValueState, StorageError> {
        use ValueStateRetrievalFlag::*;
        let (clause, bound) = match flag {
            MaxEpoch => ("epoch<=? ORDER BY epoch DESC", i64::MAX),
            MinEpoch => ("epoch<=? ORDER BY epoch", i64::MAX),
            SpecificVersion(n) => ("version=?", i64::try_from(n).map_err(storage)?),
            SpecificEpoch(n) => ("epoch=?", i64::try_from(n).map_err(storage)?),
            LeqEpoch(n) => (
                "epoch<=? ORDER BY epoch DESC",
                i64::try_from(n).map_err(storage)?,
            ),
        };
        let sql = format!("SELECT data FROM akd_record WHERE label=? AND {clause} LIMIT 1");
        let raw = self
            .connection()?
            .query_row(&sql, params![label.0, bound], |r| r.get(0))
            .optional()
            .map_err(storage)?
            .ok_or_else(missing)?;
        value_state(raw)
    }

    async fn get_user_state_versions(
        &self,
        labels: &[AkdLabel],
        flag: ValueStateRetrievalFlag,
    ) -> Result<HashMap<AkdLabel, (u64, AkdValue)>, StorageError> {
        let mut versions = HashMap::new();
        for label in labels {
            match self.get_user_state(label, flag).await {
                Ok(state) => {
                    versions.insert(label.clone(), (state.version, state.value));
                }
                Err(StorageError::NotFound(_)) => {}
                Err(e) => return Err(e),
            }
        }
        Ok(versions)
    }
}
