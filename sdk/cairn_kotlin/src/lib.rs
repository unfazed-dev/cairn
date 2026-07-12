//! `cairn-kotlin` — UniFFI bridge exposing `cairn_client::SyncClient<SqliteStorage>`
//! to Kotlin (Android). Mirrors `sdk/cairn_swift/src/lib.rs` and (structurally)
//! `sdk/cairn_tauri/src/lib.rs` + `sdk/cairn_node/src/lib.rs` — the SAME
//! `SyncClient<SqliteStorage>` the native, Tauri, Flutter, Swift, and Node SDKs
//! drive, loaded into Kotlin via UniFFI's proc-macro FFI, with no engine/wire
//! changes.
//!
//! # Why this exists
//! Feasibility scaffold for the "cheap-catch-up multi-platform" thesis: prove
//! the SAME client the five sibling SDKs drive can be loaded from Android
//! (Kotlin/JNI), with no engine/wire changes. Scope is "Rust compiles for
//! `aarch64-linux-android` + UniFFI generates Kotlin + an `.aar` bundles the
//! `.so` + an instrumented test on emulator-5554 round-trips `connect()` +
//! `query()`" — NOT a polished SDK.
//!
//! # Runtime shape
//! `CairnClient` owns a `tokio::runtime::Runtime` (the same shape
//! `sdk/cairn_node`'s and `sdk/cairn_swift`'s `CairnClient` use) so that
//! `connect`/`write`/`query`/`checkpoint` — all of which `.await` on
//! `SyncClient`'s async API — can be surfaced to Kotlin as **synchronous**
//! methods. UniFFI async (the `tokio` feature + `#[uniffi::method(async_runtime = "tokio")]`)
//! is the alternative path but adds ForeignFuture plumbing friction that is
//! not load-bearing for a scaffold; `block_on` from the foreign (JNI) thread
//! is simpler and matches `cairn_swift`'s "own runtime, block internally"
//! precedent. Kotlin's calling thread blocks briefly on each call; a future
//! `subscribe()` run loop will be spawned onto the owned runtime (mirrors
//! `cairn_node::CairnClient::subscribe`).
//!
//! # ponytail: `unsafe` policy
//! Hand-written `unsafe` is forbidden in this crate (`#![forbid(unsafe_code)]`).
//! UniFFI's macro-generated FFI scaffolding lives in the `uniffi` dependency's
//! proc-macro output, not in this crate's hand-written source, so the forbid
//! does not interact with it — same precedent as `cairn_swift`, `cairn_tauri`
//! (tauri's macro FFI), and `cairn_node` (napi-derive macro FFI). ADR-0015
//! addendum: machine-generated FFI glue is the one workspace-wide exception.
//!
//! # ponytail: deferred surfaces (upgrade path)
//! - **`subscribe(table, where_sql)` + the run loop**: not wired. The owned
//!   `rt` is retained precisely so a future `subscribe` method can
//!   `rt.spawn(client.run_with_reconnect())` (mirroring `cairn_node`'s
//!   `subscribe`). Ceiling: no row-tick callback / live sync yet; callers are
//!   offline-only. Upgrade path: add `subscribe` + a UniFFI callback interface
//!   for row-ticks, same shape as the Flutter `rows_sink`.
//! - **ABI matrix**: `aarch64-linux-android` (arm64-v8a) is the proof target
//!   here — the running emulator is API 37 / arm64. `armv7-linux-androideabi`
//!   + `x86_64-linux-android` targets are mechanical follow-ons (add the
//!   targets, the linker config triples, and a `jniLibs/<ABI>/libcairn_kotlin.so`
//!   per target). `i686-linux-android` (32-bit x86) is dropped — modern
//!   emulators are x86_64-only.

#![forbid(unsafe_code)]
// UniFFI proc-macro surface: clippy pedantic noise about "missing_errors_doc"
// on the FFI methods is not load-bearing for a scaffold; keep the surface
// readable instead (mirrors cairn_swift's allow list).
#![allow(clippy::missing_errors_doc)]
// Module-level prose bullets span multiple lines; clippy's
// `doc_lazy_continuation` lint demands per-line indent alignment that would
// make the prose unreadable for no API-doc payoff (no rustdoc is rendered
// from this scaffold's module header). Targeted allow, scoped to this crate.
#![allow(clippy::doc_lazy_continuation)]

use std::sync::Arc;
use std::time::Duration;

use cairn_client::{ClientError, SqliteStorage, SyncClient, SyncClientConfig};
use cairn_core::{PendingWrite, WriteOp};
use cairn_domain::Lsn;
use tokio::sync::Mutex as AsyncMutex;

// UniFFI scaffolding — emits the FFI entrypoints (`uniffi_*` symbols) that
// `uniffi-bindgen generate --library` reads to produce Kotlin bindings. The
// argument is the UniFFI namespace (becomes the generated `.kt` package path
// under `uniffi.cairn_kotlin` and the FFI symbol prefix).
uniffi::setup_scaffolding!("cairn_kotlin");

/// Session-level reconnect backstop — mirrors `sdk/cairn_swift`'s and
/// `sdk/cairn_node`'s `IDLE_RECONNECT_BACKSTOP` and the Flutter glue's constant
/// of the same name. Long relative to per-batch flush bounds: this is a rare
/// defense-in-depth reconnect, not a per-write latency mechanism.
const IDLE_RECONNECT_BACKSTOP: Duration = Duration::from_secs(120);

/// UniFFI-visible error type. UniFFI 0.28 refuses to bindgen `Result<_, String>`
/// ("unknown throw type: Some(String)"); every FFI method therefore returns
/// `Result<_, CairnError>`, with the message preserved verbatim from the
/// underlying `StorageError` / `ClientError` / `serde_json::Error`. The single
/// `Message` variant keeps the Kotlin side a simple
/// `throw CairnError.Message(description = ...)` — matching `cairn_node`'s
/// single-reason `napi::Error::from_reason` shape and `cairn_swift`'s enum.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CairnError {
    #[error("{description}")]
    Message {
        description: String,
    },
}

impl CairnError {
    /// Wrap any error Display-able into the single-variant `CairnError`.
    /// Used as the `.map_err(CairnError::wrap)` shorthand throughout.
    fn wrap<E: std::fmt::Display>(e: E) -> Self {
        CairnError::Message {
            description: e.to_string(),
        }
    }
}

/// A live Cairn client handle for Kotlin. Owns the tokio runtime the
/// `SyncClient`'s async API runs on, plus at most one active session (v1: one
/// table per client, matching `cairn-client`'s Phase-0 predicate floor and the
/// sibling SDKs).
///
/// Construct via `CairnClient(url, token: nil, dbPath:)` then call `connect()`
/// (opens the local SQLite store + builds the `SyncClient` — no network) and
/// drive `write` / `query` / `checkpoint`. All four are synchronous from
/// Kotlin's view — see the module `ponytail:` for why we chose sync-over-block
/// over UniFFI async.
#[derive(uniffi::Object)]
pub struct CairnClient {
    rt: tokio::runtime::Runtime,
    url: String,
    token: Option<String>,
    db_path: String,
    session: AsyncMutex<Option<Session>>,
}

/// The active session. Dropping this — including via a second `connect()`
/// replacing it — releases the `Arc<SyncClient<SqliteStorage>>`. (No
/// `run_task` to abort today — `subscribe()` is the ponytail.)
struct Session {
    client: Arc<SyncClient<SqliteStorage>>,
    table: String,
}

#[uniffi::export]
impl CairnClient {
    /// Construct a handle. Does no network I/O and does not open the store yet
    /// — `connect()` does. `db_path` is the SQLite file path (rusqlite accepts
    /// `":memory:"` for an ephemeral store, useful for tests).
    ///
    /// # Errors
    /// `CairnError` if the owned tokio runtime fails to initialize (resource
    /// exhaustion).
    #[uniffi::constructor]
    pub fn new(
        url: String,
        token: Option<String>,
        db_path: String,
    ) -> Result<Arc<Self>, CairnError> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(CairnError::wrap)?;
        Ok(Arc::new(Self {
            rt,
            url,
            token,
            db_path,
            session: AsyncMutex::new(None),
        }))
    }

    /// Open the local SQLite store at `db_path` and build a `SyncClient`
    /// against `url`. No network I/O — the subscribe/run loop is a separate
    /// (not-yet-wired) method. Idempotent: a second call while a session is
    /// live is a no-op. The default table is `tasks` (matches `cairn_node`,
    /// `cairn_tauri`, and `cairn_swift`).
    ///
    /// # Errors
    /// `CairnError` if the SQLite store can't be opened/migrated.
    pub fn connect(&self) -> Result<(), CairnError> {
        self.rt.block_on(async {
            let mut guard = self.session.lock().await;
            if guard.is_some() {
                return Ok(());
            }
            let storage = SqliteStorage::open(&self.db_path).map_err(CairnError::wrap)?;
            let config = SyncClientConfig {
                table: "tasks".to_owned(),
                token: self.token.clone(),
                idle_timeout: Some(IDLE_RECONNECT_BACKSTOP),
                ..SyncClientConfig::default()
            };
            let client = Arc::new(SyncClient::new(self.url.clone(), storage, config));
            *guard = Some(Session {
                client,
                table: "tasks".to_owned(),
            });
            Ok(())
        })
    }

    /// Enqueue a durable write against the active session's table. Resolves
    /// once the write is captured in the local outbox (NOT once the server
    /// acks it — ADR-0013 outbox contract). `op` is `"upsert"` / `"delete"` /
    /// `"patch"` (column-level UPDATE — `payload_json` carries only the
    /// changed columns). `table` MUST match the active session's table.
    ///
    /// # Errors
    /// `CairnError` if no session is active, the table mismatches, the op
    /// string is unknown, or the durable enqueue itself failed (disk full /
    /// busy).
    pub fn write(
        &self,
        table: String,
        op: String,
        pk: String,
        payload_json: Option<String>,
    ) -> Result<u64, CairnError> {
        self.rt.block_on(async {
            let write_op = match op.as_str() {
                "upsert" => WriteOp::Upsert,
                "delete" => WriteOp::Delete,
                "patch" => WriteOp::Patch,
                other => {
                    return Err(CairnError::Message {
                        description: format!(
                            "unknown write op {other:?}: expected \"upsert\", \"delete\", or \"patch\""
                        ),
                    })
                }
            };
            let client = {
                let guard = self.session.lock().await;
                let session = guard
                    .as_ref()
                    .ok_or_else(|| CairnError::Message {
                        description: "write() called before connect()".to_string(),
                    })?;
                if session.table != table {
                    return Err(CairnError::Message {
                        description: format!(
                            "write() table {table:?} does not match active session table {:?} — v1 supports one table per CairnClient",
                            session.table
                        ),
                    });
                }
                Arc::clone(&session.client)
            };
            let seq = client
                .write(PendingWrite {
                    table,
                    op: write_op,
                    pk,
                    payload_json,
                })
                .await
                .map_err(|e: ClientError| CairnError::wrap(e))?;
            Ok(seq)
        })
    }

    /// Run an arbitrary `SELECT` against the on-device SQLite store and return
    /// a JSON-array-of-objects STRING (one object per row, keyed by column
    /// name) — the same shape `cairn_node`'s, `cairn_tauri`'s, and
    /// `cairn_swift`'s `query()` emit. Requires `connect()` to have run.
    ///
    /// # Errors
    /// `CairnError` if no session is active or the SQL fails to prepare.
    pub fn query(&self, sql: String) -> Result<String, CairnError> {
        self.rt.block_on(async {
            let client = {
                let guard = self.session.lock().await;
                let session = guard
                    .as_ref()
                    .ok_or_else(|| CairnError::Message {
                        description: "query() called before connect()".to_string(),
                    })?;
                Arc::clone(&session.client)
            };
            // `with_storage` runs the closure on the client's storage task;
            // `query` is the read-side accessor on the same Mutex<Connection>
            // as the write path (see crates/cairn-client/src/sqlite.rs).
            let rows = client
                .with_storage(move |s| s.query(&sql))
                .await
                .map_err(|e: ClientError| CairnError::wrap(e))? // outer: ClientError
                .map_err(CairnError::wrap)?; // inner: StorageError (nested Result)
            serde_json::to_string(&rows).map_err(CairnError::wrap)
        })
    }

    /// Read the current durable LSN checkpoint (u64). Requires `connect()` to
    /// have run. A fresh store reports `0`.
    ///
    /// # Errors
    /// `CairnError` if no session is active or the checkpoint read fails.
    pub fn checkpoint(&self) -> Result<u64, CairnError> {
        self.rt.block_on(async {
            let client = {
                let guard = self.session.lock().await;
                let session = guard
                    .as_ref()
                    .ok_or_else(|| CairnError::Message {
                        description: "checkpoint() called before connect()".to_string(),
                    })?;
                Arc::clone(&session.client)
            };
            let lsn: Lsn = client.checkpoint().await.map_err(CairnError::wrap)?;
            Ok(lsn.0)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Proof-of-integration: the SAME `SyncClient<SqliteStorage>` the sibling
    /// SDKs drive constructs + serves an offline query through the UniFFI
    /// `CairnClient` shape, with no live Kotlin/JNI runtime required. Mirrors
    /// `cairn_swift`'s and `cairn_tauri`'s offline smoke path (construct +
    /// query round-trip).
    #[test]
    fn cairn_client_offline_connect_query_round_trip() {
        let client = CairnClient::new(
            "ws://localhost:0".into(),
            None,
            ":memory:".into(),
        )
        .expect("construct");

        client.connect().expect("connect");

        let rows_json = client.query("SELECT 1 AS one".into()).expect("query");
        assert!(
            rows_json.contains("\"one\":1") || rows_json.contains("\"one\": 1"),
            "expected an one=1 row in the JSON, got: {rows_json}"
        );

        let lsn = client.checkpoint().expect("checkpoint");
        assert_eq!(lsn, 0, "fresh store should report Lsn(0)");
    }

    /// `write()` before `connect()` surfaces a clear error rather than
    /// panicking — the same contract `cairn_swift`, `cairn_tauri`, and
    /// `cairn_node` enforce.
    #[test]
    fn write_before_connect_is_an_error() {
        let client = CairnClient::new(
            "ws://localhost:0".into(),
            None,
            ":memory:".into(),
        )
        .expect("construct");

        let err = client
            .write("tasks".into(), "upsert".into(), "pk1".into(), None)
            .expect_err("write before connect should error");
        let msg = err.to_string();
        assert!(
            msg.contains("before connect"),
            "expected a before-connect error, got: {msg}"
        );
    }
}
