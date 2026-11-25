// SPDX-License-Identifier: Apache-2.0
//! `memhouse backup` / `restore` for the Lite profile (TR-LT-09): a consistent snapshot of the
//! database file with the canonical export beside it, and a restore that re-applies the
//! deletion ledger (TR-WF-03). Postgres is backed up with its own tools.

use anyhow::Context;
use memhouse_core::Config;
use memhouse_store_sqlite::backup::{self, ExportEntry, Manifest};
use memhouse_store_sqlite::SqliteStore;
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const POSTGRES: &str = "this installation uses Postgres, which is backed up and restored with its own tools: `pg_dump -Fc` and `pg_restore`, or base backups with WAL archiving \
     (docs/operations.md, \"Backup and restore\", which also has the procedure that re-applies the deletion ledger after a restore). \
     `memhouse export` writes the canonical Memory Format export; it does not hold the audit chain or the deletion ledger. \
     `memhouse backup` and `memhouse restore` are for the Lite profile (a `sqlite:` database)";

fn lite_path(cfg: &Config) -> anyhow::Result<PathBuf> {
    memhouse_server::sqlite_path(&cfg.database.url).ok_or_else(|| anyhow::anyhow!(POSTGRES))
}

/// A tenant as part of a file name.
fn file_safe(tenant: &str) -> String {
    let s: String = tenant.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
    if s.is_empty() {
        "_".into()
    } else {
        s
    }
}

pub async fn backup(cfg: Config, dir: &Path, ledger_only: bool) -> anyhow::Result<()> {
    let path = lite_path(&cfg)?;
    anyhow::ensure!(path.exists(), "there is no database at {} to back up", path.display());
    let prefix = cfg.embedding.passage_prefix.clone().unwrap_or_default();
    if ledger_only {
        let ledger = SqliteStore::open(&path, &prefix)?.ledger()?;
        backup::private_dir(dir)?;
        let out = dir.join(backup::LEDGER_FILE);
        backup::write_ledger(&out, &ledger)?;
        println!("✓ deletion ledger: {} entries in {}", ledger.len(), out.display());
        println!("  `memhouse restore <backup> --ledger {}` re-applies them to an earlier backup", out.display());
        return Ok(());
    }
    // The engine brings the schema up to date first, and exports in the Memory Format.
    let eng = crate::engine(cfg.clone()).await?;
    let live = SqliteStore::open(&path, &prefix)?;
    let (snapshot, mut manifest) = backup::create(&live, dir, &format!("memhouse {}", env!("CARGO_PKG_VERSION"))).await?;
    // The export is read from the snapshot, not from the live database: the two hold the same records.
    let reader = memhouse_core::Engine::new(Arc::new(snapshot.clone()), eng.embedder.clone(), None, cfg.clone());
    let mut tenants = snapshot.tenants()?;
    if !tenants.contains(&cfg.memory.tenant) {
        tenants.push(cfg.memory.tenant.clone());
    }
    for tenant in tenants {
        let mut file = format!("export-{}.jsonl", file_safe(&tenant));
        let mut n = 1;
        while manifest.exports.iter().any(|e| e.file == file) {
            n += 1;
            file = format!("export-{}-{n}.jsonl", file_safe(&tenant));
        }
        let out = dir.join(&file);
        let mut w = std::io::BufWriter::new(backup::create_private(&out)?);
        let r = memhouse_core::format::export(&reader, &mut w, &tenant, None).await.with_context(|| format!("exporting tenant {tenant}"))?;
        w.flush()?;
        w.get_ref().sync_all()?;
        manifest.exports.push(ExportEntry { tenant, file, sha256: backup::sha256_file(&out)?, records: r.records, links: r.links, policies: r.policies });
    }
    manifest.write(dir)?;
    let c = &manifest.counts;
    let detail = json!({ "snapshot_sha256": manifest.snapshot.sha256, "records": c.records, "audit_events": c.audit_events, "ledger_entries": c.ledger_entries, "exports": manifest.exports.len() });
    eng.store.audit("cli", "backup.create", &cfg.memory.tenant, None, None, detail).await?;
    println!("✓ backup written to {}", dir.display());
    println!("  {}: {} records of {} subjects, {} audit events (sha256 {})", manifest.snapshot.file, c.records, c.subjects, c.audit_events, manifest.snapshot.sha256);
    for e in &manifest.exports {
        println!("  {}: tenant {}, {} records, {} links, {} policies (Memory Format v{})", e.file, e.tenant, e.records, e.links, e.policies, memhouse_core::format::VERSION);
    }
    println!("  {}: {} entries", manifest.ledger.file, c.ledger_entries);
    println!("  The backup holds everything the database held, including what is deleted later: keep it as long as your retention rules allow, no longer.");
    Ok(())
}

pub async fn restore(cfg: Config, dir: &Path, force: bool, ledger: Option<&Path>) -> anyhow::Result<()> {
    let path = lite_path(&cfg)?;
    let manifest = Manifest::read(dir)?;
    let snapshot = manifest.verified_snapshot(dir)?;
    let mut entries = vec![];
    let mut carried = None;
    if path.exists() {
        anyhow::ensure!(
            force,
            "{} already exists. `memhouse restore --force` replaces it with the backup (stop `memhouse serve` and the agents using it first); \
             the deletions recorded in it are carried over, so nothing deleted since the backup comes back",
            path.display()
        );
        // The ledger kept outside the snapshot: that of the database being replaced.
        let current = SqliteStore::open(&path, "").and_then(|s| s.ledger()).map_err(|e| {
            anyhow::anyhow!(
                "cannot read the deletion ledger of {} ({e:#}), so records deleted since the backup would come back. \
                 Move the file away and restore with `--ledger <file>` (a ledger written by `memhouse backup --ledger-only`, or a later backup's {})",
                path.display(),
                backup::LEDGER_FILE
            )
        })?;
        carried = Some(current.len());
        entries.extend(current);
    }
    if let Some(file) = ledger {
        entries.extend(backup::read_ledger(file)?);
    }
    let detail = json!({ "backup_created_at": manifest.created_at, "backup_producer": manifest.producer, "snapshot_sha256": manifest.snapshot.sha256, "replaced_existing": carried.is_some() });
    let r = backup::restore(&snapshot, &path, &entries, "cli", &cfg.memory.tenant, detail).await?;
    println!("✓ restored the backup of {} to {}", manifest.created_at.format("%Y-%m-%d %H:%M:%S UTC"), path.display());
    if r.schema_from != memhouse_store_sqlite::SCHEMA_VERSION {
        println!("  schema upgraded from version {} to {}", r.schema_from, memhouse_store_sqlite::SCHEMA_VERSION);
    }
    println!("  {} records of {} subjects", r.counts.records, r.counts.subjects);
    match (carried, ledger) {
        (None, None) => {
            println!("  ! no deletion ledger was given: anything deleted after this backup was taken is back. Restore again with `--ledger <file>` if there were deletions")
        }
        _ => println!(
            "  deletion ledger: {} entries ({} from the replaced database), {} already in the backup, {} re-applied, removing {} records",
            r.ledger.given,
            carried.unwrap_or(0),
            r.ledger.known,
            r.ledger.applied,
            r.ledger.records_removed
        ),
    }
    match r.audit_broken_at {
        None => println!("  audit chain intact ({} events)", r.audit_events),
        Some(id) => println!("  ✗ audit chain broken at event {id}: the backup's audit log was changed before or after it was taken"),
    }
    if let Some(e) = &manifest.embedder {
        println!("  embedded with {}; `memhouse doctor` checks it against this configuration", e.embedder);
    }
    Ok(())
}
