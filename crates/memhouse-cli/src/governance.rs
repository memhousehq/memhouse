// SPDX-License-Identifier: Apache-2.0
//! The operator's governance commands (G22): legal holds, deletion certificates, anchors of
//! the audit head, the evidence bundle, and the restore of a Postgres database's deletions.

use clap::Subcommand;
use memhouse_core::governance::{DeletionStatus, HOLD_KINDS};
use memhouse_core::{Config, Engine, Store};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Subcommand)]
pub enum HoldCmd {
    /// Place a legal hold: what it matches is exempt from retention and deletion until released
    Add {
        /// What is held: subject, user, agent, source, org, team, session or tenant
        kind: String,
        /// The subject, user, agent, source, org, team or session (not needed for tenant)
        target: Option<String>,
        /// Why: a matter or case reference (kept in the hold and the audit log; never memory content)
        #[arg(long)]
        reason: String,
    },
    /// List legal holds (active ones; --all adds released ones)
    List {
        #[arg(long)]
        all: bool,
        #[arg(long)]
        json: bool,
    },
    /// Release a hold; deletions it kept back are carried out now
    Release { id: String },
}

#[derive(Subcommand)]
pub enum DeletionCmd {
    /// Print the completion certificate of a deletion request (the id a forget answers with)
    Certificate {
        id: String,
        /// Check the certificate's hash and that the audit log has its event
        #[arg(long)]
        verify: bool,
        /// Write the certificate to a file instead of printing it
        #[arg(long, short)]
        out: Option<PathBuf>,
    },
    /// List deletion requests, newest first
    List {
        /// Only requests in this state: running, held or completed
        #[arg(long)]
        status: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
}

#[derive(Subcommand)]
pub enum AuditCmd {
    /// Record the audit head outside the database, or check recorded anchors against the chain
    Anchor {
        /// Append the anchor (one JSON line) to this file; printed when left out. Keep the file
        /// where the database's administrators cannot rewrite it (WORM storage, a SIEM)
        #[arg(long, short)]
        out: Option<PathBuf>,
        /// Check every anchor of this file against the chain instead of taking a new one
        #[arg(long, conflicts_with = "out")]
        verify: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
pub enum EvidenceCmd {
    /// Write the compliance evidence bundle, mapped to SOC 2 and ISO 27001 controls
    Export {
        /// Directory to write the bundle into (new or empty; created for this user alone)
        dir: PathBuf,
        /// The summary.json of a governance suite run to include (`memhouse bench run --suite governance`)
        #[arg(long)]
        suite_report: Option<PathBuf>,
    },
}

pub async fn hold(eng: &Engine, cmd: HoldCmd) -> anyhow::Result<()> {
    let tenant = eng.cfg.memory.tenant.clone();
    match cmd {
        HoldCmd::Add { kind, target, reason } => {
            anyhow::ensure!(HOLD_KINDS.contains(&kind.as_str()), "a hold is placed on one of: {}", HOLD_KINDS.join(", "));
            let h = eng.hold_place(&tenant, &kind, target.as_deref().unwrap_or(""), &reason, "cli").await?;
            println!("✓ legal hold {} on {} {}", h.id, h.target_kind, h.target);
            println!("  What it matches is kept by retention and by forget until `memhouse hold release {}`.", h.id);
        }
        HoldCmd::List { all, json } => {
            let holds = eng.holds(&tenant, !all).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&holds)?);
            } else if holds.is_empty() {
                println!("no legal holds");
            } else {
                for h in holds {
                    let state = match h.released_at {
                        Some(t) => format!("released {}", t.format("%Y-%m-%d")),
                        None => "active".into(),
                    };
                    println!("{}  {:<8} {:<24} {:<20} placed {} by {}  {}", h.id, h.target_kind, h.target, state, h.placed_at.format("%Y-%m-%d"), h.placed_by, h.reason);
                }
            }
        }
        HoldCmd::Release { id } => {
            let (h, resumed, failed) = eng.hold_release(&tenant, uuid::Uuid::parse_str(&id)?, "cli").await?;
            println!("✓ legal hold {} on {} {} released", h.id, h.target_kind, h.target);
            if let Some(why) = failed {
                println!(
                    "  ! the deletions it kept back could not all be carried out now ({why}). The hold is released; `memhouse retention` carries them out (do not release again)"
                );
            }
            for d in resumed {
                match d.status {
                    DeletionStatus::Completed => {
                        println!("  deletion {} ({} {}) completed: {} records; `memhouse deletion certificate {}`", d.id, d.scope.as_str(), d.value, d.deleted, d.id)
                    }
                    DeletionStatus::Held => println!("  deletion {} ({} {}) still has {} records under another hold", d.id, d.scope.as_str(), d.value, d.held),
                    // Carried out, but something of a sampled record is still found: not complete yet.
                    DeletionStatus::Running => println!(
                        "  deletion {} ({} {}) was carried out ({} records) but is not verified yet: {} traces of its sample are still found. `memhouse retention` checks again and completes it",
                        d.id,
                        d.scope.as_str(),
                        d.value,
                        d.deleted,
                        d.certificate.as_ref().map_or(0, |c| c.canaries_found.total())
                    ),
                }
            }
        }
    }
    Ok(())
}

pub async fn deletion(eng: &Engine, cmd: DeletionCmd) -> anyhow::Result<()> {
    let tenant = eng.cfg.memory.tenant.clone();
    match cmd {
        DeletionCmd::Certificate { id, verify, out } => {
            let d = eng.deletion(&tenant, uuid::Uuid::parse_str(&id)?).await?;
            let cert = match (&d.certificate, d.status) {
                (Some(cert), DeletionStatus::Completed) => cert,
                (Some(cert), _) => anyhow::bail!(
                    "deletion {id} is not complete: of the records sampled before it, something is still found ({}). It has no certificate until a probe is clean; \
                     the next retention pass (`memhouse retention`) probes again",
                    serde_json::to_string(&cert.canaries_found)?
                ),
                (None, DeletionStatus::Held) => anyhow::bail!(
                    "deletion {id} is not complete: {} records are kept by a legal hold ({} deleted so far). It completes, and gets its certificate, when the hold is released",
                    d.held,
                    d.deleted
                ),
                (None, _) => anyhow::bail!("deletion {id} is not complete yet ({}); the next retention pass (`memhouse retention`) continues it", d.status.as_str()),
            };
            // Checked before anything is written or printed: a certificate that does not
            // verify is not handed out as one that was asked to be verified.
            if verify {
                let (hash_ok, recorded) = eng.certificate_check(&tenant, cert).await?;
                anyhow::ensure!(hash_ok, "the certificate's hash does not cover its fields: it was changed after it was issued");
                anyhow::ensure!(recorded, "the audit log has no `deletion.certificate` event with this certificate's hash");
                anyhow::ensure!(cert.verified, "the certificate records canaries that were still found ({:?}): the deletion is not verified", cert.canaries_found);
            }
            let text = serde_json::to_string_pretty(cert)?;
            match &out {
                Some(p) => {
                    std::fs::write(p, format!("{text}\n"))?;
                    eprintln!("✓ certificate of deletion {id} written to {}", p.display());
                }
                None => println!("{text}"),
            }
            if verify {
                eprintln!(
                    "✓ hash covers the certificate; the audit log has its `deletion.certificate` event; {} canaries, none found. (The log's own integrity is checked by `memhouse audit --verify`.)",
                    cert.canaries_checked
                );
            }
        }
        DeletionCmd::List { status, limit } => {
            let status = status.map(|s| DeletionStatus::parse(&s).ok_or_else(|| anyhow::anyhow!("--status is one of running, held, completed"))).transpose()?;
            let list = eng.store.deletions(&tenant, status, limit).await?;
            if list.is_empty() {
                println!("no deletion requests");
            }
            for d in list {
                println!(
                    "{}  {} {:<9} {:<8} {:<28} {} deleted{}",
                    d.id,
                    d.requested_at.format("%Y-%m-%d %H:%M:%S"),
                    d.status.as_str(),
                    d.scope.as_str(),
                    d.value,
                    d.deleted,
                    if d.held > 0 { format!(", {} held", d.held) } else { String::new() }
                );
            }
        }
    }
    Ok(())
}

pub async fn audit(eng: &Engine, cmd: AuditCmd) -> anyhow::Result<()> {
    match cmd {
        AuditCmd::Anchor { verify: Some(file), .. } => {
            let anchors = memhouse_server::governance::read_anchors(&file)?;
            let checks = eng.anchors_check(&anchors).await?;
            let bad: Vec<_> = checks.iter().filter(|c| c.result != "match").collect();
            for c in &bad {
                eprintln!("✗ anchor of event {} (taken {}): {}", c.event_id, c.anchored_at.format("%Y-%m-%d %H:%M:%S UTC"), c.result);
            }
            let (n, broken) = eng.store.audit_verify().await?;
            if let Some(id) = broken {
                anyhow::bail!("audit chain broken at event {id} (checked {n})");
            }
            anyhow::ensure!(
                bad.is_empty(),
                "{} of {} anchors do not match the chain: the audit log was rewritten after they were taken, or they are another installation's",
                bad.len(),
                checks.len()
            );
            println!("✓ {} anchors match the chain; audit chain intact ({n} events)", checks.len());
        }
        AuditCmd::Anchor { out: Some(path), .. } => {
            let a = memhouse_server::governance::anchor_to(eng, &path, "cli").await?;
            println!("✓ anchored event {} ({}…) in {}", a.event_id, &a.hash[..a.hash.len().min(12)], path.display());
        }
        AuditCmd::Anchor { .. } => {
            let a = eng.audit_anchor(&eng.cfg.memory.tenant, "cli").await?;
            println!("{}", serde_json::to_string(&a)?);
        }
    }
    Ok(())
}

pub async fn evidence(eng: &Engine, cmd: EvidenceCmd) -> anyhow::Result<()> {
    match cmd {
        EvidenceCmd::Export { dir, suite_report } => {
            let m = memhouse_server::governance::evidence_export(eng, &dir, suite_report.as_deref(), "cli").await?;
            println!("✓ evidence bundle in {} ({} files)", dir.display(), m.files.len() + 1);
            println!(
                "  controls.json maps {} controls to SOC 2 criteria and ISO/IEC 27001:2022 Annex A, each with its evidence files",
                memhouse_core::governance::evidence::CONTROLS.len()
            );
            if suite_report.is_none() {
                println!("  ! no governance suite report was included: run `memhouse bench run --suite governance` and pass its summary.json with --suite-report");
            }
        }
    }
    Ok(())
}

/// The configured store, brought to this build's schema with the embedder the database itself
/// names: what a restore and a ledger export need. No model is loaded (a restore must work on
/// a machine that has none yet), and a database restored from an older release is upgraded
/// before its ledger is read.
pub async fn store_of(cfg: &Config) -> anyhow::Result<Arc<dyn Store>> {
    let store = memhouse_server::open_store(cfg, 2).await?;
    if let (Some(identity), _) = store.embedding_identity().await? {
        store.migrate(identity.dim, &identity.embedder).await?;
    }
    Ok(store)
}

/// `memhouse backup --ledger-only` on Postgres: the deletion ledger as JSON lines, to be kept
/// outside the database and given to `memhouse restore --ledger` after a restore.
pub async fn ledger_only(cfg: &Config, dir: &Path) -> anyhow::Result<()> {
    let ledger = store_of(cfg).await?.ledger_export().await?;
    memhouse_store_sqlite::backup::private_dir(dir)?;
    let out = dir.join(memhouse_store_sqlite::backup::LEDGER_FILE);
    memhouse_store_sqlite::backup::write_ledger(&out, &ledger)?;
    println!("✓ deletion ledger: {} entries in {}", ledger.len(), out.display());
    println!("  After restoring the database with pg_restore, `memhouse restore --ledger {}` re-applies them before it serves", out.display());
    Ok(())
}

/// `memhouse restore` on Postgres (TR-WF-03): the database was restored with Postgres' own
/// tools; this re-applies the deletion ledger to it, checks the audit chain, and records the
/// database as fit to serve.
pub async fn restore_postgres(cfg: &Config, ledger: Option<&Path>, no_ledger: bool) -> anyhow::Result<()> {
    anyhow::ensure!(
        ledger.is_some() != no_ledger,
        "on Postgres, `memhouse restore` re-applies a deletion ledger to a database restored with pg_restore: give `--ledger <file>` (written by `memhouse backup --ledger-only` \
         before the restore), or `--no-ledger` to state that nothing was deleted since the backup was taken"
    );
    let entries = match ledger {
        Some(file) => memhouse_store_sqlite::backup::read_ledger(file)?,
        None => vec![],
    };
    let store = store_of(cfg).await?;
    let detail = serde_json::json!({ "ledger_given": ledger.is_some(), "entries": entries.len() });
    let r = store.ledger_apply(&entries, "cli", &cfg.memory.tenant, detail).await?;
    match ledger {
        Some(_) => println!("✓ deletion ledger: {} entries, {} already in the database, {} re-applied, removing {} records", r.given, r.known, r.applied, r.records_removed),
        None => println!("✓ recorded: no deletion was made since the backup this database was restored from"),
    }
    let (n, broken) = store.audit_verify().await?;
    // A database whose audit chain does not verify is not recorded as fit to serve.
    if let Some(id) = broken {
        anyhow::bail!(
            "the audit chain is broken at event {id} (of {n}): the backup's audit log was changed before or after it was taken. The deletion ledger has been re-applied \
             (running this again applies nothing twice), but this command did not record the database as restored: the restore guard of `memhouse serve` still compares it \
             with what was served before. (`memhouse serve` does not itself verify the chain.) Restore a backup whose chain verifies"
        );
    }
    println!("  audit chain intact ({n} events)");
    memhouse_server::governance::record_watermark(store.as_ref(), &memhouse_core::config::home_dir()).await?;
    println!("  `memhouse serve` now starts on this database");
    Ok(())
}

/// After a Lite restore: record the database as the one `memhouse serve` compares with at its
/// next start; with `acknowledge`, for a file put in place by hand, with an audit event.
pub async fn record_lite(cfg: &Config, acknowledge: bool) -> anyhow::Result<()> {
    let store = store_of(cfg).await?;
    let (n, broken) = store.audit_verify().await?;
    if let Some(id) = broken {
        anyhow::bail!("the audit chain is broken at event {id} (of {n}): this command did not record the database as restored, so the restore guard of `memhouse serve` still compares it with what was served before. (`memhouse serve` does not itself verify the chain.) Restore a backup whose chain verifies");
    }
    if acknowledge {
        store.audit("cli", "backup.restore", &cfg.memory.tenant, None, None, serde_json::json!({ "ledger_given": false, "acknowledged": true })).await?;
        println!("✓ recorded: no deletion was made since the backup this database was restored from");
    }
    memhouse_server::governance::record_watermark(store.as_ref(), &memhouse_core::config::home_dir()).await
}
