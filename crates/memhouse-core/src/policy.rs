// SPDX-License-Identifier: Apache-2.0
//! Policy engine v1 (G08): behaviour policy as a structured spec, compiled under governance,
//! approved before it runs, versioned and rolled back (POL-01, POL-03, POL-04, POL-08).
//!
//! **Precedence** (PR-1): the security baseline, then tenant governance (`[governance]` and
//! `[access]` in the configuration), then the behaviour policy. The compiler starts from
//! governance and lets a spec only tighten it: a setting that would loosen it fails compilation
//! with a message naming the governance rule it would break. Settings a spec leaves out keep
//! their configured values, so the configuration compiles to the default policy (`gov-…`) and
//! stays the bootstrap; configuration never rewrites memory records (CFG-07).
//!
//! **Lifecycle**: `propose` stores a spec as the tenant's next numbered version; `approve`, by a
//! named approver, compiles it again and activates it; `rollback` activates an earlier approved
//! version or the default. Only approved specs execute: activation is refused in the database
//! too. Every step, and every refusal, is audited (`policy.*`). Engines pick up an activation
//! within [`REFRESH`], at once in the process that made it, without a restart.
//!
//! **Provenance** (GOV-03): every record carries the version of the compiled policy that admitted
//! it, every write and recall span carries it, and the compiled body is kept in `mh_policy`.

use crate::config::{Admission, Config, MemoryConfig};
use crate::engine::{content_hash, Engine};
use crate::error;
use crate::types::MemoryKind;
use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The spec format this build reads.
pub const SPEC_FORMAT: u32 = 1;
/// How long an engine trusts its cached policy before it asks the store which version is active.
pub const REFRESH: Duration = Duration::from_secs(2);

fn spec_format() -> u32 {
    SPEC_FORMAT
}

/// A behaviour policy as authored (TOML or JSON). Every section and field is optional: what a spec
/// leaves out keeps the governance or configured value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PolicySpec {
    /// Spec format; 1.
    #[serde(default = "spec_format")]
    pub format: u32,
    /// A short name: letters, digits, `.`, `_` and `-`.
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    pub scope: SpecScope,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_types: Option<SpecMemoryTypes>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub write_gate: Option<SpecWriteGate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retention: Option<SpecRetention>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub redaction: Option<SpecRedaction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recall: Option<SpecRecall>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ranking: Option<SpecRanking>,
}

/// What the policy governs. v1: one tenant (layers by org, team and agent come in G24).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecScope")]
pub struct SpecScope {
    pub tenant: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecMemoryTypes")]
pub struct SpecMemoryTypes {
    /// Kinds that may be written; writes of other kinds are refused. Default: all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allowed: Option<Vec<MemoryKind>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecWriteGate")]
pub struct SpecWriteGate {
    /// `auto` or `review`; `auto` only where governance doesn't require review.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admission: Option<Admission>,
    /// Cosine similarity at which a new memory counts as a duplicate (0.5 to 1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dedup_threshold: Option<f32>,
    /// At most governance's `max_content_chars`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_content_chars: Option<usize>,
    /// Always on (security baseline); may be stated, never turned off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quarantine_injection: Option<bool>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecRetention")]
pub struct SpecRetention {
    /// Days after which episodic memory is purged; 0 keeps it. Where governance purges, at most
    /// its days and never 0.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episodic_days: Option<u32>,
    /// Lifetime of working memory written without `expires_at` (1 second to 30 days).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_ttl_secs: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecRedaction")]
pub struct SpecRedaction {
    /// Categories redacted before anything is stored; must include every governance category.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub categories: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecRecall")]
pub struct SpecRecall {
    /// Labels never read; must include every label governance denies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub denied_labels: Option<Vec<String>>,
    /// Audit every recall; can't be turned off where governance turns it on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audit_reads: Option<bool>,
}

/// Ranking weights (the meaning of each is in `[memory]` of the configuration reference).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(rename = "PolicySpecRanking")]
pub struct SpecRanking {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_k: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidates: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rrf_k: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyword_weight: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vector_weight: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recency_weight: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recency_half_life_days: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query_analysis: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_weight: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_top: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_top_weight: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subquery_weight: Option<f32>,
}

/// The approved spec a compiled policy came from.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicySpecRef")]
pub struct SpecRef {
    pub name: String,
    /// The spec's version number; absent for a draft that was only validated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
    pub spec_hash: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyMemoryTypes")]
pub struct MemoryTypes {
    pub allowed: Vec<MemoryKind>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyWriteGate")]
pub struct WriteGate {
    pub admission: Admission,
    pub dedup_threshold: f32,
    pub max_content_chars: usize,
    pub quarantine_injection: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyRetention")]
pub struct Retention {
    pub episodic_days: u32,
    pub working_ttl_secs: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyRedaction")]
pub struct Redaction {
    pub categories: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyRecall")]
pub struct RecallRules {
    pub denied_labels: Vec<String>,
    pub audit_reads: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyRanking")]
pub struct Ranking {
    pub default_k: usize,
    pub candidates: usize,
    pub rrf_k: f32,
    pub keyword_weight: f32,
    pub vector_weight: f32,
    pub recency_weight: f32,
    pub recency_half_life_days: f32,
    pub query_analysis: bool,
    pub window_weight: f32,
    pub window_top: usize,
    pub window_top_weight: f32,
    pub subquery_weight: f32,
}

impl Ranking {
    fn from_config(m: &MemoryConfig) -> Ranking {
        Ranking {
            default_k: m.default_k,
            candidates: m.candidates,
            rrf_k: m.rrf_k,
            keyword_weight: m.keyword_weight,
            vector_weight: m.vector_weight,
            recency_weight: m.recency_weight,
            recency_half_life_days: m.recency_half_life_days,
            query_analysis: m.query_analysis,
            window_weight: m.window_weight,
            window_top: m.window_top,
            window_top_weight: m.window_top_weight,
            subquery_weight: m.subquery_weight,
        }
    }

    /// The ranking a stored policy body ran with (`None` for bodies from before G08).
    pub fn of_body(body: &Value) -> Option<Ranking> {
        serde_json::from_value(body.get("ranking")?.clone()).ok()
    }
}

/// Everything a policy decides, with nothing left unset: the body stored in `mh_policy`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "CompiledPolicyBody")]
pub struct CompiledBody {
    pub tenant: String,
    /// The spec it was compiled from; absent for the default policy (the configuration).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spec: Option<SpecRef>,
    pub memory_types: MemoryTypes,
    pub write_gate: WriteGate,
    pub retention: Retention,
    pub redaction: Redaction,
    pub recall: RecallRules,
    pub ranking: Ranking,
    /// Access-decision values (D-01…D-07), from the decision register in G28.
    pub decisions: Value,
}

/// A compiled policy and the version records and traces are stamped with.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct CompiledPolicy {
    /// `gov-<hash>` for the default policy, `policy-v<n>-<hash>` for an approved spec,
    /// `draft-<hash>` for one only validated. The hash is of the body, so equal policies get
    /// equal versions on every node.
    pub version: String,
    pub policy: CompiledBody,
}

impl CompiledPolicy {
    fn new(body: CompiledBody) -> CompiledPolicy {
        let hash = &content_hash(&serde_json::to_string(&body).unwrap_or_default())[..12];
        let version = match &body.spec {
            None => format!("gov-{hash}"),
            Some(SpecRef { version: Some(n), .. }) => format!("policy-v{n}-{hash}"),
            Some(_) => format!("draft-{hash}"),
        };
        CompiledPolicy { version, policy: body }
    }

    /// As kept in `mh_policy` and exported in the Memory Format.
    pub fn line(&self) -> crate::format::PolicyLine {
        crate::format::PolicyLine { version: self.version.clone(), body: serde_json::to_value(&self.policy).unwrap_or_default(), created_at: Utc::now() }
    }

    /// Whether writes of this kind are allowed.
    pub fn allows(&self, kind: MemoryKind) -> bool {
        self.policy.memory_types.allowed.contains(&kind)
    }

    /// The refusal for a write of a kind the policy doesn't allow.
    pub fn kind_refused(&self, kind: MemoryKind) -> anyhow::Error {
        error::invalid(format!("kind {kind} is not allowed by policy {} (memory_types.allowed)", self.version))
    }
}

/// A setting that doesn't compile, and why.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "PolicyViolation")]
pub struct Violation {
    /// The spec field, e.g. `retention.episodic_days`.
    pub path: String,
    /// `PR-1` (would loosen governance), `baseline` (the security floor), `range`, `unknown`,
    /// `scope` or `format`.
    pub rule: String,
    pub message: String,
}

impl std::fmt::Display for Violation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.path, self.message)
    }
}

/// One `invalid_request` error listing every violation.
pub fn violations_error(v: &[Violation]) -> anyhow::Error {
    let lines: Vec<String> = v.iter().map(|v| format!("  - {v}")).collect();
    error::invalid(format!("the policy does not compile ({} problem{}):\n{}", v.len(), if v.len() == 1 { "" } else { "s" }, lines.join("\n")))
}

/// Read a spec from TOML, or JSON when the text starts with `{`.
pub fn parse_spec(text: &str) -> anyhow::Result<PolicySpec> {
    let t = text.trim_start();
    let r: Result<PolicySpec, String> = if t.starts_with('{') { serde_json::from_str(t).map_err(|e| e.to_string()) } else { toml::from_str(t).map_err(|e| e.to_string()) };
    r.map_err(|e| error::invalid(format!("the policy spec can't be read: {}", e.trim())))
}

fn valid_name(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// The configuration as a policy: what runs while no spec is active, and the governance every
/// spec is compiled against.
pub fn default_policy(cfg: &Config, tenant: &str) -> CompiledPolicy {
    CompiledPolicy::new(governance(cfg, tenant))
}

fn governance(cfg: &Config, tenant: &str) -> CompiledBody {
    let g = &cfg.governance;
    // The floor holds even for a configuration built in code without `Config::check_floor`.
    let mut redact = g.redact.clone();
    redact.push("secret".into());
    CompiledBody {
        tenant: tenant.to_string(),
        spec: None,
        memory_types: MemoryTypes { allowed: MemoryKind::ALL.to_vec() },
        write_gate: WriteGate { admission: cfg.access.admission, dedup_threshold: cfg.memory.dedup_threshold, max_content_chars: g.max_content_chars, quarantine_injection: true },
        retention: Retention { episodic_days: g.episodic_retention_days, working_ttl_secs: cfg.memory.working_ttl_secs },
        redaction: Redaction { categories: ordered_categories(&redact) },
        recall: RecallRules { denied_labels: sorted(&g.denied_labels), audit_reads: g.audit_reads },
        ranking: Ranking::from_config(&cfg.memory),
        decisions: json!({}),
    }
}

/// Known categories in `gate::CATEGORIES` order, then unknown ones (reported by the compiler).
fn ordered_categories(c: &[String]) -> Vec<String> {
    let mut out: Vec<String> = crate::gate::CATEGORIES.iter().filter(|k| c.iter().any(|x| x == *k)).map(|s| s.to_string()).collect();
    out.extend(sorted(c).into_iter().filter(|x| !crate::gate::CATEGORIES.contains(&x.as_str())));
    out
}

fn sorted(v: &[String]) -> Vec<String> {
    let mut v = v.to_vec();
    v.sort();
    v.dedup();
    v
}

/// Compile a spec for `tenant` under the configuration's governance. `version` is the spec's
/// number once proposed. Every problem is reported, not only the first.
pub fn compile(spec: &PolicySpec, cfg: &Config, tenant: &str, version: Option<u32>) -> Result<CompiledPolicy, Vec<Violation>> {
    let gov = governance(cfg, tenant);
    let mut b = gov.clone();
    let mut errs: Vec<Violation> = vec![];
    let mut err = |path: &str, rule: &str, message: String| errs.push(Violation { path: path.into(), rule: rule.into(), message });
    const LOOSEN: &str = "PR-1";
    let pr1 = "a behaviour policy may only make governance stricter (PR-1)";

    if spec.format != SPEC_FORMAT {
        err("format", "format", format!("format {} is not one this build reads (it reads format {SPEC_FORMAT})", spec.format));
    }
    if !valid_name(&spec.name) {
        err("name", "range", "a name is 1 to 64 letters, digits, '.', '_' or '-'".into());
    }
    if spec.scope.tenant != tenant {
        err("scope.tenant", "scope", format!("the spec is for tenant {:?}, not {tenant:?}", spec.scope.tenant));
    }

    if let Some(allowed) = spec.memory_types.as_ref().and_then(|m| m.allowed.as_ref()) {
        if allowed.is_empty() {
            err("memory_types.allowed", "range", "allows no kind at all; leave it out to allow every kind".into());
        }
        b.memory_types.allowed = MemoryKind::ALL.into_iter().filter(|k| allowed.contains(k)).collect();
    }

    if let Some(w) = &spec.write_gate {
        if let Some(a) = w.admission {
            if a == Admission::Auto && gov.write_gate.admission == Admission::Review {
                err(
                    "write_gate.admission",
                    LOOSEN,
                    format!("\"auto\" commits agents' proposals without review, but governance requires review ([access] admission = \"review\"); {pr1}"),
                );
            }
            b.write_gate.admission = a;
        }
        if let Some(t) = w.dedup_threshold {
            if !(t.is_finite() && t > 0.5 && t <= 1.0) {
                err("write_gate.dedup_threshold", "range", format!("{t} is outside 0.5 (exclusive) to 1"));
            }
            b.write_gate.dedup_threshold = t;
        }
        if let Some(n) = w.max_content_chars {
            if n == 0 {
                err("write_gate.max_content_chars", "range", "0 would refuse every write".into());
            } else if n > gov.write_gate.max_content_chars {
                err(
                    "write_gate.max_content_chars",
                    LOOSEN,
                    format!("{n} is above the governance limit of {} characters ([governance] max_content_chars); {pr1}", gov.write_gate.max_content_chars),
                );
            }
            b.write_gate.max_content_chars = n;
        }
        if w.quarantine_injection == Some(false) {
            err("write_gate.quarantine_injection", "baseline", "the injection screen is part of the security baseline and can't be turned off (TR-CORE-05)".into());
        }
    }

    if let Some(r) = &spec.retention {
        if let Some(d) = r.episodic_days {
            let g = gov.retention.episodic_days;
            if g > 0 && d == 0 {
                err(
                    "retention.episodic_days",
                    LOOSEN,
                    format!("0 keeps episodic memory forever, but governance purges it after {g} days ([governance] episodic_retention_days); {pr1}"),
                );
            } else if g > 0 && d > g {
                err("retention.episodic_days", LOOSEN, format!("{d} days is longer than the {g} days governance allows ([governance] episodic_retention_days); {pr1}"));
            }
            b.retention.episodic_days = d;
        }
        if let Some(t) = r.working_ttl_secs {
            if !(1..=30 * 86_400).contains(&t) {
                err("retention.working_ttl_secs", "range", format!("{t} is outside 1 second to 30 days"));
            }
            b.retention.working_ttl_secs = t;
        }
    }

    if let Some(c) = spec.redaction.as_ref().and_then(|r| r.categories.as_ref()) {
        for x in c.iter().filter(|x| !crate::gate::CATEGORIES.contains(&x.as_str())) {
            err("redaction.categories", "unknown", format!("{x:?} is not a redaction category (known: {})", crate::gate::CATEGORIES.join(", ")));
        }
        if !c.iter().any(|x| x == "secret") {
            err("redaction.categories", "baseline", "drops \"secret\": credentials are always redacted (security baseline)".into());
        }
        for g in gov.redaction.categories.iter().filter(|g| *g != "secret" && !c.contains(g)) {
            err(
                "redaction.categories",
                LOOSEN,
                format!("drops {g:?}, which governance redacts ([governance] redact); a behaviour policy may add categories, never remove them (PR-1)"),
            );
        }
        let mut all = c.clone();
        all.extend(gov.redaction.categories.iter().cloned());
        b.redaction.categories = ordered_categories(&all);
    }

    if let Some(r) = &spec.recall {
        if let Some(l) = &r.denied_labels {
            if l.iter().any(|x| x.trim().is_empty()) {
                err("recall.denied_labels", "range", "a label is never empty".into());
            }
            for g in gov.recall.denied_labels.iter().filter(|g| !l.contains(g)) {
                err(
                    "recall.denied_labels",
                    LOOSEN,
                    format!("drops {g:?}, which governance denies ([governance] denied_labels); a behaviour policy may deny more labels, never fewer (PR-1)"),
                );
            }
            let mut all = l.clone();
            all.extend(gov.recall.denied_labels.iter().cloned());
            b.recall.denied_labels = sorted(&all);
        }
        if let Some(a) = r.audit_reads {
            if !a && gov.recall.audit_reads {
                err("recall.audit_reads", LOOSEN, format!("governance audits every recall ([governance] audit_reads = true); {pr1}"));
            }
            b.recall.audit_reads = a;
        }
    }

    if let Some(r) = &spec.ranking {
        let k = &mut b.ranking;
        let mut count = |path: &str, v: Option<usize>, lo: usize, hi: usize, slot: &mut usize| {
            if let Some(v) = v {
                if !(lo..=hi).contains(&v) {
                    err(path, "range", format!("{v} is outside {lo} to {hi}"));
                }
                *slot = v;
            }
        };
        count("ranking.default_k", r.default_k, 1, 200, &mut k.default_k);
        count("ranking.candidates", r.candidates, 1, 1000, &mut k.candidates);
        count("ranking.window_top", r.window_top, 0, 100, &mut k.window_top);
        let mut weight = |path: &str, v: Option<f32>, lo: f32, hi: f32, open_low: bool, slot: &mut f32| {
            if let Some(v) = v {
                if !v.is_finite() || v > hi || v < lo || (open_low && v == lo) {
                    err(path, "range", format!("{v} is outside {}{lo} to {hi}", if open_low { "above " } else { "" }));
                }
                *slot = v;
            }
        };
        weight("ranking.rrf_k", r.rrf_k, 0.0, 1000.0, true, &mut k.rrf_k);
        weight("ranking.keyword_weight", r.keyword_weight, 0.0, 100.0, false, &mut k.keyword_weight);
        weight("ranking.vector_weight", r.vector_weight, 0.0, 100.0, false, &mut k.vector_weight);
        weight("ranking.recency_weight", r.recency_weight, 0.0, 100.0, false, &mut k.recency_weight);
        weight("ranking.recency_half_life_days", r.recency_half_life_days, 0.0, 36_500.0, true, &mut k.recency_half_life_days);
        weight("ranking.window_weight", r.window_weight, 0.0, 100.0, false, &mut k.window_weight);
        weight("ranking.window_top_weight", r.window_top_weight, 0.0, 100.0, false, &mut k.window_top_weight);
        weight("ranking.subquery_weight", r.subquery_weight, 0.0, 100.0, false, &mut k.subquery_weight);
        if let Some(q) = r.query_analysis {
            k.query_analysis = q;
        }
        if k.keyword_weight == 0.0 && k.vector_weight == 0.0 {
            err("ranking", "range", "keyword_weight and vector_weight are both 0, so recall would rank nothing".into());
        }
    }

    if !errs.is_empty() {
        return Err(errs);
    }
    let spec_hash = content_hash(&serde_json::to_string(spec).unwrap_or_default());
    b.spec = Some(SpecRef { name: spec.name.clone(), version, spec_hash });
    Ok(CompiledPolicy::new(b))
}

/// One changed setting between two compiled policies.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PolicyChange {
    /// e.g. `ranking.recency_weight`.
    pub path: String,
    pub from: Value,
    pub to: Value,
}

/// The settings that differ, by dotted path, in path order.
pub fn diff(a: &CompiledBody, b: &CompiledBody) -> Vec<PolicyChange> {
    fn flatten(prefix: &str, v: &Value, out: &mut BTreeMap<String, Value>) {
        match v {
            Value::Object(o) if !o.is_empty() => {
                for (k, x) in o {
                    flatten(&if prefix.is_empty() { k.clone() } else { format!("{prefix}.{k}") }, x, out);
                }
            }
            _ => {
                out.insert(prefix.to_string(), v.clone());
            }
        }
    }
    let (mut fa, mut fb) = (BTreeMap::new(), BTreeMap::new());
    flatten("", &serde_json::to_value(a).unwrap_or_default(), &mut fa);
    flatten("", &serde_json::to_value(b).unwrap_or_default(), &mut fb);
    let mut keys: Vec<&String> = fa.keys().chain(fb.keys()).collect();
    keys.sort();
    keys.dedup();
    keys.into_iter()
        .filter_map(|k| {
            let (x, y) = (fa.get(k).cloned().unwrap_or(Value::Null), fb.get(k).cloned().unwrap_or(Value::Null));
            (x != y).then(|| PolicyChange { path: k.clone(), from: x, to: y })
        })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
#[schemars(rename = "PolicySpecStatus")]
pub enum SpecStatus {
    /// Stored, not yet approved: it never executes.
    Proposed,
    /// Approved by a named approver; may be activated (and rolled back to).
    Approved,
}

impl SpecStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            SpecStatus::Proposed => "proposed",
            SpecStatus::Approved => "approved",
        }
    }

    pub fn parse(s: &str) -> Option<SpecStatus> {
        [SpecStatus::Proposed, SpecStatus::Approved].into_iter().find(|x| x.as_str() == s)
    }
}

/// A stored spec version.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PolicySpecRecord {
    pub tenant: String,
    /// 1, 2, 3… per tenant.
    pub version: u32,
    pub name: String,
    pub spec: Value,
    pub spec_hash: String,
    pub status: SpecStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub proposed_by: String,
    pub proposed_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_at: Option<DateTime<Utc>>,
}

/// One activation: what ran from then on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PolicyActivation {
    pub id: i64,
    pub tenant: String,
    /// The spec version activated; absent for the default policy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
    /// The compiled policy version records were stamped with from then on.
    pub compiled: String,
    /// `approve` or `rollback`.
    pub action: String,
    pub by: String,
    pub at: DateTime<Utc>,
}

/// The active policy of a tenant, its spec versions and its activations.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PolicyStatus {
    pub tenant: String,
    /// The spec version activated last; absent while the default policy runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<u32>,
    /// The compiled policy that runs now.
    pub running: CompiledPolicy,
    /// Set when the active spec no longer compiles under the current governance, so the default
    /// policy runs instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
    pub specs: Vec<PolicySpecRecord>,
    /// Newest first.
    pub history: Vec<PolicyActivation>,
}

/// `POST /v1/policies` (propose) and `POST /v1/policies/validate`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PolicySpecRequest {
    pub spec: PolicySpec,
    /// Why the change is proposed (kept with the version).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// Whether a spec compiles for the caller's tenant, and to what.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PolicyValidation {
    pub valid: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compiled: Option<CompiledPolicy>,
    pub violations: Vec<Violation>,
}

impl PolicyValidation {
    pub fn of(r: Result<CompiledPolicy, Vec<Violation>>) -> PolicyValidation {
        match r {
            Ok(c) => PolicyValidation { valid: true, compiled: Some(c), violations: vec![] },
            Err(v) => PolicyValidation { valid: false, compiled: None, violations: v },
        }
    }
}

/// `POST /v1/policies/diff`: two policies to compare.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PolicyDiffRequest {
    /// `default` or a version (`3`, `v3`); absent: the policy running now.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// `default` or a version; give this or `spec`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    /// A spec to compare, compiled but not stored.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spec: Option<PolicySpec>,
}

/// The settings that differ between two compiled policies.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PolicyDiff {
    /// Compiled version of each side.
    pub from: String,
    pub to: String,
    pub changes: Vec<PolicyChange>,
}

/// `POST /v1/policies/rollback`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RollbackRequest {
    /// `default` or an approved version; absent: the policy active before the current one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

/// Which policy: a spec version or the default (`default`, `3` or `v3`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyTarget {
    Default,
    Version(u32),
}

impl PolicyTarget {
    pub fn parse(s: &str) -> anyhow::Result<PolicyTarget> {
        let s = s.trim();
        if s.eq_ignore_ascii_case("default") {
            return Ok(PolicyTarget::Default);
        }
        s.trim_start_matches(['v', 'V'])
            .parse()
            .ok()
            .filter(|n| *n > 0)
            .map(PolicyTarget::Version)
            .ok_or_else(|| error::invalid(format!("{s:?} names no policy: use a version (3 or v3) or \"default\"")))
    }

    fn of(v: Option<u32>) -> PolicyTarget {
        v.map(PolicyTarget::Version).unwrap_or(PolicyTarget::Default)
    }

    fn version(&self) -> Option<u32> {
        match self {
            PolicyTarget::Default => None,
            PolicyTarget::Version(n) => Some(*n),
        }
    }
}

impl std::fmt::Display for PolicyTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PolicyTarget::Default => f.write_str("the default policy"),
            PolicyTarget::Version(n) => write!(f, "v{n}"),
        }
    }
}

/// Where specs, their approval and their activations live: the `PolicySource` seam. The
/// database now ([`StorePolicies`]); the decision register replaces it in G28. Compiled policies
/// stay in the store (`mh_policy`), next to the records that name them.
#[async_trait::async_trait]
pub trait PolicySource: Send + Sync {
    /// Store a spec as the tenant's next version, `proposed`.
    async fn propose(&self, tenant: &str, name: &str, spec: &Value, spec_hash: &str, by: &str, note: Option<&str>) -> anyhow::Result<PolicySpecRecord>;
    async fn spec(&self, tenant: &str, version: u32) -> anyhow::Result<Option<PolicySpecRecord>>;
    /// Every version, oldest first.
    async fn specs(&self, tenant: &str) -> anyhow::Result<Vec<PolicySpecRecord>>;
    /// Approve a `proposed` version and activate it, atomically; false if it was not `proposed`.
    async fn approve(&self, tenant: &str, version: u32, approver: &str, compiled: &str) -> anyhow::Result<bool>;
    /// Activate an approved version, or the default policy (`None`); must refuse anything else.
    async fn activate(&self, tenant: &str, version: Option<u32>, compiled: &str, action: &str, by: &str) -> anyhow::Result<()>;
    /// The spec activated last, if a spec (not the default policy) is active.
    async fn active(&self, tenant: &str) -> anyhow::Result<Option<PolicySpecRecord>>;
    /// Activations, newest first.
    async fn history(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<PolicyActivation>>;
}

/// Policy specs in the memory store's own database.
pub struct StorePolicies(pub Arc<dyn crate::Store>);

#[async_trait::async_trait]
impl PolicySource for StorePolicies {
    async fn propose(&self, tenant: &str, name: &str, spec: &Value, spec_hash: &str, by: &str, note: Option<&str>) -> anyhow::Result<PolicySpecRecord> {
        self.0.policy_propose(tenant, name, spec, spec_hash, by, note).await
    }
    async fn spec(&self, tenant: &str, version: u32) -> anyhow::Result<Option<PolicySpecRecord>> {
        self.0.policy_spec(tenant, version).await
    }
    async fn specs(&self, tenant: &str) -> anyhow::Result<Vec<PolicySpecRecord>> {
        self.0.policy_specs(tenant).await
    }
    async fn approve(&self, tenant: &str, version: u32, approver: &str, compiled: &str) -> anyhow::Result<bool> {
        self.0.policy_approve(tenant, version, approver, compiled).await
    }
    async fn activate(&self, tenant: &str, version: Option<u32>, compiled: &str, action: &str, by: &str) -> anyhow::Result<()> {
        self.0.policy_activate(tenant, version, compiled, action, by).await
    }
    async fn active(&self, tenant: &str) -> anyhow::Result<Option<PolicySpecRecord>> {
        self.0.policy_active(tenant).await
    }
    async fn history(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<PolicyActivation>> {
        self.0.policy_history(tenant, limit).await
    }
}

/// The compiled policy of each tenant an engine has served, and when it last asked the store.
#[derive(Default)]
pub struct PolicyCache {
    entries: Mutex<HashMap<String, Cached>>,
}

struct Cached {
    policy: Arc<CompiledPolicy>,
    active: Option<u32>,
    checked: Instant,
}

impl PolicyCache {
    fn fresh(&self, tenant: &str) -> Option<Arc<CompiledPolicy>> {
        let m = self.entries.lock().ok()?;
        m.get(tenant).filter(|c| c.checked.elapsed() < REFRESH).map(|c| c.policy.clone())
    }

    /// The cached policy if `active` is still the version it was compiled from.
    fn confirm(&self, tenant: &str, active: Option<u32>) -> Option<Arc<CompiledPolicy>> {
        let mut m = self.entries.lock().ok()?;
        let c = m.get_mut(tenant).filter(|c| c.active == active)?;
        c.checked = Instant::now();
        Some(c.policy.clone())
    }

    fn put(&self, tenant: &str, active: Option<u32>, policy: Arc<CompiledPolicy>) {
        if let Ok(mut m) = self.entries.lock() {
            m.insert(tenant.to_string(), Cached { policy, active, checked: Instant::now() });
        }
    }

    /// Forget a tenant's policy, so the next operation reads the active version again.
    pub fn invalidate(&self, tenant: &str) {
        if let Ok(mut m) = self.entries.lock() {
            m.remove(tenant);
        }
    }
}

impl Engine {
    /// The policy a tenant's operations run under now. Compiled from the active spec, or the
    /// configuration when none is active or the active one no longer compiles under the current
    /// governance (logged as an error: governance always wins). Recorded in `mh_policy` before
    /// any record can carry its version.
    pub async fn policy_for(&self, tenant: &str) -> anyhow::Result<Arc<CompiledPolicy>> {
        if let Some(p) = self.policies.fresh(tenant) {
            return Ok(p);
        }
        let active = self.policy_source.active(tenant).await?;
        let n = active.as_ref().map(|r| r.version);
        if let Some(p) = self.policies.confirm(tenant, n) {
            return Ok(p);
        }
        let compiled = match &active {
            None => default_policy(&self.cfg, tenant),
            Some(r) => match self.compile_record(r) {
                Ok(c) => c,
                Err(e) => {
                    tracing::error!("tenant {tenant}: active policy v{} does not compile under the current governance, so the default policy runs: {e:#}", r.version);
                    default_policy(&self.cfg, tenant)
                }
            },
        };
        self.store.policy_put(&compiled.line()).await?;
        let p = Arc::new(compiled);
        self.policies.put(tenant, n, p.clone());
        Ok(p)
    }

    fn compile_record(&self, r: &PolicySpecRecord) -> anyhow::Result<CompiledPolicy> {
        let spec: PolicySpec = serde_json::from_value(r.spec.clone()).map_err(|e| error::invalid(format!("stored spec v{} can't be read: {e}", r.version)))?;
        compile(&spec, &self.cfg, &r.tenant, Some(r.version)).map_err(|v| violations_error(&v))
    }

    /// Compile a spec for a tenant without storing anything (`validate`).
    pub fn policy_validate(&self, tenant: &str, spec: &PolicySpec) -> Result<CompiledPolicy, Vec<Violation>> {
        compile(spec, &self.cfg, tenant, None)
    }

    /// Audit and count a refused policy change (POL-03, POL-04).
    async fn policy_refused(&self, tenant: &str, by: &str, version: Option<u32>, reason: &str, violations: &[Violation]) {
        crate::metrics::inc("memhouse_refused_total", &[("kind", "policy"), ("reason", reason)], 1.0);
        let detail = json!({
            "version": version,
            "reason": reason,
            "violations": violations.iter().map(|v| json!({ "path": v.path, "rule": v.rule })).collect::<Vec<_>>(),
        });
        if let Err(e) = self.store.audit(by, "policy.reject", tenant, None, None, detail).await {
            tracing::error!("audit of a refused policy change failed: {e:#}");
        }
    }

    /// Store a spec as the tenant's next version, if it compiles. It runs only once approved.
    pub async fn policy_propose(&self, tenant: &str, spec: &PolicySpec, by: &str, note: Option<&str>) -> anyhow::Result<PolicySpecRecord> {
        if let Err(v) = compile(spec, &self.cfg, tenant, None) {
            self.policy_refused(tenant, by, None, "does_not_compile", &v).await;
            return Err(violations_error(&v));
        }
        let value = serde_json::to_value(spec)?;
        let hash = content_hash(&value.to_string());
        let note = note.map(str::trim).filter(|n| !n.is_empty());
        let rec = self.policy_source.propose(tenant, &spec.name, &value, &hash, by, note).await?;
        self.store.audit(by, "policy.propose", tenant, None, None, json!({ "version": rec.version, "name": rec.name, "spec_hash": rec.spec_hash })).await?;
        Ok(rec)
    }

    /// Approve a proposed version and activate it. The approver is named in the record and the
    /// audit log; the spec is compiled again under the governance in force now.
    pub async fn policy_approve(&self, tenant: &str, version: u32, approver: &str) -> anyhow::Result<CompiledPolicy> {
        let approver = approver.trim();
        if approver.is_empty() || approver.len() > 120 || approver.chars().any(char::is_control) {
            return Err(error::invalid("approving a policy needs the approver's name (1 to 120 characters)"));
        }
        let rec = self.policy_source.spec(tenant, version).await?.ok_or_else(|| error::not_found(format!("policy v{version} not found")))?;
        if rec.status == SpecStatus::Approved {
            return Err(error::conflict(format!("policy v{version} is already approved; activate it again with a rollback to v{version}")));
        }
        let spec: PolicySpec = serde_json::from_value(rec.spec.clone())?;
        let compiled = match compile(&spec, &self.cfg, tenant, Some(version)) {
            Ok(c) => c,
            Err(v) => {
                self.policy_refused(tenant, approver, Some(version), "does_not_compile", &v).await;
                return Err(violations_error(&v));
            }
        };
        self.store.policy_put(&compiled.line()).await?;
        if !self.policy_source.approve(tenant, version, approver, &compiled.version).await? {
            return Err(error::conflict(format!("policy v{version} was approved meanwhile")));
        }
        self.policies.invalidate(tenant);
        self.store.audit(approver, "policy.approve", tenant, None, None, json!({ "version": version, "compiled": compiled.version, "proposed_by": rec.proposed_by })).await?;
        Ok(compiled)
    }

    /// Activate an earlier policy: `to`, or the one active before the current one. Only an
    /// approved version (or the default) can be activated, and only if it compiles under the
    /// governance in force now.
    pub async fn policy_rollback(&self, tenant: &str, to: Option<PolicyTarget>, by: &str) -> anyhow::Result<CompiledPolicy> {
        let history = self.policy_source.history(tenant, 1000).await?;
        let current = history.first().and_then(|a| a.version);
        let target = match to {
            Some(t) => t,
            None => match history.iter().skip(1).find(|a| a.version != current) {
                Some(a) => PolicyTarget::of(a.version),
                // Before the first activation the default policy ran.
                None if current.is_some() => PolicyTarget::Default,
                None => return Err(error::invalid("there is no earlier policy to roll back to")),
            },
        };
        let compiled = match target {
            PolicyTarget::Default => default_policy(&self.cfg, tenant),
            PolicyTarget::Version(n) => {
                let rec = self.policy_source.spec(tenant, n).await?.ok_or_else(|| error::not_found(format!("policy v{n} not found")))?;
                if rec.status != SpecStatus::Approved {
                    self.policy_refused(tenant, by, Some(n), "not_approved", &[]).await;
                    return Err(error::forbidden(format!("policy v{n} is not approved, and only approved policies execute (POL-03); approve it first")));
                }
                match self.compile_record(&rec) {
                    Ok(c) => c,
                    Err(e) => {
                        self.policy_refused(tenant, by, Some(n), "does_not_compile", &[]).await;
                        return Err(error::invalid(format!("policy v{n} no longer compiles under the current governance: {e:#}")));
                    }
                }
            }
        };
        self.store.policy_put(&compiled.line()).await?;
        self.policy_source.activate(tenant, target.version(), &compiled.version, "rollback", by).await?;
        self.policies.invalidate(tenant);
        self.store.audit(by, "policy.rollback", tenant, None, None, json!({ "from": current, "to": target.version(), "compiled": compiled.version })).await?;
        Ok(compiled)
    }

    /// A stored version or the default, compiled under the governance in force now.
    pub async fn policy_resolve(&self, tenant: &str, target: PolicyTarget) -> anyhow::Result<CompiledPolicy> {
        match target {
            PolicyTarget::Default => Ok(default_policy(&self.cfg, tenant)),
            PolicyTarget::Version(n) => {
                let rec = self.policy_source.spec(tenant, n).await?.ok_or_else(|| error::not_found(format!("policy v{n} not found")))?;
                self.compile_record(&rec)
            }
        }
    }

    /// The changed settings between two policies, each compiled under the governance in force now.
    pub async fn policy_diff(&self, tenant: &str, req: &PolicyDiffRequest) -> anyhow::Result<PolicyDiff> {
        let from = match &req.from {
            Some(f) => self.policy_resolve(tenant, PolicyTarget::parse(f)?).await?,
            None => self.policy_status(tenant).await?.running,
        };
        let to = match (&req.to, &req.spec) {
            (Some(t), None) => self.policy_resolve(tenant, PolicyTarget::parse(t)?).await?,
            (None, Some(s)) => compile(s, &self.cfg, tenant, None).map_err(|v| violations_error(&v))?,
            _ => return Err(error::invalid("name exactly one of `to` and `spec`")),
        };
        Ok(PolicyDiff { from: from.version, to: to.version, changes: diff(&from.policy, &to.policy) })
    }

    /// The tenant's running policy (read from the store now, not the cache), specs and history.
    pub async fn policy_status(&self, tenant: &str) -> anyhow::Result<PolicyStatus> {
        self.policies.invalidate(tenant);
        let running = (*self.policy_for(tenant).await?).clone();
        let history = self.policy_source.history(tenant, 50).await?;
        let active = history.first().and_then(|a| a.version);
        let warning = active
            .filter(|n| running.policy.spec.as_ref().and_then(|s| s.version) != Some(*n))
            .map(|n| format!("v{n} is active but no longer compiles under the current governance, so the default policy runs; roll back or propose a new version"));
        Ok(PolicyStatus { tenant: tenant.to_string(), active, running, warning, specs: self.policy_source.specs(tenant).await?, history })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(extra: &str) -> PolicySpec {
        parse_spec(&format!("name = \"t\"\n[scope]\ntenant = \"acme\"\n{extra}")).unwrap()
    }

    fn strict() -> Config {
        let mut cfg = Config::default();
        cfg.governance.redact = vec!["secret".into(), "card".into(), "email".into()];
        cfg.governance.denied_labels = vec!["hr".into()];
        cfg.governance.episodic_retention_days = 90;
        cfg.governance.audit_reads = true;
        cfg.access.admission = Admission::Review;
        cfg
    }

    /// POL-01: an empty spec compiles to the configuration; settings it gives override it.
    #[test]
    fn compiles_and_inherits() {
        let cfg = Config::default();
        let empty = compile(&spec(""), &cfg, "acme", Some(1)).unwrap();
        let mut gov = default_policy(&cfg, "acme").policy;
        gov.spec = empty.policy.spec.clone();
        assert_eq!(empty.policy, gov);
        assert!(empty.version.starts_with("policy-v1-"));
        let p = compile(&spec("[ranking]\nrecency_weight = 0.2\nrrf_k = 30\n[memory_types]\nallowed = [\"semantic\", \"working\"]"), &cfg, "acme", None).unwrap();
        assert_eq!((p.policy.ranking.recency_weight, p.policy.ranking.rrf_k), (0.2, 30.0));
        assert_eq!(p.policy.memory_types.allowed, vec![MemoryKind::Working, MemoryKind::Semantic]);
        assert!(p.version.starts_with("draft-") && !p.allows(MemoryKind::Episodic));
        // Equal policies get equal versions; the default's version names the configuration.
        assert_eq!(default_policy(&cfg, "acme").version, default_policy(&cfg, "acme").version);
        assert!(default_policy(&cfg, "acme").version.starts_with("gov-"));
        assert_ne!(default_policy(&cfg, "acme").version, default_policy(&cfg, "other").version);
    }

    /// POL-04: every attempt to loosen governance fails, each with its own message.
    #[test]
    fn loosening_fails_with_reasons() {
        let cfg = strict();
        let cases = [
            ("[retention]\nepisodic_days = 0", "retention.episodic_days", "PR-1"),
            ("[retention]\nepisodic_days = 365", "retention.episodic_days", "PR-1"),
            ("[redaction]\ncategories = [\"secret\", \"card\"]", "redaction.categories", "PR-1"),
            ("[redaction]\ncategories = [\"card\", \"email\"]", "redaction.categories", "baseline"),
            ("[recall]\ndenied_labels = []", "recall.denied_labels", "PR-1"),
            ("[recall]\naudit_reads = false", "recall.audit_reads", "PR-1"),
            ("[write_gate]\nadmission = \"auto\"", "write_gate.admission", "PR-1"),
            ("[write_gate]\nmax_content_chars = 50000", "write_gate.max_content_chars", "PR-1"),
            ("[write_gate]\nquarantine_injection = false", "write_gate.quarantine_injection", "baseline"),
        ];
        for (extra, path, rule) in cases {
            let v = compile(&spec(extra), &cfg, "acme", None).expect_err(extra);
            assert!(v.iter().any(|v| v.path == path && v.rule == rule), "{extra}: {v:?}");
            assert!(v.iter().all(|v| !v.message.is_empty()));
        }
        // Tightening is fine.
        let ok = "[retention]\nepisodic_days = 30\n[redaction]\ncategories = [\"secret\", \"card\", \"email\", \"phone\"]\n[recall]\ndenied_labels = [\"hr\", \"legal\"]";
        let p = compile(&spec(ok), &cfg, "acme", None).unwrap();
        assert_eq!(p.policy.retention.episodic_days, 30);
        assert_eq!(p.policy.recall.denied_labels, vec!["hr", "legal"]);
        // All problems at once, and the error lists them.
        let v = compile(&spec("[retention]\nepisodic_days = 0\n[recall]\naudit_reads = false\n[ranking]\nrrf_k = -1"), &cfg, "acme", None).unwrap_err();
        assert_eq!(v.len(), 3);
        assert!(violations_error(&v).to_string().contains("3 problems"));
    }

    #[test]
    fn rejects_unknown_fields_scope_and_ranges() {
        assert!(parse_spec("name = \"t\"\n[scope]\ntenant = \"acme\"\n[ranking]\nrecency = 1").unwrap_err().to_string().contains("unknown field"));
        let v = compile(&spec(""), &Config::default(), "other", None).unwrap_err();
        assert_eq!(v[0].rule, "scope");
        let v =
            compile(&spec("[ranking]\nkeyword_weight = 0\nvector_weight = 0\ndefault_k = 0\n[redaction]\ncategories = [\"secret\", \"dna\"]"), &Config::default(), "acme", None)
                .unwrap_err();
        assert!(v.iter().any(|v| v.path == "ranking.default_k") && v.iter().any(|v| v.path == "ranking") && v.iter().any(|v| v.rule == "unknown"));
        let json = parse_spec(r#"{"name": "j", "scope": {"tenant": "acme"}, "ranking": {"vector_weight": 2}}"#).unwrap();
        assert_eq!(compile(&json, &Config::default(), "acme", None).unwrap().policy.ranking.vector_weight, 2.0);
    }

    #[test]
    fn diffs_settings() {
        let cfg = Config::default();
        let a = default_policy(&cfg, "acme").policy;
        let b = compile(&spec("[ranking]\nrecency_weight = 0.3\n[recall]\ndenied_labels = [\"hr\"]"), &cfg, "acme", Some(2)).unwrap().policy;
        let d = diff(&a, &b);
        let paths: Vec<&str> = d.iter().map(|c| c.path.as_str()).collect();
        assert!(paths.contains(&"ranking.recency_weight") && paths.contains(&"recall.denied_labels") && paths.contains(&"spec.version"), "{paths:?}");
        assert!(diff(&a, &a).is_empty());
        assert_eq!(PolicyTarget::parse("v3").unwrap(), PolicyTarget::Version(3));
        assert_eq!(PolicyTarget::parse("default").unwrap(), PolicyTarget::Default);
        assert!(PolicyTarget::parse("v0").is_err());
    }
}
