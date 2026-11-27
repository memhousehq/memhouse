// SPDX-License-Identifier: Apache-2.0
//! The `Store` interface on SQLite, method by method what the Postgres store does. Statements
//! bind every value from callers; only this crate's constants are formatted in.

use crate::records::*;
use crate::search::{bind, recall_filters, recall_params, scan};
use crate::util::*;
use crate::vector::{from_f32_blob, to_bits, to_f32_blob, to_half, Probe};
use crate::{meta, Ident, SqliteStore, SCHEMA_VERSION};
use async_trait::async_trait;
use chrono::{DateTime, SubsecRound, Utc};
use memhouse_core::format::{PolicyLine, RecordLine};
use memhouse_core::identity::{ApiKey, Principal, PrincipalKind, Session};
use memhouse_core::intake::AuditEntry;
use memhouse_core::policy::{PolicyActivation, PolicySpecRecord, SpecStatus};
use memhouse_core::types::*;
use memhouse_core::Store;
use rusqlite::types::Value;
use rusqlite::{params, Connection, Row, TransactionBehavior};
use std::collections::HashSet;
use uuid::Uuid;

/// "Never": the end of a validity or a key with no end, where a statement needs a number.
const FOREVER: i64 = i64::MAX;

/// Supersede `?2` by `?3` (see `set_superseded`); `?4` is now.
/// A version stops being true when its successor starts (even if it had a later end of its
/// own), so as-of recall finds exactly one version at any time.
const SUPERSEDE_SQL: &str = "UPDATE mh_memory SET status = 'superseded', superseded_by = ?3, \
     valid_to = min(COALESCE(valid_to, 9223372036854775807), max(COALESCE((SELECT n.valid_from FROM mh_memory n WHERE n.tenant = ?1 AND n.id = ?3), ?4), valid_from)), \
     updated_at = max(?4, created_at) \
     WHERE tenant = ?1 AND id = ?2 AND status = 'committed'";

const SPEC_COLS: &str = "tenant, version, name, spec, spec_hash, status, note, proposed_by, proposed_at, approved_by, approved_at";

/// A row count or page size as SQLite's integer.
fn lim(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(i64::MAX)
}

fn micros(secs: i64) -> i64 {
    secs.saturating_mul(1_000_000)
}

fn spec_of(r: &Row) -> anyhow::Result<PolicySpecRecord> {
    let status: String = r.get("status")?;
    Ok(PolicySpecRecord {
        tenant: r.get("tenant")?,
        version: r.get::<_, u32>("version")?,
        name: r.get("name")?,
        spec: value(&r.get::<_, String>("spec")?)?,
        spec_hash: r.get("spec_hash")?,
        status: SpecStatus::parse(&status).ok_or_else(|| anyhow::anyhow!("unknown policy status {status}"))?,
        note: r.get("note")?,
        proposed_by: r.get("proposed_by")?,
        proposed_at: at(r.get("proposed_at")?),
        approved_by: r.get("approved_by")?,
        approved_at: opt_at(r, "approved_at")?,
    })
}

fn principal_of(r: &Row) -> anyhow::Result<Principal> {
    let kind: String = r.get("kind")?;
    Ok(Principal {
        id: r.get("id")?,
        tenant: r.get("tenant")?,
        kind: PrincipalKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown principal kind {kind}"))?,
        name: r.get("name")?,
        subjects: strings(&r.get::<_, String>("subjects")?)?,
        kinds: strings(&r.get::<_, String>("kinds")?)?.iter().map(|k| MemoryKind::parse(k).ok_or_else(|| anyhow::anyhow!("unknown kind {k}"))).collect::<anyhow::Result<_>>()?,
        denied_labels: strings(&r.get::<_, String>("denied_labels")?)?,
        org: r.get("org")?,
        team: r.get("team")?,
        can_commit: r.get("can_commit")?,
        act_as: r.get("act_as")?,
        disabled_at: opt_at(r, "disabled_at")?,
        created_at: at(r.get("created_at")?),
        created_by: r.get("created_by")?,
    })
}

fn key_of(r: &Row) -> anyhow::Result<ApiKey> {
    Ok(ApiKey {
        id: r.get("id")?,
        principal_id: r.get("principal_id")?,
        hash: r.get("hash")?,
        scopes: strings(&r.get::<_, String>("scopes")?)?,
        expires_at: opt_at(r, "expires_at")?,
        revoked_at: opt_at(r, "revoked_at")?,
        created_at: at(r.get("created_at")?),
        created_by: r.get("created_by")?,
    })
}

fn session_of(r: &Row) -> anyhow::Result<Session> {
    Ok(Session {
        id: r.get("id")?,
        tenant: r.get("tenant")?,
        principal_id: r.get("principal_id")?,
        key_id: r.get("key_id")?,
        key_check: r.get("key_check")?,
        created_at: at(r.get("created_at")?),
        expires_at: at(r.get("expires_at")?),
        last_seen_at: at(r.get("last_seen_at")?),
    })
}

fn link_of(r: &Row) -> anyhow::Result<Link> {
    Ok(Link {
        tenant: r.get("tenant")?,
        subject: r.get("subject")?,
        linked_subject: r.get("linked_subject")?,
        link_type: r.get("link_type")?,
        memory_id: opt_uuid(r, "memory_id")?,
        created_by: r.get("created_by")?,
        created_at: at(r.get("created_at")?),
    })
}

fn job_of(r: &Row) -> anyhow::Result<EnrichJob> {
    Ok(EnrichJob {
        id: r.get("id")?,
        tenant: r.get("tenant")?,
        subject: r.get("subject")?,
        session_id: r.get("session_id")?,
        round_ids: uuids(&r.get::<_, String>("round_ids")?)?,
        attempts: r.get::<_, i32>("attempts")? + 1,
    })
}

fn identity_of(c: &Connection, prefix: &str) -> anyhow::Result<Option<EmbeddingIdentity>> {
    let (Some(embedder), Some(dim)) = (meta(c, &format!("{prefix}embedder"))?, meta(c, &format!("{prefix}embedding_dim"))?) else {
        return Ok(None);
    };
    let passage_prefix = meta(c, &format!("{prefix}passage_prefix"))?.unwrap_or_default();
    Ok(Some(EmbeddingIdentity { embedder, dim: dim.parse()?, passage_prefix }))
}

fn set_meta(c: &Connection, key: &str, value: &str) -> anyhow::Result<()> {
    exec(c, "INSERT INTO mh_meta (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [key, value])?;
    Ok(())
}

const CLEAR_NEXT: &str = "UPDATE mh_memory SET embedding_next = NULL, embedding_alt_next = NULL, embedding_bits_next = NULL, embedding_alt_bits_next = NULL, \
     alt_hash_next = NULL, embedder_next = NULL, embedder_config_next = NULL WHERE embedding_next IS NOT NULL OR embedder_next IS NOT NULL";

impl SqliteStore {
    /// Fail recall in a process whose model is no longer the database's (after `memhouse
    /// reembed`). The whole identity is compared: a re-embedding can keep the model's name and
    /// change its dimension or passage prefix. The database's trigger refuses writes under
    /// another model name; `write_rows` calls this for the rest.
    pub(crate) fn ensure_current(&self, c: &Connection) -> anyhow::Result<()> {
        let Some(mine) = self.ident() else { return Ok(()) };
        let mine = EmbeddingIdentity { embedder: mine.embedder, dim: mine.dim, passage_prefix: self.inner.passage_prefix.clone() };
        match identity_of(c, "")? {
            // A conflict, not a failure: recall refuses instead of degrading to an empty result.
            Some(db) if db != mine => {
                // The model's name where it changed; the whole identity where only the rest did.
                let (now, was) = if db.embedder != mine.embedder { (db.embedder, mine.embedder) } else { (db.to_string(), mine.to_string()) };
                Err(memhouse_core::error::conflict(format!("this database is now embedded with {now}, not {was}; restart with the new [embedding] configuration")))
            }
            _ => Ok(()),
        }
    }

    /// Refuse a database embedded with another model than `mine` (see `Store::migrate`).
    fn refuse_other_embedder(c: &Connection, mine: &EmbeddingIdentity) -> anyhow::Result<()> {
        let Some(db) = identity_of(c, "")?.filter(|db| db != mine) else { return Ok(()) };
        let unfinished = identity_of(c, "reembed_target_")?.is_some_and(|t| t == *mine);
        anyhow::bail!(
            "this database's memories are embedded with {db}, but the configuration says {mine}. {}",
            if unfinished {
                "A re-embedding to it is unfinished: run `memhouse reembed` to complete it."
            } else {
                "Run `memhouse reembed` to re-embed every memory with the configured model, or go back to the previous [embedding] settings."
            }
        )
    }

    fn claim_jobs(&self, limit: usize, lease_secs: i64, subject: Option<(&str, &str)>) -> anyhow::Result<Vec<EnrichJob>> {
        let mut c = self.conn_relaxed();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = now();
        // One job of a subject at a time, oldest first. Without a subject, never a job of an
        // evaluation's scratch tenant: the replaying engine extracts those itself, claiming by
        // tenant and subject, and counts the spend in the replay's own counter.
        let jobs = rows(
            &tx,
            "SELECT c.id, c.tenant, c.subject, c.session_id, c.round_ids, c.attempts FROM mh_enrich_job c \
             WHERE ((c.status = 'pending' AND c.run_after <= ?1) OR (c.status = 'running' AND c.locked_until < ?1)) \
               AND ((?2 IS NULL AND instr(c.tenant, ?4) = 0) OR (c.tenant = ?2 AND c.subject = ?3)) \
               AND NOT EXISTS (SELECT 1 FROM mh_enrich_job o WHERE o.tenant = c.tenant AND o.subject = c.subject \
                               AND o.status IN ('pending', 'running') AND o.id < c.id) \
             ORDER BY c.id LIMIT ?5",
            params![now, subject.map(|s| s.0), subject.map(|s| s.1), memhouse_core::eval::SCRATCH_MARK, lim(limit)],
            job_of,
        )?;
        for j in &jobs {
            exec(
                &tx,
                "UPDATE mh_enrich_job SET status = 'running', attempts = attempts + 1, locked_until = ?2 WHERE id = ?1",
                params![j.id, now.saturating_add(micros(lease_secs))],
            )?;
        }
        tx.commit()?;
        Ok(jobs)
    }

    /// The most similar rows of a statement that returns (id, embedding).
    fn nearest_of(&self, sql: &str, params: impl rusqlite::Params, embedding: &[f32], n: usize) -> anyhow::Result<Vec<(Uuid, f32)>> {
        let c = self.read();
        let mut st = c.prepare_cached(sql)?;
        let mut found = st.query(params)?;
        scan(&mut found, &Probe::new(embedding), false, n)?.into_iter().map(|(id, sim)| Ok((uuid_of(&id)?, sim))).collect()
    }
}

#[async_trait]
impl Store for SqliteStore {
    async fn migrate(&self, dim: usize, embedder_id: &str) -> anyhow::Result<()> {
        let mine = EmbeddingIdentity { embedder: embedder_id.to_string(), dim, passage_prefix: self.inner.passage_prefix.clone() };
        let mut c = self.conn();
        Self::refuse_other_embedder(&c, &mine)?;
        let version = |c: &Connection| -> anyhow::Result<Option<u32>> { Ok(meta(c, "schema_version")?.map(|v| v.parse()).transpose()?) };
        if let Some(v) = version(&c)?.filter(|v| *v != SCHEMA_VERSION) {
            if v > SCHEMA_VERSION {
                anyhow::bail!("this database has schema version {v}, newer than this build ({SCHEMA_VERSION}); upgrade MemHouse");
            }
            // Refused before anything is copied when no step starts from this version.
            crate::migrate::pending(v).map(drop)?;
            // The file as it was, before anything changes (TR-LT-10). Outside the upgrade's
            // transaction because SQLite copies a database only from outside one; a writer that
            // slipped in between would be an older build's, and the upgrade keeps its rows.
            if let Some(path) = self.inner.path.as_deref().filter(|_| self.upgrade_snapshot) {
                let copy = crate::migrate::snapshot_path(path, SCHEMA_VERSION);
                crate::migrate::snapshot(&c, &copy)?;
                tracing::info!("database schema version {v} is older than this build's ({SCHEMA_VERSION}): kept the file as it was in {} before upgrading it", copy.display());
            }
        }
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // Read again under the write lock: another process may have upgraded the file meanwhile.
        if let Some(v) = version(&tx)?.filter(|v| *v < SCHEMA_VERSION) {
            for step in crate::migrate::pending(v)? {
                (step.run)(&tx).map_err(|e| anyhow::anyhow!("upgrading the database to schema version {} ({}): {e}", step.to, step.what))?;
                set_meta(&tx, "schema_version", &step.to.to_string())?;
            }
            tracing::info!("database upgraded from schema version {v} to {SCHEMA_VERSION}");
        }
        tx.execute_batch(crate::schema::DDL)?;
        for (k, v) in [("embedding_dim", dim.to_string()), ("embedder", embedder_id.to_string()), ("passage_prefix", self.inner.passage_prefix.clone())] {
            exec(&tx, "INSERT INTO mh_meta (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO NOTHING", [k, v.as_str()])?;
        }
        // Again under the write lock: another process may have opened the same new file with
        // another model and recorded its identity first.
        Self::refuse_other_embedder(&tx, &mine)?;
        set_meta(&tx, "schema_version", &SCHEMA_VERSION.to_string())?;
        tx.commit()?;
        drop(c);
        *self.inner.ident.lock().unwrap_or_else(|e| e.into_inner()) = Some(Ident { embedder: embedder_id.to_string(), config: mine.config_hash(), dim });
        Ok(())
    }

    #[tracing::instrument(name = "db.insert", skip_all, fields(db.system = "sqlite", db.operation = "INSERT", rows = records.len()))]
    async fn insert(&self, records: &[NewMemory]) -> anyhow::Result<()> {
        if records.is_empty() {
            return Ok(());
        }
        let lines = lines_of(records);
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        self.write_rows(&tx, &write_rows_of(&lines, records), false)?;
        Ok(tx.commit()?)
    }

    fn intake_queue(&self) -> Option<std::sync::Arc<dyn memhouse_core::IntakeQueue>> {
        Some(std::sync::Arc::new(self.clone()))
    }

    #[tracing::instrument(name = "db.apply_intake", skip_all, fields(db.system = "sqlite", db.operation = "INSERT", rows = w.records.len()))]
    async fn apply_intake(&self, w: &memhouse_core::intake::IntakeWrite) -> anyhow::Result<bool> {
        let mut c = self.conn_relaxed();
        // One writer at a time: from here to the commit no erasure, promotion or other insert
        // runs, which is what Postgres gets from its subject and row locks.
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = now();
        if let Some(pid) = w.proposal {
            let row = first(&tx, "SELECT status, record_ids FROM mh_intake WHERE id = ?1", [pid.to_string()], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
            // A proposal already erased writes nothing.
            let Some((status, queued)) = row else { return Ok(false) };
            if status == "done" {
                return Ok(false);
            }
            // A record forgotten while this attempt ran left the proposal: retry with what is left.
            let queued = uuids(&queued)?;
            anyhow::ensure!(w.records.iter().all(|r| queued.contains(&r.memory.id)), "a record of proposal {pid} was forgotten while it was being written");
        }
        if !w.records.is_empty() {
            // Exactly once in effect (TR-IN-03): the record ids are the proposal's idempotency key.
            let ids: Vec<Uuid> = w.records.iter().map(|r| r.memory.id).collect();
            // A proposal's records are written in one transaction, so they are all there or none.
            let seen: i64 =
                first(&tx, "SELECT count(*) FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", params![w.tenant, ids_json(&ids)], |r| Ok(r.get(0)?))?
                    .unwrap_or(0);
            anyhow::ensure!(seen == 0 || seen as usize == ids.len(), "{seen} of the proposal's {} records are already stored", ids.len());
            if seen > 0 {
                if let Some(pid) = w.proposal {
                    exec(&tx, "UPDATE mh_intake SET status = 'done', finished_at = ?2, locked_until = NULL, payload = NULL WHERE id = ?1", params![pid.to_string(), now])?;
                    tx.commit()?;
                }
                return Ok(false);
            }
            // A revision's references are judged against its predecessor's as they are now,
            // not as they were when the revision was made (TPL-04): read in this transaction,
            // which holds the write lock, so no observation falls in between.
            let mut records = std::borrow::Cow::Borrowed(&w.records);
            for i in 0..w.records.len() {
                let n = &w.records[i];
                // A record that takes another's place without revising it: that record's
                // references, exactly as they are now.
                if let Some(of) = n.refs_from {
                    let copied = rows(
                        &tx,
                        &format!("SELECT {CODE_REF_COLS} FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id WHERE m.tenant = ?1 AND c.memory_id = ?2 ORDER BY c.path"),
                        params![w.tenant, of.to_string()],
                        code_ref_of,
                    )?;
                    records.to_mut()[i].code_refs = copied;
                    continue;
                }
                let Some(old) = n.memory.supersedes.filter(|_| n.refs_inherited || !n.code_refs.is_empty()) else { continue };
                let predecessor = rows(
                    &tx,
                    &format!("SELECT {CODE_REF_COLS} FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id WHERE m.tenant = ?1 AND c.memory_id = ?2 ORDER BY c.path"),
                    params![w.tenant, old.to_string()],
                    code_ref_of,
                )?;
                let now = memhouse_core::staleness::successor_refs(&n.code_refs, n.refs_inherited, &predecessor, Utc::now().trunc_subsecs(6));
                if now != n.code_refs {
                    records.to_mut()[i].code_refs = now;
                }
            }
            let lines = lines_of(&records);
            self.write_rows(&tx, &write_rows_of(&lines, &records), false)?;
        }
        if !w.requires.is_empty() {
            // The sources of a promotion: one already gone stops the insert.
            let there: i64 =
                first(&tx, "SELECT count(*) FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", params![w.tenant, ids_json(&w.requires)], |r| {
                    Ok(r.get(0)?)
                })?
                .unwrap_or(0);
            let distinct: HashSet<&Uuid> = w.requires.iter().collect();
            anyhow::ensure!(there as usize == distinct.len() && distinct.len() == w.requires.len(), "a source of a promotion was deleted while it was being written");
        }
        for (old, new) in &w.supersede {
            let n = exec(&tx, SUPERSEDE_SQL, params![w.tenant, old.to_string(), new.to_string(), now])?;
            // The pipeline checked it was current; another write got there first: retry the
            // proposal, which then sees the new state.
            anyhow::ensure!(n == 1, "memory {old} stopped being current while {new} was being written");
        }
        // A held, unexpired candidate of this reason, as it is at commit time.
        // A held record is changed only by a write that carries its labels, as the pipeline
        // matched them (`Held::labels`): checked again here, where it is written. The
        // pipeline stores the confirming or repeating record in the same write; for one that
        // is not in it there are no labels to compare.
        let held = |id: &Uuid, reason: &str, by: &Uuid| -> anyhow::Result<Option<serde_json::Value>> {
            let labels = w.records.iter().find(|n| n.memory.id == *by).map(|n| &n.memory.labels);
            Ok(first(
                &tx,
                "SELECT metadata, labels FROM mh_memory WHERE tenant = ?1 AND id = ?2 AND status = 'candidate' AND (expires_at IS NULL OR expires_at > ?3)",
                params![w.tenant, id.to_string(), now],
                |r| Ok((value(&r.get::<_, String>(0)?)?, strings(&r.get::<_, String>(1)?)?)),
            )?
            .filter(|(m, l)| m["held"].as_str() == Some(reason) && labels.is_none_or(|by| memhouse_core::intake::same_labels(l, by)))
            .map(|(m, _)| m))
        };
        for (plan, by) in &w.confirm {
            // Still a held, unexpired plan at commit time; otherwise retry, which then sees it.
            let Some(mut metadata) = held(plan, "plan", by)? else { anyhow::bail!("plan {plan} stopped being a held candidate while {by} was being written") };
            if let Some(o) = metadata.as_object_mut() {
                o.remove("held");
                o.insert("confirmed_by".into(), by.to_string().into());
            }
            exec(
                &tx,
                "UPDATE mh_memory SET status = 'committed', expires_at = NULL, metadata = ?3, updated_at = max(?4, created_at) WHERE tenant = ?1 AND id = ?2",
                params![w.tenant, plan.to_string(), metadata.to_string(), now],
            )?;
        }
        for (signal, by, commit) in &w.signals {
            // Still a held, unexpired signal at commit time; otherwise retry, which then sees it.
            let Some(mut metadata) = held(signal, "signal", by)? else { anyhow::bail!("signal {signal} stopped being a held candidate while {by} was being written") };
            let seen = metadata["signals"].as_i64().or_else(|| metadata["signals"].as_str().and_then(|s| s.parse().ok())).unwrap_or(1);
            if let Some(o) = metadata.as_object_mut() {
                if *commit {
                    o.remove("held");
                }
                o.insert("signals".into(), (seen + 1).into());
                o.insert("last_signal".into(), by.to_string().into());
            }
            exec(
                &tx,
                "UPDATE mh_memory SET status = CASE WHEN ?5 THEN 'committed' ELSE status END, expires_at = CASE WHEN ?5 THEN NULL ELSE expires_at END, \
                 metadata = ?3, updated_at = max(?4, created_at) WHERE tenant = ?1 AND id = ?2",
                params![w.tenant, signal.to_string(), metadata.to_string(), now, commit],
            )?;
        }
        if let Some((subject, session, rounds)) = &w.enrich {
            exec(
                &tx,
                "INSERT INTO mh_enrich_job (tenant, subject, session_id, round_ids, run_after, enqueued_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
                params![w.tenant, subject, session, ids_json(rounds), now],
            )?;
        }
        if let Some(pid) = w.proposal {
            exec(
                &tx,
                "UPDATE mh_intake SET status = CASE WHEN ?2 IS NULL THEN 'done' ELSE 'dead' END, finished_at = ?4, locked_until = NULL, \
                 payload = NULL, outcome = ?3, error = ?2 WHERE id = ?1",
                params![pid.to_string(), w.dead, w.outcome.to_string(), now],
            )?;
        }
        for a in &w.audit {
            audit_in(&tx, &a.actor, &a.action, &w.tenant, a.subject.as_deref(), a.memory_id, &a.detail)?;
        }
        tx.commit()?;
        Ok(true)
    }

    #[tracing::instrument(name = "db.structured_lookup", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn structured_lookup(&self, q: &SearchQuery, record_type: Option<&str>, attrs: Option<&serde_json::Value>, values: &[String]) -> anyhow::Result<Vec<Hit>> {
        // The recall filters (status, labels, validity, scope) with the recall's own parameters,
        // then the exact match on the structured row.
        let sql = format!(
            "SELECT {COLS}, s.attrs AS s_attrs FROM mh_structured s JOIN mh_memory m ON m.id = s.memory_id \
             WHERE s.tenant = :tenant AND s.subject = :subject AND m.tenant = :tenant AND m.subject = :subject {} \
             AND (:record_type IS NULL OR s.record_type = :record_type) ORDER BY m.created_at DESC, m.id",
            recall_filters(q)
        );
        let lower: Vec<String> = values.iter().map(|v| v.to_lowercase()).collect();
        let mut binds = recall_params(q)?;
        binds.push((":record_type", record_type.map(|t| Value::Text(t.to_string())).unwrap_or(Value::Null)));
        let c = self.read();
        let mut st = c.prepare_cached(&sql)?;
        bind(&mut st, &binds)?;
        let mut found = st.raw_query();
        let mut hits = vec![];
        while let Some(r) = found.next()? {
            if hits.len() >= q.limit {
                break;
            }
            let have = value(&r.get::<_, String>("s_attrs")?)?;
            // A top-level attribute equal to one of the values, compared as text without case.
            let named = |o: &serde_json::Map<String, serde_json::Value>| {
                o.values().any(|v| match v {
                    serde_json::Value::Null => false,
                    serde_json::Value::String(s) => lower.contains(&s.to_lowercase()),
                    other => lower.contains(&other.to_string().to_lowercase()),
                })
            };
            if attrs.is_some_and(|want| !json_contains(&have, want)) || (!lower.is_empty() && !have.as_object().is_some_and(named)) {
                continue;
            }
            hits.push(Hit {
                memory: memory_of(r)?,
                score: 1.0,
                keyword_rank: None,
                vector_rank: None,
                similarity: None,
                rerank_score: None,
                exact: false,
                working: false,
                embedding: None,
                features: None,
            });
        }
        Ok(hits)
    }

    async fn nearest_held(&self, tenant: &str, subject: &str, embedding: &[f32], limit: usize, which: &memhouse_core::traits::Held<'_>) -> anyhow::Result<Vec<(Uuid, f32)>> {
        let scope = which.scope;
        self.nearest_of(
            "SELECT id, embedding FROM mh_memory \
             WHERE tenant = ?1 AND subject = ?2 AND status = 'candidate' AND embedding IS NOT NULL \
             AND json_extract(metadata, '$.held') = ?3 AND (expires_at IS NULL OR expires_at > ?4) \
             AND (?5 IS NULL OR kind = ?5) \
             AND scope_org IS ?6 AND scope_team IS ?7 AND scope_agent IS ?8 AND scope_user IS ?9 AND scope_session IS ?10 \
             AND (NOT ?11 OR json_extract(metadata, '$.counted') IS ?12) \
             AND NOT EXISTS (SELECT 1 FROM json_each(labels) l WHERE l.value NOT IN (SELECT value FROM json_each(?13))) \
             AND NOT EXISTS (SELECT 1 FROM json_each(?13) l WHERE l.value NOT IN (SELECT value FROM json_each(labels)))",
            params![
                tenant,
                subject,
                which.reason,
                now(),
                which.kind.map(|k| k.as_str()),
                scope.org,
                scope.team,
                scope.agent,
                scope.user,
                scope.session,
                which.counted.is_some(),
                which.counted.flatten(),
                serde_json::to_string(which.labels)?
            ],
            embedding,
            limit,
        )
    }

    #[tracing::instrument(name = "db.search", skip_all, fields(db.system = "sqlite", db.operation = "SELECT", probes = 1))]
    async fn search(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>> {
        let c = self.read();
        // One read transaction: the ranking and the rows read for it are one state of the file,
        // whatever another process writes meanwhile.
        let tx = c.unchecked_transaction()?;
        self.ensure_current(&tx)?;
        self.search_in(&tx, q, true)
    }

    #[tracing::instrument(name = "db.search", skip_all, fields(db.system = "sqlite", db.operation = "SELECT", probes = qs.len()))]
    async fn search_many(&self, qs: &[SearchQuery]) -> anyhow::Result<Vec<Vec<Hit>>> {
        // The probes of one recall read one state of the file: one read transaction for all.
        let c = self.read();
        let tx = c.unchecked_transaction()?;
        self.ensure_current(&tx)?;
        qs.iter().map(|q| self.search_in(&tx, q, true)).collect()
    }

    #[tracing::instrument(name = "db.search_unfiltered", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn search_unfiltered(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>> {
        let c = self.read();
        let tx = c.unchecked_transaction()?;
        // A vector probe is only comparable with vectors of the same model; keywords need no check.
        if q.embedding.is_some() && q.mode != RetrievalMode::Keyword {
            self.ensure_current(&tx)?;
        }
        self.search_in(&tx, q, false)
    }

    #[tracing::instrument(name = "db.get", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn get(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<Memory>> {
        first(&self.read(), &format!("SELECT {COLS} FROM mh_memory m WHERE m.tenant = ?1 AND m.id = ?2"), [tenant, id.to_string().as_str()], memory_of)
    }

    #[tracing::instrument(name = "db.list", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn list(&self, q: &ListQuery) -> anyhow::Result<Vec<Memory>> {
        let kinds = q.kinds.as_ref().map(|ks| json(&ks.iter().map(|k| k.as_str()).collect::<Vec<_>>())).transpose()?;
        let sql = format!(
            "SELECT {COLS} FROM mh_memory m WHERE m.tenant = ?1 AND (?2 IS NULL OR m.subject = ?2) \
             AND (?3 IS NULL OR m.kind IN (SELECT value FROM json_each(?3))) AND (?4 OR m.status = 'committed') \
             AND (?7 IS NULL OR (m.created_at, m.id) < (?7, ?8)) \
             AND NOT EXISTS (SELECT 1 FROM json_each(m.labels) l WHERE l.value IN (SELECT value FROM json_each(?9))) \
             AND (?10 IS NULL OR m.scope_org IS NULL OR m.scope_org = ?10) \
             AND (?11 IS NULL OR m.scope_team IS NULL OR m.scope_team = ?11) \
             AND (?12 IS NULL OR m.scope_agent IS NULL OR m.scope_agent = ?12 \
                  OR (m.scope_agent || char(31) || '*') IN (SELECT value FROM json_each(?15)) \
                  OR (m.scope_agent || char(31) || m.kind) IN (SELECT value FROM json_each(?15))) \
             AND (?13 IS NULL OR m.scope_user IS NULL OR m.scope_user = ?13) \
             AND (?14 IS NULL OR m.scope_session IS NULL OR m.scope_session = ?14 OR (?14 = ?17 AND m.kind <> 'working')) \
             AND (?16 IS NULL OR m.scope_session = ?16) \
             AND (?18 IS NULL OR EXISTS (SELECT 1 FROM json_each(m.tags) t WHERE t.value IN (SELECT value FROM json_each(?18)))) \
             AND (?19 IS NULL OR (m.valid_from <= ?19 AND (m.valid_to IS NULL OR m.valid_to > ?19) AND (m.expires_at IS NULL OR m.expires_at > ?19))) \
             AND (NOT ?20 OR m.stale_since IS NULL) \
             ORDER BY m.created_at DESC, m.id DESC LIMIT ?5 OFFSET ?6"
        );
        rows(
            &self.read(),
            &sql,
            params![
                q.tenant,
                q.subject,
                kinds,
                q.include_inactive,
                lim(q.limit),
                lim(q.offset),
                q.before.map(|b| us(b.0)),
                q.before.map(|b| b.1.to_string()),
                json(&q.denied_labels)?,
                q.scope.org,
                q.scope.team,
                q.scope.agent,
                q.scope.user,
                q.scope.session,
                json(&q.shared_agents)?,
                q.session,
                memhouse_core::access::NOBODY,
                q.tags.as_ref().map(json).transpose()?,
                q.live_at.map(us),
                q.fresh_only
            ],
            memory_of,
        )
    }

    #[tracing::instrument(name = "db.find_by_hash", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn find_by_hash(&self, tenant: &str, subject: &str, hash: &str) -> anyhow::Result<Option<Uuid>> {
        // Ordered, as in the Postgres store: the live record, not whichever row comes first.
        first(
            &self.read(),
            "SELECT id FROM mh_memory WHERE tenant = ?1 AND subject = ?2 AND content_hash = ?3 AND status <> 'superseded' \
             ORDER BY CASE status WHEN 'committed' THEN 0 WHEN 'candidate' THEN 1 ELSE 2 END, created_at, id LIMIT 1",
            [tenant, subject, hash],
            |r| uuid_of(&r.get::<_, String>(0)?),
        )
    }

    #[tracing::instrument(name = "db.existing_hashes", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn existing_hashes(&self, tenant: &str, subject: &str, hashes: &[String]) -> anyhow::Result<HashSet<String>> {
        if hashes.is_empty() {
            return Ok(Default::default());
        }
        Ok(rows(
            &self.read(),
            "SELECT content_hash FROM mh_memory WHERE tenant = ?1 AND subject = ?2 AND content_hash IN (SELECT value FROM json_each(?3))",
            params![tenant, subject, json(hashes)?],
            |r| Ok(r.get::<_, String>(0)?),
        )?
        .into_iter()
        .collect())
    }

    async fn nearest(&self, tenant: &str, subject: &str, kind: MemoryKind, embedding: &[f32]) -> anyhow::Result<Option<(Uuid, f32)>> {
        Ok(self
            .nearest_of(
                "SELECT id, embedding FROM mh_memory WHERE tenant = ?1 AND subject = ?2 AND kind = ?3 AND status = 'committed' AND embedding IS NOT NULL",
                [tenant, subject, kind.as_str()],
                embedding,
                1,
            )?
            .pop())
    }

    #[tracing::instrument(name = "db.nearest", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn nearest_many(&self, tenant: &str, subject: &str, kind: MemoryKind, embedding: &[f32], n: usize, scope: &Scope) -> anyhow::Result<Vec<(Uuid, f32)>> {
        self.nearest_of(
            "SELECT id, embedding FROM mh_memory \
             WHERE tenant = ?1 AND subject = ?2 AND kind = ?3 AND status = 'committed' AND embedding IS NOT NULL \
             AND scope_org IS ?4 AND scope_team IS ?5 AND scope_agent IS ?6 AND scope_user IS ?7 AND scope_session IS ?8",
            params![tenant, subject, kind.as_str(), scope.org, scope.team, scope.agent, scope.user, scope.session],
            embedding,
            n,
        )
    }

    #[tracing::instrument(name = "db.set_superseded", skip_all, fields(db.system = "sqlite", db.operation = "UPDATE"))]
    async fn set_superseded(&self, tenant: &str, id: Uuid, by: Uuid) -> anyhow::Result<bool> {
        Ok(exec(&self.conn(), SUPERSEDE_SQL, params![tenant, id.to_string(), by.to_string(), now()])? > 0)
    }

    #[tracing::instrument(name = "db.set_status", skip_all, fields(db.system = "sqlite", db.operation = "UPDATE"))]
    async fn set_status(&self, tenant: &str, id: Uuid, status: MemoryStatus) -> anyhow::Result<bool> {
        Ok(self.set_status_many(tenant, &[id], status).await? > 0)
    }

    async fn set_status_many(&self, tenant: &str, ids: &[Uuid], status: MemoryStatus) -> anyhow::Result<u64> {
        // Only the transitions of the lifecycle (CORE-02); anything else changes nothing.
        let from: Vec<&str> = MemoryStatus::sources_of(status).iter().map(|s| s.as_str()).collect();
        exec(
            &self.conn(),
            "UPDATE mh_memory SET status = ?3, updated_at = max(?5, created_at) \
             WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2)) AND status IN (SELECT value FROM json_each(?4))",
            params![tenant, ids_json(ids), status.as_str(), json(&from)?, now()],
        )
    }

    #[tracing::instrument(name = "db.delete", skip_all, fields(db.system = "sqlite", db.operation = "DELETE"))]
    async fn delete(&self, tenant: &str, id: Uuid, actor: &str) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let Some((subject, _)) = self.delete_in(&tx, tenant, id, true)? else { return Ok(false) };
        exec(
            &tx,
            "INSERT INTO mh_deletion_ledger (at, tenant, subject, memory_id, scope, actor) VALUES (?1, ?2, ?3, ?4, 'memory', ?5)",
            params![now(), tenant, subject, id.to_string(), actor],
        )?;
        tx.commit()?;
        Ok(true)
    }

    #[tracing::instrument(name = "db.delete_subject", skip_all, fields(db.system = "sqlite", db.operation = "DELETE"))]
    async fn delete_subject(&self, tenant: &str, subject: &str, actor: &str, purge_cache: bool) -> anyhow::Result<u64> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let n = self.delete_subject_in(&tx, tenant, subject, actor, purge_cache)?;
        tx.commit()?;
        Ok(n)
    }

    async fn purge_older_than(&self, tenant: &str, kind: MemoryKind, days: u32) -> anyhow::Result<u64> {
        // Same cascade as `delete`, in batches so a large purge never holds the writer for long:
        // the rounds, their cached vectors, facts derived from them (and their vectors), the jobs
        // that read them (and their cached extractions), and a ledger row per round.
        let before = now().saturating_sub(micros(days as i64 * 86_400));
        let mut total = 0u64;
        loop {
            let mut c = self.conn();
            let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let batch = rows(
                &tx,
                "SELECT id, subject, content, alt_hash FROM mh_memory WHERE tenant = ?1 AND kind = ?2 AND created_at < ?3 LIMIT 1000",
                params![tenant, kind.as_str(), before],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, Option<String>>(3)?)),
            )?;
            if batch.is_empty() {
                break;
            }
            let ids: Vec<Uuid> = batch.iter().map(|b| uuid_of(&b.0)).collect::<anyhow::Result<_>>()?;
            let id_list = ids_json(&ids);
            exec(&tx, "DELETE FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", [tenant, id_list.as_str()])?;
            self.purge_vectors(&tx, batch.iter().map(|b| b.2.as_str()), batch.iter().filter_map(|b| b.3.as_deref()))?;
            // Records promoted from them stay.
            let facts = self.delete_dependents(&tx, tenant, &ids, true, false)?.len();
            let subjects: HashSet<&str> = batch.iter().map(|b| b.1.as_str()).collect();
            for subject in subjects {
                let jobs = rows(
                    &tx,
                    "SELECT j.id, j.cache_key FROM mh_enrich_job j WHERE j.tenant = ?1 AND j.subject = ?2 \
                     AND EXISTS (SELECT 1 FROM json_each(j.round_ids) WHERE value IN (SELECT value FROM json_each(?3)))",
                    [tenant, subject, id_list.as_str()],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )?;
                drop_jobs(&tx, &jobs, true)?;
            }
            let at = now();
            for (id, subject, _, _) in &batch {
                exec(
                    &tx,
                    "INSERT INTO mh_deletion_ledger (at, tenant, subject, memory_id, scope, actor) VALUES (?1, ?2, ?3, ?4, 'retention', 'system')",
                    params![at, tenant, subject, id],
                )?;
            }
            tx.commit()?;
            total += (batch.len() + facts) as u64;
        }
        Ok(total)
    }

    async fn session_extend(&self, tenant: &str, subject: &str, session: &str, until: DateTime<Utc>) -> anyhow::Result<u64> {
        exec(
            &self.conn(),
            "UPDATE mh_memory SET expires_at = ?4, updated_at = max(?5, created_at) WHERE tenant = ?1 AND subject = ?2 AND scope_session = ?3 \
             AND kind = 'working' AND status = 'committed' AND json_extract(metadata, '$.ttl') = 'session' AND expires_at < ?4 AND expires_at > ?5",
            params![tenant, subject, session, us(until), now()],
        )
    }

    async fn eval_suite_put(&self, st: &memhouse_core::eval::StoredSuite) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_eval_suite (tenant, name, hash, suite, created_by, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT (tenant, name) DO UPDATE SET hash = excluded.hash, suite = excluded.suite, created_by = excluded.created_by, created_at = excluded.created_at",
            params![st.tenant, st.name, st.hash, json(&st.suite)?, st.created_by, us(st.created_at)],
        )?;
        Ok(())
    }

    async fn eval_suites(&self, tenant: &str) -> anyhow::Result<Vec<memhouse_core::eval::StoredSuite>> {
        rows(&self.conn(), "SELECT tenant, name, hash, suite, created_by, created_at FROM mh_eval_suite WHERE tenant = ?1 ORDER BY name", [tenant], |r| {
            Ok(memhouse_core::eval::StoredSuite {
                tenant: r.get(0)?,
                name: r.get(1)?,
                hash: r.get(2)?,
                suite: serde_json::from_str(&r.get::<_, String>(3)?)?,
                created_by: r.get(4)?,
                created_at: at(r.get(5)?),
            })
        })
    }

    async fn eval_suite_delete(&self, tenant: &str, name: &str) -> anyhow::Result<bool> {
        Ok(exec(&self.conn(), "DELETE FROM mh_eval_suite WHERE tenant = ?1 AND name = ?2", [tenant, name])? > 0)
    }

    async fn eval_run_put(&self, r: &memhouse_core::eval::EvalRun) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_eval_run (id, tenant, suite, suite_hash, policy_version, \"trigger\", run, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![r.id.to_string(), r.tenant, r.suite, r.suite_hash, r.policy_version, r.trigger.as_str(), json(r)?, us(r.created_at)],
        )?;
        Ok(())
    }

    async fn eval_reference(&self, tenant: &str, suite: &str, suite_hash: &str) -> anyhow::Result<Option<memhouse_core::eval::EvalRun>> {
        // The newest replay that did not belong to a failed gate (`gate_passed` absent or true).
        first(
            &self.conn(),
            "SELECT run FROM mh_eval_run WHERE tenant = ?1 AND suite = ?2 AND suite_hash = ?3 AND json_extract(run, '$.gate_passed') IS NOT 0 \
             ORDER BY created_at DESC, id DESC LIMIT 1",
            [tenant, suite, suite_hash],
            |r| Ok(serde_json::from_str(&r.get::<_, String>(0)?)?),
        )
    }

    async fn eval_runs(&self, tenant: &str, suite: Option<&str>, limit: usize) -> anyhow::Result<Vec<memhouse_core::eval::EvalRun>> {
        rows(
            &self.conn(),
            "SELECT run FROM mh_eval_run WHERE tenant = ?1 AND (?2 IS NULL OR suite = ?2) ORDER BY created_at DESC, id DESC LIMIT ?3",
            params![tenant, suite, lim(limit)],
            |r| Ok(serde_json::from_str(&r.get::<_, String>(0)?)?),
        )
    }

    async fn grant_put(&self, g: &Grant, audit: &AuditEntry) -> anyhow::Result<()> {
        let kinds: Vec<&str> = g.kinds.iter().map(|k| k.as_str()).collect();
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        exec(
            &tx,
            "INSERT INTO mh_grant (id, tenant, grantor, grantee, subjects, kinds, created_by, created_at, expires_at, revoked_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![g.id.to_string(), g.tenant, g.grantor, g.grantee, g.subjects, json(&kinds)?, g.created_by, us(g.created_at), g.expires_at.map(us), g.revoked_at.map(us)],
        )?;
        audit_in(&tx, &audit.actor, &audit.action, &g.tenant, audit.subject.as_deref(), audit.memory_id, &audit.detail)?;
        Ok(tx.commit()?)
    }

    async fn grants(&self, tenant: &str, grantee: Option<&str>) -> anyhow::Result<Vec<Grant>> {
        rows(
            &self.conn(),
            "SELECT id, tenant, grantor, grantee, subjects, kinds, created_by, created_at, expires_at, revoked_at FROM mh_grant \
             WHERE tenant = ?1 AND (?2 IS NULL OR (grantee = ?2 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?3))) \
             ORDER BY created_at DESC, id DESC LIMIT CASE WHEN ?2 IS NULL THEN 1000 ELSE -1 END",
            params![tenant, grantee, now()],
            |r| {
                Ok(Grant {
                    id: uuid_of(&r.get::<_, String>("id")?)?,
                    tenant: r.get("tenant")?,
                    grantor: r.get("grantor")?,
                    grantee: r.get("grantee")?,
                    subjects: r.get("subjects")?,
                    kinds: strings(&r.get::<_, String>("kinds")?)?.iter().filter_map(|k| MemoryKind::parse(k)).collect(),
                    created_by: r.get("created_by")?,
                    created_at: at(r.get("created_at")?),
                    expires_at: opt_at(r, "expires_at")?,
                    revoked_at: opt_at(r, "revoked_at")?,
                })
            },
        )
    }

    async fn grant_revoke(&self, tenant: &str, id: Uuid, audit: &AuditEntry) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let n = exec(&tx, "UPDATE mh_grant SET revoked_at = ?3 WHERE tenant = ?1 AND id = ?2 AND revoked_at IS NULL", params![tenant, id.to_string(), now()])?;
        if n == 0 {
            return Ok(false);
        }
        audit_in(&tx, &audit.actor, &audit.action, tenant, audit.subject.as_deref(), audit.memory_id, &audit.detail)?;
        tx.commit()?;
        Ok(true)
    }

    async fn promotion_merge(&self, tenant: &str, id: Uuid, sources: &[Uuid], kinds: &[String], labels: &[String], audit: &AuditEntry) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let ids = id.to_string();
        // It must (still) be a promotion.
        let row = first(&tx, "SELECT metadata, labels FROM mh_memory WHERE tenant = ?1 AND id = ?2", [tenant, ids.as_str()], |r| {
            Ok((value(&r.get::<_, String>(0)?)?, strings(&r.get::<_, String>(1)?)?))
        })?;
        let Some((mut metadata, mut all_labels)) = row.filter(|(m, _)| m.get("promoted_from").is_some_and(|f| f.is_array())) else { return Ok(false) };
        // As for a new promotion: the sources must still be stored; a `forget` of one after this
        // commits finds this record through the link added here.
        let there: i64 =
            first(&tx, "SELECT count(*) FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", params![tenant, ids_json(sources)], |r| Ok(r.get(0)?))?
                .unwrap_or(0);
        anyhow::ensure!(there as usize == sources.len(), "a source of a promotion was deleted while it was being written");
        // Sources and their kinds are parallel lists: merged as pairs, a source once.
        let listed = |v: Option<&serde_json::Value>| -> Vec<String> { v.and_then(|a| a.as_array()).into_iter().flatten().filter_map(|x| x.as_str().map(String::from)).collect() };
        let mut from = listed(metadata.get("promoted_from"));
        let mut from_kinds = listed(metadata.get("promoted_from_kinds"));
        from_kinds.resize(from.len(), String::new());
        for (i, source) in sources.iter().enumerate() {
            let source = source.to_string();
            if !from.contains(&source) {
                from.push(source);
                from_kinds.push(kinds.get(i).cloned().unwrap_or_default());
            }
        }
        metadata["promoted_from"] = serde_json::json!(from);
        metadata["promoted_from_kinds"] = serde_json::json!(from_kinds);
        all_labels.extend(labels.iter().cloned());
        all_labels.sort();
        all_labels.dedup();
        exec(
            &tx,
            "UPDATE mh_memory SET metadata = ?3, labels = ?4, updated_at = max(?5, created_at) WHERE tenant = ?1 AND id = ?2",
            params![tenant, ids, metadata.to_string(), json(&all_labels)?, now()],
        )?;
        index_sources(&tx, tenant, &ids, &metadata)?;
        audit_in(&tx, &audit.actor, &audit.action, tenant, audit.subject.as_deref(), audit.memory_id, &audit.detail)?;
        tx.commit()?;
        Ok(true)
    }

    #[tracing::instrument(name = "db.embed_cache_get", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn embed_cache_get(&self, model: &str, hashes: &[String]) -> anyhow::Result<Vec<(String, Vec<f32>)>> {
        if hashes.is_empty() {
            return Ok(vec![]);
        }
        rows(&self.read(), "SELECT hash, embedding FROM mh_embed_cache WHERE model = ?1 AND hash IN (SELECT value FROM json_each(?2))", params![model, json(hashes)?], |r| {
            Ok((r.get(0)?, from_f32_blob(r.get_ref(1)?.as_blob()?)))
        })
    }

    #[tracing::instrument(name = "db.embed_cache_put", skip_all, fields(db.system = "sqlite", db.operation = "INSERT"))]
    async fn embed_cache_put(&self, model: &str, items: &[(String, Vec<f32>)]) -> anyhow::Result<()> {
        let mut c = self.conn_relaxed();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        for (hash, v) in items {
            exec(&tx, "INSERT INTO mh_embed_cache (model, hash, embedding) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING", params![model, hash, to_f32_blob(v)])?;
        }
        Ok(tx.commit()?)
    }

    #[tracing::instrument(name = "db.audit", skip_all, fields(db.system = "sqlite", db.operation = "INSERT"))]
    async fn audit(&self, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<Uuid>, detail: serde_json::Value) -> anyhow::Result<()> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        audit_in(&tx, actor, action, tenant, subject, memory_id, &detail)?;
        Ok(tx.commit()?)
    }

    async fn audit_log(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<AuditEvent>> {
        rows(&self.conn(), "SELECT * FROM mh_audit WHERE tenant = ?1 ORDER BY id DESC LIMIT ?2", params![tenant, lim(limit)], |r| {
            let detail: String = r.get("detail")?;
            Ok(AuditEvent {
                id: r.get("id")?,
                at: at(r.get("at")?),
                actor: r.get("actor")?,
                action: r.get("action")?,
                tenant: r.get("tenant")?,
                subject: r.get("subject")?,
                memory_id: opt_uuid(r, "memory_id")?,
                detail: serde_json::from_str(&detail).unwrap_or(serde_json::Value::String(detail)),
                prev_hash: r.get("prev_hash")?,
                hash: r.get("hash")?,
            })
        })
    }

    async fn audit_verify(&self) -> anyhow::Result<(u64, Option<i64>)> {
        let c = self.conn();
        let mut st = c.prepare_cached("SELECT id, at, actor, action, tenant, subject, memory_id, detail, prev_hash, hash FROM mh_audit ORDER BY id")?;
        let mut events = st.query([])?;
        let mut prev = "genesis".to_string();
        let mut n = 0u64;
        while let Some(r) = events.next()? {
            n += 1;
            let (stored_prev, stored): (String, String) = (r.get(8)?, r.get(9)?);
            let (subject, memory_id): (Option<String>, Option<String>) = (r.get(5)?, r.get(6)?);
            let h = audit_hash(
                &prev,
                &at(r.get(1)?),
                &r.get::<_, String>(2)?,
                &r.get::<_, String>(3)?,
                &r.get::<_, String>(4)?,
                subject.as_deref(),
                memory_id.as_deref(),
                &r.get::<_, String>(7)?,
            );
            if stored_prev != prev || h != stored {
                return Ok((n, Some(r.get(0)?)));
            }
            prev = stored;
        }
        Ok((n, None))
    }

    async fn stats(&self, tenant: &str) -> anyhow::Result<Stats> {
        let c = self.conn();
        let (memories, committed, quarantined, superseded, subjects) = first(
            &c,
            "SELECT count(*), coalesce(sum(status = 'committed'), 0), coalesce(sum(status = 'quarantined'), 0), coalesce(sum(status = 'superseded'), 0), \
             count(DISTINCT subject) FROM mh_memory WHERE tenant = ?1",
            [tenant],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )?
        .unwrap_or_default();
        let audit_events = first(&c, "SELECT count(*) FROM mh_audit WHERE tenant = ?1", [tenant], |r| Ok(r.get(0)?))?.unwrap_or(0);
        let by_kind =
            rows(&c, "SELECT kind, count(*) FROM mh_memory WHERE tenant = ?1 AND status = 'committed' GROUP BY kind ORDER BY 2 DESC, 1", [tenant], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(Stats { memories, committed, quarantined, superseded, subjects, audit_events, by_kind })
    }

    async fn subjects(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<(String, i64)>> {
        rows(
            &self.conn(),
            "SELECT subject, count(*) FROM mh_memory WHERE tenant = ?1 AND status = 'committed' GROUP BY subject ORDER BY max(created_at) DESC LIMIT ?2",
            params![tenant, lim(limit)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
    }

    async fn get_many(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<Memory>> {
        rows(&self.read(), &format!("SELECT {COLS} FROM mh_memory m WHERE m.tenant = ?1 AND m.id IN (SELECT value FROM json_each(?2))"), params![tenant, ids_json(ids)], memory_of)
    }

    async fn enrich_enqueue(&self, tenant: &str, subject: &str, session_id: &str, round_ids: &[Uuid]) -> anyhow::Result<i64> {
        let c = self.conn();
        exec(
            &c,
            "INSERT INTO mh_enrich_job (tenant, subject, session_id, round_ids, run_after, enqueued_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![tenant, subject, session_id, ids_json(round_ids), now()],
        )?;
        Ok(c.last_insert_rowid())
    }

    async fn enrich_claim(&self, limit: usize, lease_secs: i64) -> anyhow::Result<Vec<EnrichJob>> {
        self.claim_jobs(limit, lease_secs, None)
    }

    async fn enrich_claim_for(&self, tenant: &str, subject: &str, limit: usize, lease_secs: i64) -> anyhow::Result<Vec<EnrichJob>> {
        self.claim_jobs(limit, lease_secs, Some((tenant, subject)))
    }

    async fn enrich_finish(&self, id: i64, cache_key: Option<&str>, outcome: &EnrichOutcome) -> anyhow::Result<()> {
        let mut c = self.conn_relaxed();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = now();
        // The lag is measured against the store's own enqueue time, not the worker's start.
        let Some(enqueued) = first(&tx, "SELECT enqueued_at FROM mh_enrich_job WHERE id = ?1", [id], |r| Ok(r.get::<_, i64>(0)?))? else { return Ok(()) };
        let mut outcome = serde_json::to_value(outcome)?;
        outcome["lag_ms"] = serde_json::json!((now - enqueued) as f64 / 1000.0);
        exec(
            &tx,
            // The keys recorded when the answers were cached stand (there may be more than this one).
            "UPDATE mh_enrich_job SET status = 'done', finished_at = ?2, locked_until = NULL, cache_key = coalesce(cache_key, ?3), outcome = ?4 WHERE id = ?1",
            params![id, now, cache_key, outcome.to_string()],
        )?;
        Ok(tx.commit()?)
    }

    async fn enrich_fail(&self, id: i64, error: &str, max_attempts: i32) -> anyhow::Result<()> {
        // Retry after 2^attempts seconds. Only a job that is not finished: a worker that
        // outlived its lease must not reopen a job another worker has completed since.
        exec(
            &self.conn(),
            "UPDATE mh_enrich_job SET error = ?2, locked_until = NULL, status = CASE WHEN attempts >= ?3 THEN 'failed' ELSE 'pending' END, \
             run_after = ?4 + (1 << min(attempts, 30)) * 1000000 WHERE id = ?1 AND status IN ('pending', 'running')",
            params![id, error, max_attempts, now()],
        )?;
        Ok(())
    }

    async fn enrich_status(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<EnrichStatus> {
        let c = self.conn();
        let oldest: Option<i64> = first(
            &c,
            "SELECT min(enqueued_at) FROM mh_enrich_job WHERE tenant = ?1 AND (?2 IS NULL OR subject = ?2) AND status IN ('pending', 'running')",
            params![tenant, subject],
            |r| Ok(r.get(0)?),
        )?
        .flatten();
        let mut st = EnrichStatus { oldest_pending_secs: oldest.map(|t| (now() - t) as f64 / 1e6), ..Default::default() };
        for (s, n) in rows(&c, "SELECT status, count(*) FROM mh_enrich_job WHERE tenant = ?1 AND (?2 IS NULL OR subject = ?2) GROUP BY status", params![tenant, subject], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })? {
            match s.as_str() {
                "pending" => st.pending = n,
                "running" => st.running = n,
                "done" => st.done = n,
                _ => st.failed += n,
            }
        }
        Ok(st)
    }

    async fn enrich_outcomes(&self, tenant: &str, subject: &str) -> anyhow::Result<Vec<EnrichOutcome>> {
        let found =
            rows(&self.conn(), "SELECT outcome FROM mh_enrich_job WHERE tenant = ?1 AND subject = ?2 AND status = 'done' AND outcome IS NOT NULL", [tenant, subject], |r| {
                Ok(r.get::<_, String>(0)?)
            })?;
        Ok(found.iter().filter_map(|o| serde_json::from_str(o).ok()).collect())
    }

    async fn llm_cache_get(&self, key: &str) -> anyhow::Result<Option<String>> {
        first(&self.conn(), "SELECT response FROM mh_llm_cache WHERE key = ?1", [key], |r| Ok(r.get(0)?))
    }

    async fn llm_cache_put(&self, key: &str, model: &str, text: &str) -> anyhow::Result<()> {
        exec(&self.conn(), "INSERT INTO mh_llm_cache (key, model, response, created_at) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (key) DO NOTHING", params![key, model, text, now()])?;
        Ok(())
    }

    async fn llm_cache_put_for(&self, job: i64, key: &str, model: &str, text: &str) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // A deletion of any of the job's rounds removed the job: nothing derived from them is cached after it.
        let Some(known) = first(&tx, "SELECT cache_key FROM mh_enrich_job WHERE id = ?1", [job], |r| Ok(r.get::<_, Option<String>>(0)?))? else { return Ok(false) };
        let mut keys: Vec<&str> = known.as_deref().map(|k| k.split(',').collect()).unwrap_or_default();
        if !keys.contains(&key) {
            keys.push(key);
            exec(&tx, "UPDATE mh_enrich_job SET cache_key = ?2 WHERE id = ?1", params![job, keys.join(",")])?;
        }
        exec(&tx, "INSERT INTO mh_llm_cache (key, model, response, created_at) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (key) DO NOTHING", params![key, model, text, now()])?;
        tx.commit()?;
        Ok(true)
    }

    async fn export_records(&self, tenant: &str, subject: Option<&str>, after: Option<Uuid>, limit: usize) -> anyhow::Result<Vec<RecordLine>> {
        let c = self.conn();
        // One read transaction: a record and its code references are read from one state of
        // the file, whatever another process deletes between the two statements.
        let c = c.unchecked_transaction()?;
        // A whole tenant is read along the id index, a page starting where the last one ended:
        // `+` keeps the planner from choosing the tenant's index and sorting the tenant for every
        // page, which made an export (and a migration) quadratic in the number of records.
        let scope = if subject.is_some() { "m.tenant = ?1 AND m.subject = ?2" } else { "+m.tenant = ?1 AND ?2 IS NULL" };
        let sql = format!(
            "SELECT {COLS}, m.content_hash, m.superseded_by, m.updated_at, m.alt_hash, s.record_type, s.attrs \
             FROM mh_memory m LEFT JOIN mh_structured s ON s.memory_id = m.id \
             WHERE {scope} AND {} ORDER BY m.id LIMIT ?4",
            if after.is_some() { "m.id > ?3" } else { "?3 IS NULL" }
        );
        let mut lines = rows(&c, &sql, params![tenant, subject, after.map(|u| u.to_string()), lim(limit)], |r| {
            let m = memory_of(r)?;
            let record_type: Option<String> = r.get("record_type")?;
            let attrs: Option<String> = r.get("attrs")?;
            Ok(RecordLine {
                id: m.id,
                tenant: m.tenant,
                subject: m.subject,
                kind: m.kind,
                status: m.status,
                content: m.content,
                content_hash: r.get("content_hash")?,
                session_id: m.session_id,
                turn_ref: m.turn_ref,
                occurred_at: m.occurred_at,
                valid_from: m.valid_from,
                valid_to: m.valid_to,
                expires_at: m.expires_at,
                supersedes: m.supersedes,
                superseded_by: opt_uuid(r, "superseded_by")?,
                labels: m.labels,
                tags: m.tags,
                scope: m.scope,
                source: m.source,
                confidence: m.confidence,
                provenance: m.provenance,
                language: m.language,
                alt_hash: r.get("alt_hash")?,
                structured: match record_type {
                    Some(t) => Some(Structured { record_type: t, attrs: attrs.as_deref().map(value).transpose()?.unwrap_or_else(|| serde_json::json!({})) }),
                    None => None,
                },
                code_refs: vec![],
                metadata: m.metadata,
                created_at: m.created_at,
                updated_at: at(r.get("updated_at")?),
            })
        })?;
        for line in &mut lines {
            line.code_refs = rows(&c, &format!("SELECT {CODE_REF_COLS} FROM mh_code_ref c WHERE c.memory_id = ?1 ORDER BY c.path"), [line.id.to_string()], code_ref_of)?;
        }
        Ok(lines)
    }

    async fn export_links(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<Vec<Link>> {
        rows(
            &self.conn(),
            "SELECT tenant, subject, linked_subject, link_type, memory_id, created_by, created_at FROM mh_link \
             WHERE tenant = ?1 AND (?2 IS NULL OR subject = ?2) ORDER BY subject, linked_subject, link_type",
            params![tenant, subject],
            link_of,
        )
    }

    async fn export_policies(&self) -> anyhow::Result<Vec<PolicyLine>> {
        rows(&self.conn(), "SELECT version, body, created_at FROM mh_policy ORDER BY version", [], |r| {
            Ok(PolicyLine { version: r.get(0)?, body: value(&r.get::<_, String>(1)?)?, created_at: at(r.get(2)?) })
        })
    }

    async fn import_records(&self, records: &[ImportRow]) -> anyhow::Result<u64> {
        let w: Vec<WriteRow> = records.iter().map(|i| WriteRow { r: &i.record, embedding: i.embedding.as_deref(), alt: i.alt.as_ref().map(|(_, v)| v.as_slice()) }).collect();
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let n = self.write_rows(&tx, &w, true)?.len() as u64;
        tx.commit()?;
        Ok(n)
    }

    async fn policy_put(&self, p: &PolicyLine) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_policy (version, body, created_at) VALUES (?1, ?2, ?3) ON CONFLICT (version) DO NOTHING",
            params![p.version, p.body.to_string(), us(p.created_at.trunc_subsecs(6))],
        )?;
        Ok(())
    }

    async fn policy_body(&self, version: &str) -> anyhow::Result<Option<serde_json::Value>> {
        first(&self.conn(), "SELECT body FROM mh_policy WHERE version = ?1", [version], |r| value(&r.get::<_, String>(0)?))
    }

    async fn policy_propose(&self, tenant: &str, name: &str, spec: &serde_json::Value, spec_hash: &str, by: &str, note: Option<&str>) -> anyhow::Result<PolicySpecRecord> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let version: u32 = first(&tx, "SELECT coalesce(max(version), 0) + 1 FROM mh_policy_spec WHERE tenant = ?1", [tenant], |r| Ok(r.get(0)?))?.unwrap_or(1);
        exec(
            &tx,
            "INSERT INTO mh_policy_spec (tenant, version, name, spec, spec_hash, status, note, proposed_by, proposed_at) VALUES (?1, ?2, ?3, ?4, ?5, 'proposed', ?6, ?7, ?8)",
            params![tenant, version, name, spec.to_string(), spec_hash, note, by, now()],
        )?;
        let spec = first(&tx, &format!("SELECT {SPEC_COLS} FROM mh_policy_spec WHERE tenant = ?1 AND version = ?2"), params![tenant, version], spec_of)?;
        tx.commit()?;
        spec.ok_or_else(|| anyhow::anyhow!("the proposed policy was not stored"))
    }

    async fn policy_spec(&self, tenant: &str, version: u32) -> anyhow::Result<Option<PolicySpecRecord>> {
        first(&self.conn(), &format!("SELECT {SPEC_COLS} FROM mh_policy_spec WHERE tenant = ?1 AND version = ?2"), params![tenant, version], spec_of)
    }

    async fn policy_specs(&self, tenant: &str) -> anyhow::Result<Vec<PolicySpecRecord>> {
        rows(&self.conn(), &format!("SELECT {SPEC_COLS} FROM mh_policy_spec WHERE tenant = ?1 ORDER BY version"), [tenant], spec_of)
    }

    async fn policy_approve(&self, tenant: &str, version: u32, approver: &str, compiled: &str) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = now();
        let n = exec(
            &tx,
            "UPDATE mh_policy_spec SET status = 'approved', approved_by = ?3, approved_at = ?4 WHERE tenant = ?1 AND version = ?2 AND status = 'proposed'",
            params![tenant, version, approver, now],
        )?;
        if n == 0 {
            return Ok(false);
        }
        exec(
            &tx,
            "INSERT INTO mh_policy_activation (tenant, version, compiled, action, by_whom, at) VALUES (?1, ?2, ?3, 'approve', ?4, ?5)",
            params![tenant, version, compiled, approver, now],
        )?;
        tx.commit()?;
        Ok(true)
    }

    async fn policy_activate(&self, tenant: &str, version: Option<u32>, compiled: &str, action: &str, by: &str) -> anyhow::Result<()> {
        let c = self.conn();
        exec(
            &c,
            "INSERT INTO mh_policy_activation (tenant, version, compiled, action, by_whom, at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![tenant, version, compiled, action, by, now()],
        )
        .map_err(|e| self.explain(&c, e))?;
        Ok(())
    }

    async fn policy_active(&self, tenant: &str) -> anyhow::Result<Option<PolicySpecRecord>> {
        let cols = SPEC_COLS.split(", ").map(|c| format!("s.{c}")).collect::<Vec<_>>().join(", ");
        first(
            &self.conn(),
            &format!(
                "SELECT {cols} FROM (SELECT version FROM mh_policy_activation WHERE tenant = ?1 ORDER BY id DESC LIMIT 1) a \
                 JOIN mh_policy_spec s ON s.tenant = ?1 AND s.version = a.version"
            ),
            [tenant],
            spec_of,
        )
    }

    async fn policy_history(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<PolicyActivation>> {
        rows(
            &self.conn(),
            "SELECT id, tenant, version, compiled, action, by_whom, at FROM mh_policy_activation WHERE tenant = ?1 ORDER BY id DESC LIMIT ?2",
            params![tenant, lim(limit)],
            |r| Ok(PolicyActivation { id: r.get(0)?, tenant: r.get(1)?, version: r.get(2)?, compiled: r.get(3)?, action: r.get(4)?, by: r.get(5)?, at: at(r.get(6)?) }),
        )
    }

    async fn link_put(&self, l: &Link) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_link (tenant, subject, linked_subject, link_type, memory_id, created_by, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
             ON CONFLICT (tenant, subject, linked_subject, link_type) DO NOTHING",
            params![l.tenant, l.subject, l.linked_subject, l.link_type, l.memory_id.map(|u| u.to_string()), l.created_by, us(l.created_at)],
        )?;
        Ok(())
    }

    async fn links(&self, tenant: &str, subject: &str) -> anyhow::Result<Vec<Link>> {
        self.export_links(tenant, Some(subject)).await
    }

    #[tracing::instrument(name = "db.request_get", skip_all, fields(db.system = "sqlite", db.operation = "SELECT"))]
    async fn request_get(&self, tenant: &str, key: &str) -> anyhow::Result<Option<(String, serde_json::Value)>> {
        first(&self.conn(), "SELECT request_hash, response FROM mh_request_key WHERE tenant = ?1 AND key = ?2", [tenant, key], |r| Ok((r.get(0)?, value(&r.get::<_, String>(1)?)?)))
    }

    #[tracing::instrument(name = "db.request_put", skip_all, fields(db.system = "sqlite", db.operation = "INSERT"))]
    async fn request_put(&self, tenant: &str, key: &str, subject: &str, operation: &str, request_hash: &str, response: &serde_json::Value) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_request_key (tenant, key, subject, operation, request_hash, response, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
             ON CONFLICT (tenant, key) DO NOTHING",
            params![tenant, key, subject, operation, request_hash, response.to_string(), now()],
        )?;
        Ok(())
    }

    async fn expire_due(&self, tenant: &str) -> anyhow::Result<u64> {
        let from: Vec<&str> = MemoryStatus::sources_of(MemoryStatus::Expired).iter().map(|s| s.as_str()).collect();
        exec(
            &self.conn(),
            "UPDATE mh_memory SET status = 'expired', updated_at = max(?2, created_at) WHERE tenant = ?1 AND expires_at <= ?2 AND status IN (SELECT value FROM json_each(?3))",
            params![tenant, now(), json(&from)?],
        )
    }

    async fn structured_query(&self, tenant: &str, subject: &str, record_type: &str, attrs: &serde_json::Value) -> anyhow::Result<Vec<(Uuid, serde_json::Value)>> {
        let found = rows(
            &self.read(),
            "SELECT s.memory_id, s.attrs FROM mh_structured s JOIN mh_memory m ON m.id = s.memory_id \
             WHERE s.tenant = ?1 AND s.subject = ?2 AND s.record_type = ?3 AND m.status = 'committed' ORDER BY s.memory_id",
            [tenant, subject, record_type],
            |r| Ok((uuid_of(&r.get::<_, String>(0)?)?, value(&r.get::<_, String>(1)?)?)),
        )?;
        Ok(found.into_iter().filter(|(_, have)| json_contains(have, attrs)).collect())
    }

    async fn representations(&self, tenant: &str, id: Uuid) -> anyhow::Result<(Option<Structured>, Vec<CodeRef>)> {
        let c = self.conn();
        let ids = id.to_string();
        let structured = first(
            &c,
            "SELECT s.record_type, s.attrs FROM mh_structured s JOIN mh_memory m ON m.id = s.memory_id WHERE m.tenant = ?1 AND s.memory_id = ?2",
            [tenant, ids.as_str()],
            |r| Ok(Structured { record_type: r.get(0)?, attrs: value(&r.get::<_, String>(1)?)? }),
        )?;
        let code_refs = rows(
            &c,
            &format!("SELECT {CODE_REF_COLS} FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id WHERE m.tenant = ?1 AND c.memory_id = ?2 ORDER BY c.path"),
            [tenant, ids.as_str()],
            code_ref_of,
        )?;
        Ok((structured, code_refs))
    }

    async fn forget_matches(&self, tenant: &str, scope: ForgetScope, value: &str, limit: usize) -> anyhow::Result<Vec<Uuid>> {
        let cond = forget_condition(scope)?;
        rows(&self.conn(), &format!("SELECT id FROM mh_memory WHERE tenant = ?1 AND {cond} ORDER BY id LIMIT ?3"), params![tenant, value, lim(limit)], |r| {
            uuid_of(&r.get::<_, String>(0)?)
        })
    }

    async fn forget_count(&self, tenant: &str, scope: ForgetScope, value: &str) -> anyhow::Result<u64> {
        let cond = match scope {
            ForgetScope::Tenant => "1",
            ForgetScope::Subject => "subject = ?2",
            s => forget_condition(s)?,
        };
        let n: i64 =
            first(&self.conn(), &format!("SELECT count(*) FROM mh_memory WHERE tenant = ?1 AND (?2 IS NOT NULL) AND {cond}"), [tenant, value], |r| Ok(r.get(0)?))?.unwrap_or(0);
        Ok(n as u64)
    }

    async fn delete_tenant(&self, tenant: &str, actor: &str) -> anyhow::Result<u64> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let total = self.erase_tenant(&tx, tenant, Some(actor))?;
        exec(&tx, "INSERT INTO mh_deletion_ledger (at, tenant, scope, actor) VALUES (?1, ?2, 'tenant', ?3)", params![now(), tenant, actor])?;
        tx.commit()?;
        Ok(total)
    }

    #[tracing::instrument(name = "db.recall_put", skip_all, fields(db.system = "sqlite", db.operation = "INSERT"))]
    async fn recall_put(&self, r: &RecallRecord) -> anyhow::Result<()> {
        exec(
            &self.conn_relaxed(),
            "INSERT INTO mh_recall (id, tenant, subject, principal, acting_user, at, body) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT (id) DO NOTHING",
            params![r.recall_id.to_string(), r.tenant, r.subject, r.principal, r.user, us(r.at), json(r)?],
        )?;
        Ok(())
    }

    async fn recall_get(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<RecallRecord>> {
        first(&self.conn(), "SELECT body FROM mh_recall WHERE tenant = ?1 AND id = ?2", [tenant, id.to_string().as_str()], |r| Ok(serde_json::from_str(&r.get::<_, String>(0)?)?))
    }

    async fn recalls_delete(&self, tenant: &str, user: Option<&str>, older_than_days: Option<u32>) -> anyhow::Result<u64> {
        let before = older_than_days.map(|d| now().saturating_sub(micros(d as i64 * 86_400)));
        exec(&self.conn(), "DELETE FROM mh_recall WHERE tenant = ?1 AND (?2 IS NULL OR acting_user = ?2) AND (?3 IS NULL OR at < ?3)", params![tenant, user, before])
    }

    async fn set_labels(&self, tenant: &str, id: Uuid, labels: &[String]) -> anyhow::Result<bool> {
        Ok(exec(
            &self.conn(),
            "UPDATE mh_memory SET labels = ?3, updated_at = max(?4, created_at) WHERE tenant = ?1 AND id = ?2",
            params![tenant, id.to_string(), json(labels)?, now()],
        )? > 0)
    }

    async fn principal_get(&self, id: &str) -> anyhow::Result<Option<Principal>> {
        first(&self.conn(), "SELECT * FROM mh_principal WHERE id = ?1", [id], principal_of)
    }

    async fn principal_put(&self, p: &Principal) -> anyhow::Result<()> {
        let kinds: Vec<&str> = p.kinds.iter().map(|k| k.as_str()).collect();
        // An existing principal keeps its tenant and kind: a put for another changes nothing.
        exec(
            &self.conn(),
            "INSERT INTO mh_principal (id, tenant, kind, name, subjects, kinds, denied_labels, org, team, can_commit, act_as, disabled_at, created_at, created_by) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14) \
             ON CONFLICT (id) DO UPDATE SET name = ?4, subjects = ?5, kinds = ?6, denied_labels = ?7, org = ?8, team = ?9, can_commit = ?10, act_as = ?11, disabled_at = ?12 \
             WHERE mh_principal.tenant = ?2 AND mh_principal.kind = ?3",
            params![
                p.id,
                p.tenant,
                p.kind.as_str(),
                p.name,
                json(&p.subjects)?,
                json(&kinds)?,
                json(&p.denied_labels)?,
                p.org,
                p.team,
                p.can_commit,
                p.act_as,
                p.disabled_at.map(us),
                us(p.created_at),
                p.created_by
            ],
        )?;
        Ok(())
    }

    async fn principals(&self, tenant: Option<&str>) -> anyhow::Result<Vec<Principal>> {
        rows(&self.conn(), "SELECT * FROM mh_principal WHERE ?1 IS NULL OR tenant = ?1 ORDER BY id", [tenant], principal_of)
    }

    async fn api_key_get(&self, id: &str) -> anyhow::Result<Option<ApiKey>> {
        first(&self.conn(), "SELECT * FROM mh_api_key WHERE id = ?1", [id], key_of)
    }

    async fn api_key_put(&self, k: &ApiKey) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_api_key (id, principal_id, hash, scopes, expires_at, revoked_at, created_at, created_by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![k.id, k.principal_id, k.hash, json(&k.scopes)?, k.expires_at.map(us), k.revoked_at.map(us), us(k.created_at), k.created_by],
        )?;
        Ok(())
    }

    async fn api_key_end(&self, id: &str, expire_at: Option<DateTime<Utc>>) -> anyhow::Result<bool> {
        let c = self.conn();
        let n = match expire_at {
            None => exec(&c, "UPDATE mh_api_key SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL", params![id, now()])?,
            Some(t) => exec(&c, "UPDATE mh_api_key SET expires_at = min(COALESCE(expires_at, ?3), ?2) WHERE id = ?1 AND revoked_at IS NULL", params![id, us(t), FOREVER])?,
        };
        Ok(n > 0)
    }

    async fn api_keys(&self, principal: Option<&str>) -> anyhow::Result<Vec<ApiKey>> {
        rows(&self.conn(), "SELECT * FROM mh_api_key WHERE ?1 IS NULL OR principal_id = ?1 ORDER BY principal_id, created_at", [principal], key_of)
    }

    async fn session_put(&self, s: &Session) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "INSERT INTO mh_session (id, tenant, principal_id, key_id, key_check, created_at, expires_at, last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![s.id, s.tenant, s.principal_id, s.key_id, s.key_check, us(s.created_at), us(s.expires_at), us(s.last_seen_at)],
        )?;
        Ok(())
    }

    async fn session_get(&self, id: &str) -> anyhow::Result<Option<Session>> {
        // The writer's connection: a session is read right after it is written or deleted.
        first(&self.conn(), "SELECT * FROM mh_session WHERE id = ?1", [id], session_of)
    }

    async fn session_touch(&self, id: &str, at: DateTime<Utc>) -> anyhow::Result<()> {
        exec(&self.conn_relaxed(), "UPDATE mh_session SET last_seen_at = max(last_seen_at, ?2) WHERE id = ?1", params![id, us(at)])?;
        Ok(())
    }

    async fn session_delete(&self, id: &str) -> anyhow::Result<bool> {
        Ok(exec(&self.conn(), "DELETE FROM mh_session WHERE id = ?1", [id])? > 0)
    }

    async fn sessions_purge(&self, now: DateTime<Utc>, idle_before: Option<DateTime<Utc>>) -> anyhow::Result<u64> {
        exec(&self.conn(), "DELETE FROM mh_session WHERE expires_at <= ?1 OR (?2 IS NOT NULL AND last_seen_at <= ?2)", params![us(now), idle_before.map(us)])
    }

    async fn review_queue(
        &self,
        tenant: &str,
        statuses: &[MemoryStatus],
        subject: Option<&str>,
        before: Option<(DateTime<Utc>, Uuid)>,
        limit: usize,
    ) -> anyhow::Result<Vec<Memory>> {
        let statuses = json(&statuses.iter().map(|s| s.as_str()).collect::<Vec<_>>())?;
        rows(
            &self.read(),
            &format!(
                "SELECT {COLS} FROM mh_memory m WHERE m.tenant = ?1 AND m.status IN (SELECT value FROM json_each(?2)) AND (?3 IS NULL OR m.subject = ?3) \
                 AND (?4 IS NULL OR (m.created_at, m.id) < (?4, ?5)) ORDER BY m.created_at DESC, m.id DESC LIMIT ?6"
            ),
            params![tenant, statuses, subject, before.map(|b| us(b.0)), before.map(|b| b.1.to_string()), lim(limit)],
            memory_of,
        )
    }

    async fn usage(&self, tenant: &str) -> anyhow::Result<StoreUsage> {
        let c = self.read();
        let records = first(&c, "SELECT count(*) FROM mh_memory", [], |r| Ok(r.get(0)?))?.unwrap_or(0);
        let largest_subject =
            first(&c, "SELECT subject, count(*) FROM mh_memory WHERE tenant = ?1 GROUP BY subject ORDER BY 2 DESC, 1 LIMIT 1", [tenant], |r| Ok((r.get(0)?, r.get(1)?)))?;
        let writes_last_hour = first(&c, "SELECT count(*) FROM mh_memory WHERE created_at > ?1", [now() - micros(3600)], |r| Ok(r.get(0)?))?.unwrap_or(0);
        drop(c);
        // The file and its write-ahead log, as they are on disk now; nothing for a database in memory.
        let bytes = self.inner.path.as_deref().map(|p| {
            let size = |p: &std::path::Path| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            let mut wal = p.as_os_str().to_os_string();
            wal.push("-wal");
            size(p) + size(std::path::Path::new(&wal))
        });
        Ok(StoreUsage { records, largest_subject, bytes, writes_last_hour })
    }

    async fn signing_key(&self, kid: &str) -> anyhow::Result<Option<Vec<u8>>> {
        first(&self.conn(), "SELECT secret FROM mh_signing_key WHERE id = ?1", [kid], |r| Ok(r.get(0)?))
    }

    async fn signing_key_current(&self) -> anyhow::Result<(String, Vec<u8>)> {
        const CURRENT: &str = "SELECT id, secret FROM mh_signing_key WHERE retired_at IS NULL ORDER BY created_at, id LIMIT 1";
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(key) = first(&tx, CURRENT, [], |r| Ok((r.get(0)?, r.get(1)?)))? {
            return Ok(key);
        }
        let (id, secret) = memhouse_core::identity::new_signing_secret();
        exec(&tx, "INSERT INTO mh_signing_key (id, secret, created_at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING", params![id, secret, now()])?;
        let key = first(&tx, CURRENT, [], |r| Ok((r.get(0)?, r.get(1)?)))?;
        tx.commit()?;
        key.ok_or_else(|| anyhow::anyhow!("the signing key was not stored"))
    }

    async fn stale_code_refs(&self, tenant: &str, subject: &str, path: &str, blob_hash: &str) -> anyhow::Result<Vec<Uuid>> {
        rows(
            &self.conn(),
            "SELECT c.memory_id FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id \
             WHERE c.tenant = ?1 AND c.subject = ?2 AND c.path = ?3 AND c.blob_hash <> ?4 AND m.status = 'committed' ORDER BY c.memory_id",
            [tenant, subject, path, blob_hash],
            |r| uuid_of(&r.get::<_, String>(0)?),
        )
    }

    #[tracing::instrument(name = "db.code_refs_observe", skip_all, fields(db.system = "sqlite", db.operation = "UPDATE", files = files.len()))]
    async fn code_refs_observe(
        &self,
        tenant: &str,
        subject: &str,
        files: &[FileState],
        at: DateTime<Utc>,
        audit: &memhouse_core::traits::ObservationAudit<'_>,
    ) -> anyhow::Result<Vec<RefChange>> {
        let paths = memhouse_core::staleness::paths_of(files);
        if paths.is_empty() {
            return Ok(vec![]);
        }
        let mut c = self.conn();
        // The write lock from the start: what is read is what the plan is written against,
        // and no other observation runs between the read and the write.
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stored = rows(
            &tx,
            &format!(
                "SELECT c.memory_id, {CODE_REF_COLS} FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id \
                 WHERE c.tenant = ?1 AND c.subject = ?2 AND c.path IN (SELECT value FROM json_each(?3)) AND m.tenant = ?1 AND m.status IN ('committed', 'candidate') \
                 ORDER BY c.memory_id, c.path"
            ),
            params![tenant, subject, json(&paths)?],
            |r| Ok(memhouse_core::staleness::RefRow { id: uuid_of(&r.get::<_, String>("memory_id")?)?, code: code_ref_of(r)? }),
        )?;
        let updates = memhouse_core::staleness::plan(&stored, files, at);
        if updates.is_empty() {
            return Ok(vec![]);
        }
        let mut before = std::collections::HashMap::new();
        for id in updates.iter().map(|u| u.id).collect::<HashSet<_>>() {
            let was = first(&tx, "SELECT stale_since FROM mh_memory WHERE tenant = ?1 AND id = ?2", params![tenant, id.to_string()], |r| Ok(r.get::<_, Option<i64>>(0)?))?
                .flatten()
                .is_some();
            before.insert(id, was);
        }
        // A row whose path changes is removed and written again, after every removal: moved
        // in place, `a` to `b` would meet the row of `b` that the same batch moves to `c`.
        for u in updates.iter().filter(|u| u.now.as_ref().is_none_or(|c| c.path != u.path)) {
            exec(&tx, "DELETE FROM mh_code_ref WHERE memory_id = ?1 AND path = ?2", params![u.id.to_string(), u.path])?;
        }
        for u in &updates {
            let Some(code) = &u.now else { continue };
            if code.path == u.path {
                exec(
                    &tx,
                    "UPDATE mh_code_ref SET stale_since = ?3, seen_hash = ?4 WHERE memory_id = ?1 AND path = ?2",
                    params![u.id.to_string(), u.path, code.stale_since.map(us), code.seen_hash],
                )?;
            } else {
                exec(
                    &tx,
                    "INSERT INTO mh_code_ref (memory_id, tenant, subject, path, blob_hash, stale_since, seen_hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![u.id.to_string(), tenant, subject, code.path, code.blob_hash, code.stale_since.map(us), code.seen_hash],
                )?;
            }
        }
        let mut stale = std::collections::HashMap::new();
        for id in before.keys() {
            stale.insert(*id, restale(&tx, tenant, *id)?);
        }
        let changes: Vec<RefChange> = updates
            .into_iter()
            .filter_map(|u| u.change)
            .map(|mut ch| {
                ch.stale = stale.get(&ch.id).copied().unwrap_or(false);
                ch.was_stale = before.get(&ch.id).copied().unwrap_or(false);
                ch
            })
            .collect();
        // With the changes, or not at all (see the trait).
        for e in audit(&changes) {
            audit_in(&tx, &e.actor, &e.action, tenant, e.subject.as_deref(), e.memory_id, &e.detail)?;
        }
        tx.commit()?;
        Ok(changes)
    }

    async fn code_refs_at(&self, tenant: &str, subject: &str, paths: &[String]) -> anyhow::Result<Vec<(Uuid, CodeRef)>> {
        rows(
            &self.conn(),
            &format!(
                "SELECT c.memory_id, {CODE_REF_COLS} FROM mh_code_ref c \
                 WHERE c.tenant = ?1 AND c.subject = ?2 AND c.path IN (SELECT value FROM json_each(?3)) ORDER BY c.memory_id, c.path"
            ),
            params![tenant, subject, json(paths)?],
            |r| Ok((uuid_of(&r.get::<_, String>("memory_id")?)?, code_ref_of(r)?)),
        )
    }

    #[tracing::instrument(name = "db.code_refs_revalidate", skip_all, fields(db.system = "sqlite", db.operation = "UPDATE"))]
    async fn code_refs_revalidate(
        &self,
        tenant: &str,
        id: Uuid,
        refs: Option<&[CodeRef]>,
        audit: &memhouse_core::traits::RevalidationAudit<'_>,
    ) -> anyhow::Result<Option<Vec<CodeRef>>> {
        let ids = id.to_string();
        let sql = format!("SELECT {CODE_REF_COLS} FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id WHERE m.tenant = ?1 AND c.memory_id = ?2 ORDER BY c.path");
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let Some(status) = first(&tx, "SELECT status FROM mh_memory WHERE tenant = ?1 AND id = ?2", [tenant, ids.as_str()], |r| Ok(r.get::<_, String>(0)?))? else {
            return Ok(None);
        };
        // In the transaction: a record superseded since the caller read it is not revalidated.
        memhouse_core::staleness::revalidated_status(id, &status)?;
        let stored = rows(&tx, &sql, [tenant, ids.as_str()], code_ref_of)?;
        let written = memhouse_core::staleness::revalidated(&stored, refs)?;
        for code in &written {
            // Not stale, except where the file was seen with another hash than the one
            // confirmed (`staleness::revalidated`).
            exec(
                &tx,
                "UPDATE mh_code_ref SET blob_hash = ?3, stale_since = ?4, seen_hash = ?5 WHERE memory_id = ?1 AND path = ?2",
                params![ids, code.path, code.blob_hash, code.stale_since.map(us), code.seen_hash],
            )?;
        }
        restale(&tx, tenant, id)?;
        let after = rows(&tx, &sql, [tenant, ids.as_str()], code_ref_of)?;
        // The event says what this transaction read and wrote, and is written with it.
        for e in audit(&stored, &written, &after) {
            audit_in(&tx, &e.actor, &e.action, tenant, e.subject.as_deref(), e.memory_id, &e.detail)?;
        }
        tx.commit()?;
        Ok(Some(after))
    }

    async fn embedding_identity(&self) -> anyhow::Result<(Option<EmbeddingIdentity>, Option<EmbeddingIdentity>)> {
        let c = self.conn();
        Ok((identity_of(&c, "")?, identity_of(&c, "reembed_target_")?))
    }

    async fn reembed_estimate(&self) -> anyhow::Result<ReembedEstimate> {
        let c = self.conn();
        let (records, second_vectors, characters): (i64, i64, i64) =
            first(&c, "SELECT count(*), count(alt_hash), coalesce(sum(length(content)), 0) FROM mh_memory WHERE embedding IS NOT NULL", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })?
            .unwrap_or_default();
        let done: i64 = if meta(&c, "reembed_target_embedder")?.is_some() {
            first(&c, "SELECT count(*) FROM mh_memory WHERE embedding IS NOT NULL AND embedding_next IS NOT NULL", [], |r| Ok(r.get(0)?))?.unwrap_or(0)
        } else {
            0
        };
        Ok(ReembedEstimate { records: records as u64, second_vectors: second_vectors as u64, characters: characters as u64, done: done as u64 })
    }

    async fn reembed_begin(&self, target: &EmbeddingIdentity) -> anyhow::Result<()> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let version: u32 = meta(&tx, "schema_version")?.unwrap_or_default().parse().unwrap_or(0);
        anyhow::ensure!(
            version == SCHEMA_VERSION,
            "the database is at schema version {version}; start MemHouse once with the previous [embedding] settings to upgrade it to {SCHEMA_VERSION}, then re-embed"
        );
        match identity_of(&tx, "reembed_target_")? {
            Some(t) if t == *target => return Ok(()),
            Some(t) => anyhow::bail!("an unfinished re-embedding to {t} exists; abort it first"),
            None => {}
        }
        // Leftovers of a run that stopped before recording its target.
        exec(&tx, CLEAR_NEXT, [])?;
        set_meta(&tx, "reembed_target_embedder", &target.embedder)?;
        set_meta(&tx, "reembed_target_embedding_dim", &target.dim.to_string())?;
        set_meta(&tx, "reembed_target_passage_prefix", &target.passage_prefix)?;
        Ok(tx.commit()?)
    }

    async fn reembed_pending(&self, after: Option<Uuid>, limit: usize) -> anyhow::Result<Vec<ReembedRow>> {
        rows(
            &self.conn(),
            "SELECT id, content, alt_hash FROM mh_memory WHERE embedding IS NOT NULL AND embedding_next IS NULL AND (?1 IS NULL OR id > ?1) ORDER BY id LIMIT ?2",
            params![after.map(|u| u.to_string()), lim(limit)],
            |r| Ok(ReembedRow { id: uuid_of(&r.get::<_, String>(0)?)?, content: r.get(1)?, alt_hash: r.get(2)? }),
        )
    }

    async fn reembed_write(&self, target: &EmbeddingIdentity, vectors: &[ReembedVectors]) -> anyhow::Result<()> {
        if vectors.iter().any(|r| r.embedding.len() != target.dim || r.alt.as_ref().is_some_and(|(_, v)| v.len() != target.dim)) {
            anyhow::bail!("re-embedding produced vectors that are not {}-dimensional", target.dim);
        }
        let config = target.config_hash();
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // Checked with the write: a run aborted (and another started) while these vectors were
        // being made must not find them in its staging columns.
        anyhow::ensure!(identity_of(&tx, "reembed_target_")?.as_ref() == Some(target), "no re-embedding to {target} is in progress; its vectors were not staged");
        for v in vectors {
            let alt = v.alt.as_ref().map(|(_, a)| a.as_slice());
            exec(
                &tx,
                "UPDATE mh_memory SET embedding_next = ?2, embedding_alt_next = ?3, embedding_bits_next = ?4, embedding_alt_bits_next = ?5, alt_hash_next = ?6, \
                 embedder_next = ?7, embedder_config_next = ?8 WHERE id = ?1",
                params![
                    v.id.to_string(),
                    to_half(&v.embedding),
                    alt.map(to_half),
                    to_bits(&v.embedding),
                    alt.map(to_bits),
                    v.alt.as_ref().map(|(h, _)| h.clone()),
                    target.embedder,
                    config
                ],
            )?;
        }
        Ok(tx.commit()?)
    }

    async fn reembed_cutover(&self, target: &EmbeddingIdentity) -> anyhow::Result<Option<u64>> {
        let mut c = self.conn();
        // The one writer: nothing is written between the count and the switch.
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // The whole recorded target: the staged vectors have its dimension and prefix, not only its name.
        anyhow::ensure!(identity_of(&tx, "reembed_target_")?.as_ref() == Some(target), "no re-embedding to {target} is in progress");
        let pending: i64 = first(&tx, "SELECT count(*) FROM mh_memory WHERE embedding IS NOT NULL AND embedding_next IS NULL", [], |r| Ok(r.get(0)?))?.unwrap_or(0);
        if pending > 0 {
            return Ok(Some(pending as u64));
        }
        let old = meta(&tx, "embedder")?;
        exec(
            &tx,
            "UPDATE mh_memory SET embedding = embedding_next, embedding_alt = embedding_alt_next, embedding_bits = embedding_bits_next, \
             embedding_alt_bits = embedding_alt_bits_next, alt_hash = alt_hash_next, embedder = embedder_next, embedder_config = embedder_config_next, \
             embedding_next = NULL, embedding_alt_next = NULL, embedding_bits_next = NULL, embedding_alt_bits_next = NULL, alt_hash_next = NULL, \
             embedder_next = NULL, embedder_config_next = NULL WHERE embedding IS NOT NULL",
            [],
        )?;
        set_meta(&tx, "embedder", &target.embedder)?;
        set_meta(&tx, "embedding_dim", &target.dim.to_string())?;
        set_meta(&tx, "passage_prefix", &target.passage_prefix)?;
        exec(&tx, "DELETE FROM mh_meta WHERE key LIKE 'reembed_target_%'", [])?;
        // The old model's cached vectors are copies of content under a model no longer used; they
        // go, so deletions never have to chase them (TR-WF-01).
        if let Some(old) = old {
            exec(&tx, "DELETE FROM mh_embed_cache WHERE model = ?1", [old])?;
        }
        tx.commit()?;
        Ok(None)
    }

    async fn reembed_abort(&self) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        exec(&tx, CLEAR_NEXT, [])?;
        let removed = exec(&tx, "DELETE FROM mh_meta WHERE key LIKE 'reembed_target_%'", [])?;
        tx.commit()?;
        Ok(removed > 0)
    }

    async fn export_vectors(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<memhouse_core::migrate::RecordVectors>> {
        self.vectors_of(tenant, ids)
    }

    async fn migration_summary(&self) -> anyhow::Result<memhouse_core::migrate::Summary> {
        let mut s = self.summary()?;
        if s.schema_version.is_some() {
            (s.identity, s.reembed_target) = self.embedding_identity().await?;
        }
        Ok(s)
    }

    async fn migration_dump(&self, table: &str, after: Option<&serde_json::Value>, limit: usize) -> anyhow::Result<Vec<serde_json::Value>> {
        self.dump(table, after, limit)
    }

    async fn migration_load(&self, table: &str, rows: &[serde_json::Value]) -> anyhow::Result<u64> {
        self.load(table, rows)
    }

    async fn migration_marker(&self) -> anyhow::Result<Option<serde_json::Value>> {
        self.marker()
    }

    async fn set_migration_marker(&self, marker: &serde_json::Value) -> anyhow::Result<()> {
        self.set_marker(marker)
    }
}

/// The rows a `forget` by user, agent or source matches (`?2` is the value).
fn forget_condition(scope: ForgetScope) -> anyhow::Result<&'static str> {
    Ok(match scope {
        ForgetScope::User => "(prov_user = ?2 OR scope_user = ?2)",
        ForgetScope::Agent => "(prov_agent = ?2 OR scope_agent = ?2)",
        ForgetScope::Source => "source = ?2",
        s => anyhow::bail!("no row condition for forget by {}", s.as_str()),
    })
}

/// A record is stale from the earliest time one of its references became stale (TPL-04).
/// Returns whether it is stale now.
fn restale(c: &Connection, tenant: &str, id: Uuid) -> anyhow::Result<bool> {
    let ids = id.to_string();
    exec(c, "UPDATE mh_memory SET stale_since = (SELECT min(c.stale_since) FROM mh_code_ref c WHERE c.memory_id = ?2) WHERE tenant = ?1 AND id = ?2", [tenant, ids.as_str()])?;
    Ok(first(c, "SELECT stale_since FROM mh_memory WHERE tenant = ?1 AND id = ?2", [tenant, ids.as_str()], |r| Ok(r.get::<_, Option<i64>>(0)?))?.flatten().is_some())
}
