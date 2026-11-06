// SPDX-License-Identifier: Apache-2.0
//! The write pipeline (G10). Every write goes through the same stages, in this order
//! (TR-IN-04):
//!
//! 1. **authorize**: [`crate::caller::Caller`] asks the authorizer (in the request);
//! 2. **redact**: personal data and secrets are removed from the text and from structured
//!    attributes (in the request, so nothing unredacted is ever written, not even to the queue);
//! 3. the redacted proposal is **queued** durably ([`IntakeQueue`]) and the write is answered
//!    with `candidate` (CORE-02, TR-LT-05);
//! 4. **classify and gate**: injection check, then the statement classifier (QUAL-02): facts,
//!    events, preferences and instructions are committed, plans and speculation held as
//!    candidates, corrections supersede what they correct;
//! 5. **route** by data type (HYB-01): narrative, fact, structured, relationship, code;
//! 6. **embed**;
//! 7. **insert**: duplicates, corrections and plan confirmations are resolved against what is
//!    stored, then everything is written in one transaction with the proposal's completion and
//!    its audit events ([`Store::apply_intake`]), so a proposal takes effect exactly once
//!    (TR-IN-03).
//!
//! Stages 4 to 7 run in a worker ([`JobRunner`]) or, right after the answer, in the request's own
//! task; a proposal left behind by a crash is claimed again when its lease expires, and one that
//! keeps failing is set aside and its records quarantined (TR-IN-07). Enrichment is a later stage
//! of the same pipeline: an ingested session's insert queues its enrichment job, and the facts it
//! extracts go through stages 4 to 7 like any write.

use crate::classify::{self, Classification};
use crate::engine::{content_hash, Engine};
use crate::error;
use crate::gate;
use crate::metrics;
use crate::policy::CompiledPolicy;
use crate::traits::IntakeQueue;
use crate::types::*;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tracing::Instrument;
use uuid::Uuid;

/// How a write enters the lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Entry {
    /// Committed once it passes the gate (operators, agents with a commit grant, users, admins).
    Commit,
    /// A proposal the engine admits as soon as it has passed the gate.
    ProposeAdmit,
    /// A proposal that waits for a reviewer (`access.admission = "review"`).
    Propose,
}

/// Which operation a proposal came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Op {
    Remember,
    Revise,
    Ingest,
}

/// A write between intake and the gate. It only ever holds redacted text (TR-IN-04).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Proposal {
    /// The proposal's id: the id of its first record.
    pub id: Uuid,
    pub tenant: String,
    pub subject: String,
    pub actor: String,
    #[serde(default)]
    pub user: Option<String>,
    pub source: String,
    pub op: Op,
    pub entry: Entry,
    pub records: Vec<PendingRecord>,
    /// Ingest: the session, the unit of enrichment.
    #[serde(default)]
    pub session_id: Option<String>,
    pub enqueued_at: DateTime<Utc>,
}

/// One record of a proposal, redacted, with `status: candidate`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingRecord {
    pub memory: Memory,
    pub content_hash: String,
    #[serde(default)]
    pub redactions: Vec<String>,
    /// The user's own words of a round, embedded as its second vector.
    #[serde(default)]
    pub focus: Option<String>,
    #[serde(default)]
    pub structured: Option<Structured>,
    #[serde(default)]
    pub code_refs: Vec<CodeRef>,
}

impl Proposal {
    pub fn record_ids(&self) -> Vec<Uuid> {
        self.records.iter().map(|r| r.memory.id).collect()
    }
}

/// A claimed proposal.
#[derive(Debug, Clone)]
pub struct IntakeJob {
    pub proposal: Proposal,
    /// Attempts so far, this one included.
    pub attempts: i32,
}

/// One audit event written with an insert.
#[derive(Debug, Clone, Serialize)]
pub struct AuditEntry {
    pub actor: String,
    pub action: String,
    pub subject: Option<String>,
    pub memory_id: Option<Uuid>,
    pub detail: serde_json::Value,
}

/// What the insert stage writes, in one transaction (see [`crate::Store::apply_intake`]).
#[derive(Debug, Clone, Default)]
pub struct IntakeWrite {
    /// The proposal this completes (none for facts from enrichment, whose job is the unit).
    pub proposal: Option<Uuid>,
    pub tenant: String,
    pub records: Vec<NewMemory>,
    /// (old, new): `old` must still be committed, else nothing is written.
    pub supersede: Vec<(Uuid, Uuid)>,
    /// Held candidates a completed event confirms: committed, their expiry cleared, with the
    /// confirming record's id in `metadata.confirmed_by`.
    pub confirm: Vec<(Uuid, Uuid)>,
    pub audit: Vec<AuditEntry>,
    /// Queue enrichment for these rounds: (subject, session id, round ids).
    pub enrich: Option<(String, String, Vec<Uuid>)>,
    /// Kept on the finished proposal for `outcome`.
    pub outcome: serde_json::Value,
    /// Set aside as poison with this error, its records stored as quarantined.
    pub dead: Option<String>,
}

/// A unit of background work the [`JobRunner`] repeats.
#[async_trait]
pub trait Job: Send + Sync + 'static {
    fn name(&self) -> &'static str;
    /// Do one unit of work; false when there was none to do.
    async fn run_once(&self) -> anyhow::Result<bool>;
}

/// Runs background jobs (ADR 0004): in-process workers now, a workflow engine at Scale (G31).
pub trait JobRunner: Send + Sync {
    fn name(&self) -> &'static str;
    /// Start `workers` loops of `job`; they stop when the runner is stopped.
    fn spawn(&self, job: Arc<dyn Job>, workers: usize) -> Vec<tokio::task::JoinHandle<()>>;
}

/// In-process workers on the Tokio runtime: each loops `run_once`, sleeping `idle` when there is
/// nothing to do and a second after an error.
pub struct LocalRunner {
    pub stop: Arc<AtomicBool>,
    pub idle: Duration,
}

impl LocalRunner {
    pub fn new(stop: Arc<AtomicBool>) -> LocalRunner {
        LocalRunner { stop, idle: Duration::from_millis(150) }
    }
}

impl JobRunner for LocalRunner {
    fn name(&self) -> &'static str {
        "local"
    }
    fn spawn(&self, job: Arc<dyn Job>, workers: usize) -> Vec<tokio::task::JoinHandle<()>> {
        (0..workers)
            .map(|w| {
                let (job, stop, idle) = (job.clone(), self.stop.clone(), self.idle);
                tokio::spawn(async move {
                    while !stop.load(Ordering::Relaxed) {
                        match job.run_once().await {
                            Ok(true) => {}
                            Ok(false) => tokio::time::sleep(idle).await,
                            Err(err) => {
                                tracing::warn!("{} worker {w}: {err:#}", job.name());
                                tokio::time::sleep(Duration::from_secs(1)).await;
                            }
                        }
                    }
                })
            })
            .collect()
    }
}

/// The pipeline worker: claims one proposal at a time; prunes finished ones now and then.
pub struct IntakeWorker {
    pub engine: Engine,
    last_prune: std::sync::Mutex<Instant>,
}

impl IntakeWorker {
    pub fn new(engine: Engine) -> IntakeWorker {
        IntakeWorker { engine, last_prune: std::sync::Mutex::new(Instant::now()) }
    }
}

#[async_trait]
impl Job for IntakeWorker {
    fn name(&self) -> &'static str {
        "intake"
    }
    async fn run_once(&self) -> anyhow::Result<bool> {
        let due = { self.last_prune.lock().map(|t| t.elapsed() > Duration::from_secs(60)).unwrap_or(false) };
        if due {
            if let Ok(mut t) = self.last_prune.lock() {
                *t = Instant::now();
            }
            self.engine.intake.prune(self.engine.cfg.intake.keep_done_secs).await?;
        }
        let e = &self.engine;
        let Some(job) = e.intake.claim(1, e.cfg.intake.lease_secs, None).await?.pop() else { return Ok(false) };
        e.process_job(job).await?;
        Ok(true)
    }
}

/// The queue used when the store has none: every write is refused as retryable (PERF-07).
pub struct NoQueue;

#[async_trait]
impl IntakeQueue for NoQueue {
    fn name(&self) -> &'static str {
        "none"
    }
    async fn enqueue(&self, _p: &Proposal) -> anyhow::Result<()> {
        Err(error::unavailable("this store has no intake queue"))
    }
    async fn claim(&self, _l: usize, _s: u64, _sub: Option<(&str, &str)>) -> anyhow::Result<Vec<IntakeJob>> {
        Ok(vec![])
    }
    async fn finish(&self, _id: Uuid, _o: &serde_json::Value) -> anyhow::Result<()> {
        Ok(())
    }
    async fn fail(&self, _id: Uuid, _e: &str, _d: bool, _k: bool) -> anyhow::Result<()> {
        Ok(())
    }
    async fn pending(&self, _t: &str, _id: Uuid) -> anyhow::Result<Option<Memory>> {
        Ok(None)
    }
    async fn pending_proposal(&self, _t: &str, _id: Uuid) -> anyhow::Result<Option<Uuid>> {
        Ok(None)
    }
    async fn unfinished(&self, _id: Uuid) -> anyhow::Result<bool> {
        Ok(false)
    }
    async fn outcome(&self, _id: Uuid) -> anyhow::Result<Option<serde_json::Value>> {
        Ok(None)
    }
    async fn status(&self, _t: Option<&str>) -> anyhow::Result<IntakeStatus> {
        Ok(IntakeStatus::default())
    }
    async fn prune(&self, _s: u64) -> anyhow::Result<u64> {
        Ok(0)
    }
    async fn discard(&self, _t: &str, _s: ForgetScope, _v: &str) -> anyhow::Result<u64> {
        Ok(0)
    }
}

/// A record on its way through stages 4 to 7.
pub(crate) struct Item {
    pub rec: NewMemory,
    pub focus: Option<String>,
    pub redactions: Vec<String>,
    /// Extracted by enrichment (derived facts supersede only derived facts).
    pub derived: bool,
    /// The extractor's own reading, when it gave one.
    pub hint: Option<Statement>,
    pub class: Option<Classification>,
    pub route: Route,
    /// Audit actions, in order, with the actor of each.
    pub actions: Vec<(&'static str, String)>,
    pub note: Option<String>,
    pub duplicate_of: Option<Uuid>,
    pub superseded: Option<Uuid>,
    pub confirms: Vec<Uuid>,
}

impl Item {
    pub fn new(rec: NewMemory, focus: Option<String>, redactions: Vec<String>) -> Item {
        Item {
            rec,
            focus,
            redactions,
            derived: false,
            hint: None,
            class: None,
            route: Route::Fact,
            actions: vec![],
            note: None,
            duplicate_of: None,
            superseded: None,
            confirms: vec![],
        }
    }
}

/// The record ids a write produced, and their state (for `wait`).
fn outcome_json(items: &[Item]) -> serde_json::Value {
    json!({ "records": items.iter().map(|i| json!({
        "id": i.rec.memory.id,
        "status": i.rec.memory.status.as_str(),
        "statement": i.class.as_ref().map(|c| c.statement.as_str()),
        "route": i.route.as_str(),
        "superseded": i.superseded,
        "duplicate_of": i.duplicate_of,
        "note": i.note,
    })).collect::<Vec<_>>() })
}

impl Engine {
    /// Stage 2: validate and redact a write's text under the policy (TR-IN-04).
    pub(crate) async fn redact(&self, policy: &CompiledPolicy, content: &str) -> anyhow::Result<(String, Vec<String>)> {
        let max = policy.policy.write_gate.max_content_chars;
        if content.trim().is_empty() {
            return Err(error::invalid("content is empty"));
        }
        if content.chars().count() > max {
            return Err(error::invalid(format!(
                "content is {} characters; the limit is {max} (write_gate.max_content_chars of policy {})",
                content.chars().count(),
                policy.version
            )));
        }
        // The compiler keeps "secret" in every policy (security baseline).
        self.pii.redact(content, &policy.policy.redaction.categories).await
    }

    /// Stage 2 for a structured form: every string attribute is redacted like text.
    pub(crate) async fn redact_attrs(&self, policy: &CompiledPolicy, v: &serde_json::Value, found: &mut Vec<String>) -> anyhow::Result<serde_json::Value> {
        Ok(match v {
            serde_json::Value::String(s) => {
                let (t, r) = self.pii.redact(s, &policy.policy.redaction.categories).await?;
                for c in r {
                    if !found.contains(&c) {
                        found.push(c);
                    }
                }
                serde_json::Value::String(t)
            }
            serde_json::Value::Array(a) => {
                let mut out = Vec::with_capacity(a.len());
                for x in a {
                    out.push(Box::pin(self.redact_attrs(policy, x, found)).await?);
                }
                serde_json::Value::Array(out)
            }
            serde_json::Value::Object(o) => {
                let mut out = serde_json::Map::new();
                for (k, x) in o {
                    out.insert(k.clone(), Box::pin(self.redact_attrs(policy, x, found)).await?);
                }
                serde_json::Value::Object(out)
            }
            v => v.clone(),
        })
    }

    /// Stage 3: queue the proposal durably. A queue that is down refuses the write as retryable
    /// (PERF-07); nothing is written.
    pub(crate) async fn enqueue(&self, p: &Proposal) -> anyhow::Result<()> {
        let t = Instant::now();
        let r = self.intake.enqueue(p).instrument(tracing::info_span!("intake.enqueue", records = p.records.len())).await;
        metrics::observe("memhouse_intake_ack_seconds", &[], t.elapsed().as_secs_f64());
        r.map_err(|e| {
            metrics::inc("memhouse_intake_refused_total", &[], 1.0);
            if error::code_of(&e) != error::ErrorCode::Internal {
                e
            } else {
                error::unavailable(format!("the write could not be queued, so nothing was stored; retry: {e:#}"))
            }
        })
    }

    /// After the answer: run the rest of the pipeline for the subject's queue in this process, so
    /// a write is recallable in milliseconds without waiting for a worker (PERF-04). Workers pick
    /// up whatever this leaves (a crash, a timeout).
    pub(crate) fn nudge(&self, tenant: &str, subject: &str, id: Uuid) {
        if !self.inline_intake {
            return;
        }
        let (e, tenant, subject) = (self.clone(), tenant.to_string(), subject.to_string());
        let timeout = Duration::from_millis(self.cfg.intake.wait_timeout_ms.max(1000));
        tokio::spawn(async move {
            if let Err(err) = e.settle(&tenant, &subject, id, timeout).await {
                tracing::warn!("intake of {id} left to the workers: {err:#}");
            }
        });
    }

    /// Run the subject's queued proposals here until `id` is through the pipeline or `timeout`
    /// passes. Proposals of a subject run in order, so this also finishes earlier ones.
    pub async fn settle(&self, tenant: &str, subject: &str, id: Uuid, timeout: Duration) -> anyhow::Result<bool> {
        let deadline = Instant::now() + timeout;
        loop {
            if !self.intake.unfinished(id).await? {
                return Ok(true);
            }
            match self.intake.claim(1, self.cfg.intake.lease_secs, Some((tenant, subject))).await?.pop() {
                Some(job) => {
                    let own = job.proposal.id == id;
                    // This write's own attempt failed: answer now (still a candidate); the
                    // retries run in the background.
                    if !self.process_job(job).await? && own {
                        return Ok(false);
                    }
                }
                None => tokio::time::sleep(Duration::from_millis(20)).await,
            }
            if Instant::now() > deadline {
                return Ok(!self.intake.unfinished(id).await?);
            }
        }
    }

    /// Wait for every queued proposal of a subject (benchmarks, tests, `forget`).
    pub async fn settle_subject(&self, tenant: Option<String>, subject: &str, timeout: Duration) -> anyhow::Result<bool> {
        let tenant = self.tenant(&tenant);
        let deadline = Instant::now() + timeout;
        loop {
            match self.intake.claim(1, self.cfg.intake.lease_secs, Some((&tenant, subject))).await?.pop() {
                Some(job) => {
                    self.process_job(job).await?;
                }
                None => {
                    let st = self.intake.status(Some(&tenant)).await?;
                    if st.pending + st.running == 0 {
                        return Ok(true);
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            }
            if Instant::now() > deadline {
                return Ok(false);
            }
        }
    }

    /// Stages 4 to 7 for one claimed proposal, then its completion; a failure is retried after a
    /// backoff, and after `intake.max_attempts` the proposal is set aside as poison and its records
    /// stored as quarantined, so it never blocks its subject (TR-IN-07).
    /// Returns whether the pipeline succeeded.
    pub async fn process_job(&self, job: IntakeJob) -> anyhow::Result<bool> {
        let p = &job.proposal;
        let span = tracing::info_span!("memhouse.intake", memhouse.proposal = %p.id, memhouse.subject = %p.subject, memhouse.attempt = job.attempts, memhouse.records = p.records.len(), otel.status_code = tracing::field::Empty);
        let start = Instant::now();
        match self.run_pipeline(p).instrument(span.clone()).await {
            Ok(outcome) => {
                self.intake.finish(p.id, &outcome).await?;
                metrics::inc("memhouse_intake_total", &[("outcome", "ok")], 1.0);
                metrics::observe("memhouse_intake_duration_seconds", &[], start.elapsed().as_secs_f64());
                let lag = (Utc::now() - p.enqueued_at).num_milliseconds().max(0) as f64 / 1000.0;
                metrics::observe("memhouse_intake_freshness_seconds", &[], lag);
                Ok(true)
            }
            Err(e) => {
                span.record("otel.status_code", "ERROR");
                let msg = format!("{e:#}");
                let dead = job.attempts >= self.cfg.intake.max_attempts.max(1);
                // The error names the stage and the provider's status, never the content.
                tracing::error!("intake of {} failed (attempt {}{}): {msg}", p.id, job.attempts, if dead { ", set aside" } else { "" });
                metrics::inc("memhouse_intake_total", &[("outcome", if dead { "dead" } else { "retry" })], 1.0);
                if dead {
                    let stored = self.quarantine_poison(p, &msg).await;
                    if let Err(qe) = &stored {
                        tracing::error!("poison proposal {} could not be stored as quarantined: {qe:#}", p.id);
                    }
                    if !matches!(stored, Ok(true)) {
                        self.intake.fail(p.id, &msg, true, true).await?;
                    }
                } else {
                    self.intake.fail(p.id, &msg, false, true).await?;
                }
                Ok(false)
            }
        }
    }

    /// A poison proposal's records, stored as quarantined without vectors, for a reviewer.
    async fn quarantine_poison(&self, p: &Proposal, error: &str) -> anyhow::Result<bool> {
        let mut records = vec![];
        let mut audit = vec![];
        for r in &p.records {
            let mut m = r.memory.clone();
            m.status = MemoryStatus::Quarantined;
            m.metadata["quarantine_reasons"] = json!(["intake_failed"]);
            m.metadata["intake_error"] = json!(error.chars().take(500).collect::<String>());
            audit.push(AuditEntry {
                actor: "engine".into(),
                action: "memory.quarantine".into(),
                subject: Some(p.subject.clone()),
                memory_id: Some(m.id),
                detail: json!({ "reason": "intake_failed", "proposal": p.id }),
            });
            let mut rec = NewMemory::new(m, r.content_hash.clone());
            rec.structured = r.structured.clone();
            rec.code_refs = r.code_refs.clone();
            records.push(rec);
        }
        let w =
            IntakeWrite { proposal: Some(p.id), tenant: p.tenant.clone(), records, audit, dead: Some(error.to_string()), outcome: json!({ "dead": true }), ..Default::default() };
        self.store.apply_intake(&w).await
    }

    /// Stages 4 to 7 for one proposal. Returns the outcome kept on the finished proposal.
    pub(crate) async fn run_pipeline(&self, p: &Proposal) -> anyhow::Result<serde_json::Value> {
        let policy = self.policy_for(&p.tenant).await?;
        let mut items: Vec<Item> = p
            .records
            .iter()
            .map(|r| {
                let mut rec = NewMemory::new(r.memory.clone(), r.content_hash.clone());
                rec.structured = r.structured.clone();
                rec.code_refs = r.code_refs.clone();
                Item::new(rec, r.focus.clone(), r.redactions.clone())
            })
            .collect();
        self.gate_stage(p.entry, &mut items).instrument(tracing::info_span!("intake.gate")).await?;
        Self::route_stage(&mut items);
        self.embed_stage(&mut items).instrument(tracing::info_span!("intake.embed")).await?;
        let (supersede, confirm) = self.resolve_stage(&policy, &p.tenant, &p.subject, p.entry, &mut items).instrument(tracing::info_span!("intake.resolve")).await?;
        let mut audit = vec![];
        let mut enrich = None;
        if p.op == Op::Ingest {
            let quarantined = items.iter().filter(|i| i.rec.memory.status == MemoryStatus::Quarantined).count();
            let committed: Vec<Uuid> = items.iter().filter(|i| i.rec.memory.status == MemoryStatus::Committed).map(|i| i.rec.memory.id).collect();
            // Proposed rounds are admitted by the engine at once: a conversation is a record of
            // what was said, not a claim to review.
            if p.entry != Entry::Commit && !committed.is_empty() {
                audit.push(AuditEntry {
                    actor: p.actor.clone(),
                    action: "memory.propose".into(),
                    subject: Some(p.subject.clone()),
                    memory_id: None,
                    detail: json!({ "records": committed.len() }),
                });
                audit.push(AuditEntry {
                    actor: "engine".into(),
                    action: "memory.admit".into(),
                    subject: Some(p.subject.clone()),
                    memory_id: None,
                    detail: json!({ "records": committed.len() }),
                });
            }
            audit.push(AuditEntry {
                actor: p.actor.clone(),
                action: "memory.ingest".into(),
                subject: Some(p.subject.clone()),
                memory_id: None,
                detail: json!({ "session": p.session_id, "records": items.len(), "quarantined": quarantined }),
            });
            if self.cfg.enrich.enabled && !committed.is_empty() {
                enrich = Some((p.subject.clone(), p.session_id.clone().unwrap_or_else(|| p.id.to_string()), committed));
            }
        } else {
            audit = self.record_audit(&items, &p.subject);
        }
        let outcome = outcome_json(&items);
        let w = IntakeWrite {
            proposal: Some(p.id),
            tenant: p.tenant.clone(),
            records: items.into_iter().map(|i| i.rec).collect(),
            supersede,
            confirm,
            audit,
            enrich,
            outcome: outcome.clone(),
            dead: None,
        };
        let applied = self.store.apply_intake(&w).instrument(tracing::info_span!("intake.insert", rows = w.records.len())).await?;
        if applied {
            for r in &w.records {
                metrics::inc("memhouse_writes_total", &[("status", r.memory.status.as_str())], 1.0);
            }
        }
        Ok(outcome)
    }

    /// Stage 4: the injection check, then the statement classifier, then the state each record
    /// takes (QUAL-02). Conversation rounds are a record of what was said: they are screened for
    /// injection but not classified.
    pub(crate) async fn gate_stage(&self, entry: Entry, items: &mut [Item]) -> anyhow::Result<()> {
        for it in items.iter_mut() {
            let m = &mut it.rec.memory;
            let reasons = gate::injection(&m.content);
            if m.kind != MemoryKind::Episodic {
                let mut c = self.classifier.classify(&m.content, m.kind).await?;
                // The extractor's reading wins over a plain "fact" or "event" from the rules.
                if let Some(h) = it.hint {
                    if matches!(c.statement, Statement::Fact | Statement::Event) || h == Statement::Plan {
                        if h != c.statement {
                            c = Classification { statement: h, confidence: c.confidence, reason: format!("extractor: {}", h.as_str()) };
                        }
                    }
                }
                metrics::inc("memhouse_gate_statements_total", &[("statement", c.statement.as_str())], 1.0);
                m.metadata["statement"] = json!(c.statement.as_str());
                it.class = Some(c);
            }
            let statement = it.class.as_ref().map(|c| c.statement);
            // An open item the caller chose to track is a commitment, not a claim about now.
            let open_item = m.kind == MemoryKind::Commitment && !it.derived;
            m.status = if !reasons.is_empty() {
                m.metadata["quarantine_reasons"] = json!(reasons);
                it.note = Some(format!("quarantined: looks like an instruction to the agent ({})", reasons.join(", ")));
                MemoryStatus::Quarantined
            } else if entry == Entry::Propose && m.kind != MemoryKind::Episodic {
                it.note = Some("waiting for a reviewer".into());
                MemoryStatus::Candidate
            } else if statement.is_some_and(|s| s.held()) && !open_item {
                let s = statement.expect("held");
                // Held until confirmed or expired (PR-7): by its own end date, else the TTL.
                if m.expires_at.is_none() {
                    let base = m.occurred_at.unwrap_or(m.created_at).max(m.created_at);
                    m.expires_at = Some(m.valid_to.unwrap_or(base + chrono::Duration::days(self.cfg.intake.plan_ttl_days.max(1) as i64)));
                }
                it.note = Some(format!("held as a candidate: reads as {} (QUAL-02); recalled only with include_candidates until confirmed", s.as_str()));
                MemoryStatus::Candidate
            } else {
                MemoryStatus::Committed
            };
        }
        Ok(())
    }

    /// Stage 5: the representation of each record (HYB-01).
    pub(crate) fn route_stage(items: &mut [Item]) {
        for it in items.iter_mut() {
            let m = &mut it.rec.memory;
            it.route = classify::route(m.kind, &m.content, it.rec.structured.is_some(), !it.rec.code_refs.is_empty());
            if m.kind != MemoryKind::Episodic {
                m.metadata["route"] = json!(it.route.as_str());
            }
            if it.route == Route::Code && !m.tags.iter().any(|t| t == "code") {
                m.tags.push("code".into());
            }
        }
    }

    /// Stage 6: vectors for every record, and the user-only vector of rounds that have one.
    pub(crate) async fn embed_stage(&self, items: &mut [Item]) -> anyhow::Result<()> {
        if items.is_empty() {
            return Ok(());
        }
        let n = items.len();
        let mut texts: Vec<String> = items.iter().map(|i| i.rec.memory.content.clone()).collect();
        let focus: Vec<(usize, String)> = items.iter().enumerate().filter_map(|(i, it)| it.focus.clone().map(|f| (i, f))).collect();
        texts.extend(focus.iter().map(|(_, f)| f.clone()));
        let mut vecs = self.embed_passages(&texts).await?;
        let focus_vecs = vecs.split_off(n);
        for (it, v) in items.iter_mut().zip(vecs) {
            it.rec.embedding = Some(v);
        }
        let prefix = self.cfg.embedding.passage_prefix.clone().unwrap_or_default();
        for ((i, f), v) in focus.into_iter().zip(focus_vecs) {
            items[i].rec.alt = Some((content_hash(&format!("{prefix}{f}")), v));
        }
        Ok(())
    }

    /// Stage 7, first half: settle each record against what is stored: an explicit revision
    /// supersedes its predecessor (or is rejected when that is no longer current); a near-duplicate
    /// is rejected; a correction supersedes the closest record it corrects (QUAL-01: never a
    /// silent overwrite: the old version stays, superseded and linked); a completed event confirms
    /// the held plans it fulfils. Returns the supersessions and confirmations to write.
    pub(crate) async fn resolve_stage(
        &self,
        policy: &CompiledPolicy,
        tenant: &str,
        subject: &str,
        entry: Entry,
        items: &mut [Item],
    ) -> anyhow::Result<(Vec<(Uuid, Uuid)>, Vec<(Uuid, Uuid)>)> {
        let mut supersede = vec![];
        let mut confirm = vec![];
        let icfg = &self.cfg.intake;
        for it in items.iter_mut() {
            let m = &mut it.rec.memory;
            let class = it.class.as_ref().map(|c| c.statement);
            let actor = m.provenance.agent.clone().unwrap_or_else(|| m.source.clone());
            if m.kind == MemoryKind::Episodic {
                continue;
            }
            if let Some(old) = m.supersedes {
                // Explicit revision (CORE-04). A proposal waiting for review supersedes on admission.
                if m.status == MemoryStatus::Committed {
                    match self.store.get(tenant, old).await? {
                        Some(o) if o.status == MemoryStatus::Committed => {
                            supersede.push((old, m.id));
                            it.superseded = Some(old);
                        }
                        _ => {
                            m.status = MemoryStatus::Rejected;
                            it.note = Some("rejected: the version it revises is no longer current".into());
                        }
                    }
                }
            } else if m.status != MemoryStatus::Quarantined {
                if let Some(emb) = it.rec.embedding.clone() {
                    let nearest = self.store.nearest(tenant, subject, m.kind, &emb).await?;
                    // A structured record is told apart by its attributes, not its wording.
                    let comparable = it.route != Route::Structured;
                    if let Some((dup, sim)) = nearest.filter(|(_, s)| comparable && *s >= policy.policy.write_gate.dedup_threshold) {
                        m.status = MemoryStatus::Rejected;
                        m.metadata["duplicate_of"] = json!(dup);
                        it.duplicate_of = Some(dup);
                        it.note = Some(format!("near-duplicate of an existing memory (similarity {sim:.3})"));
                    } else if class == Some(Statement::Correction) && m.status == MemoryStatus::Committed {
                        if let Some((old, sim)) = nearest.filter(|(_, s)| *s >= icfg.correction_threshold) {
                            if let Some(o) = self.store.get(tenant, old).await? {
                                let older = o.occurred_at.unwrap_or(o.created_at) <= m.occurred_at.unwrap_or(m.created_at);
                                let derived_ok = !it.derived || o.metadata.get("derived").and_then(|d| d.as_bool()).unwrap_or(false);
                                let fresh = !supersede.iter().any(|(s, _)| *s == old);
                                if o.status == MemoryStatus::Committed && older && derived_ok && fresh && classify::shares_content_word(&o.content, &m.content) {
                                    m.supersedes = Some(old);
                                    supersede.push((old, m.id));
                                    it.superseded = Some(old);
                                    it.note = Some(format!("corrects {old} (similarity {sim:.3}), which it supersedes"));
                                    metrics::inc("memhouse_gate_corrections_total", &[], 1.0);
                                }
                            }
                        }
                    }
                    if class == Some(Statement::Event) && m.status == MemoryStatus::Committed {
                        for (plan, sim) in self.store.nearest_held(tenant, subject, &emb, 3).await? {
                            let Some(pm) = self.store.get(tenant, plan).await? else { continue };
                            if sim >= icfg.confirm_threshold && classify::shares_content_word(&pm.content, &m.content) && !confirm.iter().any(|(p, _)| *p == plan) {
                                confirm.push((plan, m.id));
                                it.confirms.push(plan);
                            }
                        }
                    }
                }
            }
            // The audit trail of the record's way in.
            let proposed = entry != Entry::Commit || m.status == MemoryStatus::Candidate;
            if proposed {
                it.actions.push(("memory.propose", actor.clone()));
            }
            match m.status {
                MemoryStatus::Rejected => it.actions.push(("memory.reject", "engine".into())),
                MemoryStatus::Committed if it.superseded.is_some() => {
                    if entry != Entry::Commit {
                        it.actions.push(("memory.admit", "engine".into()));
                    }
                    it.actions.push(("memory.supersede", actor.clone()));
                }
                MemoryStatus::Committed if entry != Entry::Commit => it.actions.push(("memory.admit", "engine".into())),
                MemoryStatus::Committed | MemoryStatus::Quarantined => it.actions.push(("memory.write", actor.clone())),
                _ => {}
            }
        }
        Ok((supersede, confirm))
    }

    /// The audit events of single writes (remember, revise, enrichment facts).
    pub(crate) fn record_audit(&self, items: &[Item], subject: &str) -> Vec<AuditEntry> {
        let mut out = vec![];
        for it in items {
            let m = &it.rec.memory;
            for (action, actor) in &it.actions {
                let mut detail = json!({
                    "kind": m.kind.as_str(),
                    "status": m.status.as_str(),
                    "redactions": it.redactions,
                    "supersedes": it.superseded,
                    "embedder": self.embedder.id(),
                    "route": it.route.as_str(),
                });
                if let Some(c) = &it.class {
                    detail["statement"] = json!(c.statement.as_str());
                    detail["classifier"] = json!(c.reason);
                }
                if *action == "memory.reject" {
                    detail["reason"] = json!(it.note.clone().unwrap_or_default());
                    if let Some(d) = it.duplicate_of {
                        detail["duplicate_of"] = json!(d);
                    }
                }
                out.push(AuditEntry { actor: actor.clone(), action: (*action).into(), subject: Some(subject.to_string()), memory_id: Some(m.id), detail });
            }
            for plan in &it.confirms {
                out.push(AuditEntry {
                    actor: "engine".into(),
                    action: "memory.admit".into(),
                    subject: Some(subject.to_string()),
                    memory_id: Some(*plan),
                    detail: json!({ "confirmed_by": m.id, "reason": "a completed event confirms the plan" }),
                });
            }
        }
        out
    }

    /// The intake queue's backlog (TR-IN-06).
    pub async fn intake_status(&self, tenant: Option<&str>) -> anyhow::Result<IntakeStatus> {
        self.intake.status(tenant).await
    }

    /// Start `n` pipeline workers until `stop` is set.
    pub fn spawn_intake(&self, n: usize, stop: Arc<AtomicBool>) -> Vec<tokio::task::JoinHandle<()>> {
        LocalRunner::new(stop).spawn(Arc::new(IntakeWorker::new(self.clone())), n)
    }

    /// What a write became, for an answer with `wait`.
    pub(crate) async fn result_of(&self, tenant: &str, id: Uuid, redactions: Vec<String>) -> anyhow::Result<RememberResult> {
        let Some(m) = self.store.get(tenant, id).await? else {
            let status = self.intake.pending(tenant, id).await?.map(|m| m.status).unwrap_or(MemoryStatus::Candidate);
            return Ok(RememberResult {
                id,
                status,
                deduplicated: false,
                redactions,
                superseded: None,
                note: Some("still in the intake queue".into()),
                statement: None,
                route: None,
            });
        };
        let statement = m.metadata.get("statement").and_then(|s| s.as_str()).and_then(Statement::parse);
        let route = m.metadata.get("route").and_then(|s| serde_json::from_value(s.clone()).ok());
        let outcome = self.intake.outcome(id).await.ok().flatten();
        let note =
            outcome.as_ref().and_then(|o| o["records"].as_array().and_then(|rs| rs.iter().find(|r| r["id"] == json!(id)).and_then(|r| r["note"].as_str().map(String::from))));
        if let Some(dup) = m.metadata.get("duplicate_of").and_then(|d| serde_json::from_value::<Uuid>(d.clone()).ok()) {
            let status = self.store.get(tenant, dup).await?.map(|d| d.status).unwrap_or(MemoryStatus::Committed);
            return Ok(RememberResult { id: dup, status, deduplicated: true, redactions, superseded: None, note, statement, route });
        }
        let superseded = m.supersedes.filter(|_| m.status == MemoryStatus::Committed);
        let note = note.or_else(|| match m.status {
            MemoryStatus::Quarantined => m.metadata.get("quarantine_reasons").map(|r| {
                format!(
                    "quarantined: looks like an instruction to the agent ({})",
                    r.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default()
                )
            }),
            _ => None,
        });
        Ok(RememberResult { id, status: m.status, deduplicated: false, redactions, superseded, note, statement, route })
    }
}
