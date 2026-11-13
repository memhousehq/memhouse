// SPDX-License-Identifier: Apache-2.0
//! Governance checks for the evaluation platform (roadmap G13), on a scratch database:
//!
//! - `eval_harness`: a replay scores storage and retrieval separately, with the stale-fact and
//!   contamination rates, and leaves nothing behind (QUAL-03);
//! - `eval_gate`: a tenant's suite runs when a policy is up for approval; a policy that
//!   degrades it is refused with a report, and every replay is stored with its policy version
//!   (QUAL-04, QUAL-05);
//! - `eval_reproducible`: three replays of the same suite end the same for 99% of records or
//!   more (QUAL-10).

use crate::governance::{check, stub_engine, Check, Scratch};
use memhouse_core::error::{code_of, ErrorCode};
use memhouse_core::eval::{EvalTrigger, Expect, Suite, SuiteConversation, SuiteQuestion, SuiteSession, SuiteTurn, SUITE_FORMAT};
use memhouse_core::policy::parse_spec;
use memhouse_core::types::RememberRequest;
use memhouse_core::Engine;

type Outcome = anyhow::Result<(bool, String, String)>;

const TENANT: &str = "default";

fn verdict(problems: Vec<String>, value: String, ok: &str) -> (bool, String, String) {
    (problems.is_empty(), value, if problems.is_empty() { ok.to_string() } else { problems.into_iter().take(8).collect::<Vec<_>>().join("; ") })
}

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    let titles = [
        (
            "eval_harness",
            "QUAL-03 / QUAL-11",
            "A replayed suite is scored for storage and retrieval separately, with the stale-fact and contamination rates, and leaves nothing in the store",
        ),
        (
            "eval_gate",
            "QUAL-04 / QUAL-05",
            "A tenant's suite runs before a policy is approved and its results are stored per policy version; a policy that degrades it is refused with a report",
        ),
        ("eval_reproducible", "QUAL-10", "Three replays of a suite with the same models commit the same records in at least 99% of cases"),
    ];
    let results: Vec<Outcome> = match suites(engine).await {
        Ok(r) => r,
        Err(e) => titles.iter().map(|_| Err(anyhow::anyhow!("{e:#}"))).collect(),
    };
    titles
        .iter()
        .zip(results)
        .map(|((id, req, title), r)| match r {
            Ok((passed, value, detail)) => check(id, req, title, passed, value, "all", detail),
            Err(e) => check(id, req, title, false, "error".into(), "all", format!("{e:#}")),
        })
        .collect()
}

async fn suites(base: &Engine) -> anyhow::Result<Vec<Outcome>> {
    let scratch = Scratch::create(base, "eval").await?;
    let out = async {
        let e = stub_engine(base, &scratch.url, "stub:e", 256, "", true).await?;
        let pool = sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(&scratch.url).await?;
        let harness = eval_harness(&e, &pool).await;
        let reproducible = eval_reproducible(&e).await;
        // Last: it activates a policy.
        let gate = eval_gate(&e, &pool).await;
        Ok::<_, anyhow::Error>(vec![harness, gate, reproducible])
    }
    .await;
    scratch.drop().await?;
    out
}

const CITIES: [&str; 12] = ["Lisbon", "Porto", "Berlin", "Vienna", "Tallinn", "Dublin", "Lyon", "Bologna", "Utrecht", "Malmo", "Ghent", "Split"];
const FIRMS: [&str; 12] = ["Northwind", "Globex", "Initech", "Umbra", "Fenwhistle", "Brightwater", "Kestrel", "Halcyon", "Corvid", "Tessera", "Quillon", "Parallax"];

/// A controlled suite: per conversation two facts, a plan, a guess, small talk and a correction
/// of the first fact. The sentences share most of their words with what they correct, so the
/// stand-in embedder (a bag of words) puts them as close as a real one does.
fn controlled(n: usize) -> Suite {
    let conversations = (0..n)
        .map(|i| {
            let (old, new, firm) = (CITIES[i % 12], CITIES[(i + 5) % 12], FIRMS[i % 12]);
            let who = format!("Member{i:02}");
            let turn = |say: String, expect: Expect, key: Option<&str>| SuiteTurn { say, expect, key: key.map(String::from), kind: None, id: None, confirms: None };
            let ask = |q: String, key: &str| SuiteQuestion { q, key: key.into() };
            SuiteConversation {
                id: format!("c{i:02}"),
                sessions: vec![
                    SuiteSession {
                        at: Some(chrono::Utc::now() - chrono::Duration::days(90)),
                        turns: vec![
                            turn(format!("{who} keeps a registered home address in the city of {old} with the family."), Expect::Commit, Some("city")),
                            turn(format!("{who} holds a permanent engineering position at the company {firm}."), Expect::Commit, Some("employer")),
                            turn("Thanks, that is all for today.".into(), Expect::Ignore, None),
                        ],
                        ask: vec![ask(format!("In which city is the registered home address of {who}?"), "city")],
                    },
                    SuiteSession {
                        at: Some(chrono::Utc::now() - chrono::Duration::days(30)),
                        turns: vec![
                            turn(format!("{who} plans to open a second office for the company next year."), Expect::Hold, None),
                            turn(format!("{who} might take a sabbatical at some point, maybe."), Expect::Hold, None),
                            SuiteTurn { id: Some("office".into()), ..turn(format!("{who} plans to relocate the head office to Rotterdam next year."), Expect::Hold, None) },
                            turn(format!("Correction: {who} keeps a registered home address in the city of {new} with the family now."), Expect::Commit, Some("city")),
                        ],
                        ask: vec![
                            ask(format!("In which city is the registered home address of {who}?"), "city"),
                            ask(format!("At which company does {who} hold an engineering position?"), "employer"),
                        ],
                    },
                    // The plan is carried out: from here on it is no longer a held statement,
                    // whether or not the engine commits the plan's own record.
                    SuiteSession {
                        at: Some(chrono::Utc::now() - chrono::Duration::days(5)),
                        turns: vec![SuiteTurn {
                            confirms: Some("office".into()),
                            ..turn(format!("{who} relocated the head office to Rotterdam."), Expect::Commit, Some("office"))
                        }],
                        ask: vec![ask(format!("Where is the head office that {who} relocated?"), "office")],
                    },
                ],
            }
        })
        .collect();
    Suite { format: SUITE_FORMAT, name: "controlled".into(), description: String::new(), k: 3, conversations }
}

/// QUAL-03's acceptance test: separate storage and retrieval scores and a stale-fact rate.
async fn eval_harness(e: &Engine, pool: &sqlx::PgPool) -> Outcome {
    let mut problems = vec![];
    let suite = controlled(12);
    let run = e.eval_replay(TENANT, &suite, None, EvalTrigger::Manual).await?;
    let (c, m) = (&run.counts, &run.metrics);
    // 12 conversations. Current facts: 2 after session one, 2 after session two (the first
    // city is stale), 3 after session three. Held statements: 3 at the second checkpoint, 2 at
    // the third (the plan that was carried out is out of the scoring). 4 questions.
    if (c.truth, c.questions, c.held, c.corrected_questions) != (84, 48, 60, 12) {
        problems.push(format!(
            "scored items: {} facts, {} questions, {} held, {} questions about a corrected fact; expected 84, 48, 60, 12",
            c.truth, c.questions, c.held, c.corrected_questions
        ));
    }
    for (name, v) in [
        ("storage precision", m.storage_precision),
        ("storage recall", m.storage_recall),
        ("retrieval precision", m.retrieval_precision),
        ("retrieval recall", m.retrieval_recall),
        ("stale-fact rate", m.stale_rate),
        ("contamination rate", m.contamination_rate),
    ] {
        if v.is_none() {
            problems.push(format!("{name} is missing from the run"));
        }
    }
    // On this controlled set the engine is right throughout: every fact stored, the correction
    // supersedes, plans and guesses are held, and each question finds the current fact.
    if m.storage_f1 != Some(1.0) || m.retrieval_recall != Some(1.0) || m.stale_rate != Some(0.0) || m.contamination_rate != Some(0.0) {
        problems.push(format!(
            "controlled suite: storage F1 {:?}, retrieval recall {:?}, stale {:?}, contamination {:?}",
            m.storage_f1, m.retrieval_recall, m.stale_rate, m.contamination_rate
        ));
    }
    if run.per_conversation.len() != 12 || run.outcomes.len() != 12 * 7 {
        problems.push(format!("{} conversations and {} record outcomes reported", run.per_conversation.len(), run.outcomes.len()));
    }
    // A policy that refuses some of the writes is scored, not a failed replay: under one that
    // forbids semantic memory nothing of this suite is stored.
    let strict = parse_spec(&format!("name = \"no-facts\"\n[scope]\ntenant = \"{TENANT}\"\n[memory_types]\nallowed = [\"episodic\", \"working\"]"))?;
    match memhouse_core::policy::compile(&strict, &e.cfg, TENANT, None) {
        Ok(policy) => match e.eval_replay(TENANT, &controlled(2), Some(std::sync::Arc::new(policy)), EvalTrigger::Manual).await {
            Ok(refused) => {
                // Every turn of the two conversations is refused, the small talk included (8 each).
                if refused.metrics.storage_recall != Some(0.0) || refused.outcomes.len() != 16 || !refused.outcomes.iter().all(|o| o.ends_with(":refused")) {
                    problems.push(format!("under a policy that refuses the writes: storage recall {:?}, outcomes {:?}", refused.metrics.storage_recall, refused.outcomes.first()));
                }
            }
            Err(err) => problems.push(format!("a policy's refusals failed the replay instead of being scored: {err:#}")),
        },
        Err(v) => problems.push(format!("the strict policy does not compile: {v:?}")),
    }
    // Nothing of a replay outlives it: records, queued writes and recall explanations alike.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let mark = format!("%{}%", memhouse_core::eval::SCRATCH_MARK);
    for table in ["mh_recall", "mh_intake"] {
        let n: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT count(*) FROM {table} WHERE tenant LIKE $1"))).bind(&mark).fetch_one(pool).await?;
        if n != 0 {
            problems.push(format!("{n} rows of a scratch tenant are left in {table}"));
        }
    }
    // Claim isolation: a write queued for a scratch tenant is not handed to a worker (which
    // claims without naming a tenant and knows no pinned policy), only to the engine that asks
    // for it by tenant and subject; a normal tenant's queued write is handed to a worker.
    let scratch = format!("{TENANT}{}claimcheck", memhouse_core::eval::SCRATCH_MARK);
    let pinned = e.clone().with_policy_pin(&scratch, e.policy_for(TENANT).await?).with_inline_intake(false);
    let queued = |tenant: &str| RememberRequest {
        tenant: Some(tenant.into()),
        subject: Some("eval:claim".into()),
        content: "Queued for the claim check.".into(),
        actor: Some("eval".into()),
        ..Default::default()
    };
    pinned.remember(queued(&scratch)).await?;
    let lease = e.cfg.intake.lease_secs;
    let by_worker = e.intake.claim(10, lease, None).await?;
    if by_worker.iter().any(|j| j.proposal.tenant == scratch) {
        problems.push("a worker's claim was handed a scratch tenant's write".into());
    }
    let by_replay = e.intake.claim(10, lease, Some((&scratch, "eval:claim"))).await?;
    if by_replay.len() != 1 {
        problems.push(format!("the replaying engine's claim by tenant and subject got {} writes; expected 1", by_replay.len()));
    }
    e.clone().with_inline_intake(false).remember(queued(TENANT)).await?;
    let normal = e.intake.claim(10, lease, None).await?;
    if !normal.iter().any(|j| j.proposal.tenant == TENANT && j.proposal.subject == "eval:claim") {
        problems.push("a normal tenant's queued write was not handed to a worker".into());
    }
    // An ordinary tenant can't take a reserved name: its writes would never reach a worker.
    match e.remember(queued(&scratch)).await {
        Err(err) if code_of(&err) == ErrorCode::InvalidRequest && format!("{err:#}").contains("reserved for evaluation") => {}
        other => problems.push(format!("a write to a reserved tenant name without a pinned policy: {:?}", other.map(|r| r.status).map_err(|e| format!("{e:#}")))),
    }
    for t in [scratch.as_str(), TENANT] {
        sqlx::query("DELETE FROM mh_intake WHERE tenant = $1 AND subject = 'eval:claim'").bind(t).execute(pool).await?;
    }
    // The replay ran in a scratch tenant, which is gone; the tenant itself was not written to.
    let left: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory WHERE tenant LIKE $1 OR subject LIKE 'eval:%'")
        .bind(format!("{TENANT}{}%", memhouse_core::eval::SCRATCH_MARK))
        .fetch_one(pool)
        .await?;
    if left != 0 {
        problems.push(format!("{left} records of the replay are still stored"));
    }
    // An invalid suite is refused with the place of the fault.
    let mut bad = controlled(1);
    bad.conversations[0].sessions[0].ask[0].key = "pet".into();
    match e.eval_replay(TENANT, &bad, None, EvalTrigger::Manual).await {
        Err(err) if code_of(&err) == ErrorCode::InvalidRequest && format!("{err:#}").contains("conversation c00, session 1") => {}
        other => problems.push(format!("an invalid suite: {:?}", other.map(|r| r.metrics).map_err(|e| format!("{e:#}")))),
    }
    Ok(verdict(
        problems,
        format!(
            "storage F1 {:.1}, retrieval F1 {:.1}, stale {:.1}%, contamination {:.1}%",
            m.storage_f1.unwrap_or(0.0) * 100.0,
            m.retrieval_f1.unwrap_or(0.0) * 100.0,
            m.stale_rate.unwrap_or(1.0) * 100.0,
            m.contamination_rate.unwrap_or(1.0) * 100.0
        ),
        "12 scripted conversations: 84 facts at checkpoints, 48 questions, 60 held statements, a plan carried out, a policy's refusals scored; nothing left in the store",
    ))
}

/// QUAL-10's acceptance test: three replays, record-level agreement.
async fn eval_reproducible(e: &Engine) -> Outcome {
    let mut problems = vec![];
    let (suite, _) = crate::synth::generate("support", 5, 12, None)?;
    let mut runs = vec![];
    for _ in 0..3 {
        runs.push(e.eval_replay(TENANT, &suite, None, EvalTrigger::Manual).await?);
    }
    let agreement = crate::suites::agreement(&runs);
    if agreement < 0.99 {
        problems.push(format!("record-level agreement {:.2}% is below 99%", agreement * 100.0));
    }
    if runs.iter().any(|r| r.counts != runs[0].counts || r.suite_hash != runs[0].suite_hash || r.outcomes.is_empty()) {
        problems.push("the three replays did not score the same".into());
    }
    Ok(verdict(problems, format!("{:.2}% of {} records agree over 3 replays", agreement * 100.0, runs[0].outcomes.len()), "the same records end the same in every replay"))
}

/// QUAL-04 and QUAL-05's acceptance tests: a custom suite, triggered by a policy change.
async fn eval_gate(e: &Engine, pool: &sqlx::PgPool) -> Outcome {
    let mut problems = vec![];
    let suite = controlled(10);
    e.eval_suite_put(TENANT, &suite, "bench").await?;
    let spec = |n: u32, body: &str| parse_spec(&format!("name = \"eval-{n}\"\n[scope]\ntenant = \"{TENANT}\"\n{body}"));
    let runs = |pool: &sqlx::PgPool| {
        let pool = pool.clone();
        async move {
            sqlx::query_as::<_, (String, String)>("SELECT policy_version, trigger FROM mh_eval_run WHERE tenant = $1 ORDER BY created_at, id").bind(TENANT).fetch_all(&pool).await
        }
    };
    let default_version = e.policy_for(TENANT).await?.version.clone();

    // A harmless policy passes the gate and is activated; the suite ran for it automatically.
    let p1 = e.policy_propose(TENANT, &spec(1, "[ranking]\ndefault_k = 8")?, "bench", None).await?;
    let ok = e.policy_approve(TENANT, p1.version, "Dana Reviewer").await;
    let stored = runs(pool).await?;
    match &ok {
        Ok(c) => {
            if stored.len() != 2 || stored[0].0 != default_version || stored[1].0 != c.version || stored.iter().any(|(_, t)| t != "policy_change") {
                problems.push(format!("after an approval the stored runs are {stored:?}; expected the default policy's and {}", c.version));
            }
        }
        Err(err) => problems.push(format!("a harmless policy was refused: {err:#}")),
    }
    let gated: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_audit WHERE tenant = $1 AND action = 'policy.gate'").bind(TENANT).fetch_one(pool).await?;
    if gated != 1 {
        problems.push(format!("{gated} policy.gate audit events after one gated approval"));
    }
    let active_before = e.policy_for(TENANT).await?.version.clone();

    // The deliberately degraded change: corrections no longer supersede what they correct.
    let p2 = e.policy_propose(TENANT, &spec(2, "[ranking]\ndefault_k = 8\n[write_gate]\ncorrections = false")?, "bench", Some("keep every statement")).await?;
    let refused = e.policy_approve(TENANT, p2.version, "Dana Reviewer").await;
    let report = match &refused {
        Ok(c) => {
            problems.push(format!("a policy that disables corrections was approved as {}", c.version));
            String::new()
        }
        Err(err) => {
            let text = format!("{err:#}");
            if code_of(err) != ErrorCode::Conflict || !text.contains("regression gate failed") || !text.contains("stale_rate") || !text.contains("controlled") {
                problems.push(format!("the refusal does not report what degraded: {text}"));
            }
            text
        }
    };
    let rec = e.policy_source.spec(TENANT, p2.version).await?;
    if rec.as_ref().map(|r| r.status) != Some(memhouse_core::policy::SpecStatus::Proposed) || e.policy_for(TENANT).await?.version != active_before {
        problems.push("the refused version did not stay proposed, or the running policy changed".into());
    }
    let reason: Option<String> = sqlx::query_scalar("SELECT detail::jsonb ->> 'reason' FROM mh_audit WHERE tenant = $1 AND action = 'policy.refuse' ORDER BY id DESC LIMIT 1")
        .bind(TENANT)
        .fetch_optional(pool)
        .await?
        .flatten();
    if reason.as_deref() != Some("regression_gate") {
        problems.push(format!("the refusal's audit event has reason {reason:?}"));
    }
    // Both replays of the refused change are stored too: the active policy's is reused, the
    // candidate's is new, each under its own policy version.
    let stored = runs(pool).await?;
    let versions: std::collections::BTreeSet<&str> = stored.iter().map(|(v, _)| v.as_str()).collect();
    if stored.len() != 3 || versions.len() != 3 {
        problems.push(format!("{} runs under {} policy versions are stored; expected 3 under 3", stored.len(), versions.len()));
    }
    // With the gate turned off in the configuration the same approval goes through.
    let mut cfg = (*e.cfg).clone();
    cfg.eval.gate = false;
    let ungated = e.clone().reconfigure(cfg);
    if let Err(err) = ungated.policy_approve(TENANT, p2.version, "Dana Reviewer").await {
        problems.push(format!("with [eval] gate = false the approval was still refused: {err:#}"));
    }
    e.policy_rollback(TENANT, Some(memhouse_core::policy::PolicyTarget::Default), "Dana Reviewer").await?;
    let stale = report.split("stale_rate ").nth(1).and_then(|s| s.split(" (").next()).unwrap_or("?").to_string();
    Ok(verdict(
        problems,
        format!("refused: stale-fact rate {stale} points"),
        "a harmless policy passed and was activated; one that disables corrections was refused with a report, audited, and left proposed; runs stored per policy version",
    ))
}
