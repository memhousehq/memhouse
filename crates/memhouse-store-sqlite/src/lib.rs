// SPDX-License-Identifier: Apache-2.0
//! SQLite store adapter, the embedded store of the Lite profile (ADR 0002, TR-LT-02..05): one
//! file in WAL mode, FTS5 for keywords with the subject inside the `MATCH`, half-precision
//! vectors scored in process by an exact scan of the subject (ADR 0003), jobs in tables of the
//! same file. The logical schema and the behaviour are those of the Postgres store (TR-CORE-04).

mod intake;
mod records;
mod schema;
mod search;
mod store;
mod util;
pub mod vector;

use rusqlite::Connection;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

/// The logical schema version this build migrates to (see `docs/schema.md`).
pub const SCHEMA_VERSION: u32 = memhouse_core::format::SCHEMA_VERSION;

/// The embedder this process writes with (set by `migrate`).
#[derive(Clone)]
struct Ident {
    embedder: String,
    /// Configuration hash (model, dimension, prefix), stamped with every vector.
    config: String,
    dim: usize,
}

struct Inner {
    /// Lite is one process and one writer: every call takes the connection for its own
    /// statements only, and never across an await.
    conn: Mutex<Connection>,
    /// Prefix the engine adds to passages before embedding; needed to purge cache entries on deletion.
    passage_prefix: String,
    ident: Mutex<Option<Ident>>,
}

#[derive(Clone)]
pub struct SqliteStore {
    inner: Arc<Inner>,
    /// (rows of a subject above which it applies, candidates kept for exact rescoring).
    prefilter: Option<(usize, usize)>,
}

impl SqliteStore {
    /// Open (or create) the database file. Writes are durable when they return (TR-LT-05):
    /// WAL with `synchronous = FULL`, and a full flush to the device where the OS tells the two
    /// apart (macOS).
    pub fn open(path: &Path, passage_prefix: &str) -> anyhow::Result<SqliteStore> {
        let conn = Connection::open(path).map_err(|e| anyhow::anyhow!("cannot open the SQLite database {}: {e}", path.display()))?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON;")?;
        Self::with_connection(conn, passage_prefix)
    }

    /// A private in-memory database, for tests: nothing is kept.
    pub fn in_memory(passage_prefix: &str) -> anyhow::Result<SqliteStore> {
        Self::with_connection(Connection::open_in_memory()?, passage_prefix)
    }

    fn with_connection(conn: Connection, passage_prefix: &str) -> anyhow::Result<SqliteStore> {
        // Cascades (structured rows, code references, links, source references) rely on it.
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        // Another process on the same file (a command-line tool beside the server) waits its turn.
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        conn.set_prepared_statement_cache_capacity(256);
        Ok(SqliteStore { inner: Arc::new(Inner { conn: Mutex::new(conn), passage_prefix: passage_prefix.to_string(), ident: Mutex::new(None) }), prefilter: None })
    }

    /// Turn on the binary prefilter of ADR 0003 for recalls over subjects with more than
    /// `min_rows` scored memories: the `depth` nearest by sign bits are rescored exactly. Off by
    /// default, because it is not exact; enable it only where the exactness check still passes.
    pub fn with_bit_prefilter(mut self, min_rows: usize, depth: usize) -> SqliteStore {
        self.prefilter = Some((min_rows, depth.max(1)));
        self
    }

    /// A value of the store's own bookkeeping (`schema_version`, `embedder`, ...).
    pub fn meta(&self, key: &str) -> anyhow::Result<Option<String>> {
        meta(&self.conn(), key)
    }

    fn conn(&self) -> MutexGuard<'_, Connection> {
        // A panic while the lock was held rolled its transaction back; the connection is sound.
        self.inner.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn ident(&self) -> Option<Ident> {
        self.inner.ident.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The cache key of a passage's vector: what the engine hashed when it embedded it.
    fn cache_hash(&self, content: &str) -> String {
        memhouse_core::engine::content_hash(&format!("{}{content}", self.inner.passage_prefix))
    }

    /// The guards' errors, said the way the Postgres store says them.
    fn explain(&self, c: &Connection, e: anyhow::Error) -> anyhow::Error {
        let text = e.to_string();
        if text.contains(schema::EMBEDDER_GUARD) {
            let db = meta(c, "embedder").ok().flatten().unwrap_or_default();
            let mine = self.ident().map(|i| i.embedder).unwrap_or_default();
            return memhouse_core::error::conflict(format!("this database is now embedded with {db}, not {mine}; restart with the new [embedding] configuration"));
        }
        if text.contains(schema::POLICY_GUARD) {
            return anyhow::anyhow!("this policy version is not approved; only approved policies execute");
        }
        e
    }
}

fn meta(c: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    let exists = util::first(c, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'mh_meta'", [], |_| Ok(()))?.is_some();
    if !exists {
        return Ok(None);
    }
    util::first(c, "SELECT value FROM mh_meta WHERE key = ?1", [key], |r| Ok(r.get(0)?))
}

/// The subject as one FTS5 token (letters and digits only, so the tokenizer keeps it whole;
/// the final digit keeps the stemmer from reading a suffix into the hash). The tenant is part
/// of it: two tenants' subjects of one name never share a token.
fn subject_token(tenant: &str, subject: &str) -> String {
    format!("s{}0", &memhouse_core::engine::content_hash(&format!("{tenant}\u{1f}{subject}"))[..24])
}
