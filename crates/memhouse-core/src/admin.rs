// SPDX-License-Identifier: Apache-2.0
//! What the admin console needs beyond the memory operations (G20): principals and their keys
//! (PROF-09), the review queue and a reviewer's rephrasing of a candidate (GOV-11), a tenant's
//! evaluation suites and runs with their trend by policy version (QUAL-11), and the profile
//! advisor (PROF-11).
//!
//! Everything here is engine logic behind the API: the console is a page that calls these
//! through [`crate::caller::Caller`], which authorizes each call, and holds no rule of its own.
//! The command line calls the same methods as the operator.

use crate::engine::Engine;
use crate::error;
use crate::eval::{EvalMetrics, EvalRun, EvalTrigger};
use crate::identity::{self, ApiKey, Principal, PrincipalKind, BOOTSTRAP};
use crate::types::*;
use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

/// A principal as the API shows it (`GET /v1/principals`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PrincipalInfo {
    /// `agent:<name>`, `user:<name>` or `admin:<name>`.
    pub id: String,
    pub tenant: String,
    pub kind: PrincipalKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Subjects it may use: exact names or prefixes ending in `*`; `*` is all.
    pub subjects: Vec<String>,
    /// Memory kinds it may use; empty is all.
    pub kinds: Vec<MemoryKind>,
    /// Labels it may never read or write.
    pub denied_labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub org: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
    /// Agents only: writes commit directly instead of being proposed (GOV-08).
    pub can_commit: bool,
    /// May state which user it acts for.
    pub act_as: bool,
    /// Set while the principal is disabled: its keys, tokens and sessions are refused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub created_by: String,
}

impl From<Principal> for PrincipalInfo {
    fn from(p: Principal) -> Self {
        PrincipalInfo {
            id: p.id,
            tenant: p.tenant,
            kind: p.kind,
            name: p.name,
            subjects: p.subjects,
            kinds: p.kinds,
            denied_labels: p.denied_labels,
            org: p.org,
            team: p.team,
            can_commit: p.can_commit,
            act_as: p.act_as,
            disabled_at: p.disabled_at,
            created_at: p.created_at,
            created_by: p.created_by,
        }
    }
}

/// Create a principal or replace its attributes (`PUT /v1/principals/{id}`). The kind is the
/// prefix of the id. Every field is the whole new value: one left out takes its default,
/// except `name`, which is then kept.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct PrincipalRequest {
    /// A display name. The one field that is kept when left out: absent, `null` or empty
    /// leaves the principal's current name as it is (a name is replaced, never cleared).
    #[serde(default)]
    pub name: Option<String>,
    /// Subjects it may use: exact names or prefixes ending in `*`. Default: `["*"]`, all.
    #[serde(default)]
    pub subjects: Vec<String>,
    /// Memory kinds it may use. Default: all.
    #[serde(default)]
    pub kinds: Vec<MemoryKind>,
    /// Labels it may never read or write.
    #[serde(default)]
    pub denied_labels: Vec<String>,
    #[serde(default)]
    pub org: Option<String>,
    #[serde(default)]
    pub team: Option<String>,
    /// Agents only: commit writes directly instead of proposing them (GOV-08).
    #[serde(default)]
    pub can_commit: bool,
    /// May state which user it acts for (a backend that authenticates its users).
    #[serde(default)]
    pub act_as: bool,
}

/// An API key as the API shows it: never its secret or the hash of it.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct KeyInfo {
    /// The public id of the key (the middle part of `mh_<id>_<secret>`).
    pub id: String,
    pub principal: String,
    /// The permissions it carries.
    pub scopes: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub created_by: String,
    /// `active`, `expired` or `revoked`, at the time of the answer.
    pub state: String,
}

impl KeyInfo {
    pub fn of(k: &ApiKey, now: DateTime<Utc>) -> KeyInfo {
        let state = match (k.revoked_at, k.expires_at) {
            (Some(_), _) => "revoked",
            (None, Some(e)) if e <= now => "expired",
            _ => "active",
        };
        KeyInfo {
            id: k.id.clone(),
            principal: k.principal_id.clone(),
            scopes: k.scopes.clone(),
            expires_at: k.expires_at,
            revoked_at: k.revoked_at,
            created_at: k.created_at,
            created_by: k.created_by.clone(),
            state: state.into(),
        }
    }
}

/// Create a key for a principal (`POST /v1/keys`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct KeyRequest {
    pub principal: String,
    /// The permissions the key carries. Default: every permission the principal's kind allows
    /// that the calling credential carries itself. A key never carries more than its maker.
    #[serde(default)]
    pub scopes: Option<Vec<String>>,
    /// Lifetime in seconds. Default: no expiry.
    #[serde(default)]
    pub expires_in_secs: Option<u64>,
}

/// Replace a key (`POST /v1/keys/{id}/rotate`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct KeyRotateRequest {
    /// How long the old key keeps working, in seconds. Default: 86400 (a day); 0 ends it now.
    #[serde(default)]
    pub grace_secs: Option<u64>,
}

/// A new key. `key` is the only time its secret is shown: nothing stores it.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct KeyCreated {
    /// The full key, `mh_<id>_<secret>`: send it as `Authorization: Bearer <key>`.
    pub key: String,
    pub info: KeyInfo,
    /// For a rotation: the key it replaces and until when that one works.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replaces: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old_expires_at: Option<DateTime<Utc>>,
}

/// The answer to revoking a key.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct KeyRevoked {
    pub revoked: String,
}

/// A console session (`POST` and `GET /v1/session`). The session itself is the cookie the
/// answer sets; nothing here is a credential except `csrf_token`, which only works with it.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SessionInfo {
    pub principal: String,
    /// `agent`, `user` or `admin`.
    pub kind: String,
    pub tenant: String,
    /// The permissions of the key that opened the session.
    pub scopes: Vec<String>,
    /// When the session ends whatever its use.
    pub expires_at: DateTime<Utc>,
    /// The session also ends when unused for this long; 0: no idle limit.
    pub idle_secs: u64,
    /// Send as `x-memhouse-csrf` with every request that changes something.
    pub csrf_token: String,
}

/// The answer to `DELETE /v1/session`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SessionClosed {
    /// False when the session had ended already.
    pub closed: bool,
}

/// A stored evaluation suite without its conversations (`GET /v1/eval/suites`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EvalSuiteInfo {
    pub name: String,
    pub hash: String,
    pub description: String,
    pub conversations: usize,
    pub turns: usize,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

/// One stored replay without its per-conversation detail (`GET /v1/eval/runs`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EvalRunInfo {
    pub id: Uuid,
    pub suite: String,
    pub suite_hash: String,
    /// The policy version the replay ran under.
    pub policy_version: String,
    pub trigger: EvalTrigger,
    pub metrics: EvalMetrics,
    pub took_ms: f64,
    pub created_at: DateTime<Utc>,
    /// For a replay made by the regression gate: whether the gate passed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate_passed: Option<bool>,
}

impl From<&EvalRun> for EvalRunInfo {
    fn from(r: &EvalRun) -> Self {
        EvalRunInfo {
            id: r.id,
            suite: r.suite.clone(),
            suite_hash: r.suite_hash.clone(),
            policy_version: r.policy_version.clone(),
            trigger: r.trigger,
            metrics: r.metrics,
            took_ms: r.took_ms,
            created_at: r.created_at,
            gate_passed: r.gate_passed,
        }
    }
}

/// A suite's quality under one policy version: the latest replay that ran under it.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TrendPoint {
    pub policy_version: String,
    /// Replays stored under this version (within the runs read).
    pub runs: u32,
    pub first_at: DateTime<Utc>,
    pub last_at: DateTime<Utc>,
    /// The metrics of the latest replay under this version.
    pub metrics: EvalMetrics,
}

/// The quality metrics of one suite by policy version, oldest version first (QUAL-11).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SuiteTrend {
    pub suite: String,
    pub points: Vec<TrendPoint>,
}

/// `GET /v1/eval/trend`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EvalTrend {
    pub suites: Vec<SuiteTrend>,
}

/// Group replays (newest first, as the store returns them) by suite and policy version. A
/// version's place is that of its first replay, so the points read as the policy's history.
pub fn trend(runs: &[EvalRun]) -> EvalTrend {
    let mut suites: Vec<SuiteTrend> = vec![];
    for r in runs.iter().rev() {
        let at = match suites.iter().position(|s| s.suite == r.suite) {
            Some(i) => i,
            None => {
                suites.push(SuiteTrend { suite: r.suite.clone(), points: vec![] });
                suites.len() - 1
            }
        };
        let points = &mut suites[at].points;
        match points.iter_mut().find(|p| p.policy_version == r.policy_version) {
            Some(p) => {
                p.runs += 1;
                p.last_at = r.created_at;
                p.metrics = r.metrics;
            }
            None => points.push(TrendPoint { policy_version: r.policy_version.clone(), runs: 1, first_at: r.created_at, last_at: r.created_at, metrics: r.metrics }),
        }
    }
    suites.sort_by(|a, b| a.suite.cmp(&b.suite));
    EvalTrend { suites }
}

/// How one measured value stands against the limit of the profile (PROF-11).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct AdvisorMeasure {
    /// `records`, `largest_subject_records`, `file_mb` or `writes_per_hour`.
    pub name: String,
    pub value: f64,
    /// The limit the profile is measured at or configured with; absent: reported, not judged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<f64>,
    /// `value / limit`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ratio: Option<f64>,
    /// `ok`, `near_limit` (at or above `[advisor] warn_at` of the limit) or `over_limit`.
    pub status: String,
    /// What the value counts, and for `largest_subject_records` which subject.
    pub detail: String,
}

/// The profile advisor's report (`GET /v1/advisor`, `memhouse doctor`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct AdvisorReport {
    /// `lite` (SQLite) or `standard` (Postgres).
    pub profile: String,
    /// The worst status among the measures: `ok`, `near_limit` or `over_limit`.
    pub status: String,
    /// The share of a limit from which a measure is `near_limit`.
    pub warn_at: f64,
    pub measures: Vec<AdvisorMeasure>,
    /// What to do, when a measure is near or over its limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recommendation: Option<String>,
    /// The command that moves the installation to the recommended profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

/// The migrate command the advisor names (see `docs/operations.md`): a dry run first.
pub const MIGRATE_COMMAND: &str = "memhouse migrate --to postgres://<user>@<host>:5432/<database> --dry-run";

/// Judge measured usage against the Lite limits. On Standard nothing is judged: the values
/// are reported, and there is no next profile to recommend yet.
pub fn advise(lite: bool, usage: &StoreUsage, cfg: &crate::config::AdvisorConfig) -> AdvisorReport {
    let warn_at = cfg.warn_at.clamp(0.0, 1.0);
    let measure = |name: &str, value: f64, limit: u64, detail: String| {
        let limit = Some(limit as f64).filter(|l| lite && *l > 0.0);
        let ratio = limit.map(|l| value / l);
        let status = match ratio {
            Some(r) if r >= 1.0 => "over_limit",
            Some(r) if r >= warn_at => "near_limit",
            _ => "ok",
        };
        AdvisorMeasure { name: name.into(), value, limit, ratio, status: status.into(), detail }
    };
    let (subject, subject_records) = usage.largest_subject.clone().unwrap_or_default();
    let mut measures = vec![
        measure("records", usage.records as f64, cfg.lite_max_records, "records in the store, in every state".into()),
        measure(
            "largest_subject_records",
            subject_records as f64,
            cfg.lite_max_subject_records,
            if subject.is_empty() { "records of the largest subject".into() } else { format!("records of the largest subject, {subject}") },
        ),
    ];
    if let Some(b) = usage.bytes {
        measures.push(measure("file_mb", (b as f64 / 1_048_576.0 * 10.0).round() / 10.0, cfg.lite_max_file_mb, "size of the database on disk, in megabytes".into()));
    }
    measures.push(measure("writes_per_hour", usage.writes_last_hour as f64, cfg.lite_max_writes_per_hour, "records written in the last hour".into()));
    let worst = |s: &str| measures.iter().any(|m| m.status == s);
    let status = if worst("over_limit") {
        "over_limit"
    } else if worst("near_limit") {
        "near_limit"
    } else {
        "ok"
    };
    let (recommendation, command) = if status == "ok" {
        (None, None)
    } else {
        let which: Vec<String> = measures
            .iter()
            .filter(|m| m.status != "ok")
            .map(|m| format!("{} is at {:.0}% of what Lite is measured at ({} of {})", m.name, m.ratio.unwrap_or(0.0) * 100.0, m.value, m.limit.unwrap_or(0.0)))
            .collect();
        (
            Some(format!("{}. Move to the Standard profile (Postgres): stop `memhouse serve`, run the command below as a dry run, then without --dry-run.", which.join("; "))),
            Some(MIGRATE_COMMAND.to_string()),
        )
    };
    AdvisorReport { profile: if lite { "lite" } else { "standard" }.into(), status: status.into(), warn_at, measures, recommendation, command }
}

impl AdvisorReport {
    /// One line for the command line (`memhouse doctor`).
    pub fn line(&self) -> String {
        let values: Vec<String> = self
            .measures
            .iter()
            .map(|m| match m.limit {
                Some(l) => format!("{} {} of {} ({:.0}%)", m.name, m.value, l, m.ratio.unwrap_or(0.0) * 100.0),
                None => format!("{} {}", m.name, m.value),
            })
            .collect();
        match &self.command {
            Some(c) => format!("{}: {}. Next profile: Standard; run `{c}`", self.status, values.join(", ")),
            None => format!("{}: {}", self.status, values.join(", ")),
        }
    }
}

impl Engine {
    /// Whether the engine runs on the Lite profile (one SQLite file).
    pub fn is_lite(&self) -> bool {
        self.cfg.database.url.starts_with("sqlite:")
    }

    /// The profile advisor (PROF-11): measured usage against the profile's limits.
    pub async fn advisor(&self, tenant: &str) -> anyhow::Result<AdvisorReport> {
        let usage = self.store.usage(tenant).await?;
        Ok(advise(self.is_lite(), &usage, &self.cfg.advisor))
    }

    /// The principals of a tenant.
    pub async fn principal_list(&self, tenant: &str) -> anyhow::Result<Vec<Principal>> {
        self.store.principals(Some(tenant)).await
    }

    /// Create a principal, or replace the attributes of an existing one of the same tenant
    /// (PROF-09). Audited as `principal.put`.
    pub async fn principal_put(&self, tenant: &str, id: &str, req: &PrincipalRequest, by: &str) -> anyhow::Result<Principal> {
        let kind = id.split(':').next().and_then(PrincipalKind::parse).ok_or_else(|| error::invalid(format!("principal ids start with agent:, user: or admin: ('{id}')")))?;
        Principal::check_id(id, kind)?;
        if id == BOOTSTRAP {
            return Err(error::invalid(format!("{BOOTSTRAP} is the built-in principal of the configuration's keys; it is not stored")));
        }
        if req.can_commit && kind != PrincipalKind::Agent {
            return Err(error::invalid("can_commit is a grant for agents (users and admins always commit)"));
        }
        let ok = |v: &str| !v.trim().is_empty() && v.len() <= 200;
        if !req.subjects.iter().all(|s| ok(s)) || !req.denied_labels.iter().all(|l| ok(l)) {
            return Err(error::invalid("subjects and denied_labels must be 1 to 200 characters each; the limit is 200"));
        }
        let mut p = match self.store.principal_get(id).await? {
            Some(p) if p.tenant == tenant => p,
            // A principal of another tenant is not confirmed to exist beyond its id being taken.
            Some(_) => return Err(error::conflict(format!("the id {id} is taken"))),
            None => Principal::new(id, tenant, kind, by),
        };
        p.subjects = if req.subjects.is_empty() { vec!["*".into()] } else { req.subjects.clone() };
        p.kinds = req.kinds.clone();
        p.denied_labels = req.denied_labels.clone();
        p.org = req.org.clone().filter(|v| !v.is_empty());
        p.team = req.team.clone().filter(|v| !v.is_empty());
        p.can_commit = req.can_commit;
        p.act_as = req.act_as;
        p.name = req.name.clone().filter(|v| !v.is_empty()).or(p.name);
        self.store.principal_put(&p).await?;
        self.store
            .audit(
                by,
                "principal.put",
                tenant,
                None,
                None,
                json!({ "principal": p.id, "kind": kind.as_str(), "subjects": p.subjects, "can_commit": p.can_commit, "act_as": p.act_as, "denied_labels": p.denied_labels }),
            )
            .await?;
        Ok(p)
    }

    /// Disable or enable a principal. A disabled one's keys, tokens and sessions are refused
    /// (within the 5 seconds a verified credential is cached). Audited.
    pub async fn principal_set_disabled(&self, tenant: &str, id: &str, disabled: bool, by: &str) -> anyhow::Result<Principal> {
        let mut p = self.tenant_principal(tenant, id).await?;
        p.disabled_at = disabled.then(Utc::now);
        self.store.principal_put(&p).await?;
        self.store.audit(by, if disabled { "principal.disable" } else { "principal.enable" }, tenant, None, None, json!({ "principal": id })).await?;
        Ok(p)
    }

    async fn tenant_principal(&self, tenant: &str, id: &str) -> anyhow::Result<Principal> {
        match self.store.principal_get(id).await? {
            Some(p) if p.tenant == tenant => Ok(p),
            _ => Err(error::not_found(format!("no principal {id}"))),
        }
    }

    /// The keys of a tenant's principals (or of one), without secrets.
    pub async fn key_list(&self, tenant: &str, principal: Option<&str>) -> anyhow::Result<Vec<ApiKey>> {
        let mine: std::collections::HashSet<String> = self.store.principals(Some(tenant)).await?.into_iter().map(|p| p.id).collect();
        Ok(self.store.api_keys(principal).await?.into_iter().filter(|k| mine.contains(&k.principal_id)).collect())
    }

    /// Create a key for a principal of the tenant; the full key is returned once. `cap`: the
    /// permissions of the credential that asks, which the new key may not exceed (the
    /// operator at the command line has none). Audited as `key.create`.
    pub async fn key_create(
        &self,
        tenant: &str,
        principal: &str,
        scopes: Option<Vec<String>>,
        expires: Option<chrono::Duration>,
        by: &str,
        cap: Option<&[String]>,
    ) -> anyhow::Result<(ApiKey, String)> {
        let p = match self.store.principal_get(principal).await? {
            Some(p) if p.tenant == tenant => p,
            _ => return Err(error::not_found(format!("no principal {principal}; add it with `memhouse principal add {principal}`"))),
        };
        let allowed = p.kind.permissions();
        let within = |s: &String| cap.is_none_or(|c| c.contains(s));
        let scopes = match scopes {
            None => allowed.iter().filter(|s| within(s)).cloned().collect(),
            Some(asked) => {
                if let Some(s) = asked.iter().find(|s| !allowed.contains(s)) {
                    return Err(error::invalid(format!("a {} key can't carry {s} (allowed: {})", p.kind.as_str(), allowed.join(", "))));
                }
                if let Some(s) = asked.iter().find(|s| !within(s)) {
                    return Err(error::forbidden(format!("permission {s} can't be given: the credential that creates a key must carry it itself")));
                }
                let mut asked = asked;
                asked.sort();
                asked.dedup();
                asked
            }
        };
        let (key, full) = identity::new_key(&p.id, scopes, expires.map(|d| Utc::now() + d), by);
        self.store.api_key_put(&key).await?;
        self.store.audit(by, "key.create", tenant, None, None, json!({ "key": key.id, "principal": p.id, "scopes": key.scopes, "expires_at": key.expires_at })).await?;
        Ok((key, full))
    }

    async fn tenant_key(&self, tenant: &str, id: &str) -> anyhow::Result<ApiKey> {
        let missing = || error::not_found(format!("no key {id}"));
        let k = self.store.api_key_get(id).await?.ok_or_else(missing)?;
        match self.store.principal_get(&k.principal_id).await? {
            Some(p) if p.tenant == tenant => Ok(k),
            _ => Err(missing()),
        }
    }

    /// Revoke a key now: it, its tokens and its sessions stop working. Audited as `key.revoke`.
    pub async fn key_revoke(&self, tenant: &str, id: &str, by: &str) -> anyhow::Result<()> {
        let k = self.tenant_key(tenant, id).await?;
        if !self.store.api_key_end(id, None).await? {
            return Err(error::conflict(format!("key {id} was already revoked")));
        }
        self.store.audit(by, "key.revoke", tenant, None, None, json!({ "key": id, "principal": k.principal_id })).await?;
        Ok(())
    }

    /// Replace a key by a new one with the same permissions; the old one works until the
    /// grace period ends. Audited as `key.rotate`.
    pub async fn key_rotate(&self, tenant: &str, id: &str, grace: chrono::Duration, by: &str, cap: Option<&[String]>) -> anyhow::Result<(ApiKey, String, DateTime<Utc>)> {
        let old = self.tenant_key(tenant, id).await?;
        if old.revoked_at.is_some() {
            return Err(error::conflict(format!("key {id} is revoked")));
        }
        let lifetime = old.expires_at.map(|e| e - old.created_at);
        let (k, full) = self.key_create(tenant, &old.principal_id, Some(old.scopes.clone()), lifetime, by, cap).await?;
        let until = Utc::now() + grace;
        self.store.api_key_end(id, Some(until)).await?;
        self.store.audit(by, "key.rotate", tenant, None, None, json!({ "old": id, "new": k.id, "old_expires_at": until })).await?;
        Ok((k, full, until))
    }

    /// The tenant's evaluation suites, without their conversations.
    pub async fn eval_suite_infos(&self, tenant: &str) -> anyhow::Result<Vec<EvalSuiteInfo>> {
        Ok(self
            .store
            .eval_suites(tenant)
            .await?
            .into_iter()
            .map(|s| EvalSuiteInfo {
                conversations: s.suite.conversations.len(),
                turns: s.suite.turns(),
                description: s.suite.description.clone(),
                name: s.name,
                hash: s.hash,
                created_by: s.created_by,
                created_at: s.created_at,
            })
            .collect())
    }

    /// A reviewer rewords a candidate or a quarantined record and approves the new wording
    /// (GOV-11). The new text is a write of the reviewer's and passes the whole write gate:
    /// redaction, the injection screen, deduplication. If the gate holds it back, nothing
    /// changes and the call is refused. Otherwise the reviewed record is rejected with a
    /// pointer to its replacement, and both steps are audited.
    pub(crate) async fn rephrase(&self, tenant: &str, m: &Memory, content: &str, by: &str, user: Option<String>, reason: Option<&str>) -> anyhow::Result<ReviewResult> {
        if !matches!(m.status, MemoryStatus::Candidate | MemoryStatus::Quarantined) {
            return Err(error::conflict(format!("memory {} is {}; only a candidate or a quarantined record is rephrased", m.id, m.status.as_str())));
        }
        if content.trim().is_empty() {
            return Err(error::invalid("content is required to rephrase; it is empty"));
        }
        if content.trim() == m.content.trim() {
            return Err(error::invalid("content is the text under review; expected another wording (to approve a candidate as it is, leave content out)"));
        }
        let mut metadata = if m.metadata.is_object() { m.metadata.clone() } else { json!({}) };
        if let Some(o) = metadata.as_object_mut() {
            // What held the reviewed record back says nothing about the new wording.
            for k in ["quarantine_reasons", "intake_error", "held", "signals", "counted", "review", "statement", "route", "redactions", "duplicate_of", "supersedes_because"] {
                o.remove(k);
            }
            o.insert("rephrased_from".into(), json!(m.id));
        }
        // What the reviewed record carries beside its text goes to the new wording: its
        // structured form, and the files it is about with the hashes it was written for, so
        // the replacement goes stale with them like the original would (TPL-04). A file seen
        // changed since is reported again by the next hook, which marks the replacement.
        let (structured, code_refs) = self.store.representations(tenant, m.id).await?;
        let code_refs = code_refs.into_iter().map(|c| CodeRef::new(c.path, c.blob_hash)).collect();
        let req = RememberRequest {
            tenant: Some(tenant.to_string()),
            subject: Some(m.subject.clone()),
            content: content.to_string(),
            kind: Some(m.kind),
            tags: m.tags.clone(),
            occurred_at: m.occurred_at,
            valid_to: m.valid_to,
            supersedes: m.supersedes,
            source: Some("review".into()),
            metadata: Some(metadata),
            actor: Some(by.to_string()),
            labels: m.labels.clone(),
            scope: Some(m.scope.clone()).filter(|s| !s.is_empty()),
            user,
            expires_at: m.expires_at,
            structured,
            code_refs,
            wait: true,
            ..Default::default()
        };
        let written = self.remember_with(req, crate::intake::Entry::Commit).await?;
        if written.id == m.id {
            return Err(error::conflict("the rephrased text was taken as the record under review; use another wording"));
        }
        if written.deduplicated {
            // The wording exists already as another record. The reviewer was authorized for
            // the reviewed record's labels and scope; the lookup that found the other record
            // does not compare labels. Unless it carries exactly those, this review neither
            // commits it nor points at it: it may be a record the reviewer cannot see.
            let same = |a: &[String], b: &[String]| a.iter().collect::<std::collections::BTreeSet<_>>() == b.iter().collect::<std::collections::BTreeSet<_>>();
            let other = self.store.get(tenant, written.id).await?;
            if !other.as_ref().is_some_and(|o| same(&o.labels, &m.labels) && o.scope == m.scope && o.subject == m.subject) {
                return Err(error::conflict("the rephrased text is the text of another record; the record under review is unchanged (use another wording, or review that record)"));
            }
        }
        let status = match written.status {
            MemoryStatus::Committed => MemoryStatus::Committed,
            // Held by the statement gate (a plan, a guess): the reviewer's approval commits it.
            MemoryStatus::Candidate => self.admit(tenant, written.id, by).await?.0,
            other => other,
        };
        if status != MemoryStatus::Committed {
            // The new wording did not pass: it is not left in the queue as a second item.
            if !written.deduplicated {
                let _ = self.reject(tenant, written.id, by, "a rephrasing the write gate held back").await;
            }
            return Err(error::conflict(format!(
                "the rephrased text was not committed ({}); the record under review is unchanged",
                written.note.unwrap_or_else(|| status.as_str().to_string())
            )));
        }
        self.settle_record(tenant, m.id).await?;
        if !self.store.set_status(tenant, m.id, MemoryStatus::Rejected).await? {
            return Err(error::conflict(format!("memory {} changed while it was rephrased; its replacement {} is committed", m.id, written.id)));
        }
        self.store
            .audit(
                by,
                "memory.rephrase",
                tenant,
                Some(&m.subject),
                Some(m.id),
                json!({ "replaced_by": written.id, "from": m.status.as_str(), "reason": reason, "deduplicated": written.deduplicated }),
            )
            .await?;
        Ok(ReviewResult { id: written.id, status, superseded: written.superseded, rephrased_from: Some(m.id) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AdvisorConfig;

    fn usage(records: i64, subject: i64) -> StoreUsage {
        StoreUsage { records, largest_subject: Some(("user:ada".into(), subject)), bytes: Some(52 * 1_048_576), writes_last_hour: 12 }
    }

    #[test]
    fn advisor_warns_near_the_lite_limits_and_names_the_command() {
        let cfg = AdvisorConfig::default();
        let ok = advise(true, &usage(10_000, 2_000), &cfg);
        assert_eq!((ok.status.as_str(), ok.command.as_deref()), ("ok", None));
        // PROF-11: at 90% of a tested limit the next profile is recommended with the command.
        let near = advise(true, &usage(90_000, 2_000), &cfg);
        assert_eq!(near.status, "near_limit");
        assert_eq!(near.command.as_deref(), Some(MIGRATE_COMMAND));
        assert!(near.recommendation.as_deref().unwrap().contains("records is at 90%"), "{:?}", near.recommendation);
        assert!(near.line().contains("memhouse migrate --to"));
        let below = advise(true, &usage(79_999, 7_999), &cfg);
        assert_eq!(below.status, "ok");
        let subject = advise(true, &usage(20_000, 10_000), &cfg);
        assert_eq!(subject.status, "over_limit");
        assert_eq!(subject.measures[1].status, "over_limit");
        // Sizes without a stated limit are reported and never judged.
        let file = near.measures.iter().find(|m| m.name == "file_mb").unwrap();
        assert_eq!((file.value, file.limit, file.status.as_str()), (52.0, None, "ok"));
        let judged = advise(true, &usage(1, 1), &AdvisorConfig { lite_max_file_mb: 50, ..cfg.clone() });
        assert_eq!(judged.status, "over_limit");
        // Standard has no Lite limit: the same usage is reported, nothing is recommended.
        let standard = advise(false, &usage(500_000, 90_000), &cfg);
        assert_eq!((standard.status.as_str(), standard.command.as_deref(), standard.profile.as_str()), ("ok", None, "standard"));
        assert!(standard.measures.iter().all(|m| m.limit.is_none()));
    }

    fn run(suite: &str, version: &str, minute: u32, f1: f64) -> EvalRun {
        EvalRun {
            id: Uuid::new_v4(),
            tenant: "t".into(),
            suite: suite.into(),
            suite_hash: "h".into(),
            policy_version: version.into(),
            fingerprint: Default::default(),
            trigger: EvalTrigger::Manual,
            counts: Default::default(),
            metrics: EvalMetrics { storage_recall: Some(f1), ..Default::default() },
            per_conversation: vec![],
            outcomes: vec![],
            took_ms: 1.0,
            created_at: DateTime::from_timestamp(1_800_000_000 + minute as i64 * 60, 0).unwrap(),
            gate_passed: None,
        }
    }

    #[test]
    fn trend_groups_runs_by_suite_and_policy_version() {
        // Newest first, as the store returns them.
        let runs = vec![run("b", "v2", 5, 0.7), run("a", "v2", 4, 0.9), run("a", "v2", 3, 0.8), run("a", "v1", 2, 0.6), run("b", "v1", 1, 0.5)];
        let t = trend(&runs);
        assert_eq!(t.suites.iter().map(|s| s.suite.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        let a = &t.suites[0].points;
        assert_eq!(a.iter().map(|p| (p.policy_version.as_str(), p.runs)).collect::<Vec<_>>(), [("v1", 1), ("v2", 2)]);
        // A version's metrics are those of its latest replay.
        assert_eq!(a[1].metrics.storage_recall, Some(0.9));
        assert!(a[1].first_at < a[1].last_at);
    }
}
