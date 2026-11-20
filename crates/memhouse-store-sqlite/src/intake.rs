// SPDX-License-Identifier: Apache-2.0
//! The intake queue in the store's own file (ADR 0004, TR-LT-05): a proposal is durable once
//! `enqueue` returns, and its completion commits with the records it wrote.

use crate::util::*;
use crate::SqliteStore;
use async_trait::async_trait;
use memhouse_core::intake::{IntakeJob, Proposal};
use memhouse_core::types::*;
use rusqlite::{params, Connection, TransactionBehavior};
use std::collections::HashSet;
use uuid::Uuid;

/// `record_ids` holds this id (`?N` is the id's text).
macro_rules! holds {
    ($n:literal) => {
        concat!("EXISTS (SELECT 1 FROM json_each(record_ids) WHERE value = ?", $n, ")")
    };
}

fn proposal_of(payload: &str) -> anyhow::Result<Proposal> {
    serde_json::from_str(payload).map_err(|e| anyhow::anyhow!("unreadable intake proposal: {e}"))
}

/// Queued (or set-aside) proposals that promote any of `gone`: they go with their sources
/// (MEM-05), so none is readable by its id or written later. Returns how many were removed.
pub(crate) fn drop_promotions_of(c: &Connection, tenant: &str, gone: &HashSet<Uuid>) -> anyhow::Result<u64> {
    let queued = rows(c, "SELECT seq, payload FROM mh_intake WHERE tenant = ?1 AND payload IS NOT NULL", [tenant], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
    let mut n = 0;
    for (seq, payload) in queued {
        let payload = value(&payload)?;
        let promotes = payload["records"].as_array().into_iter().flatten().any(|r| {
            r["memory"]["metadata"]["promoted_from"].as_array().into_iter().flatten().any(|s| s.as_str().and_then(|s| Uuid::parse_str(s).ok()).is_some_and(|u| gone.contains(&u)))
        });
        if promotes {
            n += exec(c, "DELETE FROM mh_intake WHERE seq = ?1", [seq])?;
        }
    }
    Ok(n)
}

#[async_trait]
impl memhouse_core::IntakeQueue for SqliteStore {
    fn name(&self) -> &'static str {
        "sqlite"
    }

    #[tracing::instrument(name = "db.intake_enqueue", skip_all, fields(db.system = "sqlite", db.operation = "INSERT"))]
    async fn enqueue(&self, p: &Proposal) -> anyhow::Result<()> {
        let head = p.records.first().map(|r| &r.memory);
        let embedder = self.ident().map(|i| i.embedder);
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // A promotion is queued with its sources checked (MEM-05): a deletion that ran since they
        // were read has removed a source, and then nothing is queued. One writer at a time, so
        // no deletion can run between this check and the insert.
        let sources: HashSet<Uuid> = p.records.iter().flat_map(|r| memhouse_core::intake::promoted_from(&r.memory)).collect();
        if !sources.is_empty() {
            let ids: Vec<Uuid> = sources.iter().copied().collect();
            let there: i64 =
                first(&tx, "SELECT count(*) FROM mh_memory WHERE tenant = ?1 AND id IN (SELECT value FROM json_each(?2))", params![p.tenant, ids_json(&ids)], |r| Ok(r.get(0)?))?
                    .unwrap_or(0);
            if there as usize != sources.len() {
                return Err(memhouse_core::error::conflict("a source of the promotion was deleted; nothing was queued"));
            }
        }
        let t = us(p.enqueued_at);
        exec(
            &tx,
            "INSERT INTO mh_intake (id, tenant, subject, record_ids, agent, acting_user, source, scope_agent, scope_user, payload, enqueued_at, run_after, embedder) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                p.id.to_string(),
                p.tenant,
                p.subject,
                ids_json(&p.record_ids()),
                p.actor,
                p.user,
                p.source,
                head.and_then(|m| m.scope.agent.clone()),
                head.and_then(|m| m.scope.user.clone()),
                json(p)?,
                t,
                // Claimable at once, whatever the caller's clock said when it built the proposal.
                t.min(now()),
                embedder
            ],
        )
        .map_err(|e| self.explain(&tx, e))?;
        // Durable on return: the commit is flushed to the device (TR-LT-05).
        Ok(tx.commit()?)
    }

    #[tracing::instrument(name = "db.intake_claim", skip_all, fields(db.system = "sqlite", db.operation = "UPDATE"))]
    async fn claim(&self, limit: usize, lease_secs: u64, subject: Option<(&str, &str)>) -> anyhow::Result<Vec<IntakeJob>> {
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = now();
        // The oldest unfinished proposal of each subject only, so one subject's writes take effect
        // in the order they were acknowledged. An evaluation's scratch tenant runs a pinned
        // policy that only the replaying engine knows: its proposals are claimed by that engine
        // alone, by tenant and subject.
        let due = rows(
            &tx,
            "SELECT c.seq, c.payload, c.attempts FROM mh_intake c \
             WHERE ((c.status = 'pending' AND c.run_after <= ?1) OR (c.status = 'running' AND c.locked_until < ?1)) \
               AND ((?2 IS NULL AND instr(c.tenant, ?4) = 0) OR (c.tenant = ?2 AND c.subject = ?3)) \
               AND NOT EXISTS (SELECT 1 FROM mh_intake o WHERE o.tenant = c.tenant AND o.subject = c.subject \
                               AND o.status IN ('pending', 'running') AND o.seq < c.seq) \
             ORDER BY c.seq LIMIT ?5",
            params![now, subject.map(|s| s.0), subject.map(|s| s.1), memhouse_core::eval::SCRATCH_MARK, limit as i64],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, i32>(2)?)),
        )?;
        let until = now.saturating_add((lease_secs as i64).saturating_mul(1_000_000));
        let mut jobs = Vec::with_capacity(due.len());
        for (seq, payload, attempts) in due {
            let payload = payload.ok_or_else(|| anyhow::anyhow!("a claimed proposal has no content"))?;
            exec(&tx, "UPDATE mh_intake SET status = 'running', attempts = attempts + 1, locked_until = ?2 WHERE seq = ?1", params![seq, until])?;
            jobs.push(IntakeJob { proposal: proposal_of(&payload)?, attempts: attempts + 1 });
        }
        tx.commit()?;
        Ok(jobs)
    }

    async fn finish(&self, id: Uuid, outcome: &serde_json::Value) -> anyhow::Result<()> {
        exec(
            &self.conn(),
            "UPDATE mh_intake SET status = 'done', finished_at = ?3, locked_until = NULL, payload = NULL, outcome = ?2 WHERE id = ?1 AND status IN ('pending', 'running')",
            params![id.to_string(), outcome.to_string(), now()],
        )?;
        Ok(())
    }

    async fn fail(&self, id: Uuid, attempt: i32, error: &str, dead: bool, keep_payload: bool) -> anyhow::Result<()> {
        // Backoff 0.5, 1, 2, 4 ... seconds, at most 30. A proposal that will be retried keeps its
        // content whatever `keep_payload` says. Only the attempt that holds the claim: a worker
        // whose lease expired must not reset a proposal another worker now runs.
        exec(
            &self.conn(),
            "UPDATE mh_intake SET status = CASE WHEN ?3 THEN 'dead' ELSE 'pending' END, locked_until = NULL, error = ?2, \
               run_after = ?6 + min((1 << min(attempts, 20)) * 250000, 30000000), \
               finished_at = CASE WHEN ?3 THEN ?6 END, payload = CASE WHEN ?4 OR NOT ?3 THEN payload END \
             WHERE id = ?1 AND status IN ('pending', 'running') AND attempts = ?5",
            params![id.to_string(), error, dead, keep_payload, attempt, now()],
        )?;
        Ok(())
    }

    async fn pending(&self, tenant: &str, record_id: Uuid) -> anyhow::Result<Option<Memory>> {
        let row = first(
            &self.conn(),
            concat!(
                "SELECT status, payload FROM mh_intake WHERE tenant = ?1 AND ",
                holds!(2),
                " AND status IN ('pending', 'running', 'dead') AND payload IS NOT NULL ORDER BY seq DESC LIMIT 1"
            ),
            params![tenant, record_id.to_string()],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )?;
        let Some((status, payload)) = row else { return Ok(None) };
        Ok(proposal_of(&payload)?.records.into_iter().find(|r| r.memory.id == record_id).map(|r| {
            let mut m = r.memory;
            if status == "dead" {
                m.status = MemoryStatus::Quarantined;
                m.metadata["quarantine_reasons"] = serde_json::json!(["intake_failed"]);
            }
            m
        }))
    }

    async fn pending_proposal(&self, tenant: &str, record_id: Uuid) -> anyhow::Result<Option<Uuid>> {
        first(
            &self.conn(),
            concat!("SELECT id FROM mh_intake WHERE tenant = ?1 AND ", holds!(2), " AND status IN ('pending', 'running') LIMIT 1"),
            params![tenant, record_id.to_string()],
            |r| uuid_of(&r.get::<_, String>(0)?),
        )
    }

    async fn unfinished(&self, id: Uuid) -> anyhow::Result<bool> {
        Ok(first(&self.conn(), "SELECT 1 FROM mh_intake WHERE id = ?1 AND status IN ('pending', 'running')", [id.to_string()], |_| Ok(()))?.is_some())
    }

    async fn subject_unfinished(&self, tenant: &str, subject: &str) -> anyhow::Result<bool> {
        Ok(first(&self.conn(), "SELECT 1 FROM mh_intake WHERE tenant = ?1 AND subject = ?2 AND status IN ('pending', 'running') LIMIT 1", [tenant, subject], |_| Ok(()))?.is_some())
    }

    async fn outcome(&self, id: Uuid) -> anyhow::Result<Option<serde_json::Value>> {
        first(&self.conn(), concat!("SELECT outcome FROM mh_intake WHERE (id = ?1 OR ", holds!(1), ") AND outcome IS NOT NULL LIMIT 1"), [id.to_string()], |r| {
            value(&r.get::<_, String>(0)?)
        })
    }

    async fn status(&self, tenant: Option<&str>) -> anyhow::Result<IntakeStatus> {
        let c = self.conn();
        let mut st = IntakeStatus::default();
        for (s, n) in
            rows(&c, "SELECT status, count(*) FROM mh_intake WHERE (?1 IS NULL OR tenant = ?1) GROUP BY status", [tenant], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
        {
            match s.as_str() {
                "pending" => st.pending = n,
                "running" => st.running = n,
                "done" => st.done = n,
                _ => st.dead = n,
            }
        }
        let oldest: Option<i64> =
            first(&c, "SELECT min(enqueued_at) FROM mh_intake WHERE (?1 IS NULL OR tenant = ?1) AND status IN ('pending', 'running')", [tenant], |r| Ok(r.get(0)?))?.flatten();
        st.oldest_pending_secs = oldest.map(|t| (now() - t) as f64 / 1e6);
        Ok(st)
    }

    async fn prune(&self, done_older_than_secs: u64) -> anyhow::Result<u64> {
        let before = now().saturating_sub((done_older_than_secs as i64).saturating_mul(1_000_000));
        // `<=`: with no age asked for, a proposal finished this very microsecond goes too.
        exec(&self.conn(), "DELETE FROM mh_intake WHERE status = 'done' AND finished_at <= ?1", [before])
    }

    async fn discard(&self, tenant: &str, scope: ForgetScope, value: &str) -> anyhow::Result<u64> {
        let mut c = self.conn();
        if scope == ForgetScope::Record {
            // One record leaves its proposal; the other records stay queued (or kept for the operator).
            let id: Uuid = value.parse()?;
            let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let held = rows(
                &tx,
                concat!(
                    "SELECT seq, record_ids, payload FROM mh_intake WHERE tenant = ?1 AND ",
                    holds!(2),
                    " AND payload IS NOT NULL AND status IN ('pending', 'running', 'dead')"
                ),
                params![tenant, id.to_string()],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
            )?;
            let mut n = 0;
            for (seq, record_ids, payload) in held {
                let left: Vec<Uuid> = uuids(&record_ids)?.into_iter().filter(|r| *r != id).collect();
                if left.is_empty() {
                    n += exec(&tx, "DELETE FROM mh_intake WHERE seq = ?1", [seq])?;
                    continue;
                }
                let mut payload = crate::util::value(&payload)?;
                if let Some(records) = payload["records"].as_array_mut() {
                    records.retain(|r| r["memory"]["id"].as_str() != Some(id.to_string().as_str()));
                }
                n += exec(&tx, "UPDATE mh_intake SET record_ids = ?2, payload = ?3 WHERE seq = ?1", params![seq, ids_json(&left), payload.to_string()])?;
            }
            // A promotion of this record that is still queued (or set aside with its content)
            // goes with it (MEM-05): it is no longer readable by its id, and never written.
            let promoted = drop_promotions_of(&tx, tenant, &HashSet::from([id]))?;
            tx.commit()?;
            return Ok(n + promoted);
        }
        let filter = match scope {
            ForgetScope::Subject => "subject = ?2",
            ForgetScope::Tenant => "?2 = ?2",
            ForgetScope::User => "(acting_user = ?2 OR scope_user = ?2)",
            ForgetScope::Agent => "(agent = ?2 OR scope_agent = ?2)",
            ForgetScope::Source => "source = ?2",
            ForgetScope::Record => unreachable!("handled above"),
        };
        exec(&c, &format!("DELETE FROM mh_intake WHERE tenant = ?1 AND {filter} AND (payload IS NOT NULL OR status IN ('pending', 'running'))"), [tenant, value])
    }
}
