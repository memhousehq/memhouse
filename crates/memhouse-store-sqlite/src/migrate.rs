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
pub(crate) const STEPS: &[Step] = &[Step { to: 9, what: "the record's language", run: add_language }];

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
    let file = open.open(dest).map_err(|e| anyhow::anyhow!("cannot create the snapshot {}: {e}", dest.display()))?;
    let name = dest.to_str().ok_or_else(|| anyhow::anyhow!("the snapshot path {} is not valid UTF-8", dest.display()))?;
    let written = c.execute("VACUUM INTO ?1", [name]).map_err(anyhow::Error::from).and_then(|_| Ok(file.sync_all()?));
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
        };
        let hash = memhouse_core::engine::content_hash(&m.content);
        let mut n = NewMemory::new(m, hash);
        n.embedding = Some(vec![1.0, 0.0, 0.0, 0.0]);
        n
    }

    /// Take a file of this build back to logical schema version 8, which differs from 9 by the
    /// `language` column alone (`docs/schema.md`): the file a version-8 Lite build would have left.
    fn make_version_8(path: &Path) {
        let c = Connection::open(path).unwrap();
        c.execute_batch("ALTER TABLE mh_memory DROP COLUMN language; UPDATE mh_meta SET value = '8' WHERE key = 'schema_version';").unwrap();
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

        let store = SqliteStore::open(&path, "").unwrap();
        store.migrate(4, EMBEDDER).await.unwrap();

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
        assert!(!columns.contains(&"language".to_string()));
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
