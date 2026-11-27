// SPDX-License-Identifier: Apache-2.0
//! Governance II (G22): legal hold (GOV-09), the deletion workflow and its completion
//! certificate (GOV-07, TR-WF-01), retention per type and scope (GOV-06), jobs that resume
//! without duplicate effects (TR-WF-02), the deletion ledger as it is exported and re-applied
//! (TR-WF-03) and audit-head anchoring (GOV-12).
//!
//! Nothing here holds memory content: a hold, a deletion request, a certificate and an anchor
//! carry identifiers, counts and hashes only (PR-3).

use crate::engine::Engine;
use crate::error;
use crate::intake::AuditEntry;
use crate::types::*;
use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// What a legal hold can be placed on (GOV-09): a data subject, a user, an agent, a source, a
/// scope level (org, team, session) or the whole tenant.
pub const HOLD_KINDS: [&str; 8] = ["subject", "user", "agent", "source", "org", "team", "session", "tenant"];

/// A legal hold: while it is active, every record it matches is exempt from retention and from
/// deletion, and a deletion that met it is carried out when it is released (GOV-09).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct LegalHold {
    pub id: Uuid,
    pub tenant: String,
    /// One of [`HOLD_KINDS`].
    pub target_kind: String,
    /// The subject, user, agent, source, org, team or session held; the tenant for `tenant`.
    pub target: String,
    /// Why it was placed (a matter or case reference; never memory content).
    pub reason: String,
    pub placed_by: String,
    pub placed_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub released_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub released_at: Option<DateTime<Utc>>,
}

impl LegalHold {
    pub fn active(&self) -> bool {
        self.released_at.is_none()
    }

    /// Whether the hold, if active, keeps this record: the rule of [`HELD_SQL`], on a record
    /// already read.
    pub fn holds(&self, m: &Memory) -> bool {
        let is = |v: &Option<String>| v.as_deref() == Some(self.target.as_str());
        self.active()
            && self.tenant == m.tenant
            && match self.target_kind.as_str() {
                "tenant" => true,
                "subject" => self.target == m.subject,
                "user" => is(&m.provenance.user) || is(&m.scope.user),
                "agent" => is(&m.provenance.agent) || is(&m.scope.agent),
                "source" => self.target == m.source,
                "org" => is(&m.scope.org),
                "team" => is(&m.scope.team),
                "session" => is(&m.scope.session),
                _ => false,
            }
    }
}

/// The SQL condition, over the memory table under the alias `m`, of "an active legal hold
/// matches this row". The same text in both stores (TR-CORE-04): a user hold matches what a
/// `forget` by user matches, and so on for agent and source.
pub const HELD_SQL: &str = "EXISTS (SELECT 1 FROM mh_legal_hold h WHERE h.tenant = m.tenant AND h.released_at IS NULL AND ( \
       h.target_kind = 'tenant' \
    OR (h.target_kind = 'subject' AND h.target = m.subject) \
    OR (h.target_kind = 'user' AND (h.target = m.prov_user OR h.target = m.scope_user)) \
    OR (h.target_kind = 'agent' AND (h.target = m.prov_agent OR h.target = m.scope_agent)) \
    OR (h.target_kind = 'source' AND h.target = m.source) \
    OR (h.target_kind = 'org' AND h.target = m.scope_org) \
    OR (h.target_kind = 'team' AND h.target = m.scope_team) \
    OR (h.target_kind = 'session' AND h.target = m.scope_session)))";

/// A scope level a retention rule can name (GOV-06): the subject, or a level of the record's scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ScopeLevel {
    // In order of precedence: where two rules match one record, the more specific level wins.
    Session,
    User,
    Agent,
    Team,
    Org,
    Subject,
}

impl ScopeLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            ScopeLevel::Session => "session",
            ScopeLevel::User => "user",
            ScopeLevel::Agent => "agent",
            ScopeLevel::Team => "team",
            ScopeLevel::Org => "org",
            ScopeLevel::Subject => "subject",
        }
    }

    /// The column of the memory table the level is stored in (both stores).
    pub fn column(&self) -> &'static str {
        match self {
            ScopeLevel::Session => "scope_session",
            ScopeLevel::User => "scope_user",
            ScopeLevel::Agent => "scope_agent",
            ScopeLevel::Team => "scope_team",
            ScopeLevel::Org => "scope_org",
            ScopeLevel::Subject => "subject",
        }
    }
}

/// One scope a retention rule applies to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ScopeMatch {
    pub level: ScopeLevel,
    pub value: String,
}

/// Which records of a kind a purge takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PurgeAge {
    /// Written more than this many days ago (`created_at`).
    OlderThanDays(u32),
    /// Past their own `expires_at`: working memory after its session's TTL (MEM-01).
    Expired,
}

/// One retention rule as the store carries it out (GOV-06).
#[derive(Debug, Clone)]
pub struct PurgeSpec {
    pub kind: MemoryKind,
    pub age: PurgeAge,
    /// Only records of this scope; none for the type's own rule.
    pub scope: Option<ScopeMatch>,
    /// Not records of these scopes: they have a rule of their own.
    pub except: Vec<ScopeMatch>,
    /// The job run and step the purge belongs to: each batch adds its count to the run in its
    /// own transaction, so a run that is killed and resumed counts every record once (TR-WF-02).
    pub run: Option<(Uuid, String)>,
    /// Stop after this many batches (a pass may be bounded; the next one continues).
    pub max_batches: Option<usize>,
}

impl PurgeSpec {
    pub fn older_than(kind: MemoryKind, days: u32) -> PurgeSpec {
        PurgeSpec { kind, age: PurgeAge::OlderThanDays(days), scope: None, except: vec![], run: None, max_batches: None }
    }

    pub fn expired(kind: MemoryKind) -> PurgeSpec {
        PurgeSpec { kind, age: PurgeAge::Expired, scope: None, except: vec![], run: None, max_batches: None }
    }

    /// A rule the pre-G22 `purge_older_than` can carry out: a type's own rule, with no scope
    /// and no exception. (Its run and its batch bound are a durable store's concern.)
    pub fn is_plain(&self) -> Option<u32> {
        match self.age {
            PurgeAge::OlderThanDays(d) if self.scope.is_none() && self.except.is_empty() => Some(d),
            _ => None,
        }
    }
}

/// How long a recovery pass over a tenant's open deletions holds its lease without renewing it.
const RECOVERY_LEASE_SECS: i64 = 600;

/// The lease of one recovery pass: the key, this pass's holder id, and the value it last wrote
/// (what a renewal and the release compare with).
pub(crate) struct RecoveryLease {
    key: String,
    holder: String,
    value: std::sync::Mutex<String>,
}

/// What a purge did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct PurgeOutcome {
    /// Records removed, with the facts derived from them.
    pub records: u64,
    /// Monthly partitions dropped whole instead of deleting their rows (TR-DB-04).
    pub partitions_dropped: u64,
    /// Records the rule matches that a legal hold keeps (GOV-09).
    pub held: u64,
    /// False when `max_batches` stopped the purge before it ran out of records.
    pub complete: bool,
}

/// A durable job run (TR-WF-02): retention keeps its progress here, so a run that a restart
/// interrupts is continued, and each step's audit event is written exactly once.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRun {
    pub id: Uuid,
    pub tenant: String,
    pub job: String,
    /// `{"counts": {step: records}, "done": [step, ...]}`.
    pub state: serde_json::Value,
    pub started_at: DateTime<Utc>,
    /// True when this run was begun earlier and not finished.
    #[serde(default)]
    pub resumed: bool,
}

impl JobRun {
    /// Records the run has removed in a step, over every attempt.
    pub fn count(&self, step: &str) -> u64 {
        self.state.get("counts").and_then(|c| c.get(step)).and_then(|v| v.as_u64()).unwrap_or(0)
    }

    pub fn step_done(&self, step: &str) -> bool {
        self.state.get("done").and_then(|d| d.as_array()).is_some_and(|d| d.iter().any(|s| s.as_str() == Some(step)))
    }
}

/// One row of the deletion ledger, as it is exported and re-applied after a restore (TR-WF-03).
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

/// What re-applying a ledger did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reapplied {
    /// Rows given.
    pub given: u64,
    /// Rows the database already had: deletions made before its backup was taken.
    pub known: u64,
    /// Rows applied and added to the database's ledger.
    pub applied: u64,
    /// Records those rows removed, with what was derived from them.
    pub records_removed: u64,
}

/// The newest event of the audit chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct AuditHead {
    pub id: i64,
    pub hash: String,
    pub at: DateTime<Utc>,
}

/// The audit head as it is recorded outside the database (GOV-12): a later verification must
/// find event `event_id` with exactly this hash, or the chain was rewritten since.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct AuditAnchor {
    /// `memhouse.audit-anchor`.
    pub format: String,
    pub version: u32,
    /// The installation's id (`mh_meta.instance_id`): an anchor is only compared with the
    /// database it was taken from.
    pub instance: String,
    pub event_id: i64,
    pub hash: String,
    /// When that event was written.
    pub event_at: DateTime<Utc>,
    pub anchored_at: DateTime<Utc>,
    pub anchored_by: String,
}

pub const ANCHOR_FORMAT: &str = "memhouse.audit-anchor";

/// One anchor compared with the chain.
#[derive(Debug, Clone, Serialize)]
pub struct AnchorCheck {
    pub event_id: i64,
    pub anchored_at: DateTime<Utc>,
    /// `match`, `mismatch` (the event has another hash), `missing` (no such event) or
    /// `other_instance` (the anchor is another installation's).
    pub result: &'static str,
}

/// A record sampled before a deletion, looked for afterwards in every representation
/// (TR-WF-01): identifiers and hashes, never content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Canary {
    pub id: Uuid,
    pub subject: String,
    /// The keys of its cached vectors (the passage and, for a round, the user's own words).
    #[serde(default)]
    pub vector_hashes: Vec<String>,
}

/// Where the canaries of a deletion were still found: all zero when the deletion is complete.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct CanaryReport {
    /// The records themselves.
    pub records: u64,
    /// Structured forms, code references and links stored under their ids.
    pub representations: u64,
    /// Cached vectors of their text.
    pub cached_vectors: u64,
    /// Facts extracted from them and records promoted from them.
    pub derived: u64,
    /// Queued writes that still hold them.
    pub queued: u64,
    /// Extraction jobs that read them (and with them the cached extraction).
    pub jobs: u64,
}

impl CanaryReport {
    pub fn total(&self) -> u64 {
        self.records + self.representations + self.cached_vectors + self.derived + self.queued + self.jobs
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DeletionStatus {
    /// Accepted; being carried out (or interrupted: the next pass continues it).
    Running,
    /// Carried out except for records under a legal hold; completed when the hold is released.
    Held,
    /// Carried out and verified; the certificate is issued.
    Completed,
}

impl DeletionStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeletionStatus::Running => "running",
            DeletionStatus::Held => "held",
            DeletionStatus::Completed => "completed",
        }
    }

    pub fn parse(s: &str) -> Option<DeletionStatus> {
        Some(match s {
            "running" => DeletionStatus::Running,
            "held" => DeletionStatus::Held,
            "completed" => DeletionStatus::Completed,
            _ => return None,
        })
    }
}

/// A deletion request as the workflow tracks it from `forget` to its certificate (TR-WF-01).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct DeletionRequest {
    pub id: Uuid,
    pub tenant: String,
    pub scope: ForgetScope,
    /// The id, subject, user, agent, source or tenant named.
    pub value: String,
    pub actor: String,
    pub requested_at: DateTime<Utc>,
    pub status: DeletionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<DateTime<Utc>>,
    /// Records deleted so far, over every execution.
    pub deleted: u64,
    /// Records still kept by a legal hold.
    pub held: u64,
    /// Times the deletion was carried out (more than one after a hold or an interruption).
    pub executions: u32,
    /// The records sampled before the first execution.
    #[serde(default)]
    pub canaries: Vec<Canary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub certificate: Option<DeletionCertificate>,
}

pub const CERTIFICATE_FORMAT: &str = "memhouse.deletion-certificate";

/// The completion certificate of a deletion (GOV-07, TR-WF-01): what was asked, what was
/// removed, and where the sampled records were looked for afterwards. `hash` covers every other
/// field, and the `deletion.certificate` audit event carries it, so the certificate is bound
/// into the tamper-evident chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DeletionCertificate {
    pub format: String,
    pub version: u32,
    pub request_id: Uuid,
    pub tenant: String,
    pub scope: ForgetScope,
    pub value: String,
    pub requested_by: String,
    pub requested_at: DateTime<Utc>,
    pub completed_at: DateTime<Utc>,
    pub records_deleted: u64,
    pub executions: u32,
    /// How many sampled records were looked for.
    pub canaries_checked: u64,
    /// Where any of them was still found.
    pub canaries_found: CanaryReport,
    /// True when no canary was found anywhere.
    pub verified: bool,
    /// The store that carried it out (`postgres`, `sqlite`).
    pub store: String,
    pub producer: String,
    /// The audit head when the certificate was made: the deletion's events come before it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audit_head: Option<AuditHead>,
    /// sha256 of the certificate's other fields, as canonical JSON.
    pub hash: String,
}

impl DeletionCertificate {
    /// The hash the certificate should carry.
    pub fn computed_hash(&self) -> String {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let Some(o) = v.as_object_mut() {
            o.remove("hash");
        }
        hex::encode(Sha256::digest(canonical(&v).as_bytes()))
    }

    pub fn hash_ok(&self) -> bool {
        self.hash == self.computed_hash()
    }
}

/// A JSON value as text with every object's keys in order, whatever order the value holds them
/// in: what a hash over a document is taken of.
pub fn canonical(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort();
            let parts: Vec<String> = keys.iter().map(|k| format!("{}:{}", serde_json::Value::String((*k).clone()), canonical(&o[*k]))).collect();
            format!("{{{}}}", parts.join(","))
        }
        serde_json::Value::Array(a) => format!("[{}]", a.iter().map(canonical).collect::<Vec<_>>().join(",")),
        v => v.to_string(),
    }
}

/// How many records a deletion samples as canaries.
pub const CANARIES: usize = 50;

/// The retention rules of one kind in the order they are carried out: each scope rule with the
/// more specific rules as its exceptions, then the type's own rule with every scope rule as an
/// exception. A rule of 0 days purges nothing: it is only an exception.
pub fn retention_plan(kind: MemoryKind, type_days: u32, scopes: &[crate::policy::RetentionScope]) -> Vec<(String, PurgeSpec, u32)> {
    let mut rules: Vec<&crate::policy::RetentionScope> = scopes.iter().filter(|r| r.kind == kind).collect();
    rules.sort_by(|a, b| (a.level, &a.value).cmp(&(b.level, &b.value)));
    let as_match = |r: &crate::policy::RetentionScope| ScopeMatch { level: r.level, value: r.value.clone() };
    let mut plan = vec![];
    for (i, r) in rules.iter().enumerate() {
        if r.days == 0 {
            continue;
        }
        // Only a rule of another level can also match the record; one of the same level and
        // another value never does.
        let except = rules[..i].iter().filter(|o| o.level != r.level).map(|o| as_match(o)).collect();
        let step = format!("{}:{}={}", kind.as_str(), r.level.as_str(), r.value);
        plan.push((step, PurgeSpec { kind, age: PurgeAge::OlderThanDays(r.days), scope: Some(as_match(r)), except, run: None, max_batches: None }, r.days));
    }
    if type_days > 0 {
        let except = rules.iter().map(|o| as_match(o)).collect();
        plan.push((kind.as_str().to_string(), PurgeSpec { kind, age: PurgeAge::OlderThanDays(type_days), scope: None, except, run: None, max_batches: None }, type_days));
    }
    plan
}

/// The largest number of batches one retention pass runs per rule (tests bound it to stop a
/// pass half-way; the service leaves it unbounded).
#[derive(Debug, Clone, Copy, Default)]
pub struct RetentionLimits {
    pub max_batches: Option<usize>,
}

/// What a retention pass did.
#[derive(Debug, Clone, Default, Serialize)]
pub struct RetentionReport {
    /// Records past `expires_at` moved to `expired`.
    pub expired: u64,
    /// Records purged, over every rule (and over every attempt of a resumed run).
    pub purged: u64,
    pub partitions_dropped: u64,
    /// Records a rule matched that a legal hold kept.
    pub held: u64,
    /// The run continued one that an earlier pass left unfinished.
    pub resumed: bool,
    /// False when a bound stopped the pass early; the next pass continues the same run.
    pub complete: bool,
    /// Held deletions carried out because their hold was released.
    pub deletions_completed: u64,
}

impl Engine {
    fn producer() -> String {
        format!("memhouse {}", env!("CARGO_PKG_VERSION"))
    }

    /// Place a legal hold (GOV-09), audited as `hold.place` in the same transaction.
    pub async fn hold_place(&self, tenant: &str, target_kind: &str, target: &str, reason: &str, by: &str) -> anyhow::Result<LegalHold> {
        if !HOLD_KINDS.contains(&target_kind) {
            return Err(error::invalid(format!("{target_kind:?} is not something a legal hold is placed on (one of: {})", HOLD_KINDS.join(", "))));
        }
        let target = if target_kind == "tenant" { tenant.to_string() } else { target.trim().to_string() };
        if target.is_empty() {
            return Err(error::invalid(format!("a legal hold on a {target_kind} names it")));
        }
        if reason.trim().is_empty() {
            return Err(error::invalid("a legal hold needs a reason (a matter or case reference)"));
        }
        let hold = LegalHold {
            id: Uuid::new_v4(),
            tenant: tenant.to_string(),
            target_kind: target_kind.to_string(),
            target,
            reason: reason.trim().to_string(),
            placed_by: by.to_string(),
            placed_at: Utc::now(),
            released_by: None,
            released_at: None,
        };
        let audit = AuditEntry {
            actor: by.to_string(),
            action: "hold.place".into(),
            subject: (hold.target_kind == "subject").then(|| hold.target.clone()),
            memory_id: None,
            detail: json!({ "hold": hold.id, "target_kind": hold.target_kind, "target": hold.target, "reason": hold.reason }),
        };
        self.store.legal_hold_put(&hold, &audit).await?;
        Ok(hold)
    }

    /// Release a hold (audited as `hold.release`), then carry out the deletions it was holding
    /// back (GOV-09: within 24 hours of release; here at once, and again by every retention
    /// pass until none is left).
    pub async fn hold_release(&self, tenant: &str, id: Uuid, by: &str) -> anyhow::Result<(LegalHold, Vec<DeletionRequest>, Option<String>)> {
        // By id, not from the list: a hold is found however many newer ones there are.
        let hold = self.store.legal_hold_get(tenant, id).await?.ok_or_else(|| error::not_found(format!("legal hold {id} not found")))?;
        if !hold.active() {
            return Err(error::conflict(format!("legal hold {id} was released already")));
        }
        let audit = AuditEntry {
            actor: by.to_string(),
            action: "hold.release".into(),
            subject: (hold.target_kind == "subject").then(|| hold.target.clone()),
            memory_id: None,
            detail: json!({ "hold": hold.id, "target_kind": hold.target_kind, "target": hold.target }),
        };
        if !self.store.legal_hold_release(tenant, id, by, &audit).await? {
            return Err(error::conflict(format!("legal hold {id} was released already")));
        }
        // The release is committed: a failure to read the row back is no failure of the
        // release, and must not keep the kept deletions from being carried out.
        let released = match self.store.legal_hold_get(tenant, id).await {
            Ok(Some(h)) => h,
            _ => LegalHold { released_by: Some(by.to_string()), released_at: Some(Utc::now()), ..hold },
        };
        // The release is committed whatever happens next: a failure to carry the kept deletions
        // out is reported beside it, not instead of it (the next retention pass tries again).
        match self.resume_deletions(tenant).await {
            Ok(resumed) => Ok((released, resumed, None)),
            Err(e) => Ok((released, vec![], Some(format!("{e:#}")))),
        }
    }

    pub async fn holds(&self, tenant: &str, active_only: bool) -> anyhow::Result<Vec<LegalHold>> {
        self.store.legal_holds(tenant, active_only).await
    }

    /// Carry out every deletion of the tenant that is not complete: one a legal hold kept back,
    /// or one a restart interrupted. A deletion is idempotent, and its certificate and audit
    /// event are written once, with its completion (TR-WF-02). Returns those that changed.
    pub async fn resume_deletions(&self, tenant: &str) -> anyhow::Result<Vec<DeletionRequest>> {
        // One recovery pass per tenant at a time (a retention pass and a hold release may
        // coincide, also in two processes): two passes over one request could each see the
        // other's deletion as "nothing left to delete".
        // A store without durable state has one process and no lease to take.
        if !self.store.keeps_state() {
            return self.resume_deletions_locked(tenant, None).await;
        }
        let key = format!("deletions.resume.{tenant}");
        let holder = Uuid::new_v4().to_string();
        let now = Utc::now().timestamp();
        // A lookup or a compare-and-set that fails is not a lease: the pass does not run.
        let current = self.store.state_get(&key).await?;
        let free = current.as_deref().and_then(|c| c.split_once('|')).is_none_or(|(_, until)| until.parse::<i64>().map_or(true, |u| u < now));
        let value = format!("{holder}|{}", now + RECOVERY_LEASE_SECS);
        if !free || !self.store.state_cas(&key, current.as_deref(), &value).await? {
            return Ok(vec![]);
        }
        let lease = RecoveryLease { key, holder, value: std::sync::Mutex::new(value) };
        let result = self.resume_deletions_locked(tenant, Some(&lease)).await;
        // Given back only while it is still this pass's: a lease another pass took after this
        // one's lapsed is not cleared.
        let mine = lease.value.lock().unwrap().clone();
        let _ = self.store.state_cas(&lease.key, Some(&mine), &format!("{}|0", lease.holder)).await;
        result
    }

    /// Renew the recovery lease; false when it is no longer this pass's (it lapsed and another
    /// pass took it). Without a lease (a store with one process) there is nothing to lose.
    async fn lease_held(&self, lease: Option<&RecoveryLease>) -> anyhow::Result<bool> {
        let Some(lease) = lease else { return Ok(true) };
        let current = lease.value.lock().unwrap().clone();
        let next = format!("{}|{}", lease.holder, Utc::now().timestamp() + RECOVERY_LEASE_SECS);
        if next == current {
            return Ok(true);
        }
        let held = self.store.state_cas(&lease.key, Some(&current), &next).await?;
        if held {
            *lease.value.lock().unwrap() = next;
        }
        Ok(held)
    }

    async fn resume_deletions_locked(&self, tenant: &str, lease: Option<&RecoveryLease>) -> anyhow::Result<Vec<DeletionRequest>> {
        let mut out = vec![];
        // Every open request, oldest first, page by page: none is out of reach behind others.
        let mut after = None;
        'pages: loop {
            let page = self.store.deletions_open(tenant, after, 200).await?;
            let Some(last) = page.last() else { break };
            after = Some((last.requested_at, last.id));
            for mut d in page {
                // A request accepted a moment ago is still being carried out by its own call
                // (one that is only waiting for a clean probe is not).
                if d.status == DeletionStatus::Running && d.certificate.is_none() && Utc::now() - d.requested_at < chrono::Duration::minutes(10) {
                    continue;
                }
                // The lease is renewed before every request, and checked again before each
                // step of it: a pass that lost it stops, and leaves the rest to its holder.
                if !self.lease_held(lease).await? {
                    break 'pages;
                }
                let before = (d.status, d.deleted);
                self.run_deletion(&mut d, lease).await?;
                if (d.status, d.deleted) != before {
                    out.push(d);
                }
            }
        }
        Ok(out)
    }

    /// One execution of a deletion request: delete what no hold keeps, then either complete it
    /// (verify the canaries, issue the certificate), leave it `held`, or, when a canary is
    /// still found, leave it open with the residue recorded: it is completed, and certified,
    /// only once a probe is clean.
    pub(crate) async fn run_deletion(&self, d: &mut DeletionRequest, lease: Option<&RecoveryLease>) -> anyhow::Result<()> {
        if d.status == DeletionStatus::Completed {
            return Ok(());
        }
        // A request that was carried out and is waiting for a clean probe is carried out again
        // only when something it matches is still there to erase: a record a legal hold kept
        // during the first execution and released since (the release may have come between
        // the erasure and the count of held records, so the request never became `held`).
        // Otherwise it is only probed again, and writes no event of an erasure of nothing.
        let execute = match (&d.certificate, d.scope) {
            (None, _) => true,
            // Of a record: the record, or what was derived or promoted from it, as the probe finds it.
            (Some(_), ForgetScope::Record) => self.store.held_count(&d.tenant, d.scope, &d.value).await? == 0 && self.store.canary_probe(&d.tenant, &d.canaries).await?.total() > 0,
            (Some(_), _) => self.store.forget_count(&d.tenant, d.scope, &d.value).await? > self.store.held_count(&d.tenant, d.scope, &d.value).await?,
        };
        if execute {
            if !self.lease_held(lease).await? {
                return Ok(());
            }
            let n = self.execute_forget(&d.tenant, d.scope, &d.value, &d.actor).await?;
            self.deleted.notify_waiters();
            // The count is added to the stored request atomically, as a sum: a later step that
            // fails, or another pass, cannot lose it. (A process that dies between the erasure
            // and this line does lose that execution's count: see the known limits in
            // docs/governance.md.)
            // (A retry that found nothing to erase after all is not counted as an execution.)
            if n > 0 || d.certificate.is_none() {
                match self.store.deletion_progress(&d.tenant, d.id, n).await? {
                    Some(fresh) if fresh.status == DeletionStatus::Completed => {
                        *d = fresh;
                        return Ok(());
                    }
                    Some(fresh) => (d.deleted, d.executions) = (fresh.deleted, fresh.executions),
                    None => (d.deleted, d.executions) = (d.deleted + n, d.executions + 1),
                }
            }
        }
        d.held = self.store.held_count(&d.tenant, d.scope, &d.value).await?;
        if !self.lease_held(lease).await? {
            return Ok(());
        }
        if d.held > 0 {
            let first = d.status != DeletionStatus::Held;
            d.status = DeletionStatus::Held;
            d.certificate = None;
            if first {
                // The state and its event commit together: neither is there without the other.
                let audit = AuditEntry {
                    actor: d.actor.clone(),
                    action: "deletion.held".into(),
                    subject: None,
                    memory_id: None,
                    detail: json!({ "request": d.id, "scope": d.scope.as_str(), "value": d.value, "deleted": d.deleted, "held": d.held }),
                };
                self.store.deletion_record(d, &audit).await?;
            } else {
                self.store.deletion_put(d).await?;
            }
            return Ok(());
        }
        let found = self.store.canary_probe(&d.tenant, &d.canaries).await?;
        let mut cert = DeletionCertificate {
            format: CERTIFICATE_FORMAT.into(),
            version: 1,
            request_id: d.id,
            tenant: d.tenant.clone(),
            scope: d.scope,
            value: d.value.clone(),
            requested_by: d.actor.clone(),
            requested_at: d.requested_at,
            completed_at: Utc::now(),
            records_deleted: d.deleted,
            executions: d.executions,
            canaries_checked: d.canaries.len() as u64,
            verified: found.total() == 0,
            canaries_found: found,
            store: if self.is_lite() { "sqlite".into() } else { "postgres".into() },
            producer: Self::producer(),
            audit_head: self.store.audit_head().await?,
            hash: String::new(),
        };
        cert.hash = cert.computed_hash();
        d.held = 0;
        if !cert.verified {
            // Not complete: something of a sampled record is still there. The request stays
            // open with what was found, said once in the audit log, and is probed again by
            // every retention pass.
            let first = d.certificate.is_none();
            let found = serde_json::to_value(&cert.canaries_found)?;
            d.status = DeletionStatus::Running;
            d.certificate = Some(cert);
            if !self.lease_held(lease).await? {
                return Ok(());
            }
            if first {
                // The residue and its event commit together: an event that could not be
                // written leaves no residue recorded, so the next pass writes both.
                let audit = AuditEntry {
                    actor: d.actor.clone(),
                    action: "deletion.unverified".into(),
                    subject: None,
                    memory_id: None,
                    detail: json!({ "request": d.id, "scope": d.scope.as_str(), "records": d.deleted, "found": found }),
                };
                self.store.deletion_record(d, &audit).await?;
            } else {
                self.store.deletion_put(d).await?;
            }
            return Ok(());
        }
        if !self.lease_held(lease).await? {
            return Ok(());
        }
        d.status = DeletionStatus::Completed;
        d.completed_at = Some(cert.completed_at);
        let audit = AuditEntry {
            actor: d.actor.clone(),
            action: "deletion.certificate".into(),
            subject: (d.scope == ForgetScope::Subject).then(|| d.value.clone()),
            memory_id: None,
            detail: json!({
                "request": d.id, "scope": d.scope.as_str(), "records": d.deleted, "canaries": cert.canaries_checked,
                "found": 0, "verified": true, "certificate": cert.hash,
            }),
        };
        d.certificate = Some(cert);
        // The certificate, the completed state and the event commit together, once.
        self.store.deletion_record(d, &audit).await?;
        Ok(())
    }

    pub async fn deletion(&self, tenant: &str, id: Uuid) -> anyhow::Result<DeletionRequest> {
        self.store.deletion_get(tenant, id).await?.ok_or_else(|| error::not_found(format!("deletion request {id} not found")))
    }

    /// Check a certificate against this installation: its hash covers its fields, and the audit
    /// log has the `deletion.certificate` event that carries that hash. Whether the log itself
    /// is intact is another check (`audit_verify`), not made here.
    pub async fn certificate_check(&self, tenant: &str, cert: &DeletionCertificate) -> anyhow::Result<(bool, bool)> {
        let recorded = self.store.audit_find(tenant, "deletion.certificate", "certificate", &cert.hash).await?;
        Ok((cert.hash_ok(), recorded))
    }

    /// The installation's id ([`instance_id`]).
    pub async fn instance_id(&self) -> anyhow::Result<String> {
        instance_id(self.store.as_ref()).await
    }

    /// Take an anchor of the audit head (GOV-12). The anchor is the head as it is *before* the
    /// `audit.anchor` event that records the anchoring: that event is appended after it, so the
    /// chain itself (and with it the SIEM export) carries every anchor taken.
    pub async fn audit_anchor(&self, tenant: &str, by: &str) -> anyhow::Result<AuditAnchor> {
        let head = self.store.audit_head().await?.ok_or_else(|| error::conflict("the audit log is empty: there is no head to anchor"))?;
        let anchor = AuditAnchor {
            format: ANCHOR_FORMAT.into(),
            version: 1,
            instance: self.instance_id().await?,
            event_id: head.id,
            hash: head.hash.clone(),
            event_at: head.at,
            anchored_at: Utc::now(),
            anchored_by: by.to_string(),
        };
        self.store.audit(by, "audit.anchor", tenant, None, None, json!({ "event": head.id, "hash": head.hash })).await?;
        Ok(anchor)
    }

    /// Compare anchors kept outside the database with the chain (GOV-12): an anchor whose event
    /// is gone or has another hash shows the log was rewritten after the anchor was taken.
    pub async fn anchors_check(&self, anchors: &[AuditAnchor]) -> anyhow::Result<Vec<AnchorCheck>> {
        let instance = self.instance_id().await?;
        let mut out = vec![];
        for a in anchors {
            let result = if a.instance != instance {
                "other_instance"
            } else {
                match self.store.audit_hash_at(a.event_id).await? {
                    None => "missing",
                    Some(h) if h == a.hash => "match",
                    Some(_) => "mismatch",
                }
            };
            out.push(AnchorCheck { event_id: a.event_id, anchored_at: a.anchored_at, result });
        }
        Ok(out)
    }

    /// Apply each type's retention (MEM-01, GOV-06), as one durable run (TR-WF-02): expire what
    /// is past its `expires_at`, purge expired working memory, purge each type by its scope
    /// rules and its own rule, then carry out deletions whose hold was released. A run that was
    /// interrupted is continued; each rule's `retention.purge` event is written once, with the
    /// records of every attempt.
    pub async fn retention_run(&self, limits: RetentionLimits) -> anyhow::Result<RetentionReport> {
        let tenant = self.cfg.memory.tenant.clone();
        let mut report = RetentionReport { complete: true, ..Default::default() };
        let days = self.cfg.telemetry.explanation_retention_days;
        if days > 0 {
            self.store.recalls_delete(&tenant, None, Some(days)).await?;
        }
        report.expired = self.store.expire_due(&tenant).await?;
        if report.expired > 0 {
            self.store.audit("system", "retention.expire", &tenant, None, None, json!({ "records": report.expired })).await?;
        }
        // Console sessions past their end or their idle limit (T3): no row outlives its use.
        let idle = self.cfg.server.session_idle_secs;
        let now = Utc::now();
        let slack = crate::identity::session_touch_secs(idle);
        self.store.sessions_purge(now, (idle > 0).then(|| now - chrono::Duration::seconds(idle as i64 + slack))).await?;

        let policy = self.policy_for(&tenant).await?;
        let mut steps: Vec<(String, PurgeSpec, serde_json::Value)> = vec![];
        // Working memory past its TTL is purged, not only hidden (GOV-06; moved here from G11).
        steps.push(("working:expired".into(), PurgeSpec::expired(MemoryKind::Working), json!({ "kind": "working", "expired": true })));
        for kind in MemoryKind::ALL {
            for (step, spec, days) in retention_plan(kind, policy.of(kind).retention_days, &policy.policy.retention.scopes) {
                let mut detail = json!({ "kind": kind.as_str(), "days": days });
                if let Some(s) = &spec.scope {
                    detail["scope"] = json!({ "level": s.level.as_str(), "value": s.value });
                }
                steps.push((step, spec, detail));
            }
        }
        let run = self.store.job_begin(&tenant, "retention").await?;
        report.resumed = run.resumed;
        for (step, mut spec, mut detail) in steps {
            if run.step_done(&step) {
                // Done by an earlier pass of this run: counted, not run again.
                report.purged += run.count(&step);
                continue;
            }
            spec.run = Some((run.id, step.clone()));
            spec.max_batches = limits.max_batches;
            let out = self.store.purge(&tenant, &spec).await?;
            report.partitions_dropped += out.partitions_dropped;
            report.held += out.held;
            if !out.complete {
                // The run stays open: the next pass continues it from this step.
                report.complete = false;
                report.purged += out.records;
                return Ok(report);
            }
            // The step's total is what the run has counted, over this attempt and earlier ones.
            // (A store without durable runs counts nothing: there the step's own count stands.)
            let total = self.store.job_count(run.id, &step).await?.max(out.records);
            report.purged += total;
            detail["records"] = json!(total);
            if out.partitions_dropped > 0 {
                detail["partitions_dropped"] = json!(out.partitions_dropped);
            }
            if out.held > 0 {
                detail["held"] = json!(out.held);
            }
            let audit = (total > 0).then(|| AuditEntry { actor: "system".into(), action: "retention.purge".into(), subject: None, memory_id: None, detail });
            self.store.job_step_done(run.id, &step, audit.as_ref()).await?;
        }
        self.store.job_finish(run.id).await?;
        report.deletions_completed = self.resume_deletions(&tenant).await?.iter().filter(|d| d.status == DeletionStatus::Completed).count() as u64;
        if report.expired + report.purged + report.deletions_completed > 0 {
            self.working.clear();
        }
        Ok(report)
    }
}

/// The installation's id, created on first use and kept in the store: what an anchor and the
/// restore guard name the database by. A copy of the database (a backup) carries the same id.
pub async fn instance_id(store: &dyn crate::Store) -> anyhow::Result<String> {
    if let Some(id) = store.state_get("instance_id").await? {
        return Ok(id);
    }
    let id = Uuid::new_v4().to_string();
    // Two processes may race: the first write wins and both read it back.
    store.state_cas("instance_id", None, &id).await?;
    Ok(store.state_get("instance_id").await?.unwrap_or(id))
}

/// The compliance evidence export (GOV-16): which control maps to which SOC 2 criteria and
/// ISO/IEC 27001:2022 Annex A controls, and which files of the bundle are its evidence.
pub mod evidence {
    use serde::Serialize;

    /// One control of the mapping.
    #[derive(Debug, Clone, Serialize)]
    pub struct Control {
        pub id: &'static str,
        pub title: &'static str,
        /// SOC 2 trust services criteria (2017, revised points of focus 2022).
        pub soc2: &'static [&'static str],
        /// ISO/IEC 27001:2022 Annex A controls.
        pub iso27001: &'static [&'static str],
        /// The requirement ids the control implements.
        pub requirements: &'static [&'static str],
        /// Files of the bundle that are this control's evidence.
        pub evidence: &'static [&'static str],
    }

    /// The files an export writes, each produced from the running installation.
    pub const FILES: [&str; 11] = [
        "audit-chain.json",
        "access.json",
        "configuration.json",
        "policy.json",
        "retention.json",
        "legal-holds.json",
        "deletions.json",
        "isolation.json",
        "siem-export.json",
        "build.json",
        "governance-suite.json",
    ];

    /// The checks of the governance suite, by id, each with the requirement it tests. An
    /// evidence bundle names a check of a suite report only by what is listed here: text from
    /// the report file itself is never copied (the suite fails a check that is missing here).
    pub const CHECKS: &[(&str, &str)] = &[
        ("injection_persistence", "QUAL-02 / strategy 7.2"),
        ("false_quarantine", "QUAL-02"),
        ("pii_redaction", "GOV-05 / TR-IN-04"),
        ("subject_isolation", "GOV-02 / TR-RQ-01"),
        ("tenant_isolation", "GOV-02"),
        ("deletion", "GOV-07 / TR-WF-01"),
        ("subject_erasure", "GOV-07"),
        ("stale_facts", "CORE-03 / strategy 7.2"),
        ("validity", "CORE-05"),
        ("dedup", "CORE-06"),
        ("audit_chain", "GOV-12"),
        ("determinism", "Strategy 7.1"),
        ("enrich_async_gate", "QUAL-02 / GOV-05 (derived path)"),
        ("enrich_deletion", "GOV-07 / TR-WF-01 (derived path)"),
        ("retention_cascade", "GOV-08 / TR-WF-01 (derived path)"),
        ("recall_plan_scoped", "TR-RQ-01 / SCALE-04"),
        ("exact_topk", "TR-RQ-02 / SCALE-03"),
        ("invariants", "CORE-03 / CORE-04 / CORE-06 / GOV-07"),
        ("reembed", "TR-MS-04"),
        ("idempotency", "CORE-06"),
        ("lifecycle", "CORE-02 / MEM-01"),
        ("representations", "HYB-02 / HYB-04 / TR-TPL-02 / ACC-06"),
        ("format_roundtrip", "INT-10 / TR-CORE-03 / RP-06"),
        ("schema_upgrade", "QUAL-08 / TR-DB-01"),
        ("api_contract", "CORE-01 / CORE-03 / INT-02 / INT-04 / QUAL-09"),
        ("api_idempotency", "CORE-06"),
        ("revise_history", "CORE-04"),
        ("forget_scopes", "CORE-05 / GOV-07"),
        ("authentication", "GOV-01 / GOV-13 / TR-LT-07"),
        ("route_authorization", "GOV-02 / TR-CORE-05"),
        ("propose_only", "GOV-08"),
        ("label_filter", "TR-RQ-03 / ACC-04 / GOV-02"),
        ("authz_latency", "GOV-14"),
        ("recall_explanation", "GOV-04"),
        ("recall_round_trip", "PERF-02 / QUAL-07"),
        ("telemetry_overhead", "QUAL-07 / G07"),
        ("telemetry_no_content", "T13 / G07"),
        ("policy_precedence", "POL-04 / PR-1"),
        ("policy_approval", "POL-03 / GOV-03"),
        ("policy_rollback", "POL-08 / POL-01"),
        ("intake_candidates", "CORE-02 / TR-IN-04 / PERF-03"),
        ("intake_restart", "TR-LT-05 / TR-IN-03 / GOV-05"),
        ("intake_poison", "TR-IN-07"),
        ("intake_freshness", "PERF-04"),
        ("statement_gate", "QUAL-02 / QUAL-01 / PR-7"),
        ("exact_recall", "HYB-01 / HYB-02 / HYB-03 / HYB-06"),
        ("degradation", "PERF-07 / PR-5"),
        ("memory_types", "MEM-01 / MEM-02 / MEM-03"),
        ("working_session", "PERF-05 / MEM-01"),
        ("scope_inheritance", "MEM-04"),
        ("promotion", "MEM-05"),
        ("agent_grants", "INT-06"),
        ("partitions", "ACC-10"),
        ("ranking_weights", "HYB-05"),
        ("packing_dedup", "ECON-03"),
        ("token_budget", "PERF-06 / INT-04"),
        ("eval_harness", "QUAL-03 / QUAL-11"),
        ("eval_gate", "QUAL-04 / QUAL-05"),
        ("eval_reproducible", "QUAL-10"),
        ("language_packs", "QUAL-02 / HYB-03 (G36)"),
        ("injection_languages", "QUAL-02 / TR-CORE-05 (G36)"),
        ("language_recall", "HYB-03 / QUAL-01 (G36)"),
        ("gate_tiers", "ECON-04 / TR-MS-05 / QUAL-02 (G14)"),
        ("extraction_tiers", "ECON-04 / ECON-06 / SCALE-08 (G14)"),
        ("corrections_supersede", "QUAL-01 (G14)"),
        ("ingested_replay", "QUAL-03 / QUAL-11 (G14)"),
        ("adapter_conformance", "TR-CORE-02 / DEP-02 (G15)"),
        ("profile_conformance", "PROF-01 / TR-CORE-01 (G15)"),
        ("migrate_round_trip", "PROF-02 / TR-MIG-01 (G17)"),
        ("migrate_erasure_and_audit", "TR-MIG-01 / TR-WF-03 (G17)"),
        ("migrate_no_credentials", "TR-MIG-01 / AP-10 (G17)"),
        ("migrate_failed_verification", "TR-MIG-01 (G17)"),
        ("embedded_same_controls", "TR-LT-01 / INT-03 (G18)"),
        ("code_staleness", "TPL-04 / TR-TPL-02"),
        ("file_touched_recall", "TPL-05"),
        ("stale_until_revalidated", "TPL-04"),
        ("file_touched_access", "TPL-05 / GOV-02 / ACC-04"),
        ("procedural_promotion", "MEM-02"),
        ("hooks_only_call_api", "TR-TPL-03 / AP-2"),
        ("console_actions", "PROF-09 (G20)"),
        ("console_session", "T3 / GOV-01 (G20)"),
        ("console_csp_cors", "T3 (G20)"),
        ("quarantine_review", "GOV-11 (G20)"),
        ("console_evaluation", "QUAL-11 (G20)"),
        ("profile_advisor", "PROF-11 (G20)"),
        ("legal_hold", "GOV-09 (G22)"),
        ("source_purge", "GOV-10 (G22)"),
        ("deletion_certificate", "GOV-07 / TR-WF-01 (G22)"),
        ("retention_scopes", "GOV-06 / MEM-01 (G22)"),
        ("retention_resume", "TR-WF-02 (G22)"),
        ("restore_replay", "TR-WF-03 (G22)"),
        ("rls_bypass", "TR-DB-03 (G22)"),
        ("episodic_partitions", "TR-DB-04 / GOV-06 (G22)"),
        ("audit_anchor", "GOV-12 (G22)"),
        ("siem_export", "GOV-15 (G22)"),
        ("evidence_export", "GOV-16 (G22)"),
        ("pii_actions", "GOV-05 (G22)"),
    ];

    pub const CONTROLS: &[Control] = &[
        Control {
            id: "MH-01",
            title: "Authentication of every caller: per-principal keys, short-lived agent tokens, revocation",
            soc2: &["CC6.1", "CC6.2", "CC6.3"],
            iso27001: &["A.5.15", "A.5.16", "A.5.17", "A.8.5"],
            requirements: &["GOV-01", "GOV-13"],
            evidence: &["access.json", "audit-chain.json"],
        },
        Control {
            id: "MH-02",
            title: "Authorization of every operation by permission, tenant, subject, kind, label and scope",
            soc2: &["CC6.1", "CC6.3"],
            iso27001: &["A.5.15", "A.5.18", "A.8.2", "A.8.3"],
            requirements: &["GOV-02", "GOV-08"],
            evidence: &["access.json", "configuration.json", "governance-suite.json"],
        },
        Control {
            id: "MH-03",
            title: "Isolation of tenants and subjects in every statement, with row-level security as a second line",
            soc2: &["CC6.1", "CC6.6"],
            iso27001: &["A.8.3", "A.8.22"],
            requirements: &["TR-DB-03", "TR-RQ-01"],
            evidence: &["isolation.json", "governance-suite.json"],
        },
        Control {
            id: "MH-04",
            title: "Detection and redaction, masking or rejection of personal data and secrets before storage",
            soc2: &["C1.1", "P4.1", "CC6.7"],
            iso27001: &["A.5.34", "A.8.11", "A.8.12"],
            requirements: &["GOV-05", "TR-IN-04"],
            evidence: &["configuration.json", "policy.json", "governance-suite.json"],
        },
        Control {
            id: "MH-05",
            title: "Retention per memory type and scope, with purge across every representation",
            soc2: &["C1.2", "P4.2"],
            iso27001: &["A.5.33", "A.8.10"],
            requirements: &["GOV-06", "TR-DB-04", "TR-WF-02"],
            evidence: &["retention.json", "policy.json", "audit-chain.json"],
        },
        Control {
            id: "MH-06",
            title: "Deletion on request across every representation, with a completion certificate and a ledger re-applied after a restore",
            soc2: &["C1.2", "P4.3", "P5.2"],
            iso27001: &["A.5.34", "A.8.10", "A.8.13"],
            requirements: &["GOV-07", "TR-WF-01", "TR-WF-03", "CORE-05"],
            evidence: &["deletions.json", "audit-chain.json", "governance-suite.json"],
        },
        Control {
            id: "MH-07",
            title: "Legal hold: held data is exempt from retention and deletion until released",
            soc2: &["C1.1", "P4.2"],
            iso27001: &["A.5.31", "A.5.33"],
            requirements: &["GOV-09"],
            evidence: &["legal-holds.json", "deletions.json"],
        },
        Control {
            id: "MH-08",
            title: "Append-only, hash-chained audit log holding identifiers and hashes, with its head anchored outside the database",
            soc2: &["CC7.2", "CC7.3", "CC4.1"],
            iso27001: &["A.8.15", "A.5.28", "A.5.33"],
            requirements: &["GOV-12", "PR-3"],
            evidence: &["audit-chain.json"],
        },
        Control {
            id: "MH-09",
            title: "Export of audit events to the security monitoring system within 60 seconds",
            soc2: &["CC7.2", "CC7.3"],
            iso27001: &["A.8.15", "A.8.16"],
            requirements: &["GOV-15"],
            evidence: &["siem-export.json"],
        },
        Control {
            id: "MH-10",
            title: "Protection against memory poisoning: instruction-like content quarantined, untrusted sources held, a source purged with its descendants",
            soc2: &["CC6.8", "CC7.1", "PI1.2"],
            iso27001: &["A.8.7", "A.8.28", "A.5.7"],
            requirements: &["GOV-10", "QUAL-02"],
            evidence: &["configuration.json", "governance-suite.json"],
        },
        Control {
            id: "MH-11",
            title: "Behaviour policies that can only tighten governance, approved by a named person, versioned and rolled back",
            soc2: &["CC8.1", "CC5.3"],
            iso27001: &["A.8.32", "A.5.1", "A.8.9"],
            requirements: &["GOV-03", "POL-03", "POL-04", "POL-08"],
            evidence: &["policy.json", "audit-chain.json"],
        },
        Control {
            id: "MH-12",
            title: "Signed builds with a bill of materials, and controls tested by an automated suite on every release",
            soc2: &["CC8.1", "CC7.1", "CC4.1"],
            iso27001: &["A.8.25", "A.8.29", "A.8.8", "A.5.36"],
            requirements: &["GOV-16", "TR-OPS-03"],
            evidence: &["build.json", "governance-suite.json"],
        },
    ];

    /// Controls whose evidence names a file the export does not write (none, by construction;
    /// the governance suite checks it).
    pub fn unmapped() -> Vec<&'static str> {
        CONTROLS.iter().filter(|c| c.evidence.is_empty() || c.evidence.iter().any(|f| !FILES.contains(f))).map(|c| c.id).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::RetentionScope;

    #[test]
    fn a_certificate_hash_covers_every_field() {
        let mut c = DeletionCertificate {
            format: CERTIFICATE_FORMAT.into(),
            version: 1,
            request_id: Uuid::nil(),
            tenant: "t".into(),
            scope: ForgetScope::Subject,
            value: "customer:1".into(),
            requested_by: "dpo".into(),
            requested_at: DateTime::from_timestamp(1_700_000_000, 0).unwrap(),
            completed_at: DateTime::from_timestamp(1_700_000_100, 0).unwrap(),
            records_deleted: 3,
            executions: 1,
            canaries_checked: 3,
            canaries_found: CanaryReport::default(),
            verified: true,
            store: "sqlite".into(),
            producer: "memhouse test".into(),
            audit_head: None,
            hash: String::new(),
        };
        c.hash = c.computed_hash();
        assert!(c.hash_ok());
        let mut changed = c.clone();
        changed.records_deleted = 4;
        assert!(!changed.hash_ok(), "a changed count must not keep the hash");
        let mut found = c.clone();
        found.canaries_found.cached_vectors = 1;
        assert!(!found.hash_ok());
    }

    #[test]
    fn scope_rules_run_most_specific_first_and_except_each_other() {
        let rule = |level, value: &str, days| RetentionScope { level, value: value.into(), kind: MemoryKind::Episodic, days };
        let scopes = vec![rule(ScopeLevel::Subject, "customer:1", 90), rule(ScopeLevel::Team, "legal", 0), rule(ScopeLevel::User, "user:ana", 7)];
        let plan = retention_plan(MemoryKind::Episodic, 365, &scopes);
        let steps: Vec<&str> = plan.iter().map(|(s, _, _)| s.as_str()).collect();
        // The 0-day rule purges nothing; it only keeps its records out of the broader rules.
        assert_eq!(steps, vec!["episodic:user=user:ana", "episodic:subject=customer:1", "episodic"]);
        assert!(plan[0].1.except.is_empty());
        assert_eq!(plan[1].1.except.iter().map(|m| m.level).collect::<Vec<_>>(), vec![ScopeLevel::User, ScopeLevel::Team]);
        assert_eq!(plan[2].1.except.len(), 3);
        assert!(retention_plan(MemoryKind::Semantic, 0, &scopes).is_empty());
    }

    #[test]
    fn every_control_has_evidence_the_export_writes() {
        assert!(evidence::unmapped().is_empty(), "{:?}", evidence::unmapped());
        for c in evidence::CONTROLS {
            assert!(!c.soc2.is_empty() && !c.iso27001.is_empty(), "{} maps to both frameworks", c.id);
        }
    }
}
