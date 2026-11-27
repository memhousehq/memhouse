// SPDX-License-Identifier: Apache-2.0
//! The Governance II checks (roadmap G22) that work on a database as an operator does: a
//! restore, a direct connection, partitions, anchors, the SIEM export, the evidence bundle and
//! the detection set. See `gov2_checks` for the list.

use crate::gov2_checks::{derived, engine_on, events, ids_of, only_postgres, raw, record, remember, same, template, words};
use crate::governance::Scratch;
use crate::scratch::Sql;
use chrono::Utc;
use memhouse_core::config::RedactAction;
use memhouse_core::governance::*;
use memhouse_core::types::*;
use memhouse_core::Engine;
use memhouse_server::governance as ops;
use memhouse_store_postgres::PgOptions;
use rand::{Rng, RngExt, SeedableRng};
use serde_json::json;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use uuid::Uuid;

type Outcome = anyhow::Result<(bool, String, String)>;
const T: &str = "default";

fn verdict(problems: Vec<String>, value: String, ok: &str) -> Outcome {
    Ok((problems.is_empty(), value, if problems.is_empty() { ok.to_string() } else { problems.join("; ") }))
}

/// A directory of the check's own, removed when the value is dropped.
struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> anyhow::Result<TempDir> {
        let dir = std::env::temp_dir().join(format!("memhouse-gov-{name}-{}", Uuid::now_v7().simple()));
        memhouse_store_sqlite::private_dir(&dir)?;
        Ok(TempDir(dir))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// TR-WF-03: a backup is taken, deletions follow, the backup is restored.
pub(crate) async fn restore_replay(base: &Engine) -> Outcome {
    let live = Scratch::create(base, "g22live").await?;
    let mut backup = None;
    let result = restore_scenario(base, &live, &mut backup).await;
    if let Some(b) = backup {
        b.drop().await?;
    }
    live.drop().await?;
    result
}

async fn restore_scenario(base: &Engine, live: &Scratch, backup: &mut Option<Scratch>) -> Outcome {
    let home = TempDir::new("restore-home")?;
    let mut problems = vec![];
    let e = engine_on(base, &live.url, PgOptions::default(), |_| {}).await?;
    let t = template(&e).await?;
    let (keep, erase, rounds) = ("rs:keep", "rs:erase", "rs:rounds");
    let rows = vec![
        record(&t, keep, MemoryKind::Semantic, words("rs", 0), 0, |_| {}),
        record(&t, keep, MemoryKind::Semantic, words("rs", 1), 0, |_| {}),
        record(&t, keep, MemoryKind::Semantic, words("rs", 2), 0, |_| {}),
        record(&t, erase, MemoryKind::Semantic, words("rs", 3), 0, |_| {}),
        record(&t, erase, MemoryKind::Semantic, words("rs", 4), 0, |_| {}),
        record(&t, rounds, MemoryKind::Episodic, words("rs", 5), 3, |_| {}),
        record(&t, rounds, MemoryKind::Episodic, words("rs", 6), 3, |_| {}),
    ];
    let (stays, deleted_later, deleted_before) = (rows[0].memory.id, rows[1].memory.id, rows[2].memory.id);
    let fact = derived(&t, rounds, rows[5].memory.id, words("rs", 7));
    e.store.insert(&rows).await?;
    e.store.insert(&[fact]).await?;
    // A deletion the backup already knows.
    e.forget(None, deleted_before, Some("dpo".into())).await?;
    e.instance_id().await?;

    // The backup: the database as it is now.
    *backup = Some(live.copy("bk").await?);
    let backup = backup.as_ref().expect("made");

    // After the backup: a record is deleted, a subject erased, rounds purged by retention.
    e.forget_by(ForgetRequest { id: Some(deleted_later), actor: Some("dpo".into()), ..Default::default() }).await?;
    e.forget_by(ForgetRequest { subject: Some(erase.into()), actor: Some("dpo".into()), ..Default::default() }).await?;
    let purged = e.store.purge(T, &PurgeSpec::older_than(MemoryKind::Episodic, 1)).await?.records;
    if purged != 3 || !ids_of(&e, rounds).await?.is_empty() || !ids_of(&e, erase).await?.is_empty() {
        problems.push(format!("the deletions on the live database did not take: {purged} purged (3 expected)"));
    }
    let ledger = e.store.ledger_export().await?;
    // What the installation last served, kept outside the database.
    ops::record_watermark(e.store.as_ref(), &home.0).await?;
    if ops::guard(e.store.as_ref(), &home.0).await? != ops::Guard::Ok {
        problems.push("the restore guard refuses the database it has just recorded".into());
    }

    // The restore: the backup takes the place of the database.
    let r = engine_on(base, &backup.url, PgOptions::default(), |_| {}).await?;
    let guard = ops::guard(r.store.as_ref(), &home.0).await?;
    if !matches!(guard, ops::Guard::Restored { .. }) {
        problems.push(format!("the restore guard does not refuse the restored database: {guard:?}"));
    }
    let known_before = r.store.ledger_export().await?.len() as u64;
    let back = (r.store.get(T, deleted_later).await?.is_some(), ids_of(&r, erase).await?.len(), ids_of(&r, rounds).await?.len());
    if back != (true, 2, 3) {
        problems.push(format!("the backup does not hold what was deleted after it was taken (record, erased subject, rounds with their fact): {back:?}"));
    }
    let rep = r.store.ledger_apply(&ledger, "cli", T, json!({ "ledger_given": true })).await?;
    let after = (
        r.store.get(T, deleted_later).await?.is_some(),
        ids_of(&r, erase).await?.len(),
        ids_of(&r, rounds).await?.len(),
        r.store.get(T, stays).await?.is_some(),
        r.store.get(T, deleted_before).await?.is_some(),
    );
    if after != (false, 0, 0, true, false) {
        problems.push(format!("after the replay (deleted record back, erased subject, rounds, an untouched record kept, a record deleted before the backup): {after:?}"));
    }
    let given = ledger.len() as u64;
    if rep.given != given || rep.known != known_before || rep.applied != given - known_before || rep.records_removed != 6 {
        problems.push(format!("the replay reports {rep:?}; {given} rows given, {known_before} known to the backup, 6 records to remove"));
    }
    let again = r.store.ledger_apply(&ledger, "cli", T, json!({ "ledger_given": true })).await?;
    if again.applied != 0 || again.records_removed != 0 {
        problems.push(format!("a second replay applied {} rows and removed {} records", again.applied, again.records_removed));
    }
    let (n, broken) = r.store.audit_verify().await?;
    let (restores, reapplied) = (events(&r, "backup.restore").await?.len(), events(&r, "deletion.reapply").await?.len());
    if broken.is_some() || restores != 2 || reapplied != 3 {
        problems.push(format!("the restored audit chain: broken at {broken:?} of {n}; {restores} backup.restore events (2 expected), {reapplied} deletion.reapply events (3: a record, a subject, the retention rows)"));
    }
    // An unknown kind of deletion is refused whole, not skipped.
    let unknown = LedgerEntry { at: Utc::now(), tenant: T.into(), subject: None, memory_id: None, scope: "galaxy".into(), actor: "x".into() };
    if r.store.ledger_apply(&[unknown], "cli", T, json!({})).await.is_ok() {
        problems.push("a ledger row of an unknown kind was accepted".into());
    }
    // Once the ledger is re-applied the database is recorded as fit to serve.
    ops::record_watermark(r.store.as_ref(), &home.0).await?;
    if ops::guard(r.store.as_ref(), &home.0).await? != ops::Guard::Ok {
        problems.push("the restore guard still refuses the database after the replay".into());
    }
    verdict(
        problems,
        format!("{given} ledger rows, {} known to the backup → {} re-applied, {} records removed; 0 on the second replay", rep.known, rep.applied, rep.records_removed),
        "the restored database is refused until the ledger is re-applied; the deleted record, the erased subject and the purged rounds with their fact are gone again; the audit chain verifies",
    )
}

/// TR-DB-03: what a connection that did not come through the service can read.
pub(crate) async fn rls_bypass(base: &Engine) -> Outcome {
    only_postgres(base, "row-level security is a feature of the Postgres store; a Lite database is one file with one writer, opened by the service alone")?;
    let scratch = Scratch::create(base, "g22rls").await?;
    let result = rls_scenario(base, &scratch.url).await;
    scratch.drop().await?;
    result
}

async fn rls_scenario(base: &Engine, url: &str) -> Outcome {
    use sqlx::Connection;
    let options = PgOptions { row_level_security: true, episodic_partitions: false };
    let e = engine_on(base, url, options, |_| {}).await?;
    let other = engine_on(base, url, options, |c| c.memory.tenant = "other".into()).await?;
    let mut problems = vec![];
    let (a, b) = ("rls:a", "rls:b");
    for (i, subject) in [a, a, b].iter().enumerate() {
        e.remember(remember(subject, &format!("Tenant one notes {}", words("rls", i)))).await?;
    }
    other.remember(remember(a, &format!("Tenant two notes {}", words("rls-other", 0)))).await?;
    // The service works as before, each tenant within its own rows.
    let mine = e.recall(RecallRequest { subject: Some(a.into()), query: format!("tenant notes {}", words("rls", 0)), k: Some(10), ..Default::default() }).await?;
    let theirs = other.recall(RecallRequest { subject: Some(a.into()), query: format!("tenant notes {}", words("rls", 0)), k: Some(10), ..Default::default() }).await?;
    if mine.hits.is_empty() || mine.hits.iter().any(|h| h.memory.tenant != T) || theirs.hits.len() != 1 || theirs.hits.iter().any(|h| h.memory.tenant != "other") {
        problems.push(format!(
            "through the service: {} hits for the tenant (its own expected), {} for the other tenant (1 of its own expected)",
            mine.hits.len(),
            theirs.hits.len()
        ));
    }
    let status = e.store.rls_status().await?.unwrap_or_default();
    if status["enabled_on_every_memory_table"] != true {
        problems.push(format!("row-level security is not enabled and forced with a policy on every memory table: {}", status["tables"]));
    }
    let bypass = status["service_role_bypasses"] == true;

    // A direct connection: not the service's pool, so nothing has set its session settings.
    let mut c = sqlx::PgConnection::connect(url).await?;
    let role = format!("mh_probe_{}", &Uuid::new_v4().simple().to_string()[..12]);
    let other_role = sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE ROLE {role} NOLOGIN"))).execute(&mut c).await.is_ok();
    if other_role {
        sqlx::raw_sql(sqlx::AssertSqlSafe(format!("GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO {role}; SET ROLE {role}"))).execute(&mut c).await?;
    } else if bypass {
        anyhow::bail!("the check needs either the right to create a role or a service role that row-level security binds; this role bypasses it and can create none");
    }
    let outcome = async {
        let mut problems = vec![];
        let tables = ["mh_memory", "mh_structured", "mh_code_ref", "mh_link", "mh_recall", "mh_intake", "mh_request_key", "mh_enrich_job", "mh_embed_cache", "mh_llm_cache"];
        let mut seen = 0i64;
        for t in tables {
            seen += sqlx::query_scalar::<_, i64>(sqlx::AssertSqlSafe(format!("SELECT count(*) FROM {t}"))).fetch_one(&mut c).await?;
        }
        if seen != 0 {
            problems.push(format!("a connection without session settings read {seen} rows of the memory tables"));
        }
        let set = "SELECT set_config('memhouse.scope', $1, false), set_config('memhouse.tenant', $2, false), set_config('memhouse.subject', $3, false)";
        sqlx::query(set).bind("").bind(T).bind("").execute(&mut c).await?;
        let (all, foreign): (i64, i64) = sqlx::query_as("SELECT count(*), count(*) FILTER (WHERE tenant <> 'default') FROM mh_memory").fetch_one(&mut c).await?;
        if all != 3 || foreign != 0 {
            problems.push(format!("narrowed to one tenant, a statement without a filter read {all} rows (3 expected), {foreign} of another tenant"));
        }
        sqlx::query(set).bind("").bind(T).bind("rls:a").execute(&mut c).await?;
        let (in_subject, outside): (i64, i64) = sqlx::query_as("SELECT count(*), count(*) FILTER (WHERE subject <> 'rls:a') FROM mh_memory").fetch_one(&mut c).await?;
        if in_subject != 2 || outside != 0 {
            problems.push(format!("narrowed to one subject, a statement without a filter read {in_subject} rows (2 expected), {outside} of another subject"));
        }
        // Writing another tenant's row is refused by the same policy.
        let insert = sqlx::query(
            "INSERT INTO mh_memory (id, tenant, subject, kind, status, content, content_hash, valid_from, source) \
             VALUES (gen_random_uuid(), 'other', 'rls:a', 'semantic', 'committed', 'planted', 'planted', now(), 'probe')",
        )
        .execute(&mut c)
        .await;
        if !insert.as_ref().err().is_some_and(|e| e.to_string().contains("row-level security")) {
            problems.push(format!("a row of another tenant was written from a session narrowed to one tenant: {:?}", insert.map(|r| r.rows_affected())));
        }
        // The service scope is the table owner's: another role that names it reads nothing.
        sqlx::query(set).bind("service").bind("").bind("").execute(&mut c).await?;
        let as_service: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory").fetch_one(&mut c).await?;
        if other_role && as_service != 0 {
            problems.push(format!("a role that does not own the tables took the service scope and read {as_service} rows"));
        }
        anyhow::Ok(problems)
    }
    .await;
    if other_role {
        let _ = sqlx::raw_sql(sqlx::AssertSqlSafe(format!("RESET ROLE; REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {role}; DROP ROLE {role}"))).execute(&mut c).await;
    }
    let _ = c.close().await;
    problems.extend(outcome?);

    // The service as an ordinary role: one that owns the tables through membership and is
    // neither a superuser nor exempt from row-level security, so the policies bind every
    // statement it runs. Everything the service does must still work, on the session settings
    // it sets itself.
    let mut bound = "not run: this role cannot create one".to_string();
    if other_role {
        let svc = format!("mh_svc_{}", &Uuid::new_v4().simple().to_string()[..12]);
        let mut admin = sqlx::PgConnection::connect(url).await?;
        sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE ROLE {svc} NOLOGIN; DO $$ BEGIN EXECUTE format('GRANT %I TO {svc}', current_user); END $$;")))
            .execute(&mut admin)
            .await?;
        // The session takes the role as it starts: every statement of the pool runs as it.
        let svc_url = format!("{url}{}options=-c%20role%3D{svc}", if url.contains('?') { '&' } else { '?' });
        let outcome = service_as_bound_role(base, &svc_url, options).await;
        let _ = sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DO $$ BEGIN EXECUTE format('REVOKE %I FROM {svc}', current_user); END $$; DROP OWNED BY {svc}; DROP ROLE {svc}")))
            .execute(&mut admin)
            .await;
        let _ = admin.close().await;
        match outcome {
            Ok((p, summary)) => {
                problems.extend(p);
                bound = summary;
            }
            Err(e) => problems.push(format!("the service as a role the policies bind: {e:#}")),
        }
    }

    // With the policies in force the service still deletes and purges within its tenant.
    let erased = e.forget_by(ForgetRequest { subject: Some(b.into()), actor: Some("dpo".into()), ..Default::default() }).await?;
    e.retention_run(Default::default()).await?;
    let untouched = other.list(None, Some(a.into()), None, 10, 0, true).await?.len();
    if erased.deleted != 1 || untouched != 1 {
        problems.push(format!("with row-level security on, an erasure deleted {} records (1 expected) and the other tenant has {untouched} (1 expected)", erased.deleted));
    }
    verdict(
        problems,
        format!(
            "direct connection {}: 0 rows without session settings, 3 of 4 with the tenant's, 2 with the subject's, 0 of another tenant; a foreign row refused; the service as a role the policies bind: {bound}",
            if other_role { "as a role that does not own the tables" } else { "as the service's own role" }
        ),
        if bypass {
            "policies are enabled and forced on every memory table; this database's own service role is a superuser (or has BYPASSRLS), which no policy binds, so the service was also run as an ordinary role"
        } else {
            "policies are enabled and forced on every memory table and bind the service's own role too"
        },
    )
}

/// The service's own work on a connection the policies bind: writes, recall, reads, a hold, a
/// deletion with its certificate, retention. Returns what went wrong and a summary.
async fn service_as_bound_role(base: &Engine, url: &str, options: PgOptions) -> anyhow::Result<(Vec<String>, String)> {
    use sqlx::Connection;
    let mut problems = vec![];
    let s = engine_on(base, url, options, |c| c.governance.episodic_retention_days = 30).await?;
    let status = s.store.rls_status().await?.unwrap_or_default();
    if status["service_role_bypasses"] != false || status["enabled_on_every_memory_table"] != true {
        problems.push(format!("the role is not bound by the policies: {}", status["service_role"]));
    }
    // The same role without the service's session settings reads nothing: the policies do bind it.
    let mut c = sqlx::PgConnection::connect(url).await?;
    let unset: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory").fetch_one(&mut c).await?;
    let _ = c.close().await;
    let subject = "rls:bound";
    let mut ids = vec![];
    for i in 0..3 {
        ids.push(s.remember(remember(subject, &format!("The bound service notes {}", words("rls-bound", i)))).await?.id);
    }
    let rounds = s
        .ingest(IngestRequest {
            subject: Some(subject.into()),
            session_id: Some("bound".into()),
            messages: (0..2)
                .map(|i| Message { role: if i == 0 { "user".into() } else { "assistant".into() }, content: words("rls-bound-round", i), timestamp: None, id: None })
                .collect(),
            actor: Some("bench".into()),
            wait: true,
            ..Default::default()
        })
        .await?;
    let recalled =
        s.recall(RecallRequest { subject: Some(subject.into()), query: format!("the bound service notes {}", words("rls-bound", 0)), k: Some(10), ..Default::default() }).await?;
    let listed = ids_of(&s, subject).await?.len();
    let got = s.store.get(T, ids[0]).await?.is_some();
    if unset != 0 || !recalled.hits.iter().any(|h| h.memory.id == ids[0]) || listed != 3 + rounds.ids.len() || !got {
        problems.push(format!(
            "bound by the policies: {unset} rows read without session settings (0 expected); recall found the record: {}; {listed} records listed ({} expected); read by id: {got}",
            recalled.hits.iter().any(|h| h.memory.id == ids[0]),
            3 + rounds.ids.len()
        ));
    }
    let hold = s.hold_place(T, "subject", subject, "matter 2026-22", "counsel").await?;
    let held = s.forget_by(ForgetRequest { id: Some(ids[1]), actor: Some("dpo".into()), ..Default::default() }).await?;
    let (_, resumed) = s.hold_release(T, hold.id, "counsel").await?;
    let pass = s.retention_run(Default::default()).await?;
    let erased = s.forget_by(ForgetRequest { subject: Some(subject.into()), actor: Some("dpo".into()), ..Default::default() }).await?;
    let cert = match erased.deletion_id {
        Some(id) => s.deletion(T, id).await?.certificate,
        None => None,
    };
    let left = ids_of(&s, subject).await?.len();
    let (events, broken) = s.store.audit_verify().await?;
    if (held.deleted, held.held) != (0, 1) || resumed.len() != 1 || !pass.complete || left != 0 || !cert.as_ref().is_some_and(|c| c.verified) || broken.is_some() {
        problems.push(format!(
            "bound by the policies: a held forget answered ({}, {}) ((0, 1) expected), {} deletions resumed (1), retention complete {}, {left} records left after erasure (0), certificate verified {:?}, audit chain broken at {broken:?} of {events}",
            held.deleted,
            held.held,
            resumed.len(),
            pass.complete,
            cert.map(|c| c.verified)
        ));
    }
    Ok((problems, format!("writes, recall, reads, a hold, {} deletions with certificates and a retention pass all work; 0 rows without the session settings", 1 + resumed.len())))
}

/// TR-DB-04: conversion in place, partitions by month, retention by drop.
pub(crate) async fn episodic_partitions(base: &Engine) -> Outcome {
    only_postgres(base, "monthly partitions are a feature of the Postgres store; the Lite store keeps one file and purges by row")?;
    let scratch = Scratch::create(base, "g22part").await?;
    let result = partition_scenario(base, &scratch.url).await;
    scratch.drop().await?;
    result
}

async fn partition_scenario(base: &Engine, url: &str) -> Outcome {
    let mut problems = vec![];
    // A database as it is before the option is turned on, with records of both sorts.
    let plain = engine_on(base, url, PgOptions::default(), |_| {}).await?;
    let t = template(&plain).await?;
    let (facts, legacy) = ("part:facts", "part:legacy");
    let mut order = remember(facts, &format!("Order 77 holds {}", words("part-order", 0)));
    order.structured = Some(Structured { record_type: "order".into(), attrs: json!({ "order_id": "77" }) });
    let order = plain.remember(order).await?.id;
    let mut before = vec![record(&t, facts, MemoryKind::Semantic, words("part", 0), 0, |_| {})];
    for i in 0..2 {
        before.push(record(&t, legacy, MemoryKind::Episodic, words("part-legacy", i), 200, |_| {}));
    }
    plain.store.insert(&before).await?;
    if plain.store.episodic_partitions().await?.is_some() {
        problems.push("the memory table is partitioned before the option was turned on".into());
    }
    let held_before: HashSet<Uuid> = ids_of(&plain, facts).await?.union(&ids_of(&plain, legacy).await?).copied().collect();
    drop(plain);

    // Turned on: the next start converts the table in place.
    let options = PgOptions { row_level_security: false, episodic_partitions: true };
    let e = engine_on(base, url, options, |_| {}).await?;
    let held_after: HashSet<Uuid> = ids_of(&e, facts).await?.union(&ids_of(&e, legacy).await?).copied().collect();
    if e.store.episodic_partitions().await? != Some(vec![]) || held_after != held_before {
        problems.push(format!(
            "after the conversion: partitions {:?} (none yet expected), {} of {} records still there",
            e.store.episodic_partitions().await?,
            held_after.len(),
            held_before.len()
        ));
    }
    let found = e.recall(RecallRequest { subject: Some(facts.into()), query: format!("order 77 holds {}", words("part-order", 0)), k: Some(5), ..Default::default() }).await?;
    if !found.hits.iter().any(|h| h.memory.id == order) {
        problems.push("a record written before the conversion is not recalled after it".into());
    }

    // Episodic memory of three months, one row of it under a legal hold.
    let (ep, held) = ("part:rounds", "part:held");
    let mut rows = vec![];
    for i in 0..3 {
        rows.push(record(&t, ep, MemoryKind::Episodic, words("part-old", i), 110, |_| {}));
        rows.push(record(&t, ep, MemoryKind::Episodic, words("part-mid", i), 70, |_| {}));
    }
    rows[0].structured = Some(Structured { record_type: "call".into(), attrs: json!({ "minutes": 12 }) });
    let with_structured = rows[0].memory.id;
    let fact = derived(&t, ep, rows[0].memory.id, words("part-fact", 0));
    let fact_id = fact.memory.id;
    let fresh: Vec<NewMemory> = (0..2).map(|i| record(&t, ep, MemoryKind::Episodic, words("part-new", i), 0, |_| {})).collect();
    let fresh_ids: Vec<Uuid> = fresh.iter().map(|r| r.memory.id).collect();
    let held_row = record(&t, held, MemoryKind::Episodic, words("part-held", 0), 70, |_| {});
    let held_id = held_row.memory.id;
    let old_ids: Vec<Uuid> = rows.iter().map(|r| r.memory.id).collect();
    e.store.insert(&rows).await?;
    e.store.insert(&fresh).await?;
    e.store.insert(&[fact, held_row]).await?;
    let months = e.store.episodic_partitions().await?.unwrap_or_default();
    if months.len() != 3 {
        problems.push(format!("episodic memory of three months is in {} partitions: {months:?}", months.len()));
    }
    let hold = e.hold_place(T, "subject", held, "matter 2026-20", "counsel").await?;
    let db = raw(url).await?;
    let structured = |id: Uuid| {
        let db = db.clone();
        async move { db.count(same("SELECT count(*) FROM mh_structured WHERE memory_id = $1"), &[id.into()]).await }
    };
    if structured(with_structured).await? != 1 {
        problems.push("the structured form of an episodic record was not stored".into());
    }

    // Retention at 30 days: the oldest month goes whole; the month with the held row is kept
    // and loses its other rows one by one; the rows from before the conversion go by row.
    let pass = e.store.purge(T, &PurgeSpec::older_than(MemoryKind::Episodic, 30)).await?;
    let left = ids_of(&e, ep).await?;
    let after_first = e.store.episodic_partitions().await?.unwrap_or_default();
    let ledger = e.store.ledger_export().await?;
    let ledgered = old_ids.iter().filter(|id| ledger.iter().any(|l| l.scope == "retention" && l.memory_id == Some(**id))).count();
    if pass.partitions_dropped != 1 || pass.records != 9 || pass.held != 1 || after_first.len() != 2 {
        problems.push(format!("the first pass: {} partitions dropped (1 expected), {} records removed (9: six rounds, their fact, two from before the conversion), {} held (1), {} partitions left (2)", pass.partitions_dropped, pass.records, pass.held, after_first.len()));
    }
    if old_ids.iter().any(|id| left.contains(id)) || left.contains(&fact_id) || !fresh_ids.iter().all(|id| left.contains(id)) || ledgered != old_ids.len() {
        problems.push(format!(
            "after the first pass: old rounds left {}, their fact left {}, this month's rounds kept {}, {ledgered} of {} in the ledger",
            old_ids.iter().filter(|id| left.contains(id)).count(),
            left.contains(&fact_id),
            fresh_ids.iter().filter(|id| left.contains(id)).count(),
            old_ids.len()
        ));
    }
    if structured(with_structured).await? != 0 || !ids_of(&e, legacy).await?.is_empty() || !ids_of(&e, held).await?.contains(&held_id) || ids_of(&e, facts).await?.len() != 2 {
        problems.push(
            "after the first pass: the structured form of a dropped round is left, a round from before the conversion is left, the held round is gone, or a fact was touched"
                .into(),
        );
    }
    // Released: the month it kept is dropped by the next pass.
    e.hold_release(T, hold.id, "counsel").await?;
    let second = e.store.purge(T, &PurgeSpec::older_than(MemoryKind::Episodic, 30)).await?;
    let after_second = e.store.episodic_partitions().await?.unwrap_or_default();
    if second.partitions_dropped != 1 || second.records != 1 || after_second.len() != 1 || !ids_of(&e, held).await?.is_empty() {
        problems.push(format!(
            "after the release: {} partitions dropped (1 expected), {} records (1), {} partitions left (1: this month's)",
            second.partitions_dropped,
            second.records,
            after_second.len()
        ));
    }
    // What the foreign keys did before the conversion still happens: a record's structured form goes with it.
    e.forget(None, order, Some("dpo".into())).await?;
    if structured(order).await? != 0 {
        problems.push("the structured form of a deleted record is left (the cascade the foreign key gave)".into());
    }
    // Recall reads every partition.
    let recent = e.recall(RecallRequest { subject: Some(ep.into()), query: words("part-new", 0), k: Some(5), ..Default::default() }).await?;
    if !recent.hits.iter().any(|h| h.memory.id == fresh_ids[0]) {
        problems.push("a round in a monthly partition is not recalled".into());
    }
    db.close().await;
    verdict(
        problems,
        format!(
            "3 months of rounds → {} + {} partitions dropped whole, {} records and derived facts removed, {ledgered} ledger rows; the held month kept until release",
            pass.partitions_dropped,
            second.partitions_dropped,
            pass.records + second.records
        ),
        "the table is converted without moving or losing a row; a due month is dropped with its cascade and ledger rows in one transaction; a month with a held row is kept",
    )
}

/// GOV-12: anchors outside the database.
pub(crate) async fn audit_anchor(base: &Engine, url: String) -> Outcome {
    let e = engine_on(base, &url, PgOptions::default(), |_| {}).await?;
    let dir = TempDir::new("anchors")?;
    let file = dir.0.join("anchors.jsonl");
    let mut problems = vec![];
    for i in 0..3 {
        e.remember(remember("anchor:s", &format!("Before the first anchor {}", words("anchor", i)))).await?;
    }
    let first = ops::anchor_to(&e, &file, "bench").await?;
    for i in 3..6 {
        e.remember(remember("anchor:s", &format!("Before the second anchor {}", words("anchor", i)))).await?;
    }
    let second = ops::anchor_to(&e, &file, "bench").await?;
    let anchors = ops::read_anchors(&file)?;
    let checks = e.anchors_check(&anchors).await?;
    if anchors.len() != 2 || checks.iter().any(|c| c.result != "match") || second.event_id <= first.event_id || events(&e, "audit.anchor").await?.len() != 2 {
        problems.push(format!("two anchors of an untouched log: {:?}", checks.iter().map(|c| c.result).collect::<Vec<_>>()));
    }
    // Someone who can write the table removes what followed the first anchor and continues the
    // chain from there: every hash is consistent again, so the chain alone shows nothing.
    let db = raw(&url).await?;
    let removed = db.execute(same("DELETE FROM mh_audit WHERE id > $1"), &[first.event_id.into()]).await?;
    db.close().await;
    for i in 0..2 {
        e.store.audit("intruder", "memory.write", T, Some("anchor:s"), None, json!({ "kind": "semantic", "n": i })).await?;
    }
    let (n, broken) = e.store.audit_verify().await?;
    let after = e.anchors_check(&anchors).await?;
    let results: Vec<&str> = after.iter().map(|c| c.result).collect();
    if broken.is_some() {
        problems.push(format!("the rewritten chain does not verify (event {broken:?} of {n}): the scenario needs a rewrite the chain cannot show"));
    }
    if removed == 0 || results.first() != Some(&"match") || results.get(1) == Some(&"match") || results.len() != 2 {
        problems.push(format!("after the rewrite ({removed} events removed) the anchors read {results:?}; the first should match and the second should not"));
    }
    let mut foreign = anchors[0].clone();
    foreign.instance = Uuid::new_v4().to_string();
    if e.anchors_check(&[foreign]).await?[0].result != "other_instance" {
        problems.push("an anchor of another installation was compared with this one's log".into());
    }
    verdict(
        problems,
        format!("2 anchors, then {removed} events removed and the chain continued: the chain verifies ({n} events), the anchors read {results:?}"),
        "the anchors match an untouched log; a rewrite that leaves the chain consistent is exposed by the anchor taken before it",
    )
}

/// What a receiver took in, with when.
type Received = Arc<Mutex<Vec<(chrono::DateTime<Utc>, String)>>>;

/// A syslog receiver: one message per line.
async fn syslog_sink(listener: tokio::net::TcpListener, into: Received) {
    loop {
        let Ok((mut stream, _)) = listener.accept().await else { return };
        let into = into.clone();
        tokio::spawn(async move {
            let mut text = String::new();
            let _ = stream.read_to_string(&mut text).await;
            let at = Utc::now();
            into.lock().unwrap().extend(text.lines().filter(|l| !l.is_empty()).map(|l| (at, l.to_string())));
        });
    }
}

/// An OTLP/HTTP collector: takes the body of each request and answers 200.
async fn otlp_sink(listener: tokio::net::TcpListener, into: Received) {
    loop {
        let Ok((mut stream, _)) = listener.accept().await else { return };
        let into = into.clone();
        tokio::spawn(async move {
            let mut buf = vec![];
            let mut chunk = [0u8; 8192];
            let (mut head_end, mut length) = (None, 0usize);
            loop {
                if let Some(end) = head_end {
                    if buf.len() >= end + length {
                        break;
                    }
                }
                match stream.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => buf.extend_from_slice(&chunk[..n]),
                }
                if head_end.is_none() {
                    if let Some(at) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        head_end = Some(at + 4);
                        let head = String::from_utf8_lossy(&buf[..at]).to_ascii_lowercase();
                        length = head.lines().find_map(|l| l.strip_prefix("content-length:")).and_then(|v| v.trim().parse().ok()).unwrap_or(0);
                    }
                }
            }
            if let Some(end) = head_end {
                let body = String::from_utf8_lossy(&buf[end..(end + length).min(buf.len())]).to_string();
                into.lock().unwrap().push((Utc::now(), body));
            }
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}").await;
            let _ = stream.shutdown().await;
        });
    }
}

fn external_ids(lines: &[(chrono::DateTime<Utc>, String)]) -> Vec<i64> {
    lines.iter().filter_map(|(_, l)| l.split("externalId=").nth(1)?.split(' ').next()?.parse().ok()).collect()
}

/// GOV-15: the export to both receivers, its delay, its order, and a receiver that is down.
pub(crate) async fn siem_export(base: &Engine, url: String) -> Outcome {
    use memhouse_server::siem::Exporter;
    let e = engine_on(base, &url, PgOptions::default(), |_| {}).await?;
    let mut problems = vec![];
    let syslog = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let otlp = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let (syslog_addr, otlp_addr) = (syslog.local_addr()?, otlp.local_addr()?);
    let (lines, bodies): (Received, Received) = Default::default();
    let syslog_task = tokio::spawn(syslog_sink(syslog, lines.clone()));
    let otlp_task = tokio::spawn(otlp_sink(otlp, bodies.clone()));
    let cfg = memhouse_core::config::SiemConfig {
        syslog: format!("tcp://{syslog_addr}"),
        otlp_endpoint: format!("http://{otlp_addr}"),
        interval_secs: 1,
        batch: 50,
        ..Default::default()
    };
    let exporter = Exporter::with(e.store.clone(), cfg.clone(), "memhouse");
    // The export starts with what is written from now on.
    let start = exporter.pass().await?;
    let head = e.store.audit_head().await?.map_or(0, |h| h.id);
    if !start.leader || !start.sent.is_empty() {
        problems.push(format!("the first pass sent {:?} (nothing expected: the export starts at the head)", start.sent));
    }
    // A marker in every memory's text: it must reach neither receiver.
    let marker = format!("zebra{}", &Uuid::new_v4().simple().to_string()[..10]);
    for i in 0..120 {
        e.remember(remember("siem:s", &format!("{marker} {}", words("siem", i)))).await?;
    }
    let written = e.store.audit_after(head, 100_000).await?;
    let pass = exporter.pass().await?;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let want: Vec<i64> = written.iter().map(|a| a.id).collect();
    let got_lines = lines.lock().unwrap().clone();
    let got_bodies = bodies.lock().unwrap().clone();
    let syslog_ids = external_ids(&got_lines);
    let mut otlp_ids = vec![];
    for (_, body) in &got_bodies {
        let v: serde_json::Value = serde_json::from_str(body)?;
        for r in v["resourceLogs"][0]["scopeLogs"][0]["logRecords"].as_array().into_iter().flatten() {
            let id = r["attributes"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|a| a["key"] == "memhouse.audit.id")
                .and_then(|a| a["value"]["intValue"].as_str())
                .and_then(|s| s.parse::<i64>().ok());
            otlp_ids.extend(id);
        }
    }
    // Batches go over separate connections, and a receiver may finish reading a later one
    // first: what is compared is that each event arrived, once.
    let sorted = |mut v: Vec<i64>| {
        v.sort_unstable();
        v
    };
    if sorted(syslog_ids.clone()) != want || sorted(otlp_ids.clone()) != want || want.len() < 120 {
        problems.push(format!("{} events written; the syslog receiver has {} and the collector {} (each once expected)", want.len(), syslog_ids.len(), otlp_ids.len()));
    }
    if !got_lines.iter().all(|(_, l)| l.starts_with("<110>1 ") && l.contains("CEF:0|MemHouse|memhouse|")) {
        problems.push("a syslog message is not an RFC 5424 line carrying CEF".into());
    }
    // The delay of each event: from its being written to its being taken by the receiver.
    let at_of: std::collections::HashMap<i64, chrono::DateTime<Utc>> = written.iter().map(|a| (a.id, a.at)).collect();
    let delays: Vec<i64> = got_lines.iter().zip(&syslog_ids).filter_map(|((at, _), id)| at_of.get(id).map(|w| (*at - *w).num_milliseconds())).collect();
    let worst = delays.iter().copied().max().unwrap_or(0);
    let late = delays.iter().filter(|d| **d > 60_000).count();
    if late > 0 || pass.max_delay_ms > 60_000 {
        problems.push(format!("{late} events reached the receiver more than 60 s after they were written (worst {worst} ms)"));
    }
    if got_lines.iter().any(|(_, l)| l.contains(&marker)) || got_bodies.iter().any(|(_, b)| b.contains(&marker)) {
        problems.push("memory content reached a receiver".into());
    }
    let idle = exporter.pass().await?;
    if !idle.sent.is_empty() {
        problems.push(format!("a pass with nothing new sent {:?}", idle.sent));
    }
    // A second replica stands by while the first holds the export.
    let standby = Exporter::with(e.store.clone(), cfg.clone(), "memhouse").pass().await?;
    if standby.leader {
        problems.push("two exporters exported at once".into());
    }
    // The syslog receiver goes down: its events wait, the collector still gets its own.
    syslog_task.abort();
    let _ = syslog_task.await;
    for i in 0..5 {
        e.remember(remember("siem:s", &format!("{marker} {}", words("siem-down", i)))).await?;
    }
    let down = exporter.pass().await?;
    if !down.errors.iter().any(|x| x.starts_with("syslog")) || down.sent.contains_key("syslog") || !down.sent.contains_key("otlp") {
        problems.push(format!("with the syslog receiver down: sent {:?}, errors {:?}", down.sent, down.errors));
    }
    let syslog = tokio::net::TcpListener::bind(syslog_addr).await?;
    let syslog_task = tokio::spawn(syslog_sink(syslog, lines.clone()));
    let up = exporter.pass().await?;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let all: Vec<i64> = e.store.audit_after(head, 100_000).await?.iter().map(|a| a.id).collect();
    let final_ids = sorted(external_ids(&lines.lock().unwrap()));
    if final_ids != all || !up.errors.is_empty() {
        problems.push(format!("after the receiver came back: {} of {} events delivered, errors {:?} (every event once expected)", final_ids.len(), all.len(), up.errors));
    }
    syslog_task.abort();
    otlp_task.abort();
    verdict(
        problems,
        format!(
            "{} events to syslog (CEF) and OTLP: 100% within 60 s (worst {worst} ms, target 99.9%); {} more after an outage, none lost or repeated",
            want.len(),
            all.len() - want.len()
        ),
        "each event once at both receivers, read from the log in order, no memory content; one replica exports at a time; a receiver that is down delays its events and loses none",
    )
}

/// GOV-16: the bundle and its mapping.
pub(crate) async fn evidence_export(base: &Engine, url: String) -> Outcome {
    let e = engine_on(base, &url, PgOptions::default(), |_| {}).await?;
    let dir = TempDir::new("evidence")?;
    let mut problems = vec![];
    // Something for each kind of evidence: a principal with a key, memories, a deletion, a hold.
    e.principal_put(T, "agent:evidence-bot", &memhouse_core::admin::PrincipalRequest { subjects: vec!["*".into()], ..Default::default() }, "bench").await?;
    let (key, secret) = e.key_create(T, "agent:evidence-bot", None, None, "bench", None).await?;
    let marker = format!("zebra{}", &Uuid::new_v4().simple().to_string()[..10]);
    for i in 0..3 {
        e.remember(remember("evidence:s", &format!("{marker} {}", words("evidence", i)))).await?;
    }
    e.forget_by(ForgetRequest { subject: Some("evidence:s".into()), actor: Some("dpo".into()), ..Default::default() }).await?;
    e.remember(remember("evidence:kept", &format!("{marker} {}", words("evidence", 9)))).await?;
    e.hold_place(T, "subject", "evidence:kept", "matter 2026-21", "counsel").await?;
    let out = dir.0.join("bundle");
    let manifest = ops::evidence_export(&e, &out, None, "bench").await?;
    let read = |name: &str| std::fs::read_to_string(out.join(name)).unwrap_or_default();
    let mut everything = String::new();
    for f in &manifest.files {
        let text = read(&f.file);
        if text.len() < 3 || hex::encode(<sha2::Sha256 as sha2::Digest>::digest(text.as_bytes())) != f.sha256 || text.len() as u64 != f.bytes {
            problems.push(format!("{} is empty or does not match its checksum in the manifest", f.file));
        }
        everything.push_str(&text);
    }
    let on_disk: serde_json::Value = serde_json::from_str(&read("manifest.json"))?;
    if on_disk["files"].as_array().map(|f| f.len()) != Some(manifest.files.len()) || on_disk["format"] != "memhouse.evidence" {
        problems.push("manifest.json does not list the bundle's files".into());
    }
    // Every control: both frameworks, and evidence files that are in the bundle.
    let controls: serde_json::Value = serde_json::from_str(&read("controls.json"))?;
    let listed = controls["controls"].as_array().cloned().unwrap_or_default();
    let mut without = vec![];
    for c in evidence::CONTROLS {
        let entry = listed.iter().find(|l| l["id"] == c.id);
        let files = entry.and_then(|l| l["evidence"].as_array()).cloned().unwrap_or_default();
        let complete = !files.is_empty()
            && files.iter().all(|f| f["sha256"].as_str().is_some_and(|s| manifest.files.iter().any(|m| Some(m.file.as_str()) == f["file"].as_str() && m.sha256 == s)))
            && entry.is_some_and(|l| l["soc2"].as_array().is_some_and(|a| !a.is_empty()) && l["iso27001"].as_array().is_some_and(|a| !a.is_empty()));
        if !complete {
            without.push(c.id);
        }
    }
    if !without.is_empty() || listed.len() != evidence::CONTROLS.len() {
        problems.push(format!("controls without evidence in the bundle, or without both mappings: {without:?}"));
    }
    // What the evidence says of this installation.
    let chain: serde_json::Value = serde_json::from_str(&read("audit-chain.json"))?;
    let deletions: serde_json::Value = serde_json::from_str(&read("deletions.json"))?;
    let holds: serde_json::Value = serde_json::from_str(&read("legal-holds.json"))?;
    let access: serde_json::Value = serde_json::from_str(&read("access.json"))?;
    if chain["verified"]["intact"] != true
        || deletions["completed"] != 1
        || holds["active"] != 1
        || !access["keys"].as_array().is_some_and(|k| k.iter().any(|x| x["id"] == json!(key.id)))
    {
        problems.push(format!(
            "the evidence does not show the installation's state: chain intact {}, {} deletions completed, {} active holds, the key listed {}",
            chain["verified"]["intact"], deletions["completed"], holds["active"], access["keys"]
        ));
    }
    // No content, no key and no hash of a key.
    for (what, value) in [("memory content", marker.as_str()), ("a key", secret.as_str()), ("the hash of a key's secret", key.hash.as_str())] {
        if everything.contains(value) {
            problems.push(format!("the bundle holds {what}"));
        }
    }
    if events(&e, "evidence.export").await?.len() != 1 {
        problems.push("the export is not in the audit log".into());
    }
    if ops::evidence_export(&e, &out, None, "bench").await.is_ok() {
        problems.push("a second export was written over the first".into());
    }
    verdict(
        problems,
        format!("{} controls mapped to SOC 2 and ISO 27001, {} evidence files; {} controls without evidence", evidence::CONTROLS.len(), manifest.files.len(), without.len()),
        "every mapped control has evidence files in the bundle, each with its checksum; the bundle holds no memory content, key or key hash",
    )
}

/// A card number that passes the Luhn check, in one of the ways people write them.
fn card(rng: &mut impl Rng) -> String {
    let mut digits: Vec<u32> = (0..15).map(|i| if i == 0 { rng.random_range(3..7) } else { rng.random_range(0..10) }).collect();
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, d)| {
            if i % 2 == 0 {
                let x = d * 2;
                if x > 9 {
                    x - 9
                } else {
                    x
                }
            } else {
                *d
            }
        })
        .sum();
    digits.push((10 - sum % 10) % 10);
    let s: String = digits.iter().map(|d| char::from_digit(*d, 10).unwrap()).collect();
    match rng.random_range(0..3) {
        0 => s,
        1 => [&s[0..4], &s[4..8], &s[8..12], &s[12..16]].join(" "),
        _ => [&s[0..4], &s[4..8], &s[8..12], &s[12..16]].join("-"),
    }
}

fn pick(rng: &mut impl Rng, alphabet: &[u8], n: usize) -> String {
    (0..n).map(|_| alphabet[rng.random_range(0..alphabet.len())] as char).collect()
}

const ALNUM: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const UPPER_DIGIT: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const DIGITS: &[u8] = b"0123456789";

/// A credential in one of the shapes the gate knows. Made at run time: no literal in the source.
fn credential(rng: &mut impl Rng) -> String {
    match rng.random_range(0..4) {
        0 => format!("sk-{}", pick(rng, ALNUM, 32)),
        1 => format!("AKIA{}", pick(rng, UPPER_DIGIT, 16)),
        2 => format!("ghp_{}", pick(rng, ALNUM, 36)),
        _ => format!("eyJ{}.{}.{}", pick(rng, ALNUM, 24), pick(rng, ALNUM, 32), pick(rng, ALNUM, 28)),
    }
}

fn national_id(rng: &mut impl Rng) -> String {
    format!("{}-{}-{}", pick(rng, DIGITS, 3), pick(rng, DIGITS, 2), pick(rng, DIGITS, 4))
}

fn account(rng: &mut impl Rng) -> String {
    let country = ["DE", "FR", "GB", "NL", "ES", "IT"][rng.random_range(0..6)];
    let groups: Vec<String> = (0..rng.random_range(4..6)).map(|_| pick(rng, DIGITS, 4)).collect();
    let spaced = rng.random_bool(0.5);
    format!("{country}{}{}{}", pick(rng, DIGITS, 2), if spaced { " " } else { "" }, groups.join(if spaced { " " } else { "" }))
}

/// GOV-05: the labelled set, storage, and the three actions.
pub(crate) async fn pii_actions(base: &Engine, url: String) -> Outcome {
    let e = engine_on(base, &url, PgOptions::default(), |_| {}).await?;
    let mut problems = vec![];
    let mut rng = rand::rngs::StdRng::seed_from_u64(22);
    let frames = ["Please note {} for the renewal", "The customer gave {} on the call", "On file: {}.", "Use {} when the invoice is issued", "Reference {} was read out twice"];
    // 2,000 labelled items: 500 of each Must category (credentials, account numbers as cards
    // and IBANs, national ids).
    let mut items: Vec<(&str, String, String)> = vec![];
    for i in 0..2000 {
        let (category, value) = match i % 4 {
            0 => ("secret", credential(&mut rng)),
            1 => ("card", card(&mut rng)),
            2 => ("ssn", national_id(&mut rng)),
            _ => ("iban", account(&mut rng)),
        };
        items.push((category, frames[i % frames.len()].replace("{}", &value), value));
    }
    let categories = e.cfg.governance.redact.clone();
    let mut missed: std::collections::BTreeMap<&str, usize> = Default::default();
    for (category, text, value) in &items {
        let (out, found) = memhouse_core::gate::redact_text(text, &categories);
        if out.contains(value.as_str()) || found.is_empty() {
            *missed.entry(category).or_default() += 1;
        }
    }
    let total_missed: usize = missed.values().sum();
    let recall = 100.0 * (items.len() - total_missed) as f64 / items.len() as f64;
    if recall < 98.0 {
        problems.push(format!("{total_missed} of {} labelled items were not detected ({recall:.2}%, at least 98% required): {missed:?}", items.len()));
    }
    // Look-alikes that must stay: order numbers that fail the Luhn check, dates, versions.
    let mut false_hits = 0;
    for i in 0..300 {
        let benign = match i % 3 {
            0 => "Order 1234567890123 shipped".to_string(),
            1 => format!("The call is on 2026-{:02}-{:02} at 14:30", 1 + i % 12, 1 + i % 28),
            _ => format!("Release {}.{}.{} fixed ticket {}", i % 9, i % 20, i % 50, 40_000 + i),
        };
        if !memhouse_core::gate::redact_text(&benign, &categories).1.is_empty() {
            false_hits += 1;
        }
    }
    if false_hits > 3 {
        problems.push(format!("{false_hits} of 300 benign look-alikes were redacted"));
    }
    // Storage: a sample through the write path; no value is anywhere as written.
    let sample: Vec<&(&str, String, String)> = items.iter().step_by(10).collect();
    for (i, (_, text, _)) in sample.iter().enumerate() {
        e.remember(remember("pii:set", &format!("{text} ({})", words("pii", i)))).await?;
    }
    let db = raw(&url).await?;
    let mut stored = db.texts(same("SELECT content FROM mh_memory"), &[]).await?;
    stored.extend(db.texts(same("SELECT detail FROM mh_audit"), &[]).await?);
    stored.extend(db.texts(Sql::each("SELECT coalesce(payload::text, '') FROM mh_intake", "SELECT coalesce(payload, '') FROM mh_intake"), &[]).await?);
    db.close().await;
    let everything = stored.join("\n");
    let unredacted = sample.iter().filter(|(_, _, value)| everything.contains(value.as_str())).count();
    if unredacted > 0 {
        problems.push(format!("{unredacted} of {} sampled items are stored as written", sample.len()));
    }

    // The action of a category: mask keeps the last four characters, reject refuses the write.
    let mut cfg = (*e.cfg).clone();
    cfg.governance.actions = [("card".to_string(), RedactAction::Mask), ("ssn".to_string(), RedactAction::Reject)].into_iter().collect();
    cfg.check_floor()?;
    let strict = e.clone().reconfigure(cfg.clone());
    let masked = strict.remember(remember("pii:actions", "Card on file is 4111 1111 1111 1111, contact via ticket only")).await?;
    let content = strict.store.get(T, masked.id).await?.map(|m| m.content).unwrap_or_default();
    if !content.contains("[MASKED:card:1111]") || content.contains("4111 1111") || !masked.redactions.iter().any(|r| r == "card") {
        problems.push(format!("a masked card is stored as {content:?} (redactions {:?})", masked.redactions));
    }
    if memhouse_core::gate::redact_text(&content, &strict.policy_for(T).await?.policy.redaction.rules()).0 != content {
        problems.push("masking is not idempotent".into());
    }
    let before = ids_of(&strict, "pii:actions").await?.len();
    let refused = strict.remember(remember("pii:actions", "Her number is 123-45-6789, she said")).await;
    let after = ids_of(&strict, "pii:actions").await?.len();
    let invalid = refused.as_ref().err().map(|x| (memhouse_core::error::code_of(x) == memhouse_core::error::ErrorCode::InvalidRequest, x.to_string().contains("123-45-6789")));
    if invalid != Some((true, false)) || after != before {
        problems.push(format!(
            "a write holding a rejected category: {:?} (an invalid_request that does not repeat the value expected), {} records stored",
            refused.map(|r| r.status),
            after - before
        ));
    }
    // A secret is never masked; a policy may make an action stricter, never looser.
    let mut bad = cfg.clone();
    bad.governance.actions.insert("secret".into(), RedactAction::Mask);
    let looser = memhouse_core::policy::parse_spec("name = \"looser\"\n[scope]\ntenant = \"default\"\n[redaction.actions]\nssn = \"redact\"")?;
    let stricter = memhouse_core::policy::parse_spec("name = \"stricter\"\n[scope]\ntenant = \"default\"\n[redaction.actions]\ncard = \"reject\"\nemail = \"redact\"")?;
    let loosened = memhouse_core::policy::compile(&looser, &cfg, T, None).err().is_some_and(|v| v.iter().any(|x| x.path == "redaction.actions" && x.rule == "PR-1"));
    let tightened = memhouse_core::policy::compile(&stricter, &cfg, T, Some(1));
    let rules = tightened.as_ref().map(|p| p.policy.redaction.rules()).unwrap_or_default();
    if bad.check_floor().is_ok() || !loosened || !(rules.contains(&"card:reject".to_string()) && rules.contains(&"email".to_string()) && rules.contains(&"ssn:reject".to_string()))
    {
        problems.push(format!("a masked secret accepted: {}; a looser policy refused: {loosened}; a stricter policy compiles to {rules:?}", bad.check_floor().is_ok()));
    }
    verdict(
        problems,
        format!("{} of {} labelled items detected ({recall:.2}%), {unredacted} of {} sampled items stored as written, {false_hits} of 300 look-alikes redacted", items.len() - total_missed, items.len(), sample.len()),
        "detection at or above 98% with nothing stored as written; mask keeps the last four characters, reject refuses the write without repeating the value, a secret cannot be masked, a policy can only tighten",
    )
}
