// SPDX-License-Identifier: Apache-2.0
//! Backup and restore of a Lite database (TR-LT-09): a consistent snapshot of the file, and a
//! restore that re-applies the deletion ledger, so nothing deleted or erased after the snapshot
//! was taken comes back with it (TR-WF-03).
//!
//! The ledger that matters at a restore is the one kept *outside* the snapshot: the snapshot's
//! own ledger ends where the snapshot was taken. A restore therefore takes the ledger of the
//! database it replaces, or one exported earlier ([`write_ledger`]), and applies every row the
//! snapshot does not have yet.

use crate::records::audit_in;
use crate::util::{at, exec, first, rows, us};
use crate::SqliteStore;
use chrono::{DateTime, Utc};
use memhouse_core::types::EmbeddingIdentity;
use memhouse_core::Store;
use rusqlite::{params, Connection, OpenFlags, TransactionBehavior};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const MANIFEST_FORMAT: &str = "memhouse.backup";
pub const MANIFEST_VERSION: u32 = 1;
pub const MANIFEST_FILE: &str = "manifest.json";
pub const SNAPSHOT_FILE: &str = "memhouse.db";
pub const LEDGER_FILE: &str = "deletion-ledger.jsonl";

/// One row of the deletion ledger, as it is exported and re-applied.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub at: DateTime<Utc>,
    pub tenant: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_id: Option<Uuid>,
    /// `memory`, `retention`, `subject`, `subject-reset` or `tenant`.
    pub scope: String,
    pub actor: String,
}

/// What identifies a ledger row: the same deletion is applied once, whoever carries it.
type LedgerKey = (i64, String, Option<String>, Option<String>, String);

impl LedgerEntry {
    fn key(&self) -> LedgerKey {
        (us(self.at), self.tenant.clone(), self.subject.clone(), self.memory_id.map(|u| u.to_string()), self.scope.clone())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub file: String,
    pub sha256: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Counts {
    pub tenants: u64,
    pub subjects: u64,
    pub records: u64,
    pub policies: u64,
    pub audit_events: u64,
    pub ledger_entries: u64,
}

/// The canonical export of one tenant, beside the snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportEntry {
    pub tenant: String,
    pub file: String,
    pub sha256: String,
    pub records: u64,
    pub links: u64,
    pub policies: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub format: String,
    pub version: u32,
    pub created_at: DateTime<Utc>,
    pub producer: String,
    pub schema_version: u32,
    pub embedder: Option<EmbeddingIdentity>,
    pub snapshot: FileEntry,
    pub ledger: FileEntry,
    pub counts: Counts,
    /// Memory Format files, one per tenant; filled by whoever has an engine to export with.
    #[serde(default)]
    pub exports: Vec<ExportEntry>,
}

impl Manifest {
    /// Written last: flushing its directory also makes the names of the files written before it durable.
    pub fn write(&self, dir: &Path) -> anyhow::Result<()> {
        write_private(&dir.join(MANIFEST_FILE), (serde_json::to_string_pretty(self)? + "\n").as_bytes())
    }

    pub fn read(dir: &Path) -> anyhow::Result<Manifest> {
        let path = dir.join(MANIFEST_FILE);
        let text = std::fs::read_to_string(&path).map_err(|e| anyhow::anyhow!("{} is not a MemHouse backup: cannot read {}: {e}", dir.display(), path.display()))?;
        let m: Manifest = serde_json::from_str(&text).map_err(|e| anyhow::anyhow!("{} is not a backup manifest: {e}", path.display()))?;
        anyhow::ensure!(m.format == MANIFEST_FORMAT, "{} is not a backup manifest (format {:?})", path.display(), m.format);
        anyhow::ensure!(m.version <= MANIFEST_VERSION, "{} is a version {} manifest; this build reads up to {MANIFEST_VERSION}: upgrade MemHouse", path.display(), m.version);
        Ok(m)
    }

    /// The snapshot file of the backup in `dir`, once its content is what the manifest says.
    pub fn verified_snapshot(&self, dir: &Path) -> anyhow::Result<PathBuf> {
        // A manifest names files of its own directory only.
        anyhow::ensure!(
            Path::new(&self.snapshot.file).file_name().is_some_and(|n| n == self.snapshot.file.as_str()),
            "the manifest names a snapshot outside the backup: {:?}",
            self.snapshot.file
        );
        let path = dir.join(&self.snapshot.file);
        let found = sha256_file(&path)?;
        anyhow::ensure!(found == self.snapshot.sha256, "the snapshot {} does not match its manifest: sha256 {found}, expected {}", path.display(), self.snapshot.sha256);
        Ok(path)
    }
}

pub fn sha256_file(path: &Path) -> anyhow::Result<String> {
    let mut file = std::fs::File::open(path).map_err(|e| anyhow::anyhow!("cannot read {}: {e}", path.display()))?;
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(hex::encode(hash.finalize()))
}

/// A new file of the user's alone; never over one that is there.
pub fn create_private(path: &Path) -> anyhow::Result<std::fs::File> {
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.mode(0o600);
    }
    open.open(path).map_err(|e| anyhow::anyhow!("cannot create {}: {e}", path.display()))
}

/// A new private file with this content, durable when it returns: the file is flushed, then
/// its directory (a flushed file whose name is lost in a power failure is no backup).
fn write_private(path: &Path, content: &[u8]) -> anyhow::Result<()> {
    let mut file = create_private(path)?;
    file.write_all(content)?;
    file.sync_all()?;
    crate::sync_dir(path.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new(".")))
}

/// The directory a backup is written into: the user's own and closed to others, like the
/// database's (a backup holds everything the database does).
pub fn private_dir(dir: &Path) -> anyhow::Result<()> {
    crate::private_dir(dir)
}

/// Write ledger rows as JSON lines, into a new private file.
pub fn write_ledger(path: &Path, entries: &[LedgerEntry]) -> anyhow::Result<()> {
    let mut out = Vec::new();
    for e in entries {
        serde_json::to_writer(&mut out, e)?;
        out.push(b'\n');
    }
    write_private(path, &out)
}

pub fn read_ledger(path: &Path) -> anyhow::Result<Vec<LedgerEntry>> {
    let file = std::fs::File::open(path).map_err(|e| anyhow::anyhow!("cannot read the deletion ledger {}: {e}", path.display()))?;
    let mut entries = vec![];
    for (n, line) in std::io::BufReader::new(file).lines().enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        // A ledger that cannot be read in full is not applied in part: a skipped row is an erasure undone.
        entries.push(serde_json::from_str(&line).map_err(|e| anyhow::anyhow!("{} line {}: not a deletion-ledger row: {e}", path.display(), n + 1))?);
    }
    Ok(entries)
}

/// What re-applying a ledger did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Reapplied {
    /// Rows given.
    pub given: u64,
    /// Rows the database already had: deletions made before its snapshot was taken.
    pub known: u64,
    /// Rows applied and added to the database's ledger.
    pub applied: u64,
    /// Records those rows removed, with what was derived from them.
    pub records_removed: u64,
}

impl SqliteStore {
    /// Open a database file without changing it: for reading a snapshot whose checksum is recorded.
    pub fn open_read_only(path: &Path, passage_prefix: &str) -> anyhow::Result<SqliteStore> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
            .map_err(|e| anyhow::anyhow!("cannot open the SQLite database {}: {e}", path.display()))?;
        Self::with_connection(conn, passage_prefix, None)
    }

    /// A consistent copy of the database into the new file `dest`, while the database may be in
    /// use (`VACUUM INTO`, see `migrate::snapshot`).
    pub fn snapshot_to(&self, dest: &Path) -> anyhow::Result<()> {
        crate::migrate::snapshot(&self.conn(), dest)
    }

    /// Every row of the deletion ledger, oldest first.
    pub fn ledger(&self) -> anyhow::Result<Vec<LedgerEntry>> {
        rows(&self.conn(), "SELECT at, tenant, subject, memory_id, scope, actor FROM mh_deletion_ledger ORDER BY id", [], |r| {
            Ok(LedgerEntry {
                at: at(r.get(0)?),
                tenant: r.get(1)?,
                subject: r.get(2)?,
                memory_id: r.get::<_, Option<String>>(3)?.map(|s| crate::util::uuid_of(&s)).transpose()?,
                scope: r.get(4)?,
                actor: r.get(5)?,
            })
        })
    }

    /// Every tenant with something a canonical export holds of its own: a record or a link
    /// (policies are not a tenant's: every export carries them all).
    pub fn tenants(&self) -> anyhow::Result<Vec<String>> {
        rows(&self.conn(), "SELECT tenant FROM mh_memory UNION SELECT tenant FROM mh_link ORDER BY 1", [], |r| Ok(r.get(0)?))
    }

    pub fn counts(&self) -> anyhow::Result<Counts> {
        let c = self.conn();
        let n = |sql: &str| -> anyhow::Result<u64> { Ok(first(&c, sql, [], |r| Ok(r.get::<_, i64>(0)?))?.unwrap_or(0) as u64) };
        Ok(Counts {
            tenants: n("SELECT count(DISTINCT tenant) FROM mh_memory")?,
            subjects: n("SELECT count(*) FROM (SELECT DISTINCT tenant, subject FROM mh_memory)")?,
            records: n("SELECT count(*) FROM mh_memory")?,
            policies: n("SELECT count(*) FROM mh_policy")?,
            audit_events: n("SELECT count(*) FROM mh_audit")?,
            ledger_entries: n("SELECT count(*) FROM mh_deletion_ledger")?,
        })
    }

    /// Apply the deletions of `entries` this database does not have in its ledger yet, each with
    /// the cascade of the deletion it records, and add them to the ledger as they were made
    /// (their time and actor), so the next backup carries them. One transaction: a restored
    /// database is never seen with half its deletions. Audited as `deletion.reapply`.
    pub fn apply_ledger(&self, entries: &[LedgerEntry], actor: &str) -> anyhow::Result<Reapplied> {
        self.reapply(entries, actor, None)
    }

    /// `apply_ledger`, closing with a `backup.restore` event for `restore` (tenant, detail) in the same transaction.
    fn reapply(&self, entries: &[LedgerEntry], actor: &str, restore: Option<(&str, serde_json::Value)>) -> anyhow::Result<Reapplied> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut known: HashSet<LedgerKey> =
            rows(&tx, "SELECT at, tenant, subject, memory_id, scope FROM mh_deletion_ledger", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?
                .into_iter()
                .collect();
        let mut rep = Reapplied { given: entries.len() as u64, ..Default::default() };
        // In the order the deletions were made.
        let mut ordered: Vec<&LedgerEntry> = entries.iter().collect();
        ordered.sort_by_key(|e| e.at);
        // Retention writes a row per record: one event per tenant says how many, not one each.
        let mut retention: BTreeMap<&str, (u64, u64)> = BTreeMap::new();
        for e in ordered {
            let key = e.key();
            if known.contains(&key) {
                rep.known += 1;
                continue;
            }
            // No cutoff by time. A deletion this database's ledger does not have was made after
            // the snapshot was taken, so everything the snapshot holds was written before it,
            // whatever a record's `created_at` says (an import keeps the file's times).
            let need = |v: Option<&str>, what: &str| v.map(String::from).ok_or_else(|| anyhow::anyhow!("a `{}` ledger row of {} without a {what}", e.scope, e.at.to_rfc3339()));
            let removed = match e.scope.as_str() {
                "memory" | "retention" => {
                    let id = e.memory_id.ok_or_else(|| anyhow::anyhow!("a `{}` ledger row of {} without a memory id", e.scope, e.at.to_rfc3339()))?;
                    // Retention keeps what was promoted from a purged record; a deletion does not.
                    let removed = self.delete_in(&tx, &e.tenant, id, e.scope == "memory")?.map_or(0, |(_, n)| n);
                    // The snapshot may hold the record still queued (the worker wrote it only
                    // after the backup, and it was deleted or purged after that): it leaves its
                    // proposal, or the restored queue would write it again.
                    crate::intake::drop_queued_record(&tx, &e.tenant, id)?;
                    if e.scope == "memory" {
                        crate::intake::drop_promotions_of(&tx, &e.tenant, &HashSet::from([id]))?;
                    }
                    removed
                }
                "subject" => self.erase_subject(&tx, &e.tenant, &need(e.subject.as_deref(), "subject")?, true)?,
                "subject-reset" => self.erase_subject(&tx, &e.tenant, &need(e.subject.as_deref(), "subject")?, false)?,
                "tenant" => self.erase_tenant(&tx, &e.tenant, None)?,
                // Refused, not skipped: an unknown kind of deletion left out would be an erasure undone.
                other => anyhow::bail!("unknown deletion-ledger scope {other:?} (row of {}); nothing was applied", e.at.to_rfc3339()),
            };
            exec(
                &tx,
                "INSERT INTO mh_deletion_ledger (at, tenant, subject, memory_id, scope, actor) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![key.0, e.tenant, e.subject, key.3, e.scope, e.actor],
            )?;
            known.insert(key);
            rep.applied += 1;
            rep.records_removed += removed;
            if e.scope == "retention" {
                let t = retention.entry(e.tenant.as_str()).or_default();
                *t = (t.0 + 1, t.1 + removed);
            } else {
                let detail = serde_json::json!({ "scope": e.scope, "deleted_at": e.at, "deleted_by": e.actor, "records": removed });
                audit_in(&tx, actor, "deletion.reapply", &e.tenant, e.subject.as_deref(), e.memory_id, &detail)?;
            }
        }
        for (tenant, (entries, records)) in retention {
            audit_in(&tx, actor, "deletion.reapply", tenant, None, None, &serde_json::json!({ "scope": "retention", "entries": entries, "records": records }))?;
        }
        if let Some((tenant, mut detail)) = restore {
            detail["ledger"] = serde_json::to_value(&rep)?;
            audit_in(&tx, actor, "backup.restore", tenant, None, None, &detail)?;
        }
        tx.commit()?;
        Ok(rep)
    }
}

/// Snapshot the database `live` into the new or empty private directory `dir`, with its deletion
/// ledger beside it. Returns the snapshot, opened read-only (so the canonical export can be
/// read from exactly what the snapshot holds), and the manifest, still to be written.
pub async fn create(live: &SqliteStore, dir: &Path, producer: &str) -> anyhow::Result<(SqliteStore, Manifest)> {
    private_dir(dir)?;
    anyhow::ensure!(!dir.join(MANIFEST_FILE).exists() && !dir.join(SNAPSHOT_FILE).exists(), "{} already holds a backup: choose a new directory", dir.display());
    let path = dir.join(SNAPSHOT_FILE);
    live.snapshot_to(&path)?;
    let snapshot = SqliteStore::open_read_only(&path, &live.inner.passage_prefix)?;
    let ledger = snapshot.ledger()?;
    write_ledger(&dir.join(LEDGER_FILE), &ledger)?;
    let file = |name: &str| -> anyhow::Result<FileEntry> {
        let p = dir.join(name);
        Ok(FileEntry { file: name.into(), sha256: sha256_file(&p)?, bytes: std::fs::metadata(&p)?.len() })
    };
    let manifest = Manifest {
        format: MANIFEST_FORMAT.into(),
        version: MANIFEST_VERSION,
        created_at: Utc::now(),
        producer: producer.into(),
        schema_version: snapshot.meta("schema_version")?.and_then(|v| v.parse().ok()).unwrap_or(crate::SCHEMA_VERSION),
        embedder: snapshot.embedding_identity().await?.0,
        snapshot: file(SNAPSHOT_FILE)?,
        ledger: file(LEDGER_FILE)?,
        counts: snapshot.counts()?,
        exports: vec![],
    };
    Ok((snapshot, manifest))
}

/// What a restore did.
#[derive(Debug, Clone, Serialize)]
pub struct Restored {
    pub ledger: Reapplied,
    /// The snapshot's schema version, before it was brought to this build's.
    pub schema_from: u32,
    pub counts: Counts,
    pub audit_events: u64,
    /// The first audit event whose hash does not follow from the one before, if any.
    pub audit_broken_at: Option<i64>,
}

/// Put the snapshot file `snapshot` in place as the database `db`, with every deletion of
/// `ledger` it does not know applied first. The work happens on a copy beside `db`, which
/// replaces `db` only once it is complete: a restore that fails before that move leaves `db`
/// as it was. After the move only the flush of the directory can fail: `db` is then the
/// restored database, and the error says so. Nothing may have `db` open. `detail` goes into the
/// `backup.restore` audit event of `tenant`.
pub async fn restore(snapshot: &Path, db: &Path, ledger: &[LedgerEntry], actor: &str, tenant: &str, detail: serde_json::Value) -> anyhow::Result<Restored> {
    let dir = db.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    crate::private_dir(dir)?;
    let side = |suffix: &str| {
        let mut name = db.file_name().unwrap_or_default().to_os_string();
        name.push(suffix);
        db.with_file_name(name)
    };
    let work = side(&format!(".restoring-{}", std::process::id()));
    let work_files = [work.clone(), PathBuf::from(format!("{}-wal", work.display())), PathBuf::from(format!("{}-shm", work.display()))];
    let clean = || work_files.iter().for_each(|p| drop(std::fs::remove_file(p)));
    clean();
    let done: anyhow::Result<Restored> = async {
        std::io::copy(&mut std::fs::File::open(snapshot).map_err(|e| anyhow::anyhow!("cannot read the snapshot {}: {e}", snapshot.display()))?, &mut create_private(&work)?)?;
        // The snapshot says which embedder wrote it; the configuration is checked against it at the next start.
        let (identity, schema_from) = {
            let c = Connection::open_with_flags(&work, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            let get = |key: &str| crate::meta(&c, key).map_err(|e| anyhow::anyhow!("{} is not a MemHouse database: {e}", snapshot.display()));
            match (get("embedder")?, get("embedding_dim")?, get("schema_version")?) {
                (Some(embedder), Some(dim), Some(version)) => {
                    (EmbeddingIdentity { embedder, dim: dim.parse()?, passage_prefix: get("passage_prefix")?.unwrap_or_default() }, version.parse::<u32>()?)
                }
                _ => anyhow::bail!("{} is not a MemHouse database", snapshot.display()),
            }
        };
        // No copy before the upgrade: the backup is that copy, and another would keep what the ledger removes.
        let store = SqliteStore::open(&work, &identity.passage_prefix)?.without_upgrade_snapshot();
        store.migrate(identity.dim, &identity.embedder).await?;
        let applied = store.reapply(ledger, actor, Some((tenant, detail)))?;
        let (audit_events, audit_broken_at) = store.audit_verify().await?;
        let counts = store.counts()?;
        // Everything into the one file that moves into place.
        store.conn().execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;")?;
        drop(store);
        std::fs::File::open(&work)?.sync_all()?;
        // The write-ahead log of the database being replaced must not be read into the new one.
        // Folded into its file first, so that file is still whole if the move below fails.
        // A log that cannot be folded in holds committed writes the file does not: the restore
        // stops there, with both files as they were.
        if db.exists() {
            let unfolded = |e: &dyn std::fmt::Display| anyhow::anyhow!("cannot fold the write-ahead log of {} into it ({e}); the database was left as it was", db.display());
            let old = Connection::open(db).map_err(|e| unfolded(&e))?;
            old.busy_timeout(std::time::Duration::from_secs(10)).map_err(|e| unfolded(&e))?;
            // The first column is 1 when another connection kept the checkpoint from completing.
            let busy: i64 = old.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| r.get(0)).map_err(|e| unfolded(&e))?;
            anyhow::ensure!(busy == 0, "{}", unfolded(&"another process has the database open: stop `memhouse serve` and the agents using it"));
        }
        for old in [side("-wal"), side("-shm")] {
            match std::fs::remove_file(&old) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => anyhow::bail!("cannot remove {}: {e}", old.display()),
                _ => {}
            }
        }
        std::fs::rename(&work, db).map_err(|e| anyhow::anyhow!("cannot move the restored database to {}: {e}", db.display()))?;
        // The move is durable once the directory is flushed. From here the database is the
        // restored one, so a failure must not read as "nothing changed".
        crate::sync_dir(dir).map_err(|e| {
            anyhow::anyhow!(
                "the restored database is in place at {}, but {e:#}: the restore may not survive a power failure. Run `memhouse restore` again to be sure",
                db.display()
            )
        })?;
        Ok(Restored { ledger: applied, schema_from, counts, audit_events, audit_broken_at })
    }
    .await;
    if done.is_err() {
        clean();
    }
    done
}
