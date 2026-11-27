// SPDX-License-Identifier: Apache-2.0
//! What a served deployment does for governance beside its requests (G22): the restore guard
//! (TR-WF-03), anchors of the audit head written outside the database (GOV-12), and the
//! compliance evidence export (GOV-16).

use chrono::{DateTime, Utc};
use memhouse_core::governance::{evidence, instance_id, AuditAnchor, DeletionStatus};
use memhouse_core::{Engine, Store};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};

/// The newest state of a database this installation has served: what a later start compares
/// the database with, to tell one that was restored from a backup.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Watermark {
    pub instance: String,
    /// The id of the newest audit event.
    pub audit_event: i64,
    pub audit_hash: String,
    pub seen_at: DateTime<Utc>,
}

fn private(path: &Path, content: &[u8]) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() {
        memhouse_store_sqlite::private_dir(dir)?;
    }
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.mode(0o600);
    }
    let mut f = open.open(path).map_err(|e| anyhow::anyhow!("cannot write {}: {e}", path.display()))?;
    f.write_all(content)?;
    f.sync_all()?;
    Ok(())
}

/// Where the watermark of an installation is kept: under `MEMHOUSE_HOME`, outside the database.
pub fn watermark_path(home: &Path, instance: &str) -> PathBuf {
    let safe: String = instance.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    home.join("state").join(format!("restore-guard-{safe}.json"))
}

pub async fn watermark(store: &dyn Store) -> anyhow::Result<Option<Watermark>> {
    let Some(head) = store.audit_head().await? else { return Ok(None) };
    Ok(Some(Watermark { instance: instance_id(store).await?, audit_event: head.id, audit_hash: head.hash, seen_at: Utc::now() }))
}

/// Record the database's state as seen now. Called when serving starts, after every retention
/// pass, and by `memhouse restore` once the ledger is re-applied. It needs the store alone: a
/// restore loads no model.
pub async fn record_watermark(store: &dyn Store, home: &Path) -> anyhow::Result<()> {
    let Some(w) = watermark(store).await? else { return Ok(()) };
    private(&watermark_path(home, &w.instance), serde_json::to_string_pretty(&w)?.as_bytes())
}

/// What the restore guard found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Guard {
    /// Nothing recorded for this database, or the database is at or past what was recorded.
    Ok,
    /// The database is older than the one last served: it was restored from a backup.
    Restored { seen: i64, now: i64, seen_at: DateTime<Utc> },
    /// The database has the event last seen, with another hash: its audit log was rewritten,
    /// or it is a restored copy that was written to since.
    Diverged { event: i64 },
}

/// Compare the database with the watermark (TR-WF-03): a restored database must have its
/// deletion ledger re-applied before it serves.
pub async fn guard(store: &dyn Store, home: &Path) -> anyhow::Result<Guard> {
    let instance = instance_id(store).await?;
    let path = watermark_path(home, &instance);
    let Ok(text) = std::fs::read_to_string(&path) else { return Ok(Guard::Ok) };
    let seen: Watermark = match serde_json::from_str(&text) {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!("the restore guard's state {} cannot be read ({e}); starting without it", path.display());
            return Ok(Guard::Ok);
        }
    };
    let now = store.audit_head().await?.map_or(0, |h| h.id);
    if now < seen.audit_event {
        return Ok(Guard::Restored { seen: seen.audit_event, now, seen_at: seen.seen_at });
    }
    match store.audit_hash_at(seen.audit_event).await? {
        Some(h) if h == seen.audit_hash => Ok(Guard::Ok),
        _ => Ok(Guard::Diverged { event: seen.audit_event }),
    }
}

/// Refuse to serve a restored database until `memhouse restore` has run (TR-WF-03).
pub async fn check_before_serving(engine: &Engine) -> anyhow::Result<()> {
    if !engine.cfg.governance.restore_guard {
        return Ok(());
    }
    let home = memhouse_core::config::home_dir();
    match guard(engine.store.as_ref(), &home).await? {
        Guard::Ok => Ok(()),
        Guard::Restored { seen, now, seen_at } => anyhow::bail!(
            "this database is older than the one this installation last served: its audit log ends at event {now}, and event {seen} was seen on {}. \
             It was restored from a backup, so records deleted since may be back. Run `memhouse restore --ledger <file>` to re-apply the deletion ledger \
             (a file written by `memhouse backup --ledger-only` before the restore), or `memhouse restore --no-ledger` if nothing was deleted since the backup; \
             then start again (docs/operations.md, \"Backup and restore\"). `[governance] restore_guard = false` turns this check off",
            seen_at.format("%Y-%m-%d %H:%M:%S UTC")
        ),
        Guard::Diverged { event } => anyhow::bail!(
            "this database's audit log is not the one this installation last served: event {event} has another hash than the one seen. Either the log was rewritten \
             (`memhouse audit --verify`, and `memhouse audit anchor --verify <file>` against anchors kept elsewhere), or a restored copy was written to. \
             After checking, `memhouse restore --no-ledger` records the database as it is now"
        ),
    }
}

/// Append an anchor of the audit head to the file `path` (GOV-12): one JSON line per anchor.
pub async fn anchor_to(engine: &Engine, path: &Path, by: &str) -> anyhow::Result<AuditAnchor> {
    let anchor = engine.audit_anchor(&engine.cfg.memory.tenant, by).await?;
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let mut f = std::fs::OpenOptions::new().append(true).create(true).open(path).map_err(|e| anyhow::anyhow!("cannot write the anchor file {}: {e}", path.display()))?;
    writeln!(f, "{}", serde_json::to_string(&anchor)?)?;
    f.sync_all()?;
    Ok(anchor)
}

pub fn read_anchors(path: &Path) -> anyhow::Result<Vec<AuditAnchor>> {
    let text = std::fs::read_to_string(path).map_err(|e| anyhow::anyhow!("cannot read the anchor file {}: {e}", path.display()))?;
    text.lines()
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty())
        .map(|(n, l)| serde_json::from_str(l).map_err(|e| anyhow::anyhow!("{} line {}: not an anchor: {e}", path.display(), n + 1)))
        .collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidenceFile {
    pub file: String,
    pub sha256: String,
    pub bytes: u64,
}

/// The manifest of an evidence bundle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidenceManifest {
    /// `memhouse.evidence`.
    pub format: String,
    pub version: u32,
    pub generated_at: DateTime<Utc>,
    pub producer: String,
    pub tenant: String,
    pub instance: String,
    pub files: Vec<EvidenceFile>,
}

/// Write the compliance evidence bundle of a tenant into the new or empty directory `dir`
/// (GOV-16): one file per kind of evidence, read from the running installation, `controls.json`
/// that maps each control to SOC 2 criteria and ISO/IEC 27001:2022 Annex A controls and to the
/// files that are its evidence, and `manifest.json` with every file's checksum. The bundle
/// holds identifiers, settings, counts and hashes: no memory content, no key and no key hash.
pub async fn evidence_export(engine: &Engine, dir: &Path, suite_report: Option<&Path>, by: &str) -> anyhow::Result<EvidenceManifest> {
    memhouse_store_sqlite::private_dir(dir)?;
    anyhow::ensure!(std::fs::read_dir(dir)?.next().is_none(), "{} is not empty: choose a new directory for the evidence bundle", dir.display());
    let tenant = engine.cfg.memory.tenant.clone();
    let cfg = &engine.cfg;
    let now = Utc::now();
    let policy = engine.policy_for(&tenant).await?;
    let mut files: Vec<(&str, serde_json::Value)> = vec![];

    let (events, broken_at) = engine.store.audit_verify().await?;
    let head = engine.store.audit_head().await?;
    let recent = engine.store.audit_log(&tenant, 10_000).await?;
    let mut by_action: std::collections::BTreeMap<String, u64> = Default::default();
    for e in &recent {
        *by_action.entry(e.action.clone()).or_default() += 1;
    }
    let anchors = if cfg.governance.audit_anchor_path.is_empty() {
        json!({ "configured": false })
    } else {
        match read_anchors(Path::new(&cfg.governance.audit_anchor_path)) {
            Ok(a) => {
                let checks = engine.anchors_check(&a).await?;
                json!({ "configured": true, "anchors": checks.len(), "matching": checks.iter().filter(|c| c.result == "match").count(),
                        "not_matching": checks.iter().filter(|c| c.result == "mismatch" || c.result == "missing").count(), "newest": a.last() })
            }
            Err(e) => json!({ "configured": true, "error": e.to_string() }),
        }
    };
    files.push((
        "audit-chain.json",
        json!({
            "verified": { "events": events, "intact": broken_at.is_none(), "broken_at": broken_at },
            "head": head, "anchors": anchors, "audit_reads": policy.policy.recall.audit_reads,
            "events_by_action": by_action, "events_counted": recent.len(), "holds_content": false,
        }),
    ));

    let principals = engine.store.principals(Some(&tenant)).await.unwrap_or_default();
    let keys = engine.store.api_keys(None).await.unwrap_or_default();
    let ids: std::collections::HashSet<&str> = principals.iter().map(|p| p.id.as_str()).collect();
    files.push((
        "access.json",
        json!({
            "admission": cfg.access.admission, "token_ttl_secs": cfg.access.token_ttl_secs,
            "bootstrap_keys_configured": cfg.server.api_keys.len(),
            "principals": principals.iter().map(|p| json!({
                "id": p.id, "kind": p.kind, "subjects": p.subjects, "kinds": p.kinds, "denied_labels": p.denied_labels,
                "org": p.org, "team": p.team, "can_commit": p.can_commit, "disabled": p.disabled_at.is_some(),
            })).collect::<Vec<_>>(),
            // The key's id and what it may do; never its secret or the secret's hash.
            "keys": keys.iter().filter(|k| ids.contains(k.principal_id.as_str())).map(|k| json!({
                "id": k.id, "principal": k.principal_id, "permissions": k.scopes, "created_at": k.created_at,
                "expires_at": k.expires_at, "revoked_at": k.revoked_at,
            })).collect::<Vec<_>>(),
        }),
    ));

    files.push((
        "configuration.json",
        json!({
            "governance": {
                "redact": cfg.governance.redact, "actions": cfg.governance.actions, "quarantine_injection": cfg.governance.quarantine_injection,
                "denied_labels": cfg.governance.denied_labels, "audit_reads": cfg.governance.audit_reads,
                "episodic_retention_days": cfg.governance.episodic_retention_days, "max_content_chars": cfg.governance.max_content_chars,
                "untrusted_sources": cfg.governance.untrusted_sources, "audit_anchor_configured": !cfg.governance.audit_anchor_path.is_empty(),
                "restore_guard": cfg.governance.restore_guard,
            },
            "database": { "row_level_security": cfg.database.row_level_security, "episodic_partitions": cfg.database.episodic_partitions },
            "server": { "session_ttl_secs": cfg.server.session_ttl_secs, "session_idle_secs": cfg.server.session_idle_secs, "cors_origins": cfg.server.cors_origins },
            "enrichment": { "enabled": cfg.enrich.enabled },
            "siem": { "syslog_configured": !cfg.siem.syslog.is_empty(), "otlp_configured": !cfg.siem.otlp_endpoint.is_empty(), "interval_secs": cfg.siem.interval_secs },
        }),
    ));

    let specs = engine.store.policy_specs(&tenant).await?;
    let history = engine.store.policy_history(&tenant, 100).await?;
    files.push((
        "policy.json",
        json!({
            "active": { "version": policy.version, "body": policy.policy },
            "specs": specs.iter().map(|s| json!({
                "version": s.version, "name": s.name, "status": s.status, "spec_hash": s.spec_hash, "proposed_by": s.proposed_by,
                "proposed_at": s.proposed_at, "approved_by": s.approved_by, "approved_at": s.approved_at,
            })).collect::<Vec<_>>(),
            "activations": history,
        }),
    ));

    let retention_events: Vec<&memhouse_core::AuditEvent> = recent.iter().filter(|e| e.action.starts_with("retention.")).take(50).collect();
    files.push((
        "retention.json",
        json!({
            "types": memhouse_core::MemoryKind::ALL.iter().map(|k| json!({ "kind": k.as_str(), "retention_days": policy.of(*k).retention_days, "ttl_secs": policy.of(*k).ttl_secs })).collect::<Vec<_>>(),
            "scopes": policy.policy.retention.scopes,
            "explanation_retention_days": cfg.telemetry.explanation_retention_days,
            "episodic_partitions": engine.store.episodic_partitions().await?,
            "recent_passes": retention_events,
        }),
    ));

    let holds = engine.holds(&tenant, false).await?;
    files.push(("legal-holds.json", json!({ "active": holds.iter().filter(|h| h.active()).count(), "released": holds.iter().filter(|h| !h.active()).count(), "holds": holds })));

    let deletions = engine.store.deletions(&tenant, None, 1000).await?;
    let count = |s: DeletionStatus| deletions.iter().filter(|d| d.status == s).count();
    files.push((
        "deletions.json",
        json!({
            "completed": count(DeletionStatus::Completed), "held": count(DeletionStatus::Held), "running": count(DeletionStatus::Running),
            "unverified_certificates": deletions.iter().filter(|d| d.certificate.as_ref().is_some_and(|c| !c.verified)).count(),
            "requests": deletions.iter().map(|d| json!({
                "id": d.id, "scope": d.scope, "requested_at": d.requested_at, "requested_by": d.actor, "status": d.status,
                "completed_at": d.completed_at, "records_deleted": d.deleted, "held": d.held,
                "certificate": d.certificate.as_ref().map(|c| json!({ "hash": c.hash, "verified": c.verified, "canaries_checked": c.canaries_checked })),
            })).collect::<Vec<_>>(),
        }),
    ));

    files.push((
        "isolation.json",
        json!({
            "profile": if engine.is_lite() { "lite" } else { "standard" },
            "statement_filters": "every statement filters on tenant and subject (governance checks subject_isolation, tenant_isolation, recall_plan_scoped)",
            "row_level_security": engine.store.rls_status().await?,
        }),
    ));

    files.push(("siem-export.json", crate::siem::status(engine.store.as_ref(), &cfg.siem).await?));

    files.push((
        "build.json",
        json!({
            "product": "memhouse", "version": env!("CARGO_PKG_VERSION"), "schema_version": memhouse_core::format::SCHEMA_VERSION,
            "store": if engine.is_lite() { "sqlite" } else { "postgres" }, "embedder": engine.embedder.id(),
            "release_integrity": "release artefacts are signed keylessly with provenance and a bill of materials; verify with the commands in docs/security/supply-chain.md",
        }),
    ));

    let suite = match suite_report {
        Some(p) => {
            let text = std::fs::read_to_string(p).map_err(|e| anyhow::anyhow!("cannot read the governance suite report {}: {e}", p.display()))?;
            let report: serde_json::Value = serde_json::from_str(&text).map_err(|e| anyhow::anyhow!("{} is not a governance suite summary: {e}", p.display()))?;
            json!({ "included": true, "sha256": hex::encode(Sha256::digest(text.as_bytes())), "report": report })
        }
        None => json!({ "included": false, "how": "run `memhouse bench run --suite governance` and pass its summary.json with --suite-report" }),
    };
    files.push(("governance-suite.json", suite));

    let mut manifest = EvidenceManifest {
        format: "memhouse.evidence".into(),
        version: 1,
        generated_at: now,
        producer: format!("memhouse {}", env!("CARGO_PKG_VERSION")),
        tenant: tenant.clone(),
        instance: engine.instance_id().await?,
        files: vec![],
    };
    let write = |name: &str, v: &serde_json::Value, manifest: &mut EvidenceManifest| -> anyhow::Result<()> {
        let text = serde_json::to_string_pretty(v)?;
        private(&dir.join(name), text.as_bytes())?;
        manifest.files.push(EvidenceFile { file: name.into(), sha256: hex::encode(Sha256::digest(text.as_bytes())), bytes: text.len() as u64 });
        Ok(())
    };
    for (name, v) in &files {
        write(name, v, &mut manifest)?;
    }
    let sums: std::collections::BTreeMap<String, String> = manifest.files.iter().map(|f| (f.file.clone(), f.sha256.clone())).collect();
    let controls: Vec<serde_json::Value> = evidence::CONTROLS
        .iter()
        .map(|c| {
            json!({
                "id": c.id, "title": c.title, "soc2": c.soc2, "iso27001": c.iso27001, "requirements": c.requirements,
                "evidence": c.evidence.iter().map(|f| json!({ "file": f, "sha256": sums.get(*f) })).collect::<Vec<_>>(),
            })
        })
        .collect();
    write(
        "controls.json",
        &json!({
            "frameworks": { "soc2": "AICPA Trust Services Criteria (2017, revised points of focus 2022)", "iso27001": "ISO/IEC 27001:2022 Annex A" },
            "note": "A mapping of product controls to criteria, with the evidence this installation produced for each. It supports an audit; it is not an attestation.",
            "controls": controls,
        }),
        &mut manifest,
    )?;
    private(&dir.join("manifest.json"), serde_json::to_string_pretty(&manifest)?.as_bytes())?;
    engine
        .store
        .audit(by, "evidence.export", &tenant, None, None, json!({ "files": manifest.files.len(), "controls": evidence::CONTROLS.len(), "suite_report": suite_report.is_some() }))
        .await?;
    Ok(manifest)
}
