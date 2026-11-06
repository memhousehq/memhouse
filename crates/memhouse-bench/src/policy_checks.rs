// SPDX-License-Identifier: Apache-2.0
//! Governance checks for the policy engine (roadmap G08), on a scratch database: a behaviour
//! policy can't loosen governance, now or after governance tightens (POL-04); only approved
//! versions execute, records and traces carry the version that admitted them (POL-03, GOV-03);
//! a policy change alters recall without a restart and a rollback restores it exactly (POL-08).

use crate::governance::{check, stub_engine, Check, Scratch};
use crate::telemetry_checks::Capture;
use memhouse_core::error::{code_of, ErrorCode};
use memhouse_core::policy::{self, PolicyDiffRequest, PolicyTarget, REFRESH};
use memhouse_core::types::*;
use memhouse_core::Engine;
use tracing::instrument::WithSubscriber;
use tracing_subscriber::layer::SubscriberExt;

type Outcome = (bool, String, String);

fn verdict(problems: Vec<String>, value: String, ok: &str) -> Outcome {
    (problems.is_empty(), value, if problems.is_empty() { ok.to_string() } else { problems.into_iter().take(6).collect::<Vec<_>>().join("; ") })
}

const CHECKS: [(&str, &str, &str); 3] = [
    (
        "policy_precedence",
        "POL-04 / PR-1",
        "30 behaviour policies that loosen retention, redaction, labels, audit, admission, size or the injection screen fail to compile with reasons, and are refused and audited; an approved policy that governance later outranks stops running",
    ),
    (
        "policy_approval",
        "POL-03 / GOV-03",
        "A proposed policy never runs; activating it unapproved is refused (also by the database) and audited; once approved by a named approver, records, recall explanations and spans carry its version",
    ),
    (
        "policy_rollback",
        "POL-08 / POL-01",
        "Changing ranking weights through a policy changes recall at once and in a second engine within the refresh time, without a restart; rolling back restores the earlier results exactly, audited",
    ),
];

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    match run_all(engine).await {
        Ok(results) => CHECKS.iter().zip(results).map(|((id, req, title), (passed, value, detail))| check(id, req, title, passed, value, "all", detail)).collect(),
        Err(e) => CHECKS.iter().map(|(id, req, title)| check(id, req, title, false, "error".into(), "all", format!("{e:#}"))).collect(),
    }
}

async fn run_all(base: &Engine) -> anyhow::Result<Vec<Outcome>> {
    let scratch = Scratch::create(base, "pol1").await?;
    let result = async {
        let e = stub_engine(base, &scratch.url, "stub:a", 16, "", true).await?;
        let mut cfg = (*e.cfg).clone();
        cfg.governance.audit_reads = false;
        cfg.governance.denied_labels = vec![];
        cfg.governance.episodic_retention_days = 0;
        // Scores before a policy and after its rollback are compared exactly: no clock in them.
        cfg.memory.recency_weight = 0.0;
        let e = e.reconfigure(cfg);
        let pool = sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(&scratch.url).await?;
        let out = vec![precedence(&e, &pool).await?, approval(base, &e, &scratch.url, &pool).await?, rollback(base, &e, &scratch.url, &pool).await?];
        pool.close().await;
        anyhow::Ok(out)
    }
    .await;
    scratch.drop().await?;
    result
}

fn spec(tenant: &str, body: &str) -> anyhow::Result<policy::PolicySpec> {
    policy::parse_spec(&format!("name = \"gov-check\"\n[scope]\ntenant = \"{tenant}\"\n{body}"))
}

async fn audits(pool: &sqlx::PgPool, tenant: &str, action: &str) -> anyhow::Result<i64> {
    Ok(sqlx::query_scalar("SELECT count(*) FROM mh_audit WHERE tenant = $1 AND action = $2").bind(tenant).bind(action).fetch_one(pool).await?)
}

/// The loosening attempts: each names the field its refusal must name.
const LOOSENING: [(&str, &str); 30] = [
    ("[retention]\nepisodic_days = 0", "retention.episodic_days"),
    ("[retention]\nepisodic_days = 91", "retention.episodic_days"),
    ("[retention]\nepisodic_days = 120", "retention.episodic_days"),
    ("[retention]\nepisodic_days = 365", "retention.episodic_days"),
    ("[retention]\nepisodic_days = 3650", "retention.episodic_days"),
    ("[redaction]\ncategories = [\"secret\", \"card\"]", "redaction.categories"),
    ("[redaction]\ncategories = [\"secret\", \"email\"]", "redaction.categories"),
    ("[redaction]\ncategories = [\"secret\"]", "redaction.categories"),
    ("[redaction]\ncategories = [\"card\", \"email\"]", "redaction.categories"),
    ("[redaction]\ncategories = [\"secret\", \"phone\"]", "redaction.categories"),
    ("[redaction]\ncategories = []", "redaction.categories"),
    ("[redaction]\ncategories = [\"secret\", \"card\", \"phone\", \"ip\"]", "redaction.categories"),
    ("[recall]\ndenied_labels = []", "recall.denied_labels"),
    ("[recall]\ndenied_labels = [\"legal\"]", "recall.denied_labels"),
    ("[recall]\ndenied_labels = [\"HR\"]", "recall.denied_labels"),
    ("[recall]\ndenied_labels = [\"hr2\"]", "recall.denied_labels"),
    ("[recall]\naudit_reads = false", "recall.audit_reads"),
    ("[write_gate]\nadmission = \"auto\"", "write_gate.admission"),
    ("[write_gate]\nmax_content_chars = 8001", "write_gate.max_content_chars"),
    ("[write_gate]\nmax_content_chars = 10000", "write_gate.max_content_chars"),
    ("[write_gate]\nmax_content_chars = 20000", "write_gate.max_content_chars"),
    ("[write_gate]\nmax_content_chars = 100000", "write_gate.max_content_chars"),
    ("[write_gate]\nmax_content_chars = 1000000", "write_gate.max_content_chars"),
    ("[write_gate]\nquarantine_injection = false", "write_gate.quarantine_injection"),
    ("[retention]\nepisodic_days = 0\n[recall]\naudit_reads = false", "retention.episodic_days"),
    ("[redaction]\ncategories = []\n[recall]\ndenied_labels = []", "recall.denied_labels"),
    ("[write_gate]\nadmission = \"auto\"\nmax_content_chars = 9000", "write_gate.admission"),
    ("[retention]\nepisodic_days = 400\n[write_gate]\nquarantine_injection = false", "write_gate.quarantine_injection"),
    ("[recall]\ndenied_labels = []\naudit_reads = false", "recall.audit_reads"),
    ("[ranking]\nrecency_weight = 0.5\n[redaction]\ncategories = [\"secret\", \"card\", \"ssn\"]", "redaction.categories"),
];

/// POL-04: under strict governance every loosening spec fails compilation with a reason naming
/// the governance rule, is not stored, and is audited; tightening specs compile. An approved
/// policy that a later, stricter governance outranks stops running (the default runs instead).
async fn precedence(e: &Engine, pool: &sqlx::PgPool) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let t = "pol-precedence";
    let mut cfg = (*e.cfg).clone();
    cfg.governance.redact = vec!["secret".into(), "card".into(), "email".into()];
    cfg.governance.denied_labels = vec!["hr".into()];
    cfg.governance.episodic_retention_days = 90;
    cfg.governance.audit_reads = true;
    cfg.governance.max_content_chars = 8000;
    cfg.access.admission = memhouse_core::config::Admission::Review;
    let strict = e.clone().reconfigure(cfg);
    let mut refused = 0;
    for (body, path) in LOOSENING {
        match strict.policy_propose(t, &spec(t, body)?, "bench", None).await {
            Ok(r) => problems.push(format!("compiled and stored as v{}: {body:?}", r.version)),
            Err(err) => {
                let msg = format!("{err:#}");
                let explained = msg.contains(path) && (msg.contains("PR-1") || msg.contains("security baseline"));
                if code_of(&err) != ErrorCode::InvalidRequest || !explained {
                    problems.push(format!("{body:?} refused without naming {path} and the rule: {msg}"));
                } else {
                    refused += 1;
                }
            }
        }
    }
    let stored = strict.policy_source.specs(t).await?.len();
    let rejections = audits(pool, t, "policy.reject").await?;
    if stored != 0 || rejections != LOOSENING.len() as i64 {
        problems.push(format!("after the refusals: {stored} specs stored, {rejections} policy.reject audit events (want 0 and {})", LOOSENING.len()));
    }
    for body in [
        "[retention]\nepisodic_days = 30",
        "[redaction]\ncategories = [\"secret\", \"card\", \"email\", \"phone\"]",
        "[recall]\ndenied_labels = [\"hr\", \"legal\"]\naudit_reads = true",
        "[write_gate]\nadmission = \"review\"\nmax_content_chars = 4000",
        "[ranking]\nrecency_weight = 0.3",
    ] {
        if let Err(v) = strict.policy_validate(t, &spec(t, body)?) {
            problems.push(format!("a tightening spec failed: {body:?}: {}", v.iter().map(|v| v.to_string()).collect::<Vec<_>>().join("; ")));
        }
    }
    // Approved under lenient governance, then outranked by stricter governance.
    let later = "pol-later";
    let p = e.policy_propose(later, &spec(later, "[retention]\nepisodic_days = 0\n[ranking]\nrecency_weight = 0.4")?, "bench", None).await?;
    e.policy_approve(later, p.version, "Dana Reviewer").await?;
    let under_strict = strict.policy_status(later).await?;
    if !under_strict.running.version.starts_with("gov-") || under_strict.warning.is_none() || under_strict.running.policy.retention.episodic_days != 90 {
        problems.push(format!("an outranked policy kept running: {} (warning {:?})", under_strict.running.version, under_strict.warning));
    }
    if strict.policy_rollback(later, Some(PolicyTarget::Version(p.version)), "Dana Reviewer").await.is_ok() {
        problems.push("rolling back to an outranked policy was accepted".into());
    }
    Ok(verdict(
        problems,
        format!("{refused}/{} refused", LOOSENING.len()),
        "every loosening refused with its rule, audited and not stored; tightening compiles; an outranked policy stops running",
    ))
}

/// POL-03 and GOV-03: proposed is not running; unapproved activation is refused by the engine and
/// by the database, and audited; approval names the approver; after it, writes of a kind the
/// policy forbids are refused, labels it denies are not recalled, and records, explanations and
/// spans carry its version.
async fn approval(base: &Engine, e: &Engine, url: &str, pool: &sqlx::PgPool) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let t = "pol-approve";
    let subj = "customer:pol";
    let remember = |content: &str, kind: MemoryKind, labels: Vec<String>| RememberRequest {
        tenant: Some(t.into()),
        subject: Some(subj.into()),
        content: content.into(),
        kind: Some(kind),
        labels,
        actor: Some("bench".into()),
        wait: true,
        ..Default::default()
    };
    let before = e.remember(remember("Acme's data sheet lists 40 seats", MemoryKind::Document, vec![])).await?;
    e.remember(remember("Acme's legal hold covers the 2025 contract", MemoryKind::Semantic, vec!["pol-secret".into()])).await?;
    let default_version = e.policy_for(t).await?.version.clone();
    let stamped = |m: Option<Memory>| m.and_then(|m| m.provenance.policy_version).unwrap_or_default();
    if stamped(e.store.get(t, before.id).await?) != default_version || !default_version.starts_with("gov-") {
        problems.push(format!("a write before any policy is not stamped with the default {default_version}"));
    }
    let proposed = e
        .policy_propose(
            t,
            &spec(t, "[memory_types]\nallowed = [\"semantic\", \"episodic\", \"preference\", \"working\"]\n[recall]\ndenied_labels = [\"pol-secret\"]")?,
            "agent:bench",
            Some("no documents"),
        )
        .await?;
    let n = proposed.version;
    // Another engine (a process that never saw the proposal) still runs the default.
    let other = stub_engine(base, url, "stub:a", 16, "", false).await?.reconfigure((*e.cfg).clone());
    if other.policy_for(t).await?.version != default_version {
        problems.push("a proposed, unapproved policy is running".into());
    }
    let rejected = audits(pool, t, "policy.reject").await?;
    match e.policy_rollback(t, Some(PolicyTarget::Version(n)), "bench").await {
        Ok(_) => problems.push("an unapproved version was activated by rollback".into()),
        Err(err) if code_of(&err) != ErrorCode::Forbidden => problems.push(format!("activating an unapproved version: {err:#}")),
        Err(_) => {}
    }
    if audits(pool, t, "policy.reject").await? != rejected + 1 {
        problems.push("the refused activation was not audited".into());
    }
    let direct = sqlx::query("INSERT INTO mh_policy_activation (tenant, version, compiled, action, by_whom) VALUES ($1, $2, 'x', 'approve', 'sql')")
        .bind(t)
        .bind(n as i32)
        .execute(pool)
        .await;
    if direct.is_ok() {
        problems.push("the database accepted an activation of an unapproved version".into());
    }
    if e.policy_approve(t, n, "  ").await.is_ok() {
        problems.push("an approval without an approver's name was accepted".into());
    }
    let compiled = e.policy_approve(t, n, "Dana Reviewer").await?;
    let v = compiled.version.clone();
    if !v.starts_with(&format!("policy-v{n}-")) {
        problems.push(format!("approved version is named {v}"));
    }
    let rec = e.policy_source.spec(t, n).await?;
    if rec.as_ref().and_then(|r| r.approved_by.as_deref()) != Some("Dana Reviewer") || rec.as_ref().map(|r| r.proposed_by.as_str()) != Some("agent:bench") {
        problems.push("the version does not record its proposer and named approver".into());
    }
    let approved_by: Option<String> = sqlx::query_scalar("SELECT actor FROM mh_audit WHERE tenant = $1 AND action = 'policy.approve'").bind(t).fetch_optional(pool).await?;
    if approved_by.as_deref() != Some("Dana Reviewer") || audits(pool, t, "policy.propose").await? != 1 {
        problems.push(format!("policy.propose/approve audit events missing or without the approver ({approved_by:?})"));
    }
    if e.store.policy_body(&v).await?.and_then(|b| b["spec"]["version"].as_u64()) != Some(n as u64) {
        problems.push(format!("compiled body of {v} is not kept in mh_policy"));
    }
    // The policy runs: a document write is refused, a denied label is not recalled.
    match e.remember(remember("Acme's second data sheet lists 45 seats", MemoryKind::Document, vec![])).await {
        Ok(_) => problems.push("a kind the policy forbids was written".into()),
        Err(err) if code_of(&err) != ErrorCode::InvalidRequest || !format!("{err:#}").contains(&v) => problems.push(format!("refusal of a forbidden kind: {err:#}")),
        Err(_) => {}
    }
    // Records, the recall explanation and every span carry the approved version.
    let cap = Capture::default();
    let dispatch = tracing::Dispatch::new(tracing_subscriber::registry().with(cap.clone()));
    let traced = async {
        let w = e.remember(remember("Acme renews in March with 40 seats", MemoryKind::Semantic, vec![])).await?;
        let r = e
            .recall(RecallRequest { tenant: Some(t.into()), subject: Some(subj.into()), query: "Acme legal hold contract seats".into(), k: Some(10), ..Default::default() })
            .await?;
        anyhow::Ok((w, r))
    }
    .with_subscriber(dispatch)
    .await?;
    let (w, r) = traced;
    if stamped(e.store.get(t, w.id).await?) != v {
        problems.push(format!("a write under {v} is stamped {:?}", stamped(e.store.get(t, w.id).await?)));
    }
    if r.hits.iter().any(|h| h.memory.labels.contains(&"pol-secret".to_string())) {
        problems.push("a label the policy denies was recalled".into());
    }
    let explained = match r.recall_id {
        Some(id) => e.recall_record(t, id).await?.map(|x| x.policy_version),
        None => None,
    };
    if explained.as_deref() != Some(v.as_str()) {
        problems.push(format!("the recall explanation names policy {explained:?}"));
    }
    let spans = cap.take();
    let ops: Vec<_> = spans.iter().filter(|s| s.name == "memhouse.remember" || s.name == "memhouse.recall").collect();
    if ops.len() != 2 || ops.iter().any(|s| s.fields.get("memhouse.policy_version") != Some(&v)) {
        problems.push(format!("spans carry {:?}", ops.iter().map(|s| (s.name.clone(), s.fields.get("memhouse.policy_version").cloned())).collect::<Vec<_>>()));
    }
    Ok(verdict(
        problems,
        format!("v{n} by Dana Reviewer → {v}"),
        "unapproved never ran and could not be activated (engine and database), refusals audited; records, explanation and spans carry the approved version",
    ))
}

/// The done-when of G08 and POL-08: ranking weights changed by a policy change recall in the same
/// engine at once and in a second engine within `REFRESH`, with no restart; a rollback restores
/// the results exactly, in both, and is audited.
async fn rollback(base: &Engine, e: &Engine, url: &str, pool: &sqlx::PgPool) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let t = "pol-rollback";
    let subj = "customer:rb";
    let now = chrono::Utc::now();
    let facts = [
        (400, "Acme renewal pricing was agreed at 40 seats on the annual plan"),
        (300, "Acme asked for a renewal discount on support hours"),
        (200, "Acme's renewal contact moved from Priya to Tom"),
        (120, "Support ticket about Acme's invoice export failing"),
        (90, "Acme renewal: legal wants a new data processing agreement"),
        (60, "Acme pricing review scheduled with finance"),
        (30, "Acme said the renewal depends on the SSO feature"),
        (14, "Acme support escalation about slow search"),
        (7, "Acme renewal call moved to next Tuesday"),
        (3, "Acme pricing: they want monthly billing"),
        (2, "Acme mentioned a competitor offering lower pricing"),
        (1, "Acme renewal approved by their CFO pending pricing"),
    ];
    for (days, text) in facts {
        e.remember(RememberRequest {
            tenant: Some(t.into()),
            subject: Some(subj.into()),
            content: text.into(),
            occurred_at: Some(now - chrono::Duration::days(days)),
            actor: Some("bench".into()),
            wait: true,
            ..Default::default()
        })
        .await?;
    }
    let queries = ["Acme renewal pricing", "support for Acme", "who is the renewal contact"];
    let recall = |eng: Engine| async move {
        let mut out = vec![];
        for q in queries {
            let r =
                eng.recall(RecallRequest { tenant: Some(t.into()), subject: Some(subj.into()), query: q.into(), k: Some(5), analyze: Some(false), ..Default::default() }).await?;
            out.push(r.hits.iter().map(|h| (h.memory.id, h.score)).collect::<Vec<_>>());
        }
        anyhow::Ok(out)
    };
    let other = stub_engine(base, url, "stub:a", 16, "", false).await?.reconfigure((*e.cfg).clone());
    let baseline = recall(e.clone()).await?;
    if recall(other.clone()).await? != baseline {
        problems.push("two engines on one database disagree before any policy".into());
    }
    let p = e
        .policy_propose(t, &spec(t, "[ranking]\nrecency_weight = 3.0\nrecency_half_life_days = 7\nkeyword_weight = 0.3\nvector_weight = 2.0")?, "bench", Some("favour recent"))
        .await?;
    let d = e.policy_diff(t, &PolicyDiffRequest { from: None, to: Some(format!("v{}", p.version)), spec: None }).await?;
    if !d.changes.iter().any(|c| c.path == "ranking.recency_weight") {
        problems.push(format!("the diff does not show the ranking change: {:?}", d.changes.iter().map(|c| &c.path).collect::<Vec<_>>()));
    }
    e.policy_approve(t, p.version, "Dana Reviewer").await?;
    let changed = recall(e.clone()).await?;
    let differ = changed.iter().zip(&baseline).filter(|(a, b)| a.iter().map(|x| x.0).collect::<Vec<_>>() != b.iter().map(|x| x.0).collect::<Vec<_>>()).count();
    if differ == 0 {
        problems.push("the new ranking weights changed no result order".into());
    }
    tokio::time::sleep(REFRESH + std::time::Duration::from_millis(300)).await;
    let changed_other = recall(other.clone()).await?;
    let same_ids = |a: &Vec<Vec<(uuid::Uuid, f32)>>, b: &Vec<Vec<(uuid::Uuid, f32)>>| a.iter().zip(b).all(|(x, y)| x.iter().map(|h| h.0).eq(y.iter().map(|h| h.0)));
    if !same_ids(&changed_other, &changed) {
        problems.push(format!("a second engine did not pick up the policy within {} s", REFRESH.as_secs_f32()));
    }
    let back = e.policy_rollback(t, None, "Dana Reviewer").await?;
    if !back.version.starts_with("gov-") {
        problems.push(format!("rollback activated {} instead of the default", back.version));
    }
    let restored = recall(e.clone()).await?;
    tokio::time::sleep(REFRESH + std::time::Duration::from_millis(300)).await;
    let restored_other = recall(other).await?;
    let exact = restored.iter().zip(&baseline).filter(|(a, b)| a == b).count();
    if restored != baseline || restored_other != baseline {
        problems.push(format!("after rollback {exact}/{} result lists equal the earlier ones (second engine: {})", baseline.len(), restored_other == baseline));
    }
    let history = e.policy_source.history(t, 10).await?;
    let actions: Vec<(String, Option<u32>)> = history.iter().map(|a| (a.action.clone(), a.version)).collect();
    if actions != vec![("rollback".to_string(), None), ("approve".to_string(), Some(p.version))] || audits(pool, t, "policy.rollback").await? != 1 {
        problems.push(format!("activations {actions:?}, {} policy.rollback audit events", audits(pool, t, "policy.rollback").await?));
    }
    Ok(verdict(
        problems,
        format!("{differ}/{} changed, {exact}/{} restored exactly", queries.len(), queries.len()),
        "the weights changed recall in this engine at once and in another within the refresh time; rollback restored identical ids and scores",
    ))
}
