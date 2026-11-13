// SPDX-License-Identifier: Apache-2.0
//! The evaluation harness (roadmap G13): scripted multi-session conversations with ground truth
//! at checkpoints, replayed through the real write and recall paths, and scored for storage and
//! retrieval separately (QUAL-03), with the stale-fact and contamination rates (QUAL-11).
//!
//! A *suite* is a list of conversations. Each turn says what should become of it: `commit` (a
//! fact, a correction, a preference), `hold` (a plan or a guess: it must not become a fact) or
//! `ignore` (small talk, no expectation). A `commit` turn may name the `key` it sets, so a later
//! turn with the same key makes the earlier one stale. After each session comes a checkpoint: the
//! state of the store is compared with the truth at that point, and the session's questions are
//! asked.
//!
//! The same suite replayed under two policies gives the regression gate its paired comparison
//! (QUAL-05): [`compare`] refuses a change that lowers storage or retrieval F1 or raises the
//! stale-fact or contamination rate by more than the thresholds.
//!
//! A replay writes into a scratch tenant of its own, under the policy being evaluated, and
//! erases it afterwards: evaluating never touches a tenant's memory. No model is called beyond
//! what the write path itself is configured to call.

use crate::policy::CompiledPolicy;
use crate::types::*;
use crate::Engine;
use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use uuid::Uuid;

/// The suite format version this build reads and writes.
pub const SUITE_FORMAT: u32 = 1;

/// Part of every scratch tenant's name. A scratch tenant runs a policy pinned in the engine that
/// replays into it, so the intake queue hands its proposals only to a caller that asks for them
/// by tenant and subject (the replaying engine), never to a worker.
pub const SCRATCH_MARK: &str = "~eval~";

/// What should become of a turn.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Expect {
    /// A fact, a correction or a preference: it should be committed.
    #[default]
    Commit,
    /// A plan or a guess: it must not be committed as a fact (PR-7).
    Hold,
    /// Small talk or a question: nothing is expected of it and it is not scored.
    Ignore,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SuiteTurn {
    /// What the user says; written as it would be by an agent calling `remember`.
    pub say: String,
    #[serde(default)]
    pub expect: Expect,
    /// What the turn states a value for (`city`, `plan`). A later `commit` turn with the same key
    /// replaces this one: from then on this turn is stale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// The memory type written; semantic when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<MemoryKind>,
    /// A name for the turn within its conversation, so a later turn can refer to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// The `id` of an earlier `hold` turn that this turn carries out ("I plan to move to
    /// Porto" … "I moved to Porto"). The engine may then commit the plan's own record, and
    /// rightly so: from here on the plan is not scored, neither as held nor as contamination.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confirms: Option<String>,
    /// What the statement gate should read the turn as. Used by a language pack's test set
    /// (`memhouse lang check --tests`); a replay does not score it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub statement: Option<Statement>,
    /// The turn is an injection attempt: the gate must quarantine it. Such a turn is a `hold`
    /// turn (it must not be committed).
    #[serde(default, skip_serializing_if = "is_false")]
    pub injection: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// A question asked at a checkpoint.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SuiteQuestion {
    pub q: String,
    /// The key whose current value answers it: the record of the newest `commit` turn with this
    /// key is the relevant one, and the records of the turns it replaced are stale. Empty for a
    /// question that only tests how it is read (`covers`, `ids`); a replay does not ask it.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub key: String,
    /// Days the question's time phrases must cover, read at the session's time ("two weeks
    /// ago" asked on 1 July covers 17 June). Used by a language pack's test set.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub covers: Vec<chrono::NaiveDate>,
    /// The identifiers the question names ("order A-1001" names `a-1001`). Used by a language
    /// pack's test set.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SuiteSession {
    /// When the session happened (the event time of its turns).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<DateTime<Utc>>,
    pub turns: Vec<SuiteTurn>,
    /// Asked at the checkpoint after the session.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ask: Vec<SuiteQuestion>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SuiteConversation {
    pub id: String,
    pub sessions: Vec<SuiteSession>,
}

/// An evaluation suite, as written in YAML or JSON.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Suite {
    /// Suite format; 1.
    #[serde(default = "suite_format")]
    pub format: u32,
    /// A short name: letters, digits, `.`, `_` and `-`.
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    /// The language the suite is written in, as a language-pack code: set on a pack's test set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// Hits a question's answer is looked for in (default 5).
    #[serde(default = "default_k")]
    pub k: usize,
    pub conversations: Vec<SuiteConversation>,
}

fn suite_format() -> u32 {
    SUITE_FORMAT
}

fn default_k() -> usize {
    5
}

impl Suite {
    /// Check a suite before it is stored or run; the message names the conversation and turn.
    pub fn validate(&self) -> anyhow::Result<()> {
        let bad = |m: String| Err(crate::error::invalid(format!("suite {}: {m}", self.name)));
        if self.format != SUITE_FORMAT {
            return bad(format!("format {} is not one this build reads ({SUITE_FORMAT})", self.format));
        }
        if self.name.is_empty() || self.name.len() > 80 || !self.name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)) {
            return bad("the name must be 1 to 80 letters, digits, '.', '_' or '-'".into());
        }
        if !(1..=50).contains(&self.k) {
            return bad(format!("k = {} is outside 1 to 50", self.k));
        }
        if self.conversations.is_empty() {
            return bad("it has no conversation".into());
        }
        let mut ids = std::collections::HashSet::new();
        for c in &self.conversations {
            if c.id.is_empty() || !ids.insert(&c.id) {
                return bad(format!("conversation id '{}' is empty or used twice", c.id));
            }
            let mut keys = std::collections::HashSet::new();
            let mut plans = std::collections::HashSet::new();
            let mut turn_ids = std::collections::HashSet::new();
            for (s, session) in c.sessions.iter().enumerate() {
                for (t, turn) in session.turns.iter().enumerate() {
                    if turn.say.trim().is_empty() {
                        return bad(format!("conversation {}, session {}, turn {}: nothing is said", c.id, s + 1, t + 1));
                    }
                    if let Some(of) = &turn.confirms {
                        if turn.expect != Expect::Commit || !plans.contains(of.as_str()) {
                            return bad(format!(
                                "conversation {}, session {}, turn {}: `confirms: {of}` must be on a commit turn and name an earlier hold turn's id",
                                c.id,
                                s + 1,
                                t + 1
                            ));
                        }
                    }
                    if let Some(id) = &turn.id {
                        if !turn_ids.insert(id.as_str()) {
                            return bad(format!("conversation {}, session {}, turn {}: the turn id '{id}' is used twice", c.id, s + 1, t + 1));
                        }
                        if turn.expect == Expect::Hold {
                            plans.insert(id.as_str());
                        }
                    }
                    if let (Expect::Commit, Some(k)) = (turn.expect, &turn.key) {
                        keys.insert(k.as_str());
                    }
                    let held = turn.statement.is_some_and(|st| st.held()) || turn.injection;
                    if (turn.statement.is_some() || turn.injection) && held != (turn.expect == Expect::Hold) {
                        return bad(format!(
                            "conversation {}, session {}, turn {}: a plan, a guess and an injection attempt are `expect: hold` turns, and no other labelled statement is",
                            c.id,
                            s + 1,
                            t + 1
                        ));
                    }
                }
                if let Some(q) = session.ask.iter().find(|q| q.key.is_empty() && q.covers.is_empty() && q.ids.is_empty()) {
                    return bad(format!("conversation {}, session {}: the question '{}' has no key, and tests nothing else (covers, ids)", c.id, s + 1, q.q));
                }
                if let Some(q) = session.ask.iter().find(|q| !q.covers.is_empty() && session.at.is_none()) {
                    return bad(format!("conversation {}, session {}: the question '{}' has `covers`, so its session needs a time (`at`)", c.id, s + 1, q.q));
                }
                if let Some(q) = session.ask.iter().find(|q| !q.key.is_empty() && !keys.contains(q.key.as_str())) {
                    return bad(format!("conversation {}, session {}: the question '{}' asks for key '{}', which no earlier turn commits", c.id, s + 1, q.q, q.key));
                }
            }
        }
        Ok(())
    }

    /// The suite's identity: the hash of its canonical JSON. Two runs are paired only when they
    /// replayed the same items.
    pub fn hash(&self) -> String {
        crate::engine::content_hash(&serde_json::to_string(self).unwrap_or_default())
    }

    pub fn turns(&self) -> usize {
        self.conversations.iter().flat_map(|c| &c.sessions).map(|s| s.turns.len()).sum()
    }
}

/// Counts from one replay (of a conversation, or summed over a suite). Every metric is a ratio
/// of two of them, so sums over conversations stay exact and can be resampled.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct EvalCounts {
    /// Current facts at checkpoints, and how many of them were stored (committed and valid).
    pub truth: u64,
    pub truth_stored: u64,
    /// Scored records found committed and valid at checkpoints, and how many of them are current
    /// facts (the others are stale facts still valid, or plans and guesses committed).
    pub stored: u64,
    pub stored_true: u64,
    /// Questions asked, those whose first hit is the current fact, and those with it in the top k.
    pub questions: u64,
    pub first_correct: u64,
    pub found: u64,
    /// Questions about a fact that was corrected, and those answered with a stale version in the top k.
    pub corrected_questions: u64,
    pub stale_returned: u64,
    /// Plans and guesses at checkpoints, and how many were committed as facts.
    pub held: u64,
    pub held_committed: u64,
}

impl EvalCounts {
    pub fn add(&mut self, o: &EvalCounts) {
        self.truth += o.truth;
        self.truth_stored += o.truth_stored;
        self.stored += o.stored;
        self.stored_true += o.stored_true;
        self.questions += o.questions;
        self.first_correct += o.first_correct;
        self.found += o.found;
        self.corrected_questions += o.corrected_questions;
        self.stale_returned += o.stale_returned;
        self.held += o.held;
        self.held_committed += o.held_committed;
    }

    pub fn metrics(&self) -> EvalMetrics {
        let ratio = |a: u64, b: u64| if b == 0 { None } else { Some(a as f64 / b as f64) };
        let f1 = |p: Option<f64>, r: Option<f64>| match (p, r) {
            (Some(p), Some(r)) if p + r > 0.0 => Some(2.0 * p * r / (p + r)),
            (Some(_), Some(_)) => Some(0.0),
            _ => None,
        };
        let (sp, sr) = (ratio(self.stored_true, self.stored).or(ratio(0, self.truth)), ratio(self.truth_stored, self.truth));
        let (rp, rr) = (ratio(self.first_correct, self.questions), ratio(self.found, self.questions));
        EvalMetrics {
            storage_precision: sp,
            storage_recall: sr,
            storage_f1: f1(sp, sr),
            retrieval_precision: rp,
            retrieval_recall: rr,
            retrieval_f1: f1(rp, rr),
            stale_rate: ratio(self.stale_returned, self.corrected_questions),
            contamination_rate: ratio(self.held_committed, self.held),
        }
    }
}

/// The quality metrics of a replay, each 0 to 1; `None` when the suite has nothing to measure it
/// on (no question, no correction, no plan).
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct EvalMetrics {
    /// Of the scored records committed and valid at a checkpoint, the part that are current facts.
    pub storage_precision: Option<f64>,
    /// Of the current facts at a checkpoint, the part that is stored.
    pub storage_recall: Option<f64>,
    pub storage_f1: Option<f64>,
    /// Of the questions, the part whose first hit is the current fact.
    pub retrieval_precision: Option<f64>,
    /// Of the questions, the part with the current fact in the top k.
    pub retrieval_recall: Option<f64>,
    pub retrieval_f1: Option<f64>,
    /// Of the questions about a corrected fact, the part answered with a stale version in the top k.
    pub stale_rate: Option<f64>,
    /// Of the plans and guesses, the part committed as facts.
    pub contamination_rate: Option<f64>,
}

/// What the engine ran with, apart from the policy: a change of any part is a model or engine
/// change (QUAL-05), and with all of them pinned a replay is reproducible (QUAL-10).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Fingerprint {
    pub engine: String,
    pub embedder: String,
    pub classifier: String,
    pub reranker: Option<String>,
    /// Hash of the write pipeline's settings (`[intake]`): thresholds such as
    /// `correction_threshold` change what a replay stores without changing the policy.
    #[serde(default)]
    pub intake: String,
}

/// Why a suite was replayed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum EvalTrigger {
    /// Asked for (`memhouse eval run`).
    Manual,
    /// A policy version waiting for approval, and the active policy it is compared with.
    PolicyChange,
    /// The engine or a model changed (`memhouse eval gate`).
    ModelChange,
}

impl EvalTrigger {
    pub fn as_str(&self) -> &'static str {
        match self {
            EvalTrigger::Manual => "manual",
            EvalTrigger::PolicyChange => "policy_change",
            EvalTrigger::ModelChange => "model_change",
        }
    }

    pub fn parse(s: &str) -> Option<EvalTrigger> {
        [EvalTrigger::Manual, EvalTrigger::PolicyChange, EvalTrigger::ModelChange].into_iter().find(|t| t.as_str() == s)
    }
}

/// One replay of a suite, as stored per tenant and policy version (QUAL-04).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct EvalRun {
    pub id: Uuid,
    pub tenant: String,
    pub suite: String,
    pub suite_hash: String,
    pub policy_version: String,
    pub fingerprint: Fingerprint,
    pub trigger: EvalTrigger,
    pub counts: EvalCounts,
    pub metrics: EvalMetrics,
    /// Counts per conversation, in suite order (for confidence intervals and paired comparison).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub per_conversation: Vec<EvalCounts>,
    /// Content hash and final status of every scored record, in suite order (QUAL-10).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outcomes: Vec<String>,
    pub took_ms: f64,
    pub created_at: DateTime<Utc>,
    /// Set on a replay made for a gate: whether the gate passed with it. A replay that failed
    /// its gate is kept for the record but is never the reference of a later comparison.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate_passed: Option<bool>,
}

/// A suite a tenant registered (QUAL-04): replayed on demand and before a policy is approved.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct StoredSuite {
    pub tenant: String,
    pub name: String,
    pub hash: String,
    pub suite: Suite,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

/// The regression gate's limits (QUAL-05), in points (hundredths).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct GateLimits {
    pub max_f1_drop: f64,
    pub max_stale_rise: f64,
    pub max_contamination_rise: f64,
}

/// One metric of a gate decision, in points.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct GateFinding {
    pub suite: String,
    pub metric: String,
    pub before: f64,
    pub after: f64,
    /// `after - before`.
    pub change: f64,
    /// The largest change allowed in the bad direction.
    pub limit: f64,
    pub passed: bool,
}

/// The gate's decision on a change, with every metric it looked at.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct GateReport {
    pub passed: bool,
    pub before_policy: String,
    pub after_policy: String,
    pub findings: Vec<GateFinding>,
}

impl GateReport {
    /// The report as text: one line per metric that failed, or all of them.
    pub fn text(&self, all: bool) -> String {
        let line = |f: &GateFinding| {
            format!("{} {}: {} {:.1} -> {:.1} ({:+.1} points, limit {:.1})", if f.passed { "ok  " } else { "FAIL" }, f.suite, f.metric, f.before, f.after, f.change, f.limit)
        };
        let lines: Vec<String> = self.findings.iter().filter(|f| all || !f.passed).map(line).collect();
        format!("regression gate {}: {} against {}\n{}", if self.passed { "passed" } else { "failed" }, self.after_policy, self.before_policy, lines.join("\n"))
    }
}

/// Compare two replays of the same suite (QUAL-05): storage and retrieval F1 may not fall by more
/// than `max_f1_drop` points, the stale-fact rate may not rise by more than `max_stale_rise`
/// points, nor the contamination rate by more than `max_contamination_rise`. A metric the suite
/// can't measure is left out.
pub fn compare(suite: &str, before: &EvalMetrics, after: &EvalMetrics, limits: &GateLimits) -> Vec<GateFinding> {
    let mut out = vec![];
    let mut check = |metric: &str, b: Option<f64>, a: Option<f64>, limit: f64, higher_is_better: bool| {
        if let (Some(b), Some(a)) = (b, a) {
            let (b, a) = (b * 100.0, a * 100.0);
            let change = a - b;
            let worse = if higher_is_better { -change } else { change };
            out.push(GateFinding { suite: suite.into(), metric: metric.into(), before: b, after: a, change, limit, passed: worse <= limit + 1e-9 });
        }
    };
    check("storage_f1", before.storage_f1, after.storage_f1, limits.max_f1_drop, true);
    check("retrieval_f1", before.retrieval_f1, after.retrieval_f1, limits.max_f1_drop, true);
    check("stale_rate", before.stale_rate, after.stale_rate, limits.max_stale_rise, false);
    check("contamination_rate", before.contamination_rate, after.contamination_rate, limits.max_contamination_rise, false);
    out
}

/// A turn as replayed: what was expected of it and the record it became.
struct Played {
    expect: Expect,
    key: Option<String>,
    /// The record the turn became; nil when the policy refused the write.
    id: Uuid,
    /// The turn's own name in the suite, if it has one.
    name: Option<String>,
}

impl Engine {
    /// What this engine runs with, apart from the policy.
    pub fn fingerprint(&self) -> Fingerprint {
        Fingerprint {
            engine: env!("CARGO_PKG_VERSION").to_string(),
            embedder: self.embedder.id().to_string(),
            // The language packs are the rules' data: other packs, other results.
            classifier: format!(
                "{}{}",
                match self.cfg.intake.classifier {
                    crate::config::ClassifierKind::Rules => "rules".to_string(),
                    crate::config::ClassifierKind::Llm => format!("llm:{}", self.cfg.intake.llm.model),
                },
                if self.languages.tag().is_empty() { String::new() } else { format!("+lang:{}", self.languages.tag()) }
            ),
            reranker: self.reranker.as_ref().filter(|_| self.cfg.rerank.enabled).map(|_| self.cfg.rerank.model.clone()),
            intake: crate::engine::content_hash(&serde_json::to_string(&self.cfg.intake).unwrap_or_default())[..12].to_string(),
        }
    }

    /// Replay a suite under `policy` (the tenant's active policy when `None`) and score it. The
    /// replay writes into a scratch tenant, which is erased before this returns; nothing is
    /// stored about the run (see [`Engine::eval_record`]).
    pub async fn eval_replay(&self, tenant: &str, suite: &Suite, policy: Option<Arc<CompiledPolicy>>, trigger: EvalTrigger) -> anyhow::Result<EvalRun> {
        suite.validate()?;
        let start = std::time::Instant::now();
        let policy = match policy {
            Some(p) => p,
            None => self.policy_for(tenant).await?,
        };
        let id = Uuid::now_v7();
        let scratch = format!("{tenant}{SCRATCH_MARK}{}", &id.simple().to_string()[20..]);
        // The scratch tenant runs the policy being evaluated; its records carry that version.
        self.store.policy_put(&policy.line()).await?;
        // No recall explanation is kept: it is written off the request path and could land
        // after the scratch tenant is erased.
        let mut engine = self.clone().with_policy_pin(&scratch, policy.clone());
        engine.explain_recalls = false;
        // A replay measures quality, not speed: a recall is given the time it needs, and one
        // that still fails is an error of the replay, never an empty answer to score.
        let mut cfg = (*engine.cfg).clone();
        cfg.memory.recall_timeout_ms = 0;
        engine.cfg = Arc::new(cfg);
        let replayed = futures::future::join_all(suite.conversations.chunks(suite.conversations.len().div_ceil(8).max(1)).map(|chunk| {
            let engine = &engine;
            let scratch = &scratch;
            async move {
                let mut out = vec![];
                for c in chunk {
                    out.push(engine.eval_conversation(scratch, c, suite.k).await);
                }
                out
            }
        }))
        .await;
        let erased =
            engine.forget_by(ForgetRequest { tenant: Some(scratch.clone()), all: true, confirm: Some(scratch.clone()), actor: Some("eval".into()), ..Default::default() }).await;
        let mut counts = EvalCounts::default();
        let (mut per_conversation, mut outcomes) = (vec![], vec![]);
        for r in replayed.into_iter().flatten() {
            let (c, o) = r?;
            counts.add(&c);
            per_conversation.push(c);
            outcomes.extend(o);
        }
        erased?;
        Ok(EvalRun {
            id,
            tenant: tenant.into(),
            suite: suite.name.clone(),
            suite_hash: suite.hash(),
            policy_version: policy.version.clone(),
            fingerprint: self.fingerprint(),
            trigger,
            counts,
            metrics: counts.metrics(),
            per_conversation,
            outcomes,
            took_ms: start.elapsed().as_secs_f64() * 1000.0,
            created_at: Utc::now(),
            gate_passed: None,
        })
    }

    /// One conversation: its sessions in order, a checkpoint after each.
    async fn eval_conversation(&self, tenant: &str, c: &SuiteConversation, k: usize) -> anyhow::Result<(EvalCounts, Vec<String>)> {
        let subject = format!("eval:{}", c.id);
        let mut counts = EvalCounts::default();
        let mut played: Vec<Played> = vec![];
        // Plans carried out so far (by turn id): no longer scored.
        let mut confirmed: std::collections::HashSet<String> = std::collections::HashSet::new();
        for session in &c.sessions {
            for turn in &session.turns {
                let written = self
                    .remember(RememberRequest {
                        tenant: Some(tenant.into()),
                        subject: Some(subject.clone()),
                        content: turn.say.clone(),
                        kind: turn.kind,
                        occurred_at: session.at,
                        actor: Some("eval".into()),
                        source: Some("eval".into()),
                        wait: true,
                        ..Default::default()
                    })
                    .await;
                let id = match written {
                    Ok(r) => r.id,
                    // The policy refuses the write (a kind it forbids, a text over its limit):
                    // that is an outcome to score, not a failed replay. Nothing was stored. Only
                    // an error raised as a refusal counts: a store or provider failure whose
                    // message merely reads like one fails the replay.
                    Err(e) if crate::error::coded(&e) == Some(crate::error::ErrorCode::InvalidRequest) => Uuid::nil(),
                    Err(e) => return Err(e),
                };
                // A write still queued when its wait ran out (a loaded machine) would be judged
                // by the next turn's gate as if it did not exist. Wait until it is settled: a
                // replay that can't settle a write fails, it never scores a half-written state.
                let mut tries = 0;
                while !id.is_nil() && self.intake.pending(tenant, id).await?.is_some() {
                    tries += 1;
                    anyhow::ensure!(tries <= 30, "evaluation: the write of conversation {} did not settle; its replay is not scored", c.id);
                    self.settle_record(tenant, id).await?;
                }
                // A write the pipeline gave up on (set aside after its attempts failed: a model
                // or the store was down) says nothing about quality: the replay fails.
                if !id.is_nil() {
                    let gave_up = self.store.get(tenant, id).await?.is_some_and(|m| {
                        m.status == MemoryStatus::Quarantined
                            && m.metadata.get("quarantine_reasons").and_then(|r| r.as_array()).is_some_and(|r| r.iter().any(|x| x == "intake_failed"))
                    });
                    anyhow::ensure!(!gave_up, "evaluation: the write pipeline failed on a write of conversation {}; its replay is not scored", c.id);
                }
                if let Some(of) = &turn.confirms {
                    confirmed.insert(of.clone());
                }
                played.push(Played { expect: turn.expect, key: turn.key.clone(), id, name: turn.id.clone() });
            }
            // The truth at this checkpoint: for each key, the newest commit turn is current and
            // the earlier ones are stale.
            let mut current: HashMap<&str, usize> = HashMap::new();
            for (i, p) in played.iter().enumerate() {
                if let (Expect::Commit, Some(key)) = (p.expect, p.key.as_deref()) {
                    current.insert(key, i);
                }
            }
            let is_current = |i: usize, p: &Played| p.expect == Expect::Commit && p.key.as_deref().is_none_or(|key| current.get(key) == Some(&i));
            let now = Utc::now();
            let mut live = std::collections::HashSet::new();
            // A plan that a later turn carried out is out of the scoring from then on.
            let scored = |p: &Played| p.expect != Expect::Ignore && !(p.expect == Expect::Hold && p.name.as_ref().is_some_and(|n| confirmed.contains(n)));
            for p in played.iter().filter(|p| !p.id.is_nil()) {
                if let Some(m) = self.store.get(tenant, p.id).await? {
                    if m.status == MemoryStatus::Committed && m.valid_to.is_none_or(|t| t > now) && m.expires_at.is_none_or(|t| t > now) {
                        live.insert(p.id);
                    }
                }
            }
            // A turn deduplicated onto an earlier record shares its id: score each record once,
            // by the newest turn that produced it.
            let mut newest: HashMap<Uuid, usize> = HashMap::new();
            for (i, p) in played.iter().enumerate() {
                if scored(p) && !p.id.is_nil() {
                    newest.insert(p.id, i);
                }
            }
            for (i, p) in played.iter().enumerate() {
                if !scored(p) {
                    continue;
                }
                match p.expect {
                    Expect::Ignore => continue,
                    Expect::Hold => {
                        counts.held += 1;
                        counts.held_committed += u64::from(live.contains(&p.id));
                    }
                    Expect::Commit if is_current(i, p) => {
                        counts.truth += 1;
                        counts.truth_stored += u64::from(live.contains(&p.id));
                    }
                    Expect::Commit => {}
                }
                if newest.get(&p.id) == Some(&i) && live.contains(&p.id) {
                    counts.stored += 1;
                    counts.stored_true += u64::from(is_current(i, p));
                }
            }
            for q in &session.ask {
                let Some(&answer) = current.get(q.key.as_str()) else { continue };
                let stale: Vec<Uuid> = played
                    .iter()
                    .enumerate()
                    .filter(|(i, p)| *i != answer && p.expect == Expect::Commit && p.key.as_deref() == Some(q.key.as_str()) && p.id != played[answer].id)
                    .map(|(_, p)| p.id)
                    .collect();
                let r = self
                    .recall(RecallRequest {
                        tenant: Some(tenant.into()),
                        subject: Some(subject.clone()),
                        query: q.q.clone(),
                        k: Some(k),
                        actor: Some("eval".into()),
                        ..Default::default()
                    })
                    .await?;
                if let Some(why) = &r.degraded {
                    anyhow::bail!("evaluation: a recall of conversation {} failed ({why:?}); its replay is not scored", c.id);
                }
                let ids: Vec<Uuid> = r.hits.iter().map(|h| h.memory.id).collect();
                counts.questions += 1;
                counts.first_correct += u64::from(ids.first() == Some(&played[answer].id));
                counts.found += u64::from(ids.contains(&played[answer].id));
                if !stale.is_empty() {
                    counts.corrected_questions += 1;
                    counts.stale_returned += u64::from(stale.iter().any(|s| ids.contains(s)));
                }
            }
        }
        // What each scored turn ended as: the same on every replay with pinned models (QUAL-10).
        let mut outcomes = vec![];
        for (turn, p) in c.sessions.iter().flat_map(|s| &s.turns).zip(&played) {
            // A refused write is an outcome whatever was expected of the turn.
            if p.expect != Expect::Ignore || p.id.is_nil() {
                let status =
                    if p.id.is_nil() { "refused".to_string() } else { self.store.get(tenant, p.id).await?.map(|m| m.status.as_str().to_string()).unwrap_or_else(|| "gone".into()) };
                outcomes.push(format!("{}:{}:{status}", c.id, &crate::engine::content_hash(&turn.say)[..12]));
            }
        }
        Ok((counts, outcomes))
    }

    /// Register a suite for the tenant (QUAL-04), replacing one of the same name.
    pub async fn eval_suite_put(&self, tenant: &str, suite: &Suite, by: &str) -> anyhow::Result<StoredSuite> {
        suite.validate()?;
        let stored = StoredSuite { tenant: tenant.into(), name: suite.name.clone(), hash: suite.hash(), suite: suite.clone(), created_by: by.into(), created_at: Utc::now() };
        self.store.eval_suite_put(&stored).await?;
        self.store
            .audit(
                by,
                "eval.suite_put",
                tenant,
                None,
                None,
                serde_json::json!({ "suite": suite.name, "hash": stored.hash, "conversations": suite.conversations.len(), "turns": suite.turns() }),
            )
            .await?;
        Ok(stored)
    }

    pub async fn eval_suite_delete(&self, tenant: &str, name: &str, by: &str) -> anyhow::Result<bool> {
        let gone = self.store.eval_suite_delete(tenant, name).await?;
        if gone {
            self.store.audit(by, "eval.suite_delete", tenant, None, None, serde_json::json!({ "suite": name })).await?;
        }
        Ok(gone)
    }

    /// Replay a suite and keep the result with the policy version it ran under (QUAL-04).
    pub async fn eval_record(&self, tenant: &str, suite: &Suite, policy: Option<Arc<CompiledPolicy>>, trigger: EvalTrigger) -> anyhow::Result<EvalRun> {
        let run = self.eval_replay(tenant, suite, policy, trigger).await?;
        self.store.eval_run_put(&run).await?;
        Ok(run)
    }

    /// The regression gate for a policy change (QUAL-05): replay every suite of the tenant under
    /// the active policy and under `candidate`, on the same items, and compare. Both runs are
    /// stored. `None` when the tenant has no suite or the gate is turned off.
    pub async fn eval_gate_policy(&self, tenant: &str, candidate: Arc<CompiledPolicy>) -> anyhow::Result<Option<GateReport>> {
        if !self.cfg.eval.gate {
            return Ok(None);
        }
        let suites = self.store.eval_suites(tenant).await?;
        if suites.is_empty() {
            return Ok(None);
        }
        let active = self.policy_for(tenant).await?;
        let limits = self.cfg.eval.limits();
        let fingerprint = self.fingerprint();
        let (mut findings, mut replays) = (vec![], vec![]);
        for s in &suites {
            // The active policy's replay of these items by this engine is reused when it exists.
            let known = self.store.eval_runs(tenant, Some(&s.name), 50).await?;
            let reusable = |r: &EvalRun| r.suite_hash == s.hash && r.policy_version == active.version && r.fingerprint == fingerprint && r.gate_passed != Some(false);
            let before = match known.into_iter().find(reusable) {
                Some(r) => r,
                None => self.eval_record(tenant, &s.suite, Some(active.clone()), EvalTrigger::PolicyChange).await?,
            };
            let after = self.eval_replay(tenant, &s.suite, Some(candidate.clone()), EvalTrigger::PolicyChange).await?;
            findings.extend(compare(&s.name, &before.metrics, &after.metrics, &limits));
            replays.push(after);
        }
        // The gate is one decision over all suites: every replay made for it carries that
        // decision, so none of a refused change's replays is a reference later.
        let passed = findings.iter().all(|f| f.passed);
        for mut run in replays {
            run.gate_passed = Some(passed);
            self.store.eval_run_put(&run).await?;
        }
        Ok(Some(GateReport { passed: findings.iter().all(|f| f.passed), before_policy: active.version.clone(), after_policy: candidate.version.clone(), findings }))
    }

    /// The regression gate for an engine or model change (QUAL-05): replay every suite of the
    /// tenant now and compare each with its last stored replay of the same items. `None` when
    /// there is nothing to compare with yet (the replays are stored as the first reference).
    pub async fn eval_gate_now(&self, tenant: &str) -> anyhow::Result<Option<GateReport>> {
        let suites = self.store.eval_suites(tenant).await?;
        let policy = self.policy_for(tenant).await?;
        let limits = self.cfg.eval.limits();
        let (mut findings, mut before_policy, mut replays) = (vec![], None, vec![]);
        for s in &suites {
            // The reference: the last replay of these items that did not belong to a failed
            // gate, however many failed ones came after it, so a failed gate fails again.
            let last = self.store.eval_reference(tenant, &s.name, &s.hash).await?;
            let now = self.eval_replay(tenant, &s.suite, Some(policy.clone()), EvalTrigger::ModelChange).await?;
            let compared = last.is_some();
            if let Some(last) = last {
                findings.extend(compare(&s.name, &last.metrics, &now.metrics, &limits));
                before_policy.get_or_insert(last.policy_version);
            }
            replays.push((now, compared));
        }
        // One decision over all suites; a replay with nothing to compare with becomes a first
        // reference only if the gate as a whole did not fail.
        let passed = findings.iter().all(|f| f.passed);
        for (mut run, compared) in replays {
            // A first replay made while the gate failed is of the engine that failed it: it is
            // not a reference either.
            run.gate_passed = if compared || !passed { Some(passed) } else { None };
            self.store.eval_run_put(&run).await?;
        }
        Ok(before_policy.map(|b| GateReport { passed: findings.iter().all(|f| f.passed), before_policy: b, after_policy: policy.version.clone(), findings }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn suite(yaml_like: &str) -> Suite {
        serde_json::from_str(yaml_like).unwrap()
    }

    #[test]
    fn validates_names_keys_and_questions() {
        let ok = suite(
            r#"{"name":"s1","conversations":[{"id":"a","sessions":[{"turns":[{"say":"I live in Lisbon.","key":"city"},{"say":"I might move.","expect":"hold"}],
                "ask":[{"q":"Where do I live?","key":"city"}]}]}]}"#,
        );
        ok.validate().unwrap();
        assert_eq!((ok.k, ok.format, ok.turns()), (5, 1, 2));
        assert_eq!(ok.hash(), ok.clone().hash());
        let mut bad = ok.clone();
        bad.conversations[0].sessions[0].ask[0].key = "pet".into();
        assert!(bad.validate().unwrap_err().to_string().contains("no earlier turn commits"));
        let mut bad = ok.clone();
        bad.name = "has space".into();
        assert!(bad.validate().is_err());
        let mut bad = ok.clone();
        bad.conversations.push(bad.conversations[0].clone());
        assert!(bad.validate().unwrap_err().to_string().contains("used twice"));
        assert!(serde_json::from_str::<Suite>(r#"{"name":"s","conversations":[],"extra":1}"#).is_err());
    }

    #[test]
    fn metrics_are_ratios_of_the_counts() {
        let c = EvalCounts {
            truth: 10,
            truth_stored: 8,
            stored: 10,
            stored_true: 8,
            questions: 4,
            first_correct: 2,
            found: 4,
            corrected_questions: 2,
            stale_returned: 1,
            held: 5,
            held_committed: 1,
        };
        let m = c.metrics();
        assert_eq!((m.storage_precision, m.storage_recall), (Some(0.8), Some(0.8)));
        assert!((m.storage_f1.unwrap() - 0.8).abs() < 1e-9);
        assert_eq!((m.retrieval_precision, m.retrieval_recall), (Some(0.5), Some(1.0)));
        assert!((m.retrieval_f1.unwrap() - 2.0 / 3.0).abs() < 1e-9);
        assert_eq!((m.stale_rate, m.contamination_rate), (Some(0.5), Some(0.2)));
        // Nothing to measure on: no value, not zero.
        let empty = EvalCounts::default().metrics();
        assert_eq!((empty.retrieval_f1, empty.stale_rate, empty.contamination_rate), (None, None, None));
        // Truth exists and nothing was stored: precision and F1 are 0, not missing.
        let none = EvalCounts { truth: 3, ..Default::default() }.metrics();
        assert_eq!((none.storage_recall, none.storage_f1), (Some(0.0), Some(0.0)));
        let mut sum = c;
        sum.add(&c);
        assert_eq!(sum.metrics(), m);
    }

    #[test]
    fn the_gate_fails_on_a_drop_or_a_rise_past_its_limits() {
        let limits = GateLimits { max_f1_drop: 2.0, max_stale_rise: 1.0, max_contamination_rise: 1.0 };
        let before = EvalMetrics { storage_f1: Some(0.90), retrieval_f1: Some(0.80), stale_rate: Some(0.02), contamination_rate: Some(0.0), ..Default::default() };
        let same = compare("s", &before, &before, &limits);
        assert!(same.len() == 4 && same.iter().all(|f| f.passed));
        let within = EvalMetrics { storage_f1: Some(0.88), retrieval_f1: Some(0.85), stale_rate: Some(0.03), contamination_rate: Some(0.01), ..Default::default() };
        assert!(compare("s", &before, &within, &limits).iter().all(|f| f.passed));
        let worse = EvalMetrics { storage_f1: Some(0.879), retrieval_f1: Some(0.80), stale_rate: Some(0.40), contamination_rate: Some(0.0), ..Default::default() };
        let f = compare("s", &before, &worse, &limits);
        let failed: Vec<&str> = f.iter().filter(|x| !x.passed).map(|x| x.metric.as_str()).collect();
        assert_eq!(failed, ["storage_f1", "stale_rate"]);
        let report = GateReport { passed: false, before_policy: "gov-a".into(), after_policy: "policy-v2-b".into(), findings: f };
        let text = report.text(false);
        assert!(
            text.contains("regression gate failed: policy-v2-b against gov-a")
                && text.contains("stale_rate 2.0 -> 40.0 (+38.0 points, limit 1.0)")
                && !text.contains("retrieval_f1")
        );
        // A metric one side can't measure is left out.
        assert_eq!(compare("s", &before, &EvalMetrics::default(), &limits).len(), 0);
    }
}
