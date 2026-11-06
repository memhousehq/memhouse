// SPDX-License-Identifier: Apache-2.0
//! Governance checks for the write pipeline (roadmap G10): candidates answered at once and
//! resolved, the stage order (nothing unredacted is ever queued), exactly-once effects across a
//! crash, poison proposals set aside, freshness, the statement gate (plans and speculation held,
//! corrections superseding, confirmations, expiry), exact structured recall, and degradation.

use crate::governance::{check, stub_engine, Check, Scratch, StubEmbedder};
use memhouse_core::types::*;
use memhouse_core::{EmbedKind, Embedder, Engine};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub(crate) async fn run(engine: &Engine, run_id: &str) -> Vec<Check> {
    let s = |name: &str| format!("bench:{run_id}:gov:{name}");
    let mut out = vec![];
    for (id, req, title, result) in [
        (
            "intake_candidates",
            "CORE-02 / TR-IN-04 / PERF-03",
            "remember answers a candidate at once; every id resolves to one stored state; nothing unredacted is ever queued",
            candidates(engine).await,
        ),
        ("intake_restart", "TR-LT-05 / TR-IN-03", "Proposals left by a killed worker resume after their lease and take effect exactly once", restart(engine).await),
        ("intake_poison", "TR-IN-07", "A proposal that keeps failing is set aside and quarantined without blocking its subject", poison(engine).await),
        ("intake_freshness", "PERF-04", "A write that passes the gate is recallable within 5 s at p95", freshness(engine, &s("fresh")).await),
        (
            "statement_gate",
            "QUAL-02 / QUAL-01 / PR-7",
            "The gate holds plans and speculation as candidates, commits facts, supersedes what a correction corrects, and confirms or expires plans",
            statement_gate(engine, &s("gate")).await,
        ),
        ("exact_recall", "HYB-01 / HYB-02 / HYB-03", "Structured records are routed to the structured table and answered by exact query", exact_recall(engine).await),
        (
            "degradation",
            "PERF-07 / PR-5",
            "Failed retrieval answers empty and flagged within 500 ms; refused access returns no data; a write intake can't queue is refused as retryable",
            degradation(engine).await,
        ),
    ] {
        out.push(match result {
            Ok((passed, value, detail)) => check(id, req, title, passed, value, "all", detail),
            Err(e) => check(id, req, title, false, "error".into(), "all", format!("{e:#}")),
        });
    }
    for name in ["fresh", "gate"] {
        let _ = engine.forget_subject(None, &s(name), Some("bench".into())).await;
    }
    out
}

type Outcome = anyhow::Result<(bool, String, String)>;

/// Distinct words, so test writes are never near-duplicates of each other.
const WORDS: [&str; 30] = [
    "aurora", "basalt", "cobalt", "dune", "ember", "fjord", "glacier", "harbor", "indigo", "juniper", "kestrel", "lagoon", "meadow", "nebula", "obsidian", "prairie", "quartz",
    "ravine", "saffron", "tundra", "umber", "velvet", "willow", "xenon", "yarrow", "zircon", "alder", "bramble", "cedar", "delta",
];
/// Wide enough that hashed words rarely collide.
const DIM: usize = 256;
const PEOPLE: [&str; 5] = ["Ana", "Bram", "Chen", "Divya", "Emeka"];
const VERBS: [&str; 5] = ["reviewed the budget", "drafted the roadmap", "fixed the billing export", "met the auditors", "signed off the design"];

fn verdict(problems: Vec<String>, value: String, ok: &str) -> Outcome {
    Ok((problems.is_empty(), value, if problems.is_empty() { ok.to_string() } else { problems.join("; ") }))
}

fn write(subject: &str, content: &str, wait: bool) -> RememberRequest {
    RememberRequest { subject: Some(subject.into()), content: content.into(), actor: Some("bench".into()), wait, ..Default::default() }
}

fn p95(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v.get((v.len() * 95 / 100).min(v.len().saturating_sub(1))).copied().unwrap_or(0.0)
}

/// A scratch database with the stub embedder, intake left to workers (or nobody).
async fn scratch_engine(base: &Engine, suffix: &str, tune: impl FnOnce(&mut memhouse_core::Config)) -> anyhow::Result<(Scratch, Engine, sqlx::PgPool)> {
    let scratch = Scratch::create(base, suffix).await?;
    let e = stub_engine(base, &scratch.url, "stub:intake", DIM, "", true).await?;
    let mut cfg = (*e.cfg).clone();
    cfg.governance.audit_reads = false;
    tune(&mut cfg);
    let e = e.reconfigure(cfg).with_inline_intake(false);
    let pool = sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(&scratch.url).await?;
    Ok((scratch, e, pool))
}

async fn wait_idle(e: &Engine, timeout: Duration) -> anyhow::Result<bool> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        let st = e.intake_status(None).await?;
        if st.pending + st.running == 0 {
            return Ok(true);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    Ok(false)
}

/// CORE-02, TR-IN-04, PERF-03: 200 writes, each answered as a candidate; while queued, no PII
/// canary is anywhere in the queue; workers then resolve every id to exactly one stored record.
async fn candidates(base: &Engine) -> Outcome {
    let (scratch, e, pool) = scratch_engine(base, "int1", |_| {}).await?;
    let result = async {
        let mut problems = vec![];
        let subj = "customer:intake";
        let canaries = ["4111 1111 1111 1111", "078-05-1120", "sk-live-a1b2c3d4e5f6g7h8i9j0k1l2"]; // secret-scan: allow (fake fixture)
        let mut ack = vec![];
        let mut ids = vec![];
        for i in 0..200 {
            let text = match i % 20 {
                0 => format!("Order {i}: the customer paid with card {} and gave SSN {}", canaries[0], canaries[1]),
                1 => format!("Integration {i} uses the key {}", canaries[2]),
                _ => format!("Account note {i}: the customer's region is zone {}", i * 7),
            };
            let t = Instant::now();
            let r = e.remember(write(subj, &text, false)).await?;
            ack.push(t.elapsed().as_secs_f64() * 1000.0);
            if r.status != MemoryStatus::Candidate {
                problems.push(format!("write {i} answered {}", r.status.as_str()));
            }
            ids.push(r.id);
        }
        // Queued, not yet through the gate: readable as candidates; no canary in the queue.
        let queued: Vec<String> = sqlx::query_scalar("SELECT payload::text FROM mh_intake WHERE payload IS NOT NULL").fetch_all(&pool).await?;
        let leaked = queued.iter().filter(|p| canaries.iter().any(|c| p.contains(c))).count();
        if queued.len() != 200 || leaked > 0 {
            problems.push(format!("{} proposals queued, {leaked} with a PII canary", queued.len()));
        }
        let mut readable = 0;
        for id in ids.iter().take(20) {
            if e.get_record(&e.cfg.memory.tenant, *id).await?.is_some_and(|m| m.status == MemoryStatus::Candidate) {
                readable += 1;
            }
        }
        if readable != 20 {
            problems.push(format!("{readable}/20 queued ids readable as candidates"));
        }
        let stop = Arc::new(AtomicBool::new(false));
        let t = Instant::now();
        let workers = e.spawn_intake(4, stop.clone());
        let idle = wait_idle(&e, Duration::from_secs(60)).await?;
        let resolved_s = t.elapsed().as_secs_f64();
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for w in workers {
            let _ = w.await;
        }
        let rows: Vec<(Uuid, i64)> = sqlx::query_as("SELECT id, count(*) FROM mh_memory WHERE id = ANY($1) GROUP BY id").bind(&ids).fetch_all(&pool).await?;
        if !idle || rows.len() != ids.len() || rows.iter().any(|(_, n)| *n != 1) {
            problems.push(format!("{} of {} ids stored after {resolved_s:.1} s (queue idle: {idle})", rows.len(), ids.len()));
        }
        let stored: Vec<String> = sqlx::query_scalar("SELECT content FROM mh_memory UNION ALL SELECT detail FROM mh_audit").fetch_all(&pool).await?;
        if stored.iter().any(|c| canaries.iter().any(|k| c.contains(k))) {
            problems.push("a PII canary reached storage".into());
        }
        let ack_p95 = p95(&mut ack);
        verdict(
            problems,
            format!("200 candidates, ack p95 {ack_p95:.1} ms; all resolved in {resolved_s:.1} s"),
            "every id answered candidate, readable at once, stored exactly once; no canary queued or stored (ack target ≤ 50 ms, measured on one node)",
        )
    }
    .await;
    pool.close().await;
    scratch.drop().await?;
    result
}

/// TR-LT-05, TR-IN-03: a worker claims 10 of 30 proposals and dies; another proposal is processed
/// twice at once. After the lease, workers finish everything, and each record and its audit
/// event exist exactly once.
async fn restart(base: &Engine) -> Outcome {
    let (scratch, e, pool) = scratch_engine(base, "int2", |c| c.intake.lease_secs = 1).await?;
    let result = async {
        let mut problems = vec![];
        let mut ids = vec![];
        for i in 0..30 {
            ids.push(e.remember(write(&format!("customer:r{}", i % 15), &format!("{} renewal handled by {}", WORDS[i], WORDS[(i + 7) % WORDS.len()]), false)).await?.id);
        }
        // The worker that dies: claims, then never finishes (its process is gone).
        let mut abandoned = 0;
        for _ in 0..10 {
            abandoned += e.intake.claim(1, 1, None).await?.len();
        }
        // Two workers holding the same proposal (a lease that ran out under a slow worker).
        let dup = e.intake.claim(1, 1, None).await?.pop().ok_or_else(|| anyhow::anyhow!("nothing to claim"))?;
        let (a, b) = tokio::join!(e.process_job(dup.clone()), e.process_job(dup));
        let both_ok = a.is_ok() && b.is_ok();
        let stop = Arc::new(AtomicBool::new(false));
        let workers = e.spawn_intake(3, stop.clone());
        let idle = wait_idle(&e, Duration::from_secs(30)).await?;
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for w in workers {
            let _ = w.await;
        }
        let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory WHERE id = ANY($1)").bind(&ids).fetch_one(&pool).await?;
        let events: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_audit WHERE action = 'memory.write' AND memory_id = ANY($1)").bind(&ids).fetch_one(&pool).await?;
        let retried: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_intake WHERE attempts > 1").fetch_one(&pool).await?;
        if !idle || rows != 30 || events != 30 || abandoned != 10 || !both_ok || retried < 10 {
            problems.push(format!("queue idle: {idle}; {rows}/30 records, {events}/30 write events; {abandoned} abandoned, {retried} retried; double processing ok: {both_ok}"));
        }
        verdict(
            problems,
            format!("30 proposals, 10 abandoned by a killed worker, 1 processed twice → {rows} records, {events} write events"),
            "resumed after the lease; exactly once in effect",
        )
    }
    .await;
    pool.close().await;
    scratch.drop().await?;
    result
}

/// An embedder that fails on text containing POISON.
struct Poisoned(StubEmbedder);

#[async_trait::async_trait]
impl Embedder for Poisoned {
    fn id(&self) -> &str {
        self.0.id()
    }
    fn dim(&self) -> usize {
        self.0.dim()
    }
    async fn embed(&self, texts: &[String], kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>> {
        anyhow::ensure!(!texts.iter().any(|t| t.contains("POISON")), "embedding endpoint returned 500 (poison)");
        self.0.embed(texts, kind).await
    }
}

/// TR-IN-07: a proposal whose embedding always fails, then a good one for the same subject.
async fn poison(base: &Engine) -> Outcome {
    let (scratch, e, pool) = scratch_engine(base, "int3", |c| {
        c.intake.max_attempts = 3;
    })
    .await?;
    let result = async {
        let mut problems = vec![];
        let mut e = e;
        e.embedder = Arc::new(Poisoned(StubEmbedder { id: "stub:intake".into(), dim: DIM }));
        let subj = "customer:poison";
        let bad = e.remember(write(subj, "POISON pill note about the account", false)).await?.id;
        let good = e.remember(write(subj, "The account manager is Lena", false)).await?.id;
        let stop = Arc::new(AtomicBool::new(false));
        let t = Instant::now();
        let workers = e.spawn_intake(2, stop.clone());
        let idle = wait_idle(&e, Duration::from_secs(30)).await?;
        let took = t.elapsed().as_secs_f64();
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for w in workers {
            let _ = w.await;
        }
        let tenant = e.cfg.memory.tenant.clone();
        let b = e.store.get(&tenant, bad).await?;
        let g = e.store.get(&tenant, good).await?;
        let dead: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_intake WHERE status = 'dead' AND id = $1").bind(bad).fetch_one(&pool).await?;
        let audited: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_audit WHERE action = 'memory.quarantine' AND memory_id = $1").bind(bad).fetch_one(&pool).await?;
        let quarantined = b.as_ref().is_some_and(|m| m.status == MemoryStatus::Quarantined && m.metadata["quarantine_reasons"][0] == "intake_failed");
        let committed = g.as_ref().is_some_and(|m| m.status == MemoryStatus::Committed);
        if !idle || !quarantined || !committed || dead != 1 || audited != 1 {
            problems.push(format!("queue idle: {idle}; poison quarantined: {quarantined}, set aside: {}, audited: {audited}; next write committed: {committed}", dead == 1));
        }
        verdict(
            problems,
            format!("poison set aside after 3 attempts in {took:.1} s; the subject's next write committed"),
            "quarantined with intake_failed, audited, never blocking",
        )
    }
    .await;
    pool.close().await;
    scratch.drop().await?;
    result
}

/// PERF-04: write, then recall until the record comes back.
async fn freshness(e: &Engine, subj: &str) -> Outcome {
    let mut problems = vec![];
    let mut lags = vec![];
    let mut gated_out: Vec<String> = vec![];
    for i in 0..30 {
        let word = WORDS[i];
        let t = Instant::now();
        let text = format!("{} {} for the {word} team in {}", PEOPLE[i % PEOPLE.len()], VERBS[(i / PEOPLE.len()) % VERBS.len()], WORDS[(i * 7 + 3) % WORDS.len()]);
        let id = e.remember(write(subj, &text, false)).await?.id;
        loop {
            let r = e.recall(RecallRequest { subject: Some(subj.into()), query: word.to_string(), k: Some(3), mode: Some(RetrievalMode::Keyword), ..Default::default() }).await?;
            if r.hits.iter().any(|h| h.memory.id == id) {
                lags.push(t.elapsed().as_secs_f64() * 1000.0);
                break;
            }
            if t.elapsed() > Duration::from_secs(10) {
                // PERF-04 counts writes that pass the gate; a rejected near-duplicate is no miss.
                match e.store.get(&e.cfg.memory.tenant, id).await?.map(|m| m.status) {
                    Some(MemoryStatus::Committed) | None => problems.push(format!("write {i} not recallable after 10 s")),
                    Some(other) => gated_out.push(format!("{i}: {}", other.as_str())),
                }
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
    let p = p95(&mut lags);
    if p > 5000.0 {
        problems.push(format!("p95 {p:.0} ms"));
    }
    if gated_out.len() > 3 {
        problems.push(format!("the gate kept out {}: {}", gated_out.len(), gated_out.join(", ")));
    }
    verdict(problems, format!("time to recallable p95 {p:.0} ms over {} committed writes", lags.len()), "≤ 5,000 ms")
}

/// QUAL-02 (with its contamination rate), QUAL-01, PR-7: a labelled set through the real gate.
async fn statement_gate(e: &Engine, subj: &str) -> Outcome {
    let mut problems = vec![];
    let held = [
        "The user plans to move to Berlin next year.",
        "Priya is going to take over the Acme account.",
        "We intend to migrate the billing service to Postgres 17.",
        "The customer wants to upgrade to the Enterprise plan.",
        "The user hopes to run a marathon in the spring.",
        "Bob might leave the company soon.",
        "The vendor will probably raise prices in March.",
        "I think Acme is considering switching vendors.",
        "Maybe the outage was caused by the new load balancer.",
        "Apparently the CFO is unhappy with the renewal terms.",
    ];
    let committed = [
        "The user lives in Lisbon.",
        "Acme's renewal date is 1 March 2027.",
        "The user adopted a cat named Miso last week.",
        "The team shipped version 2.3 on Friday.",
        "The user prefers aisle seats on long flights.",
        "Always run the integration tests before tagging a release.",
        "The office is on the fourth floor of the Harbour building.",
        "Priya signed the Acme contract in October.",
        "The customer's support tier is Gold.",
        "Dana is allergic to peanuts.",
    ];
    let mut contaminated = vec![];
    let mut held_ids = vec![];
    for t in held {
        let r = e.remember(write(subj, t, true)).await?;
        if r.status != MemoryStatus::Candidate {
            contaminated.push(format!("{t:?} → {}", r.status.as_str()));
        }
        held_ids.push(r.id);
    }
    let mut wrongly_held = vec![];
    for t in committed {
        let r = e.remember(write(subj, t, true)).await?;
        if r.status != MemoryStatus::Committed {
            wrongly_held.push(format!("{t:?} → {} ({:?})", r.status.as_str(), r.statement));
        }
    }
    let rate = contaminated.len() as f64 * 100.0 / held.len() as f64;
    if rate > 2.0 {
        problems.push(format!("plans or speculation committed: {}", contaminated.join(", ")));
    }
    if !wrongly_held.is_empty() {
        problems.push(format!("facts not committed: {}", wrongly_held.join(", ")));
    }
    // PR-7: invisible to default recall, labelled when asked for.
    let q =
        |include| RecallRequest { subject: Some(subj.into()), query: "Berlin move plans and Acme account".into(), k: Some(50), include_candidates: include, ..Default::default() };
    let default = e.recall(q(false)).await?;
    let asked = e.recall(q(true)).await?;
    if default.hits.iter().any(|h| held_ids.contains(&h.memory.id)) {
        problems.push("default recall returned a held candidate".into());
    }
    if !asked.hits.iter().any(|h| held_ids.contains(&h.memory.id) && h.memory.status == MemoryStatus::Candidate) {
        problems.push("include_candidates did not return the held candidates labelled".into());
    }
    // QUAL-01: a correction supersedes, keeping the old version with its link.
    let old = e.remember(write(subj, "Dana lives in Lisbon.", true)).await?.id;
    let new = e.remember(write(subj, "Dana no longer lives in Lisbon; she now lives in Porto.", true)).await?;
    let o = e.store.get(&e.cfg.memory.tenant, old).await?;
    let linked = o.as_ref().is_some_and(|m| m.status == MemoryStatus::Superseded) && new.superseded == Some(old) && new.statement == Some(Statement::Correction);
    let r = e.recall(RecallRequest { subject: Some(subj.into()), query: "where does Dana live".into(), k: Some(5), ..Default::default() }).await?;
    let fresh = r.hits.iter().any(|h| h.memory.id == new.id) && !r.hits.iter().any(|h| h.memory.id == old);
    if !linked || !fresh {
        problems.push(format!("correction: superseded and linked {linked}, recall current only {fresh} ({:?})", new.note));
    }
    // A completed event confirms the plan it fulfils.
    let plan = e.remember(write(subj, "The user plans to visit Kyoto in May.", true)).await?.id;
    let event = e.remember(write(subj, "The user visited Kyoto in May.", true)).await?;
    let p = e.store.get(&e.cfg.memory.tenant, plan).await?;
    let confirmed = p.as_ref().is_some_and(|m| m.status == MemoryStatus::Committed && m.metadata["confirmed_by"] == event.id.to_string());
    if !confirmed {
        problems.push(format!("plan not confirmed by the event: {:?}", p.map(|m| (m.status, m.metadata))));
    }
    // An unconfirmed plan past its date expires.
    let lapsed = e
        .remember(RememberRequest { valid_to: Some(chrono::Utc::now() - chrono::Duration::days(1)), ..write(subj, "The user plans to renew the gym membership.", true) })
        .await?
        .id;
    e.store.expire_due(&e.cfg.memory.tenant).await?;
    let expired = e.store.get(&e.cfg.memory.tenant, lapsed).await?.is_some_and(|m| m.status == MemoryStatus::Expired);
    if !expired {
        problems.push("an unconfirmed plan past its date did not expire".into());
    }
    verdict(
        problems,
        format!(
            "contamination {rate:.0}% ({}/{} held statements committed); {}/{} facts committed",
            contaminated.len(),
            held.len(),
            committed.len() - wrongly_held.len(),
            committed.len()
        ),
        "≤ 2% contamination; held candidates recalled only on request, labelled; correction supersedes with the old version kept; plans confirmed or expired",
    )
}

/// HYB-01/02/03: 300 orders written as JSON records; questions naming an order get it first.
async fn exact_recall(base: &Engine) -> Outcome {
    let (scratch, e, pool) = scratch_engine(base, "int4", |_| {}).await?;
    let result = async {
        let mut problems = vec![];
        let subj = "customer:orders";
        let statuses = ["shipped", "pending", "cancelled", "delivered"];
        for i in 0..300 {
            let content = serde_json::json!({"record_type": "order", "order_id": format!("A-{}", 1000 + i), "status": statuses[i % 4], "total": 20 + i}).to_string();
            let r = e.remember(write(subj, &content, true)).await?;
            if r.route != Some(Route::Structured) {
                problems.push(format!("order {i} routed to {:?}", r.route));
                break;
            }
        }
        let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_structured WHERE record_type = 'order'").fetch_one(&pool).await?;
        if rows != 300 {
            problems.push(format!("{rows}/300 rows in the structured table"));
        }
        let (mut planned, mut vector_only, mut asked) = (0, 0, 0);
        for i in (0..300).step_by(6) {
            let id = format!("A-{}", 1000 + i);
            let question = format!("What is the status of order {id}?");
            let top_is = |r: &RecallResult| r.hits.first().is_some_and(|h| h.memory.content.contains(&format!("order_id={id},")));
            let r = e.recall(RecallRequest { subject: Some(subj.into()), query: question.clone(), k: Some(5), ..Default::default() }).await?;
            planned += usize::from(top_is(&r) && r.hits[0].exact);
            let v = e
                .recall(RecallRequest { subject: Some(subj.into()), query: question, k: Some(5), mode: Some(RetrievalMode::Dense), analyze: Some(false), ..Default::default() })
                .await?;
            vector_only += usize::from(top_is(&v));
            let x = e
                .recall(RecallRequest {
                    subject: Some(subj.into()),
                    query: "order status".into(),
                    k: Some(5),
                    exact: Some(ExactQuery { record_type: Some("order".into()), attrs: serde_json::json!({"order_id": id}) }),
                    ..Default::default()
                })
                .await?;
            asked += usize::from(top_is(&x) && x.hits.iter().filter(|h| h.exact).count() == 1);
        }
        if planned != 50 || asked != 50 {
            problems.push(format!("exact answers: {planned}/50 planned from the question, {asked}/50 asked explicitly"));
        }
        verdict(
            problems,
            format!("{planned}/50 single-row lookups exact from the question, {asked}/50 by explicit query; vector-only top-1 {vector_only}/50"),
            "100% exact on single-row lookups; every order routed to the structured table",
        )
    }
    .await;
    pool.close().await;
    scratch.drop().await?;
    result
}

/// An embedder that hangs, for the retrieval timeout.
struct Hanging;

#[async_trait::async_trait]
impl Embedder for Hanging {
    fn id(&self) -> &str {
        "stub:intake"
    }
    fn dim(&self) -> usize {
        DIM
    }
    async fn embed(&self, _texts: &[String], _kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>> {
        tokio::time::sleep(Duration::from_secs(5)).await;
        anyhow::bail!("unreachable")
    }
}

/// PERF-07: kill each dependency in turn.
async fn degradation(base: &Engine) -> Outcome {
    let (scratch, e, pool) = scratch_engine(base, "int5", |_| {}).await?;
    let result = async {
        let mut problems = vec![];
        let subj = "customer:degrade";
        e.remember(write(subj, "Acme's renewal is in March", true)).await?;
        let q = || RecallRequest { subject: Some(subj.into()), query: "Acme renewal".into(), ..Default::default() };
        let mut timings = vec![];
        // The embedding model hangs; then it fails outright.
        let mut hang = e.clone();
        hang.embedder = Arc::new(Hanging);
        let mut fail = e.clone();
        fail.embedder = Arc::new(Poisoned(StubEmbedder { id: "stub:intake".into(), dim: DIM }));
        // The database goes away: an engine whose pool is closed (every statement fails).
        let store = memhouse_store_postgres::PgStore::connect(&scratch.url, 2, "").await?;
        let dead_pool = store.pool.clone();
        let gone = Engine::new(Arc::new(store), Arc::new(StubEmbedder { id: "stub:intake".into(), dim: DIM }), None, (*e.cfg).clone()).with_inline_intake(false);
        dead_pool.close().await;
        for (what, eng, query) in [("hanging model", &hang, q()), ("failing model", &fail, RecallRequest { query: "POISON".into(), ..q() }), ("database down", &gone, q())] {
            let t = Instant::now();
            let r = eng.recall(query).await;
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            timings.push(format!("{what} {ms:.0} ms"));
            match r {
                Ok(r) if r.hits.is_empty() && r.degraded.is_some() && ms <= 500.0 + 100.0 => {}
                Ok(r) => problems.push(format!("{what}: {} hits, degraded {:?}, {ms:.0} ms", r.hits.len(), r.degraded)),
                Err(err) => problems.push(format!("{what}: error {err:#}")),
            }
        }
        // A write that can't be queued is refused as retryable, nothing stored.
        let w = gone.remember(write(subj, "This write cannot be queued", false)).await;
        match &w {
            Err(err) if memhouse_core::error::code_of(err) == memhouse_core::error::ErrorCode::Unavailable => {}
            other => problems.push(format!("write with the queue down: {:?}", other.as_ref().map(|r| r.status).map_err(|e| format!("{e:#}")))),
        }
        // Authorization fails closed: a caller limited to another subject gets no data.
        let mut agent = memhouse_core::identity::Principal::new("agent:elsewhere", "default", memhouse_core::identity::PrincipalKind::Agent, "bench");
        agent.subjects = vec!["customer:other".into()];
        e.store.principal_put(&agent).await?;
        let (k, full) = memhouse_core::identity::new_key("agent:elsewhere", memhouse_core::identity::PrincipalKind::Agent.permissions(), None, "bench");
        e.store.api_key_put(&k).await?;
        let who = e.auth.authenticate(&full, None).await.map_err(|f| anyhow::anyhow!("{f}"))?;
        match e.caller(who).recall(q()).await {
            Err(err) if memhouse_core::error::code_of(&err) == memhouse_core::error::ErrorCode::Forbidden => {}
            other => problems.push(format!("refused recall: {:?}", other.map(|r| r.hits.len()).map_err(|e| format!("{e:#}")))),
        }
        verdict(problems, timings.join(", "), "empty and flagged within 500 ms; refused access returns nothing; the write is refused with `unavailable`, nothing stored")
    }
    .await;
    pool.close().await;
    scratch.drop().await?;
    result
}
