// SPDX-License-Identifier: Apache-2.0
//! Schema upgrades of a Lite file (TR-LT-10): an ordered list of steps, each taking the file to
//! one logical schema version (`docs/schema.md`), run after a snapshot of the file as it was.

use crate::util::{exec, first};
use crate::SCHEMA_VERSION;
use rusqlite::Connection;
use std::path::{Path, PathBuf};

pub(crate) struct Step {
    /// The logical schema version the file has after this step.
    pub to: u32,
    pub what: &'static str,
    pub run: fn(&Connection) -> anyhow::Result<()>,
}

/// In version order, without gaps. A file is upgraded by every step above its version; what a
/// step adds is also in `schema::DDL`, which creates a new file at the current version.
pub(crate) const STEPS: &[Step] = &[
    Step { to: 9, what: "the record's language", run: add_language },
    Step { to: 10, what: "staleness of code references", run: add_staleness },
    Step { to: 11, what: "console sessions", run: add_sessions },
];

/// The oldest version the steps start from.
pub(crate) fn oldest() -> u32 {
    STEPS.first().map_or(SCHEMA_VERSION, |s| s.to - 1)
}

fn has_column(c: &Connection, table: &str, column: &str) -> anyhow::Result<bool> {
    Ok(first(c, "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2", [table, column], |_| Ok(()))?.is_some())
}

/// Version 9: `mh_memory.language`, absent on records written before.
fn add_language(c: &Connection) -> anyhow::Result<()> {
    if !has_column(c, "mh_memory", "language")? {
        exec(c, "ALTER TABLE mh_memory ADD COLUMN language TEXT", [])?;
    }
    Ok(())
}

/// Version 10: since when a code reference is stale and the hash last seen, and the earliest
/// of them on the record. Absent (not stale) on everything written before.
fn add_staleness(c: &Connection) -> anyhow::Result<()> {
    for (table, column, ty) in [("mh_code_ref", "stale_since", "INTEGER"), ("mh_code_ref", "seen_hash", "TEXT"), ("mh_memory", "stale_since", "INTEGER")] {
        if !has_column(c, table, column)? {
            exec(c, &format!("ALTER TABLE {table} ADD COLUMN {column} {ty}"), [])?;
        }
    }
    // From this version a reference is matched by its path in one form (TPL-04): rows written
    // before, with the path as the writer spelled it (`./src//a.rs`), are put in it. Where a
    // memory then has two rows for one path, the one already in that form is kept.
    let stored: Vec<(String, String)> =
        c.prepare("SELECT memory_id, path FROM mh_code_ref ORDER BY memory_id, path")?.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    let stored: Vec<(uuid::Uuid, String)> = stored.into_iter().map(|(id, path)| Ok((id.parse()?, path))).collect::<anyhow::Result<_>>()?;
    for (id, from, to) in memhouse_core::staleness::canonical_paths(&stored) {
        match to {
            Some(to) => exec(c, "UPDATE mh_code_ref SET path = ?3 WHERE memory_id = ?1 AND path = ?2", rusqlite::params![id.to_string(), from, to])?,
            None => exec(c, "DELETE FROM mh_code_ref WHERE memory_id = ?1 AND path = ?2", rusqlite::params![id.to_string(), from])?,
        };
    }
    // The count only: a path may say more about a repository than a log should hold.
    let skipped = memhouse_core::staleness::uncanonical_paths(&stored);
    if skipped > 0 {
        tracing::warn!(
            rows = skipped,
            "schema upgrade: code references whose path has no canonical form (it leaves the repository with `..`, or is too long) were left as stored; they match no file report (docs/schema.md)"
        );
    }
    Ok(())
}

/// Version 11: the table of console sessions (`mh_session`). It is a new table and starts
/// empty, so the step has nothing to move: `schema::DDL`, run after the steps, creates it.
fn add_sessions(_c: &Connection) -> anyhow::Result<()> {
    Ok(())
}

/// A file written by a newer MemHouse is not opened: this build does not know what it holds.
pub(crate) fn refuse_newer(stored: Option<&str>, file: &str) -> anyhow::Result<()> {
    let Some(v) = stored else { return Ok(()) };
    let v: u32 = v.parse().map_err(|_| anyhow::anyhow!("{file} has an unreadable schema version {v:?}"))?;
    anyhow::ensure!(
        v <= SCHEMA_VERSION,
        "{file} has schema version {v}, written by a newer MemHouse; this build reads up to version {SCHEMA_VERSION}. Upgrade MemHouse to open it (the file was not changed)"
    );
    Ok(())
}

/// The steps that take a file at `stored` to the current version.
pub(crate) fn pending(stored: u32) -> anyhow::Result<impl Iterator<Item = &'static Step>> {
    anyhow::ensure!(stored >= oldest(), "this database has schema version {stored}; this build upgrades from version {} or later", oldest());
    Ok(STEPS.iter().filter(move |s| s.to > stored))
}

/// Where the copy of a file goes before it is upgraded to `to`: beside it.
pub(crate) fn snapshot_path(db: &Path, to: u32) -> PathBuf {
    let mut name = db.file_name().unwrap_or_default().to_os_string();
    name.push(format!(".before-v{to}-{}", chrono::Utc::now().format("%Y%m%dT%H%M%S%3fZ")));
    db.with_file_name(name)
}

/// A consistent copy of the database into a new file of the user's alone, while the database
/// may be in use: SQLite writes it from one read transaction (`VACUUM INTO`), so it holds every
/// committed write and no half of one, which a copy of a WAL database's files would not promise.
pub(crate) fn snapshot(c: &Connection, dest: &Path) -> anyhow::Result<()> {
    let mut open = std::fs::OpenOptions::new();
    // Never over a file that is there; created closed to others, before any content is in it.
    open.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.mode(0o600);
    }
    // Before the file is created: a path SQLite cannot be given must not leave an empty file behind.
    let name = dest.to_str().ok_or_else(|| anyhow::anyhow!("the snapshot path {} is not valid UTF-8", dest.display()))?;
    let file = open.open(dest).map_err(|e| anyhow::anyhow!("cannot create the snapshot {}: {e}", dest.display()))?;
    // The file, then its name: the copy must outlive a power failure before anything is upgraded.
    let dir = dest.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let written = c.execute("VACUUM INTO ?1", [name]).map_err(anyhow::Error::from).and_then(|_| Ok(file.sync_all()?)).and_then(|_| crate::sync_dir(dir));
    if let Err(e) = written {
        let _ = std::fs::remove_file(dest);
        anyhow::bail!("cannot write the snapshot {}: {e}", dest.display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::SqliteStore;
    use chrono::{Duration, Utc};
    use memhouse_core::types::*;
    use memhouse_core::Store;
    use rusqlite::Connection;
    use std::path::{Path, PathBuf};
    use uuid::Uuid;

    const EMBEDDER: &str = "test:axis";

    fn record(content: &str) -> NewMemory {
        let now = Utc::now();
        let m = Memory {
            id: Uuid::now_v7(),
            tenant: "acme".into(),
            subject: "user:ada".into(),
            kind: MemoryKind::Semantic,
            status: MemoryStatus::Committed,
            content: content.into(),
            session_id: None,
            turn_ref: None,
            occurred_at: None,
            valid_from: now - Duration::seconds(1),
            valid_to: None,
            supersedes: None,
            labels: vec![],
            tags: vec![],
            source: "test".into(),
            confidence: 0.9,
            metadata: serde_json::json!({}),
            created_at: now,
            expires_at: None,
            scope: Scope::default(),
            provenance: Provenance::default(),
            language: None,
            stale_since: None,
        };
        let hash = memhouse_core::engine::content_hash(&m.content);
        let mut n = NewMemory::new(m, hash);
        n.embedding = Some(vec![1.0, 0.0, 0.0, 0.0]);
        n
    }

    /// Take a file of this build back to logical schema version 8, which differs from the
    /// current one by the `language` column (version 9), the staleness columns (version 10)
    /// and the session table (version 11, `docs/schema.md`): the file a version-8 Lite build
    /// would have left.
    fn make_version_8(path: &Path) {
        let c = Connection::open(path).unwrap();
        c.execute_batch(
            "ALTER TABLE mh_memory DROP COLUMN language; ALTER TABLE mh_memory DROP COLUMN stale_since; \
             ALTER TABLE mh_code_ref DROP COLUMN stale_since; ALTER TABLE mh_code_ref DROP COLUMN seen_hash; \
             DROP TABLE mh_session; \
             UPDATE mh_meta SET value = '8' WHERE key = 'schema_version';",
        )
        .unwrap();
    }

    fn session(secret_hash: &str) -> memhouse_core::identity::Session {
        let now = chrono::DateTime::from_timestamp_micros(Utc::now().timestamp_micros()).unwrap();
        memhouse_core::identity::Session {
            id: secret_hash.into(),
            tenant: "acme".into(),
            principal_id: "admin:ada".into(),
            key_id: "k1".into(),
            key_check: None,
            created_at: now,
            expires_at: now + chrono::Duration::hours(8),
            last_seen_at: now,
        }
    }

    /// Version 11 adds a table and moves nothing: a version 10 file is copied, gains
    /// `mh_session` empty, and keeps every row it had.
    #[tokio::test]
    async fn a_version_10_file_gains_the_session_table() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("memhouse.db");
        let a = record("Ada lives in Porto");
        {
            let store = SqliteStore::open(&path, "").unwrap();
            store.migrate(4, EMBEDDER).await.unwrap();
            store.insert(std::slice::from_ref(&a)).await.unwrap();
        }
        Connection::open(&path).unwrap().execute_batch("DROP TABLE mh_session; UPDATE mh_meta SET value = '10' WHERE key = 'schema_version';").unwrap();
        let store = SqliteStore::open(&path, "").unwrap();
        store.migrate(4, EMBEDDER).await.unwrap();
        assert_eq!(version_of(&path), crate::SCHEMA_VERSION.to_string());
        let copies = snapshots(dir.path());
        assert_eq!((copies.len(), version_of(&copies[0]).as_str()), (1, "10"));
        assert_eq!(store.get("acme", a.memory.id).await.unwrap().unwrap().content, "Ada lives in Porto");
        // The table works: put, read, touch, purge by end and by idleness, delete.
        let s = session("hash-one");
        store.session_put(&s).await.unwrap();
        assert_eq!(store.session_get("hash-one").await.unwrap().as_ref(), Some(&s));
        assert!(store.session_put(&s).await.is_err(), "a session id is stored once");
        let later = s.last_seen_at + chrono::Duration::minutes(5);
        store.session_touch("hash-one", later).await.unwrap();
        store.session_touch("hash-one", s.last_seen_at).await.unwrap();
        assert_eq!(store.session_get("hash-one").await.unwrap().unwrap().last_seen_at, later, "the last use never moves back");
        let mut ended = session("hash-ended");
        ended.expires_at = s.created_at - chrono::Duration::seconds(1);
        let mut idle = session("hash-idle");
        idle.last_seen_at = s.created_at - chrono::Duration::hours(2);
        store.session_put(&ended).await.unwrap();
        store.session_put(&idle).await.unwrap();
        assert_eq!(store.sessions_purge(s.created_at, None).await.unwrap(), 1);
        assert_eq!(store.sessions_purge(s.created_at, Some(s.created_at - chrono::Duration::hours(1))).await.unwrap(), 1);
        assert!(store.session_get("hash-one").await.unwrap().is_some());
        assert!(store.session_delete("hash-one").await.unwrap() && !store.session_delete("hash-one").await.unwrap());
        // Erasing the tenant ends its sessions with everything else.
        store.session_put(&session("hash-two")).await.unwrap();
        store.delete_tenant("acme", "test").await.unwrap();
        assert!(store.session_get("hash-two").await.unwrap().is_none());
    }

    fn snapshots(dir: &Path) -> Vec<PathBuf> {
        let mut found: Vec<PathBuf> =
            std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).filter(|p| p.file_name().unwrap().to_str().unwrap().contains(".before-v")).collect();
        found.sort();
        found
    }

    fn version_of(path: &Path) -> String {
        Connection::open(path).unwrap().query_row("SELECT value FROM mh_meta WHERE key = 'schema_version'", [], |r| r.get(0)).unwrap()
    }

    #[tokio::test]
    async fn an_older_file_is_copied_then_upgraded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("memhouse.db");
        let (a, b) = (record("Ada lives in Porto"), record("Ada prefers tea"));
        {
            let store = SqliteStore::open(&path, "").unwrap();
            store.migrate(4, EMBEDDER).await.unwrap();
            store.insert(&[a.clone(), b.clone()]).await.unwrap();
            store.audit("test", "memory.write", "acme", Some("user:ada"), Some(a.memory.id), serde_json::json!({})).await.unwrap();
            assert!(snapshots(dir.path()).is_empty(), "a new file is not an upgrade");
        }
        make_version_8(&path);
        assert_eq!(version_of(&path), "8");
        // References as a version 8 process stored them: the path as the writer spelled it.
        {
            let old = Connection::open(&path).unwrap();
            for (id, p, h) in [(a.memory.id, "./src//a.rs", "h1"), (b.memory.id, "src\\b.rs", "h1"), (b.memory.id, "src/b.rs", "h2"), (b.memory.id, "../outside", "h1")] {
                old.execute(
                    "INSERT INTO mh_code_ref (memory_id, tenant, subject, path, blob_hash) VALUES (?1, 'acme', 'user:ada', ?2, ?3)",
                    rusqlite::params![id.to_string(), p, h],
                )
                .unwrap();
            }
        }

        let store = SqliteStore::open(&path, "").unwrap();
        store.migrate(4, EMBEDDER).await.unwrap();
        // The upgrade put them in the form observations are matched in: one row per file, the
        // one already in that form kept, a path that has none left alone.
        let paths = |id: uuid::Uuid| -> Vec<(String, String)> {
            let c = store.conn();
            let mut q = c.prepare("SELECT path, blob_hash FROM mh_code_ref WHERE memory_id = ?1 ORDER BY path").unwrap();
            q.query_map([id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().collect::<Result<_, _>>().unwrap()
        };
        assert_eq!(paths(a.memory.id), vec![("src/a.rs".to_string(), "h1".to_string())]);
        assert_eq!(paths(b.memory.id), vec![("../outside".to_string(), "h1".to_string()), ("src/b.rs".to_string(), "h2".to_string())]);
        let seen = store.code_refs_observe("acme", "user:ada", &[FileState::present("src/a.rs", "h9")], Utc::now(), &memhouse_core::traits::no_audit).await.unwrap();
        assert!(seen.len() == 1 && seen[0].flagged && seen[0].id == a.memory.id, "a reference stored as ./src//a.rs follows its file: {seen:?}");

        // The copy is the file as it was: version 8, no `language` column, both records.
        let copies = snapshots(dir.path());
        assert_eq!(copies.len(), 1, "{copies:?}");
        let name = copies[0].file_name().unwrap().to_str().unwrap().to_string();
        assert!(name.starts_with(&format!("memhouse.db.before-v{}-", crate::SCHEMA_VERSION)), "{name}");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&copies[0]).unwrap().permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(version_of(&copies[0]), "8");
        let old = Connection::open(&copies[0]).unwrap();
        let columns: Vec<String> = old.prepare("SELECT name FROM pragma_table_info('mh_memory')").unwrap().query_map([], |r| r.get(0)).unwrap().collect::<Result<_, _>>().unwrap();
        assert!(!columns.contains(&"language".to_string()) && !columns.contains(&"stale_since".to_string()));
        assert_eq!(old.query_row("SELECT count(*) FROM mh_memory", [], |r| r.get::<_, i64>(0)).unwrap(), 2);

        // The upgraded file: the current version, the data intact and readable, keywords and audit chain included.
        assert_eq!(store.meta("schema_version").unwrap().as_deref(), Some(crate::SCHEMA_VERSION.to_string().as_str()));
        for n in [&a, &b] {
            let got = store.get("acme", n.memory.id).await.unwrap().expect("the record is still there");
            assert_eq!((got.content.as_str(), got.language.as_deref()), (n.memory.content.as_str(), None));
        }
        let found: i64 = store.conn().query_row("SELECT count(*) FROM mh_memory_fts WHERE mh_memory_fts MATCH 'porto'", [], |r| r.get(0)).unwrap();
        assert_eq!(found, 1);
        assert_eq!(store.audit_verify().await.unwrap(), (1, None));
        // What version 9 added works on the upgraded file.
        let mut c = record("Ada spricht Deutsch");
        c.memory.language = Some("de".into());
        store.insert(std::slice::from_ref(&c)).await.unwrap();
        assert_eq!(store.get("acme", c.memory.id).await.unwrap().unwrap().language.as_deref(), Some("de"));
        // And what version 10 added: a reference goes stale when its file is seen changed.
        let mut d = record("The parser lives in src/parse.rs");
        d.code_refs = vec![CodeRef::new("src/parse.rs", "h1")];
        store.insert(std::slice::from_ref(&d)).await.unwrap();
        let flagged = store.code_refs_observe("acme", "user:ada", &[FileState::present("src/parse.rs", "h2")], Utc::now(), &memhouse_core::traits::no_audit).await.unwrap();
        assert!(flagged.len() == 1 && flagged[0].flagged && store.get("acme", d.memory.id).await.unwrap().unwrap().stale_since.is_some());

        // Opening it again upgrades nothing and copies nothing.
        drop(store);
        SqliteStore::open(&path, "").unwrap().migrate(4, EMBEDDER).await.unwrap();
        assert_eq!(snapshots(dir.path()).len(), 1);
    }

    #[tokio::test]
    async fn a_newer_file_is_refused_and_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("memhouse.db");
        SqliteStore::open(&path, "").unwrap().migrate(4, EMBEDDER).await.unwrap();
        let newer = (crate::SCHEMA_VERSION + 1).to_string();
        Connection::open(&path).unwrap().execute("UPDATE mh_meta SET value = ?1 WHERE key = 'schema_version'", [&newer]).unwrap();
        let before = std::fs::read(&path).unwrap();
        let e = SqliteStore::open(&path, "").err().expect("a newer file is not opened").to_string();
        assert!(e.contains(&format!("schema version {newer}")) && e.contains("newer MemHouse") && e.contains("memhouse.db"), "{e}");
        assert_eq!(std::fs::read(&path).unwrap(), before, "the file was changed");
        assert!(snapshots(dir.path()).is_empty());
    }

    /// A newer process that stopped without closing leaves its last commits in the write-ahead
    /// log. The refusal reads them (the file alone still says the older version) and folds
    /// nothing into the file.
    #[tokio::test]
    async fn a_newer_file_with_a_write_ahead_log_is_refused_and_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("memhouse.db");
        SqliteStore::open(&path, "").unwrap().migrate(4, EMBEDDER).await.unwrap();
        let newer = (crate::SCHEMA_VERSION + 1).to_string();
        let writer = Connection::open(&path).unwrap();
        writer.execute_batch("PRAGMA wal_autocheckpoint = 0;").unwrap();
        writer.execute("UPDATE mh_meta SET value = ?1 WHERE key = 'schema_version'", [&newer]).unwrap();
        // The files as a stopped process leaves them: the database and its log, no one holding them.
        let left = dir.path().join("left");
        std::fs::create_dir(&left).unwrap();
        let (db, wal) = (left.join("memhouse.db"), left.join("memhouse.db-wal"));
        std::fs::copy(&path, &db).unwrap();
        std::fs::copy(dir.path().join("memhouse.db-wal"), &wal).unwrap();
        drop(writer);
        let before = (std::fs::read(&db).unwrap(), std::fs::read(&wal).unwrap());
        assert!(!before.1.is_empty(), "the newer version is only in the log");

        let e = SqliteStore::open(&db, "").err().expect("a newer file is not opened").to_string();
        assert!(e.contains(&format!("schema version {newer}")) && e.contains("newer MemHouse"), "{e}");
        assert_eq!(std::fs::read(&db).unwrap(), before.0, "the log was folded into the file");
        assert_eq!(std::fs::read(&wal).unwrap(), before.1, "the log was changed or removed");
    }

    #[tokio::test]
    async fn a_file_older_than_any_step_is_refused_without_a_copy() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("memhouse.db");
        SqliteStore::open(&path, "").unwrap().migrate(4, EMBEDDER).await.unwrap();
        Connection::open(&path).unwrap().execute("UPDATE mh_meta SET value = '7' WHERE key = 'schema_version'", []).unwrap();
        let e = SqliteStore::open(&path, "").unwrap().migrate(4, EMBEDDER).await.unwrap_err().to_string();
        assert!(e.contains("schema version 7") && e.contains("version 8 or later"), "{e}");
        assert!(snapshots(dir.path()).is_empty());
    }

    #[test]
    fn steps_are_in_order_and_end_at_the_current_version() {
        let versions: Vec<u32> = super::STEPS.iter().map(|s| s.to).collect();
        assert_eq!(versions, (super::oldest() + 1..=crate::SCHEMA_VERSION).collect::<Vec<_>>());
    }
}
