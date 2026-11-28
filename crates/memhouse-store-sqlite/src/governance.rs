// SPDX-License-Identifier: Apache-2.0
//! Governance II on the Lite store (G22, schema v12): legal holds, the deletion workflow's
//! requests, durable job runs, retention by rule, the audit head and the store's small state.
//! Row-level security and monthly partitions belong to the Postgres store: one file with one
//! writer has neither a second connection to defend against nor partitions to drop.

use crate::records::{audit_in, drop_jobs};
use crate::util::*;
use crate::SqliteStore;
use chrono::Utc;
use memhouse_core::governance::{AuditHead, Canary, CanaryReport, DeletionRequest, DeletionStatus, JobRun, LegalHold, PurgeAge, PurgeOutcome, PurgeSpec, ScopeMatch, HELD_SQL};
use memhouse_core::intake::AuditEntry;
use memhouse_core::types::*;
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, Row, TransactionBehavior};
use std::collections::HashSet;
use uuid::Uuid;

/// The condition of a forget scope over the alias `m` (`?2` is the value).
fn scope_condition(scope: ForgetScope) -> &'static str {
    match scope {
        ForgetScope::Record => "(m.id = ?2 OR m.id IN (SELECT r.memory_id FROM mh_source_ref r WHERE r.tenant = ?1 AND r.source_id = ?2))",
        ForgetScope::Subject => "m.subject = ?2",
        ForgetScope::Tenant => "?2 IS NOT NULL",
        ForgetScope::User => "(m.prov_user = ?2 OR m.scope_user = ?2)",
        ForgetScope::Agent => "(m.prov_agent = ?2 OR m.scope_agent = ?2)",
        ForgetScope::Source => "m.source = ?2",
        ForgetScope::Untrusted => "(m.status = 'candidate' AND json_extract(m.metadata, '$.held') = 'untrusted_source' AND (?2 = '*' OR m.source = ?2))",
    }
}

/// The rows a `forget` by user, agent, source or untrusted source matches, over `m`.
pub(crate) fn forget_condition(scope: ForgetScope) -> anyhow::Result<&'static str> {
    match scope {
        ForgetScope::User | ForgetScope::Agent | ForgetScope::Source | ForgetScope::Untrusted => Ok(scope_condition(scope)),
        s => anyhow::bail!("no row condition for forget by {}", s.as_str()),
    }
}

fn hold_of(r: &Row) -> anyhow::Result<LegalHold> {
    Ok(LegalHold {
        id: uuid_of(&r.get::<_, String>("id")?)?,
        tenant: r.get("tenant")?,
        target_kind: r.get("target_kind")?,
        target: r.get("target")?,
        reason: r.get("reason")?,
        placed_by: r.get("placed_by")?,
        placed_at: at(r.get("placed_at")?),
        released_by: r.get("released_by")?,
        released_at: opt_at(r, "released_at")?,
    })
}

fn deletion_of(r: &Row) -> anyhow::Result<DeletionRequest> {
    let scope: String = r.get("scope")?;
    let status: String = r.get("status")?;
    let certificate: Option<String> = r.get("certificate")?;
    Ok(DeletionRequest {
        id: uuid_of(&r.get::<_, String>("id")?)?,
        tenant: r.get("tenant")?,
        scope: serde_json::from_value(serde_json::Value::String(scope))?,
        value: r.get("value")?,
        actor: r.get("actor")?,
        requested_at: at(r.get("requested_at")?),
        status: DeletionStatus::parse(&status).ok_or_else(|| anyhow::anyhow!("unknown deletion status '{status}' in the database"))?,
        completed_at: opt_at(r, "completed_at")?,
        deleted: r.get::<_, i64>("deleted")?.max(0) as u64,
        held: r.get::<_, i64>("held")?.max(0) as u64,
        executions: r.get::<_, i64>("executions")?.max(0) as u32,
        canaries: serde_json::from_str(&r.get::<_, String>("canaries")?)?,
        certificate: certificate.map(|c| serde_json::from_str(&c)).transpose()?,
    })
}

fn audit(c: &Connection, tenant: &str, a: &AuditEntry) -> anyhow::Result<()> {
    audit_in(c, &a.actor, &a.action, tenant, a.subject.as_deref(), a.memory_id, &a.detail)
}

fn active_holds(c: &Connection, tenant: &str) -> anyhow::Result<i64> {
    Ok(first(c, "SELECT count(*) FROM mh_legal_hold WHERE tenant = ?1 AND released_at IS NULL", [tenant], |r| Ok(r.get(0)?))?.unwrap_or(0))
}

/// The rule of a purge over the alias `m`: `?1` is the tenant, `?2` the kind, `?3` the time
/// the rule compares with; scope values follow from `?4`.
fn purge_filter(spec: &PurgeSpec) -> (String, Vec<Value>) {
    let now = now();
    let (mut sql, time) = match spec.age {
        PurgeAge::OlderThanDays(d) => (
            "m.created_at < ?3".to_string(), // (Saturating all the way: an age no record can have selects nothing, and does not wrap.)
            now.saturating_sub((d as i64).saturating_mul(86_400 * 1_000_000)),
        ),
        PurgeAge::Expired => ("m.expires_at IS NOT NULL AND m.expires_at < ?3".to_string(), now),
    };
    let mut values = vec![Value::Integer(time)];
    if let Some(ScopeMatch { level, value }) = &spec.scope {
        values.push(Value::Text(value.clone()));
        sql.push_str(&format!(" AND m.{} = ?{}", level.column(), values.len() + 2));
    }
    for ScopeMatch { level, value } in &spec.except {
        values.push(Value::Text(value.clone()));
        sql.push_str(&format!(" AND (m.{col} IS NULL OR m.{col} <> ?{n})", col = level.column(), n = values.len() + 2));
    }
    (sql, values)
}

impl SqliteStore {
    /// One retention rule (see `Store::purge`): the same cascade as `delete`, in batches so a
    /// large purge never holds the writer for long, each batch counted on its run in the batch's
    /// own transaction.
    pub(crate) fn purge_by(&self, tenant: &str, spec: &PurgeSpec) -> anyhow::Result<PurgeOutcome> {
        let (filter, values) = purge_filter(spec);
        let bound =
            |values: &[Value]| -> Vec<Value> { [Value::Text(tenant.to_string()), Value::Text(spec.kind.as_str().to_string())].into_iter().chain(values.iter().cloned()).collect() };
        let mut out = PurgeOutcome { complete: true, ..Default::default() };
        let mut batches = 0usize;
        loop {
            if spec.max_batches.is_some_and(|max| batches >= max) {
                out.complete = false;
                break;
            }
            let mut c = self.conn();
            let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let batch = rows(
                &tx,
                &format!("SELECT m.id, m.subject, m.content, m.alt_hash FROM mh_memory m WHERE m.tenant = ?1 AND m.kind = ?2 AND {filter} AND NOT {HELD_SQL} LIMIT 1000"),
                params_from_iter(bound(&values)),
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, Option<String>>(3)?)),
            )?;
            if batch.is_empty() {
                break;
            }
            let ids: Vec<Uuid> = batch.iter().map(|b| uuid_of(&b.0)).collect::<anyhow::Result<_>>()?;
            let id_list = ids_json(&ids);
            exec(&tx, "DELETE FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", [tenant, id_list.as_str()])?;
            self.purge_vectors(&tx, batch.iter().map(|b| b.2.as_str()), batch.iter().filter_map(|b| b.3.as_deref()))?;
            // Records promoted from them stay; a derived fact under a legal hold stays too, and
            // the ledger then says exactly what went (`record` rows): a `retention` row is
            // re-applied with the cascade, which would take the kept fact on a restore.
            let kept = self.held_facts(&tx, tenant, &ids)?;
            let fact_ids = self.delete_dependents(&tx, tenant, &ids, true, false, true)?;
            let facts = fact_ids.len();
            let subjects: HashSet<&str> = batch.iter().map(|b| b.1.as_str()).collect();
            // The jobs that read a purged record or a fact that went with it.
            let read_list = ids_json(&ids.iter().chain(fact_ids.iter()).copied().collect::<Vec<Uuid>>());
            for subject in subjects {
                let jobs = rows(
                    &tx,
                    "SELECT j.id, j.cache_key FROM mh_enrich_job j WHERE j.tenant = ?1 AND j.subject = ?2 \
                     AND EXISTS (SELECT 1 FROM json_each(j.round_ids) WHERE value IN (SELECT value FROM json_each(?3)))",
                    [tenant, subject, read_list.as_str()],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )?;
                drop_jobs(&tx, &jobs, true)?;
            }
            let at = now();
            let scope = if kept { "record" } else { "retention" };
            for (id, subject, _, _) in &batch {
                exec(
                    &tx,
                    "INSERT INTO mh_deletion_ledger (at, tenant, subject, memory_id, scope, actor) VALUES (?1, ?2, ?3, ?4, ?5, 'system')",
                    params![at, tenant, subject, id, scope],
                )?;
            }
            if kept {
                for f in &fact_ids {
                    exec(&tx, "INSERT INTO mh_deletion_ledger (at, tenant, memory_id, scope, actor) VALUES (?1, ?2, ?3, 'record', 'system')", params![at, tenant, f.to_string()])?;
                }
            }
            let n = (batch.len() + facts) as u64;
            if let Some((run, step)) = &spec.run {
                let state: Option<String> = first(&tx, "SELECT state FROM mh_job_run WHERE id = ?1", [run.to_string()], |r| Ok(r.get(0)?))?;
                if let Some(state) = state {
                    let mut state = value(&state)?;
                    let so_far = state["counts"][step.as_str()].as_u64().unwrap_or(0);
                    state["counts"][step.as_str()] = serde_json::json!(so_far + n);
                    exec(&tx, "UPDATE mh_job_run SET state = ?2, updated_at = ?3 WHERE id = ?1", params![run.to_string(), state.to_string(), at])?;
                }
            }
            tx.commit()?;
            out.records += n;
            batches += 1;
        }
        let c = self.conn();
        if active_holds(&c, tenant)? > 0 {
            out.held =
                first(&c, &format!("SELECT count(*) FROM mh_memory m WHERE m.tenant = ?1 AND m.kind = ?2 AND {filter} AND {HELD_SQL}"), params_from_iter(bound(&values)), |r| {
                    Ok(r.get::<_, i64>(0)?)
                })?
                .unwrap_or(0)
                .max(0) as u64;
        }
        Ok(out)
    }

    pub(crate) fn hold_put(&self, h: &LegalHold, a: &AuditEntry) -> anyhow::Result<()> {
        anyhow::ensure!(memhouse_core::governance::HOLD_KINDS.contains(&h.target_kind.as_str()), "{:?} is not something a legal hold is placed on", h.target_kind);
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        exec(
            &tx,
            "INSERT INTO mh_legal_hold (id, tenant, target_kind, target, reason, placed_by, placed_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![h.id.to_string(), h.tenant, h.target_kind, h.target, h.reason, h.placed_by, us(h.placed_at)],
        )?;
        audit(&tx, &h.tenant, a)?;
        Ok(tx.commit()?)
    }

    pub(crate) fn hold_release(&self, tenant: &str, id: Uuid, by: &str, a: &AuditEntry) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let n = exec(
            &tx,
            "UPDATE mh_legal_hold SET released_at = ?3, released_by = ?4 WHERE tenant = ?1 AND id = ?2 AND released_at IS NULL",
            params![tenant, id.to_string(), now(), by],
        )?;
        if n == 0 {
            return Ok(false);
        }
        audit(&tx, tenant, a)?;
        tx.commit()?;
        Ok(true)
    }

    pub(crate) fn holds(&self, tenant: &str, active_only: bool) -> anyhow::Result<Vec<LegalHold>> {
        rows(
            &self.read(),
            "SELECT * FROM mh_legal_hold WHERE tenant = ?1 AND (NOT ?2 OR released_at IS NULL) ORDER BY placed_at DESC, id LIMIT 1000",
            params![tenant, active_only],
            hold_of,
        )
    }

    /// Whether a fact derived from any of these records is under a legal hold.
    fn held_facts(&self, c: &Connection, tenant: &str, sources: &[Uuid]) -> anyhow::Result<bool> {
        Ok(first(
            c,
            &format!(
                "SELECT 1 FROM mh_source_ref r JOIN mh_memory m ON m.id = r.memory_id WHERE r.tenant = ?1 AND m.tenant = ?1 AND r.via = 'source' \
                 AND r.source_id IN (SELECT value FROM json_each(?2)) AND {HELD_SQL} LIMIT 1"
            ),
            params![tenant, ids_json(sources)],
            |_| Ok(()),
        )?
        .is_some())
    }

    pub(crate) fn hold_one(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<LegalHold>> {
        first(&self.read(), "SELECT * FROM mh_legal_hold WHERE tenant = ?1 AND id = ?2", [tenant, id.to_string().as_str()], hold_of)
    }

    pub(crate) fn deletion_add(&self, tenant: &str, id: Uuid, deleted: u64) -> anyhow::Result<Option<DeletionRequest>> {
        // A sum in the database: two executions each add their own count, neither overwrites.
        exec(
            &self.conn(),
            "UPDATE mh_deletion_request SET deleted = deleted + ?3, executions = executions + 1 WHERE tenant = ?1 AND id = ?2 AND status <> 'completed'",
            params![tenant, id.to_string(), deleted as i64],
        )?;
        self.deletion_one(tenant, id)
    }

    pub(crate) fn deletion_open(&self, tenant: &str, after: Option<(chrono::DateTime<Utc>, Uuid)>, limit: usize) -> anyhow::Result<Vec<DeletionRequest>> {
        rows(
            &self.conn(),
            "SELECT * FROM mh_deletion_request WHERE tenant = ?1 AND status <> 'completed' AND (?2 IS NULL OR (requested_at, id) > (?2, ?3)) ORDER BY requested_at, id LIMIT ?4",
            params![tenant, after.map(|a| us(a.0)), after.map(|a| a.1.to_string()), limit.min(i64::MAX as usize) as i64],
            deletion_of,
        )
    }

    pub(crate) fn held(&self, tenant: &str, scope: ForgetScope, value: &str) -> anyhow::Result<u64> {
        let c = self.conn();
        if active_holds(&c, tenant)? == 0 {
            return Ok(0);
        }
        let cond = scope_condition(scope);
        let n: i64 = first(&c, &format!("SELECT count(*) FROM mh_memory m WHERE m.tenant = ?1 AND {cond} AND {HELD_SQL}"), [tenant, value], |r| Ok(r.get(0)?))?.unwrap_or(0);
        Ok(n.max(0) as u64)
    }

    pub(crate) fn deletion_store(&self, d: &DeletionRequest, a: Option<&AuditEntry>) -> anyhow::Result<()> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let written = exec(
            &tx,
            "INSERT INTO mh_deletion_request (id, tenant, scope, value, actor, requested_at, status, completed_at, deleted, held, executions, canaries, certificate) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) \
             ON CONFLICT (id) DO UPDATE SET status = excluded.status, completed_at = excluded.completed_at, held = excluded.held, certificate = excluded.certificate, \
               deleted = max(mh_deletion_request.deleted, excluded.deleted), executions = max(mh_deletion_request.executions, excluded.executions) \
             WHERE mh_deletion_request.status <> 'completed'",
            params![
                d.id.to_string(),
                d.tenant,
                d.scope.as_str(),
                d.value,
                d.actor,
                us(d.requested_at),
                d.status.as_str(),
                d.completed_at.map(us),
                d.deleted as i64,
                d.held as i64,
                d.executions as i64,
                json(&d.canaries)?,
                d.certificate.as_ref().map(json).transpose()?,
            ],
        )?;
        // The certificate's event is written with the completion, and only by the call that completes it.
        if let Some(a) = a.filter(|_| written > 0) {
            audit(&tx, &d.tenant, a)?;
        }
        Ok(tx.commit()?)
    }

    pub(crate) fn deletion_one(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<DeletionRequest>> {
        first(&self.conn(), "SELECT * FROM mh_deletion_request WHERE tenant = ?1 AND id = ?2", [tenant, id.to_string().as_str()], deletion_of)
    }

    pub(crate) fn deletion_list(&self, tenant: &str, status: Option<DeletionStatus>, limit: usize) -> anyhow::Result<Vec<DeletionRequest>> {
        rows(
            &self.conn(),
            "SELECT * FROM mh_deletion_request WHERE tenant = ?1 AND (?2 IS NULL OR status = ?2) ORDER BY requested_at DESC, id LIMIT ?3",
            params![tenant, status.map(|s| s.as_str()), limit.min(i64::MAX as usize) as i64],
            deletion_of,
        )
    }

    pub(crate) fn canaries_of(&self, tenant: &str, scope: ForgetScope, value: &str, limit: usize) -> anyhow::Result<Vec<Canary>> {
        let cond = scope_condition(scope);
        rows(
            &self.conn(),
            &format!("SELECT m.id, m.subject, m.content, m.alt_hash FROM mh_memory m WHERE m.tenant = ?1 AND {cond} ORDER BY m.id LIMIT ?3"),
            params![tenant, value, limit.min(i64::MAX as usize) as i64],
            |r| {
                // The key of the cached vector, never the text it is the key of.
                let mut vector_hashes = vec![self.cache_hash(&r.get::<_, String>(2)?)];
                vector_hashes.extend(r.get::<_, Option<String>>(3)?);
                Ok(Canary { id: uuid_of(&r.get::<_, String>(0)?)?, subject: r.get(1)?, vector_hashes })
            },
        )
    }

    pub(crate) fn probe(&self, tenant: &str, canaries: &[Canary]) -> anyhow::Result<CanaryReport> {
        if canaries.is_empty() {
            return Ok(CanaryReport::default());
        }
        let c = self.conn();
        let ids = ids_json(&canaries.iter().map(|c| c.id).collect::<Vec<_>>());
        let hashes = serde_json::Value::from(canaries.iter().flat_map(|c| c.vector_hashes.iter().cloned()).collect::<Vec<_>>()).to_string();
        let count = |sql: &str, p: &[&str]| -> anyhow::Result<u64> { Ok(first(&c, sql, params_from_iter(p.iter()), |r| Ok(r.get::<_, i64>(0)?))?.unwrap_or(0).max(0) as u64) };
        Ok(CanaryReport {
            records: count("SELECT count(*) FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", &[tenant, &ids])?,
            representations: count(
                "SELECT (SELECT count(*) FROM mh_structured WHERE memory_id IN (SELECT value FROM json_each(?1))) \
                      + (SELECT count(*) FROM mh_code_ref WHERE memory_id IN (SELECT value FROM json_each(?1))) \
                      + (SELECT count(*) FROM mh_link WHERE memory_id IN (SELECT value FROM json_each(?1)))",
                &[&ids],
            )?,
            cached_vectors: count("SELECT count(*) FROM mh_embed_cache WHERE hash IN (SELECT value FROM json_each(?1))", &[&hashes])?,
            derived: count("SELECT count(DISTINCT memory_id) FROM mh_source_ref WHERE tenant = ?1 AND source_id IN (SELECT value FROM json_each(?2))", &[tenant, &ids])?,
            queued: count(
                "SELECT count(*) FROM mh_intake q WHERE q.tenant = ?1 AND (q.payload IS NOT NULL OR q.status IN ('pending', 'running')) \
                 AND EXISTS (SELECT 1 FROM json_each(q.record_ids) WHERE value IN (SELECT value FROM json_each(?2)))",
                &[tenant, &ids],
            )?,
            jobs: count(
                "SELECT count(*) FROM mh_enrich_job j WHERE j.tenant = ?1 AND EXISTS (SELECT 1 FROM json_each(j.round_ids) WHERE value IN (SELECT value FROM json_each(?2)))",
                &[tenant, &ids],
            )?,
        })
    }

    pub(crate) fn job_open(&self, tenant: &str, job: &str) -> anyhow::Result<JobRun> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let open = first(&tx, "SELECT id, state, started_at FROM mh_job_run WHERE tenant = ?1 AND job = ?2 AND finished_at IS NULL", [tenant, job], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))
        })?;
        let run = match open {
            Some((id, state, started)) => JobRun { id: uuid_of(&id)?, tenant: tenant.into(), job: job.into(), state: value(&state)?, started_at: at(started), resumed: true },
            None => {
                let run = JobRun { id: Uuid::new_v4(), tenant: tenant.into(), job: job.into(), state: serde_json::json!({}), started_at: Utc::now(), resumed: false };
                exec(
                    &tx,
                    "INSERT INTO mh_job_run (id, tenant, job, state, started_at, updated_at) VALUES (?1, ?2, ?3, '{}', ?4, ?4)",
                    params![run.id.to_string(), tenant, job, us(run.started_at)],
                )?;
                run
            }
        };
        tx.commit()?;
        Ok(run)
    }

    pub(crate) fn job_counted(&self, run: Uuid, step: &str) -> anyhow::Result<u64> {
        let state: Option<String> = first(&self.conn(), "SELECT state FROM mh_job_run WHERE id = ?1", [run.to_string()], |r| Ok(r.get(0)?))?;
        Ok(state.map(|s| value(&s)).transpose()?.and_then(|s| s["counts"][step].as_u64()).unwrap_or(0))
    }

    pub(crate) fn job_step(&self, run: Uuid, step: &str, a: Option<&AuditEntry>) -> anyhow::Result<bool> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let Some((tenant, state)) = first(&tx, "SELECT tenant, state FROM mh_job_run WHERE id = ?1", [run.to_string()], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        else {
            return Ok(false);
        };
        let mut state = value(&state)?;
        let mut done: Vec<String> = serde_json::from_value(state["done"].take()).unwrap_or_default();
        if done.iter().any(|d| d == step) {
            return Ok(false);
        }
        done.push(step.to_string());
        state["done"] = serde_json::json!(done);
        exec(&tx, "UPDATE mh_job_run SET state = ?2, updated_at = ?3 WHERE id = ?1", params![run.to_string(), state.to_string(), now()])?;
        if let Some(a) = a {
            audit(&tx, &tenant, a)?;
        }
        tx.commit()?;
        Ok(true)
    }

    pub(crate) fn job_close(&self, run: Uuid) -> anyhow::Result<()> {
        let c = self.conn();
        exec(&c, "UPDATE mh_job_run SET finished_at = ?2, updated_at = ?2 WHERE id = ?1 AND finished_at IS NULL", params![run.to_string(), now()])?;
        // Finished runs are a short history, not a log: the audit events are the record.
        // Housekeeping: a failure here must not make a finished pass look failed.
        let _ = exec(&c, "DELETE FROM mh_job_run WHERE finished_at < ?1", [now() - 30 * 86_400 * 1_000_000]);
        Ok(())
    }

    pub(crate) fn head(&self) -> anyhow::Result<Option<AuditHead>> {
        first(&self.conn(), "SELECT id, hash, at FROM mh_audit ORDER BY id DESC LIMIT 1", [], |r| Ok(AuditHead { id: r.get(0)?, hash: r.get(1)?, at: at(r.get(2)?) }))
    }

    pub(crate) fn state(&self, key: &str) -> anyhow::Result<Option<String>> {
        self.meta(&format!("state.{key}"))
    }

    pub(crate) fn set_state(&self, key: &str, expect: Option<Option<&str>>, new: &str) -> anyhow::Result<bool> {
        let key = format!("state.{key}");
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current: Option<String> = first(&tx, "SELECT value FROM mh_meta WHERE key = ?1", [key.as_str()], |r| Ok(r.get(0)?))?;
        if expect.is_some_and(|e| e != current.as_deref()) {
            return Ok(false);
        }
        exec(&tx, "INSERT INTO mh_meta (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [key.as_str(), new])?;
        tx.commit()?;
        Ok(true)
    }
}
