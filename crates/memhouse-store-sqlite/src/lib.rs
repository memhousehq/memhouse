// SPDX-License-Identifier: Apache-2.0
//! SQLite store adapter, the embedded store of the Lite profile (ADR 0002, TR-LT-02..05): one
//! file in WAL mode, FTS5 for keywords with the subject inside the `MATCH`, half-precision
//! vectors scored in process by an exact scan of the subject (ADR 0003), jobs in tables of the
//! same file. The logical schema and the behaviour are those of the Postgres store (TR-CORE-04).

pub mod backup;
mod intake;
mod migrate;
mod records;
mod schema;
mod search;
mod store;
mod util;
pub mod vector;

use rusqlite::Connection;
use std::path::{Path, PathBuf};
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
    /// The database file; `None` in memory. Where the pre-upgrade snapshot goes (TR-LT-10).
    path: Option<PathBuf>,
    /// Prefix the engine adds to passages before embedding; needed to purge cache entries on deletion.
    passage_prefix: String,
    ident: Mutex<Option<Ident>>,
}

#[derive(Clone)]
pub struct SqliteStore {
    inner: Arc<Inner>,
    /// (rows of a subject above which it applies, candidates kept for exact rescoring).
    prefilter: Option<(usize, usize)>,
    /// Whether `migrate` keeps a copy of an older file before upgrading it (TR-LT-10).
    upgrade_snapshot: bool,
}

/// The directory a database lives in: created for the user alone when it is missing; refused
/// when it belongs to someone else or others may write to it. A database file is only as
/// trustworthy as the directory that can hold its journal.
pub fn private_dir(dir: &Path) -> anyhow::Result<()> {
    if !dir.exists() {
        std::fs::create_dir_all(dir).map_err(|e| anyhow::anyhow!("cannot create the database directory {}: {e}", dir.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let meta = std::fs::metadata(dir)?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        let me = unsafe { libc::geteuid() };
        anyhow::ensure!(
            meta.is_dir() && meta.uid() == me,
            "the database directory {} does not belong to this user: the Lite store only opens a database in a directory of its own user",
            dir.display()
        );
        anyhow::ensure!(
            meta.mode() & 0o022 == 0,
            "the database directory {} can be written by other users (mode {:o}): close it first, for example `chmod 700 {}`",
            dir.display(),
            meta.mode() & 0o777,
            dir.display()
        );
    }
    Ok(())
}

impl SqliteStore {
    /// Open (or create) the database file. Writes are durable when they return (TR-LT-05):
    /// WAL with `synchronous = FULL`, and a full flush to the device where the OS tells the two
    /// apart (macOS).
    ///
    /// The file's directory must be the user's own and closed to others (see [`private_dir`]):
    /// SQLite trusts the `-wal` and `-shm` files it finds beside a database, so nobody else may
    /// be able to put one there.
    pub fn open(path: &Path, passage_prefix: &str) -> anyhow::Result<SqliteStore> {
        let dir = path.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
        private_dir(dir)?;
        let conn = Connection::open(path).map_err(|e| anyhow::anyhow!("cannot open the SQLite database {}: {e}", path.display()))?;
        // Before anything is written to it, journal mode included: a file of a newer MemHouse
        // is left exactly as it is (TR-LT-10).
        migrate::refuse_newer(
            meta(&conn, "schema_version").map_err(|e| anyhow::anyhow!("{} is not a MemHouse database: {e}", path.display()))?.as_deref(),
            &path.display().to_string(),
        )?;
        // The memories are the user's alone: no other account reads the file.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON;")?;
        Self::with_connection(conn, passage_prefix, Some(path.to_path_buf()))
    }

    /// A private in-memory database, for tests: nothing is kept.
    pub fn in_memory(passage_prefix: &str) -> anyhow::Result<SqliteStore> {
        Self::with_connection(Connection::open_in_memory()?, passage_prefix, None)
    }

    fn with_connection(conn: Connection, passage_prefix: &str, path: Option<PathBuf>) -> anyhow::Result<SqliteStore> {
        // Cascades (structured rows, code references, links, source references) rely on it.
        conn.execute_batch("PRAGMA foreign_keys = ON;")?;
        // Another process on the same file (a command-line tool beside the server) waits its turn.
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        conn.set_prepared_statement_cache_capacity(256);
        Ok(SqliteStore {
            inner: Arc::new(Inner { conn: Mutex::new(conn), path, passage_prefix: passage_prefix.to_string(), ident: Mutex::new(None) }),
            prefilter: None,
            upgrade_snapshot: true,
        })
    }

    /// Upgrade an older file without keeping a copy of it first. For a file that is itself a
    /// copy (a backup being restored): a second copy would keep what the deletion ledger is
    /// about to remove.
    pub fn without_upgrade_snapshot(mut self) -> SqliteStore {
        self.upgrade_snapshot = false;
        self
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
