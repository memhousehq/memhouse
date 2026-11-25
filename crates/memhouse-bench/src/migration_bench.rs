// SPDX-License-Identifier: Apache-2.0
//! The migration at size (TR-MIG-01: one million records; PROF-03: five minutes of downtime or
//! less per million): a Lite file is filled with synthetic records, each with a vector and an
//! audit event, and migrated with `memhouse migrate`'s own code to a scratch Postgres database
//! (or to another file). The time of the copy and the verification is the downtime: the server
//! is stopped for exactly that long. Run on demand, never in CI.

use crate::footprint::sentence;
use memhouse_core::config::Config;
use memhouse_core::intake::{AuditEntry, IntakeWrite};
use memhouse_core::types::*;
use memhouse_core::{EmbedKind, Embedder, Store};
use memhouse_server::migrate::{self, Request};
use std::fmt::Write as _;
use std::sync::Arc;
use std::time::Instant;
use uuid::Uuid;

const DIM: usize = 384;
const TENANT: &str = "bench";

/// Write `records` records into the store, in transactions of 500, through the insert stage of
/// the write pipeline (records and their audit events together), with stand-in vectors.
async fn load(store: &dyn Store, records: usize, per_subject: usize) -> anyhow::Result<()> {
    let embedder = memhouse_conformance::fakes::HashEmbedder::new(DIM);
    let now = chrono::Utc::now();
    let mut n = 0u64;
    while (n as usize) < records {
        let take = 500.min(records - n as usize);
        let texts: Vec<String> = (0..take as u64)
            .map(|i| {
                let k = n + i;
                // Four in five are conversation rounds, three sentences long; the rest are facts.
                if k % 5 == 0 {
                    sentence(k)
                } else {
                    format!("user: {} {}\nassistant: {}", sentence(k), sentence(k + 7_000_000_000), sentence(k + 13_000_000_000))
                }
            })
            .collect();
        let vectors = embedder.embed(&texts, EmbedKind::Passage).await?;
        let mut w = IntakeWrite { tenant: TENANT.into(), outcome: serde_json::json!({}), ..Default::default() };
        for (i, (content, vector)) in texts.into_iter().zip(vectors).enumerate() {
            let k = n + i as u64;
            let subject = format!("bench:migrate:{}", k as usize / per_subject);
            let round = k % 5 != 0;
            let at = now - chrono::Duration::seconds((records as u64 - k) as i64);
            let memory = Memory {
                id: Uuid::now_v7(),
                tenant: TENANT.into(),
                subject: subject.clone(),
                kind: if round { MemoryKind::Episodic } else { MemoryKind::Semantic },
                status: MemoryStatus::Committed,
                content,
                session_id: Some(format!("s{}", k / 50)),
                turn_ref: Some(format!("m{k}")),
                occurred_at: Some(at),
                valid_from: at,
                valid_to: None,
                supersedes: None,
                labels: if k % 11 == 0 { vec!["pii".into()] } else { vec![] },
                tags: if k % 7 == 0 { vec!["bench".into()] } else { vec![] },
                source: "bench".into(),
                confidence: 0.9,
                metadata: if round { serde_json::json!({ "round": k % 50 }) } else { serde_json::json!({}) },
                created_at: at,
                expires_at: None,
                scope: Scope::default(),
                provenance: Provenance { agent: Some("bench".into()), policy_version: Some("p-bench".into()), ..Default::default() },
                language: Some("en".into()),
            };
            w.audit.push(AuditEntry {
                actor: "bench".into(),
                action: "memory.commit".into(),
                subject: Some(subject),
                memory_id: Some(memory.id),
                detail: serde_json::json!({ "kind": memory.kind.as_str(), "source": "bench" }),
            });
            let hash = memhouse_core::engine::content_hash(&format!("{}\u{1f}{}", memory.kind.as_str(), memory.content));
            let mut new = NewMemory::new(memory, hash);
            new.embedding = Some(vector);
            w.records.push(new);
        }
        anyhow::ensure!(store.apply_intake(&w).await?, "a batch of synthetic records was not written");
        n += take as u64;
    }
    Ok(())
}

/// The benchmark's scratch database: a fixed name among the benchmark's own (`memhouse_bench_…`,
/// as the benchmark databases are named), never one derived from the configured database's
/// name. Whatever an earlier run left under it is this benchmark's, and is dropped first, so a
/// run that was killed does not block the next.
const SCRATCH_DB: &str = "memhouse_bench_migrate_scratch";

/// The scratch Postgres database, empty, on the configured server. Returns (admin pool, name, URL).
async fn scratch_postgres(cfg: &Config) -> anyhow::Result<(sqlx::PgPool, String, String)> {
    anyhow::ensure!(
        memhouse_server::sqlite_path(&cfg.database.url).is_none(),
        "the scratch database is created on the configured server, which must be Postgres (or use --to-sqlite)"
    );
    let admin = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&cfg.database.url)
        .await
        .map_err(|e| anyhow::anyhow!("cannot connect to Postgres at {}: {e}", migrate::redact(&cfg.database.url)))?;
    let db = SCRATCH_DB.to_string();
    let current: String = sqlx::query_scalar("SELECT current_database()").fetch_one(&admin).await?;
    anyhow::ensure!(current != db, "the configured database is the benchmark's scratch database ({db}): it would be dropped");
    sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP DATABASE IF EXISTS \"{db}\" WITH (FORCE)"))).execute(&admin).await?;
    sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE DATABASE \"{db}\""))).execute(&admin).await?;
    let (head, tail) = cfg.database.url.rsplit_once('/').ok_or_else(|| anyhow::anyhow!("unexpected database url"))?;
    let query = tail.split_once('?').map(|(_, q)| format!("?{q}")).unwrap_or_default();
    Ok((admin, db.clone(), format!("{head}/{db}{query}")))
}

/// Load, plan and migrate. Returns the report as Markdown.
/// `existing` is a Lite file to migrate instead of a freshly loaded one (a file an earlier run
/// kept, or a copy of a real one); it is only read.
pub async fn run(cfg: &Config, records: usize, per_subject: usize, to_sqlite: bool, existing: Option<&std::path::Path>, dir: &std::path::Path) -> anyhow::Result<String> {
    anyhow::ensure!(records > 0 && per_subject > 0, "the numbers of records and of records per subject must be at least 1");
    memhouse_store_sqlite::private_dir(dir)?;
    let source = existing.map(std::path::PathBuf::from).unwrap_or_else(|| dir.join("source.db"));
    let t_load = Instant::now();
    if existing.is_none() {
        let store = memhouse_store_sqlite::SqliteStore::open(&source, "")?;
        store.migrate(DIM, &memhouse_conformance::fakes::HashEmbedder::new(DIM).id).await?;
        store.policy_put(&memhouse_core::format::PolicyLine { version: "p-bench".into(), body: serde_json::json!({}), created_at: chrono::Utc::now() }).await?;
        load(&store, records, per_subject).await?;
    }
    let load_secs = t_load.elapsed().as_secs_f64();
    let bytes = std::fs::metadata(&source)?.len();

    let scratch = if to_sqlite { None } else { Some(scratch_postgres(cfg).await?) };
    let target = match &scratch {
        Some((_, _, url)) => url.clone(),
        None => format!("sqlite:{}", dir.join("target.db").display()),
    };
    let mut cfg = cfg.clone();
    cfg.memory.tenant = TENANT.into();
    let req = Request {
        from: migrate::endpoint(&format!("sqlite:{}", source.display()))?,
        to: migrate::endpoint(&target)?,
        cfg,
        config_path: None,
        progress: Some(Arc::new(|m: &str| eprintln!("  {m}"))),
    };
    let ran = async {
        let t_plan = Instant::now();
        let plan = migrate::plan(&req).await?;
        let plan_secs = t_plan.elapsed().as_secs_f64();
        let plan_text = migrate::describe_plan(&req, &plan);
        let t_run = Instant::now();
        let (report, _) = migrate::run(&req).await?;
        anyhow::Ok((plan_secs, plan_text, t_run.elapsed().as_secs_f64(), report))
    }
    .await;
    if let Some((admin, db, _)) = &scratch {
        let _ = sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP DATABASE IF EXISTS \"{db}\" WITH (FORCE)"))).execute(admin).await;
    }
    let (plan_secs, plan_text, run_secs, report) = ran?;

    let records = report.records as usize;
    let millions = records as f64 / 1e6;
    let per_million = run_secs / millions / 60.0;
    let mut o = String::new();
    let _ = writeln!(o, "# Migration at size: Lite to {}\n", if to_sqlite { "Lite (another file)" } else { "Standard (Postgres)" });
    let _ = match existing {
        None => writeln!(
            o,
            "{} synthetic records in {} subjects, each with a {DIM}-dimension vector (a stand-in embedder) and one audit event; {} audit events in all. The source file is {:.0} MB (loaded in {:.0} s).\n",
            report.records,
            records.div_ceil(per_subject),
            report.audit_events,
            bytes as f64 / 1_048_576.0,
            load_secs
        ),
        Some(_) => writeln!(
            o,
            "{} records of an existing file ({} with a vector), {} audit events. The source file is {:.0} MB.\n",
            report.records,
            report.source.vectors,
            report.audit_events,
            bytes as f64 / 1_048_576.0
        ),
    };
    let _ = writeln!(o, "| | |\n|---|---|");
    let _ = writeln!(o, "| Dry run | {plan_secs:.1} s |");
    let _ = writeln!(o, "| Copy (records with their vectors, every other table, the audit log) | {:.1} s |", report.copy_secs);
    let _ = writeln!(o, "| Verification (every record read back and compared by hash; tables row for row; the audit chain) | {:.1} s |", report.verify_secs);
    let _ = writeln!(o, "| The whole migration: the downtime | {run_secs:.1} s, {:.0} records a second |", records as f64 / run_secs.max(1e-6));
    let _ = writeln!(o, "| PROF-03: downtime per million records | {per_million:.2} min (target ≤ 5) {} |", if per_million <= 5.0 { "✅" } else { "❌" });
    let _ = writeln!(o, "| Records differing after the copy | 0 of {} (the migration fails otherwise) |", report.records);
    let _ = writeln!(o, "| Vectors compared on a sample | {}, largest difference of a component {} |", report.vectors_compared, report.vector_max_gap);
    let _ = writeln!(o, "\nThe dry run said:\n\n```\n{}```", plan_text);
    Ok(o)
}
