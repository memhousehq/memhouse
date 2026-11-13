// SPDX-License-Identifier: Apache-2.0
//! Benchmark runner: replays each conversation into MemHouse through the public engine API,
//! asks every question, scores retrieval against ground-truth evidence and (optionally) scores
//! answers with an LLM judge using the benchmark's own protocol.

use crate::datasets::{self, Item, Question, Selection};
use crate::metrics::{self, eval_ranking, unique_in_order, Estimate, Latency};
use memhouse_core::types::*;
use memhouse_core::Engine;
use memhouse_models::{Llm, LlmUsage};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub const SESSION_KS: [usize; 4] = [1, 3, 5, 10];
pub const ROUND_KS: [usize; 6] = [1, 3, 5, 10, 30, 50];
pub const FETCH_K: usize = 100;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QaResult {
    pub answer: String,
    pub judgement: String,
    pub correct: bool,
    #[serde(default)]
    pub answer_usage: LlmUsage,
    #[serde(default)]
    pub judge_usage: LlmUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionResult {
    pub id: String,
    pub qtype: String,
    pub abstention: bool,
    /// Retrieval metrics; empty when the question has no evidence to score against.
    pub metrics: BTreeMap<String, f64>,
    pub recall_ms: f64,
    #[serde(default)]
    pub search_ms: f64,
    #[serde(default)]
    pub embed_ms: f64,
    pub top_sessions: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub qa: Option<QaResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ItemResult {
    pub conv_id: String,
    pub sessions: usize,
    pub rounds: usize,
    pub ingest_ms: f64,
    pub questions: Vec<QuestionResult>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub enrich: Option<ItemEnrich>,
}

/// Background enrichment of one benchmark item (all of its sessions).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ItemEnrich {
    pub jobs: Vec<memhouse_core::types::EnrichOutcome>,
    pub failed: i64,
    /// Time from the end of ingest until every job had finished.
    pub wait_ms: f64,
    /// A recall run right after ingest, while jobs were still queued or running: it shows that
    /// recall does not wait for enrichment.
    pub recall_during_ms: Option<f64>,
    pub pending_at_recall: i64,
    /// Derived facts stored for the item.
    pub facts: usize,
}

#[derive(Clone)]
pub struct QaSetup {
    pub answer: Llm,
    pub judge: Llm,
    pub answer_k: usize,
    /// Derived facts given to the answer model, besides the `answer_k` rounds.
    pub answer_facts: usize,
    /// Answer prompt: 1 = short direct answer, 2 = per-question-type guidance and an "Answer:" line.
    pub prompt_version: u8,
    /// Stop the run once this much has been spent (USD); costs without a known price count as 0.
    pub max_cost_usd: Option<f64>,
    /// Spend so far in micro-dollars, shared by all workers.
    pub spent_micro_usd: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl QaSetup {
    fn charge(&self, u: &LlmUsage) -> anyhow::Result<()> {
        let add = (u.cost_usd.unwrap_or(0.0) * 1e6).round() as u64;
        let total = self.spent_micro_usd.fetch_add(add, Ordering::Relaxed) + add;
        if let Some(max) = self.max_cost_usd {
            if total as f64 / 1e6 > max {
                anyhow::bail!("QA spend ${:.4} passed --max-cost-usd {max}; stopping", total as f64 / 1e6);
            }
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct RunSpec {
    pub dataset: String,
    pub selection: Selection,
    pub mode: RetrievalMode,
    pub rerank: bool,
    pub concurrency: usize,
    pub keep: bool,
    pub run_id: String,
    pub qa: Option<QaSetup>,
    /// Wait for background enrichment of each item before asking its questions.
    pub enrich: bool,
}

fn round_relevant(refs: &[String], evidence: &HashSet<String>) -> bool {
    refs.iter().any(|r| evidence.contains(r))
}

fn hit_refs(h: &Hit) -> Vec<String> {
    h.memory.turn_ref.as_deref().map(|t| t.split(',').map(String::from).collect()).unwrap_or_default()
}

/// Score one ranked recall against a question's evidence.
pub fn score(q: &Question, hits: &[Hit]) -> BTreeMap<String, f64> {
    let mut m = BTreeMap::new();
    let ev_sessions: HashSet<String> = q.evidence_sessions.iter().cloned().collect();
    if !ev_sessions.is_empty() {
        let ranked_sessions = unique_in_order(hits.iter().filter_map(|h| h.memory.session_id.clone()));
        for k in SESSION_KS {
            let (any, all, ndcg) = eval_ranking(&ranked_sessions, &ev_sessions, k);
            m.insert(format!("session/recall_any@{k}"), any);
            m.insert(format!("session/recall_all@{k}"), all);
            m.insert(format!("session/ndcg@{k}"), ndcg);
        }
    }
    let ev_turns: HashSet<String> = q.evidence_turns.iter().cloned().collect();
    if !ev_turns.is_empty() {
        // Each round is relevant if it contains an evidence message; "all" needs every evidence
        // message covered by the top-k rounds.
        let round_ids: Vec<String> = hits.iter().map(|h| h.memory.id.to_string()).collect();
        let relevant: HashSet<String> = hits.iter().filter(|h| round_relevant(&hit_refs(h), &ev_turns)).map(|h| h.memory.id.to_string()).collect();
        for k in ROUND_KS {
            let covered: HashSet<String> = hits.iter().take(k).flat_map(hit_refs).filter(|r| ev_turns.contains(r)).collect();
            let any = (!covered.is_empty()) as u8 as f64;
            let all = (covered.len() == ev_turns.len()) as u8 as f64;
            // nDCG over rounds; the ideal assumes every evidence message sits in its own round.
            let dcg: f64 = round_ids.iter().take(k).enumerate().map(|(i, id)| if relevant.contains(id) { 1.0 / ((i + 2) as f64).log2() } else { 0.0 }).sum();
            let ideal: f64 = (0..ev_turns.len().min(k)).map(|i| 1.0 / ((i + 2) as f64).log2()).sum();
            m.insert(format!("round/recall_any@{k}"), any);
            m.insert(format!("round/recall_all@{k}"), all);
            m.insert(format!("round/ndcg@{k}"), if ideal > 0.0 { (dcg / ideal).min(1.0) } else { 0.0 });
        }
    }
    m
}

fn is_fact(h: &Hit) -> bool {
    h.memory.metadata["derived"].as_bool().unwrap_or(false)
}

const ANSWER_SYSTEM_V2: &str = "You are a helpful assistant with long-term memory of your past conversations with the user. Answer using the retrieved memories: facts extracted from the conversations and conversation excerpts, all dated.
- Read every memory before answering; the answer is often in a conversation excerpt rather than in the facts.
- Check the question against the memories: note every specific thing it names (each item, person, place, employer, job title, means of transport, event) and find each one in the memories. If any of them is never mentioned, even when something similar is (Harajuku is not Shinjuku, a train is not a bus, a baseball is not a football, a Senior Software Engineer is not a Software Engineer Manager), do not compute or guess an answer and never answer 0 for it: reply \"Answer: The information provided is not enough\" and say which part is missing and what the memories do say. For a question about two things (A and B, A or B), both must be in the memories.
- When something changed over time, the most recent statement is current.
- For time questions (when, how long ago, how many days, weeks or months between, which came first), find the date of each event in the memories and compute from those dates and today's date.
- For counting or listing questions (how many, which ones, in total), list each candidate with its date and source, keep only those that match every condition in the question (type, time period, status), merge duplicates (a fact and an excerpt often describe the same thing), then give the total.
- If the question asks for advice, recommendations or ideas, build the answer around the user's own details from the memories (what they own, did, liked or disliked, their situation) rather than generic tips.
- If the question asks what someone would likely do, think or prefer, infer it from what the memories say about them.
- Answer at the granularity the question implies (\"three months\", not \"3 months and 9 days\"; a place, not a sentence about it).
- Say that you don't know only when no memory bears on the question.";

fn answer_prompt(q: &Question, hits: &[Hit], k: usize, n_facts: usize, version: u8, plan: Option<&memhouse_core::query::QueryPlan>) -> (String, String) {
    let mut ctx: Vec<&Hit> = hits.iter().filter(|h| !is_fact(h)).take(k).collect();
    ctx.sort_by_key(|h| h.memory.occurred_at);
    let mut facts: Vec<&Hit> = hits.iter().filter(|h| is_fact(h)).take(n_facts).collect();
    facts.sort_by_key(|h| h.memory.occurred_at);
    let mut lines = vec![];
    if !facts.is_empty() {
        let fl: Vec<String> = facts
            .iter()
            .map(|h| {
                let when = h.memory.occurred_at.map(|t| t.format("%Y-%m-%d").to_string()).unwrap_or_else(|| "undated".into());
                let said = h.memory.metadata["observed_at"].as_str().and_then(|s| s.get(..10)).map(|d| format!(", mentioned {d}")).unwrap_or_default();
                format!("- [{when}{said}] {}", h.memory.content)
            })
            .collect();
        lines.push(format!("Facts extracted from the conversations:\n{}", fl.join("\n")));
        lines.push("Conversation excerpts:".to_string());
    }
    for h in ctx {
        let when = h.memory.occurred_at.map(|t| t.format("%Y-%m-%d %H:%M (%a)").to_string()).unwrap_or_else(|| "unknown date".into());
        lines.push(format!("[{when}]\n{}", h.memory.content));
    }
    let today = q.date.map(|d| d.format("%Y-%m-%d (%a)").to_string()).unwrap_or_else(|| "unknown".into());
    let system = "You are a helpful assistant with long-term memory. Answer the user's question using the memories retrieved from earlier conversations. Each memory is dated; when facts changed over time, the most recent one is current. Work out dates and durations carefully. If the memories do not contain the answer, say that you don't know.".to_string();
    if version >= 2 {
        // The dates recall resolved for the question's time phrases ("last Saturday", "three
        // weeks ago"), so the answer model does not have to redo that arithmetic.
        let times: Vec<String> =
            plan.map(|p| p.windows.iter().filter(|w| !w.meaning.is_empty()).map(|w| format!("\"{}\" = {}", w.phrase, w.meaning)).collect()).unwrap_or_default();
        let times = if times.is_empty() { String::new() } else { format!("Time references in the question: {}\n", times.join("; ")) };
        let user = format!(
            "Retrieved memories (oldest first):\n\n{}\n\nToday's date: {today}\n{times}Question: {}\n\nWork it out briefly, then end with a line \"Answer: <final answer>\".",
            lines.join("\n\n"),
            q.question
        );
        return (ANSWER_SYSTEM_V2.to_string(), user);
    }
    let user = format!(
        "Retrieved memories (oldest first):\n\n{}\n\nToday's date: {today}\nQuestion: {}\n\nThink briefly, then give a short, direct final answer.",
        lines.join("\n\n"),
        q.question
    );
    (system, user)
}

/// Judge prompts follow the LongMemEval protocol (per question type) and the LLM-as-judge
/// protocol commonly used for LoCoMo.
fn judge_prompt(dataset: &str, q: &Question, response: &str) -> String {
    if dataset == "locomo" {
        return format!(
            "Your task is to label an answer to a question as CORRECT or WRONG. You get a question, a gold (ground truth) answer and a generated answer. Be generous: if the generated answer refers to the same topic and contains the key information in the gold answer, count it as CORRECT. For time questions, the same date or period in a different format counts as CORRECT.\n\nQuestion: {}\nGold answer: {}\nGenerated answer: {}\n\nReply with one word: CORRECT or WRONG.",
            q.question, q.answer, response
        );
    }
    let rule = if q.abstention {
        "The question cannot be answered from the history. Answer yes if the response correctly says the information is unavailable or unknown; otherwise answer no.".to_string()
    } else {
        match q.qtype.as_str() {
            "temporal-reasoning" => "Answer yes if the response contains the correct answer, or is equivalent to it, or contains all the intermediate steps to get it. Otherwise answer no. If the response only contains a subset of the required information, answer no. Do not penalise off-by-one errors in the number of days, weeks or months.".to_string(),
            "knowledge-update" => "Answer yes if the response contains the correct answer, or is equivalent to it. If the response also mentions older information alongside the updated answer, it still counts as correct as long as the updated answer is given as the answer. Otherwise answer no.".to_string(),
            "single-session-preference" => "The correct answer is a rubric describing the desired personalised response. Answer yes if the response satisfies the rubric; it does not need every point, but must use the user's personal information correctly. Otherwise answer no.".to_string(),
            _ => "Answer yes if the response contains the correct answer, or is equivalent to it, or contains all the intermediate steps to get it. Otherwise answer no. If the response only contains a subset of the required information, answer no.".to_string(),
        }
    };
    format!(
        "I will give you a question, a correct answer and a response from a model. {rule}\n\nQuestion: {}\n\nCorrect answer: {}\n\nModel response: {}\n\nIs the model response correct? Answer yes or no only.",
        q.question, q.answer, response
    )
}

fn parse_judgement(dataset: &str, s: &str) -> bool {
    let t = s.trim().to_ascii_lowercase();
    if dataset == "locomo" {
        !t.contains("wrong") && t.contains("correct")
    } else {
        t.starts_with("yes") || (t.contains("yes") && !t.contains("no"))
    }
}

async fn run_item(engine: &Engine, spec: &RunSpec, item: Item) -> anyhow::Result<ItemResult> {
    let subject = format!("bench:{}:{}", spec.run_id, item.conv_id);
    let t0 = Instant::now();
    let mut rounds = 0;
    for s in &item.sessions {
        let messages = s.turns.iter().map(|t| Message { role: t.role.clone(), content: t.content.clone(), timestamp: s.date, id: Some(t.ref_id.clone()) }).collect();
        let r = engine
            .ingest(IngestRequest {
                subject: Some(subject.clone()),
                session_id: Some(s.id.clone()),
                session_time: s.date,
                messages,
                per_message: item.per_message,
                source: Some(format!("bench:{}", spec.dataset)),
                actor: Some("bench".into()),
                wait: true,
                ..Default::default()
            })
            .await?;
        rounds += r.stored + r.quarantined;
    }
    let ingest_ms = t0.elapsed().as_secs_f64() * 1000.0;

    let enrich = if spec.enrich {
        let tenant = engine.cfg.memory.tenant.clone();
        let st = engine.store.enrich_status(&tenant, Some(&subject)).await?;
        let pending = st.pending + st.running;
        let mut during = None;
        if let (true, Some(q)) = (pending > 0, item.questions.first()) {
            let r = engine
                .recall(RecallRequest {
                    subject: Some(subject.clone()),
                    query: q.question.clone(),
                    k: Some(FETCH_K),
                    reference_time: q.date,
                    actor: Some("bench".into()),
                    ..Default::default()
                })
                .await?;
            during = Some(r.took_ms);
        }
        let t1 = Instant::now();
        let st = engine.enrich_wait(None, &subject, std::time::Duration::from_secs(3600)).await?;
        let jobs = engine.store.enrich_outcomes(&tenant, &subject).await?;
        let facts = jobs.iter().map(|j| j.facts).sum();
        Some(ItemEnrich {
            jobs,
            failed: st.failed + st.pending + st.running,
            wait_ms: t1.elapsed().as_secs_f64() * 1000.0,
            recall_during_ms: during,
            pending_at_recall: pending,
            facts,
        })
    } else {
        None
    };

    let mut out = vec![];
    for q in &item.questions {
        let r = engine
            .recall(RecallRequest {
                subject: Some(subject.clone()),
                query: q.question.clone(),
                k: Some(FETCH_K),
                // The question date is "now" for the question, not a filter: the reference
                // protocol searches the whole history, and LongMemEval_S stamps some evidence
                // sessions later on the question's own day.
                reference_time: q.date,
                mode: Some(spec.mode),
                rerank: Some(spec.rerank),
                actor: Some("bench".into()),
                ..Default::default()
            })
            .await?;
        let metrics = if q.abstention { BTreeMap::new() } else { score(q, &r.hits) };
        let qa = match &spec.qa {
            None => None,
            Some(setup) => {
                // Facts are short, so the answer model gets many of them from a facts-only
                // recall (close to the subject's whole fact log), next to the top rounds.
                let mut hits = r.hits.clone();
                if setup.answer_facts > 0 {
                    let f = engine
                        .recall(RecallRequest {
                            subject: Some(subject.clone()),
                            query: q.question.clone(),
                            k: Some(setup.answer_facts),
                            kinds: Some(vec![MemoryKind::Semantic, MemoryKind::Preference, MemoryKind::Commitment]),
                            reference_time: q.date,
                            mode: Some(spec.mode),
                            actor: Some("bench".into()),
                            ..Default::default()
                        })
                        .await?;
                    hits.retain(|h| !is_fact(h));
                    hits.extend(f.hits);
                }
                let (sys, user) = answer_prompt(q, &hits, setup.answer_k, setup.answer_facts, setup.prompt_version, r.plan.as_ref());
                let a = setup.answer.complete_with_usage(&sys, &user).await?;
                setup.charge(&a.usage)?;
                let j = setup.judge.complete_with_usage("You are a careful, impartial grader.", &judge_prompt(&spec.dataset, q, &a.text)).await?;
                setup.charge(&j.usage)?;
                let correct = parse_judgement(&spec.dataset, &j.text);
                Some(QaResult { answer: a.text, judgement: j.text, correct, answer_usage: a.usage, judge_usage: j.usage })
            }
        };
        out.push(QuestionResult {
            id: q.id.clone(),
            qtype: q.qtype.clone(),
            abstention: q.abstention,
            metrics,
            recall_ms: r.took_ms,
            search_ms: r.search_ms,
            embed_ms: r.embed_ms,
            top_sessions: unique_in_order(r.hits.iter().filter_map(|h| h.memory.session_id.clone())).into_iter().take(10).collect(),
            qa,
        });
    }
    if !spec.keep {
        engine.reset_subject(None, &subject, Some("bench".into())).await?;
    }
    Ok(ItemResult { conv_id: item.conv_id, sessions: item.sessions.len(), rounds, ingest_ms, questions: out, enrich })
}

/// Stream the dataset through `concurrency` workers. Progress goes to stderr; results to `sink`.
pub async fn run(engine: Engine, spec: RunSpec, mut sink: impl FnMut(&ItemResult) -> anyhow::Result<()>) -> anyhow::Result<Vec<ItemResult>> {
    let path = datasets::path_for(&spec.dataset)?;
    if !path.exists() {
        anyhow::bail!("{} is not downloaded; run `memhouse bench download {}`", spec.dataset, spec.dataset);
    }
    let (tx, rx) = tokio::sync::mpsc::channel::<Item>(spec.concurrency.max(1) * 2);
    let ds = spec.dataset.clone();
    let sel = spec.selection.clone();
    let loader = tokio::task::spawn_blocking(move || datasets::stream(&ds, &path, &sel, |it| tx.blocking_send(it).map_err(|_| anyhow::anyhow!("runner stopped"))));

    let rx = Arc::new(tokio::sync::Mutex::new(rx));
    let (rtx, mut rrx) = tokio::sync::mpsc::unbounded_channel::<anyhow::Result<ItemResult>>();
    let mut workers = vec![];
    for _ in 0..spec.concurrency.max(1) {
        let rx = rx.clone();
        let rtx = rtx.clone();
        let engine = engine.clone();
        let spec = spec.clone();
        workers.push(tokio::spawn(async move {
            loop {
                let item = { rx.lock().await.recv().await };
                let Some(item) = item else { break };
                let id = item.conv_id.clone();
                let r = run_item(&engine, &spec, item).await.map_err(|e| e.context(format!("item {id}")));
                let failed = r.is_err();
                if rtx.send(r).is_err() || failed {
                    break;
                }
            }
        }));
    }
    drop(rtx);

    let started = Instant::now();
    let done = AtomicUsize::new(0);
    let agg: Mutex<BTreeMap<String, (f64, usize)>> = Mutex::new(BTreeMap::new());
    let mut results = vec![];
    while let Some(r) = rrx.recv().await {
        let r = r?;
        let n = done.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut a = agg.lock().unwrap();
            for q in &r.questions {
                for key in ["session/recall_all@5", "session/recall_any@5", "round/recall_all@10"] {
                    if let Some(v) = q.metrics.get(key) {
                        let e = a.entry(key.to_string()).or_insert((0.0, 0));
                        e.0 += v;
                        e.1 += 1;
                    }
                }
                if let Some(qa) = &q.qa {
                    let e = a.entry("qa/accuracy".into()).or_insert((0.0, 0));
                    e.0 += qa.correct as u8 as f64;
                    e.1 += 1;
                }
            }
            let summary: Vec<String> = a.iter().map(|(k, (s, c))| format!("{k}={:.3}", s / *c as f64)).collect();
            eprintln!(
                "[{n:>4}] {:<28} {:>4} rounds, ingest {:>6.0} ms | running: {} | {:.0}s",
                r.conv_id.chars().take(28).collect::<String>(),
                r.rounds,
                r.ingest_ms,
                summary.join(" "),
                started.elapsed().as_secs_f64()
            );
        }
        sink(&r)?;
        results.push(r);
    }
    for w in workers {
        let _ = w.await;
    }
    loader.await??;
    Ok(results)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Aggregate {
    pub questions: usize,
    pub scored: usize,
    pub retrieval: BTreeMap<String, Estimate>,
    pub by_type: BTreeMap<String, BTreeMap<String, Estimate>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub qa_accuracy: Option<Estimate>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty", default)]
    pub qa_by_type: BTreeMap<String, Estimate>,
    pub recall_latency: Latency,
    #[serde(default)]
    pub search_latency: Latency,
    #[serde(default)]
    pub query_embed_latency: Latency,
    pub ingest_rounds: usize,
    pub ingest_ms_total: f64,
    pub rounds_per_second: f64,
    /// Enrichment runs only: background extraction cost, volume and lag.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub enrich: Option<EnrichTally>,
    /// QA runs only: what the LLM calls cost and how long they took.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub llm: Option<LlmTally>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrichTally {
    pub model: String,
    pub jobs: usize,
    pub llm_calls: usize,
    pub cached: usize,
    pub skipped: usize,
    pub failed: i64,
    pub facts: usize,
    pub calls: RoleTally,
    /// Enqueue to facts committed, per job (includes queueing behind other jobs).
    pub lag: Latency,
    /// Recall latency measured while that item's jobs were still pending.
    pub recall_during: Latency,
    pub recall_during_pending_jobs: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RoleTally {
    pub calls: usize,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub cost_usd: f64,
    /// Calls whose cost the provider reported; the rest are priced from the table or unknown.
    pub cost_reported_calls: usize,
    pub cost_unknown_calls: usize,
    pub retries: u64,
    pub latency: Latency,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmTally {
    pub answer: RoleTally,
    pub judge: RoleTally,
    pub total_cost_usd: f64,
    /// What an agent sees: memory recall plus the answer model's call. The judge is benchmark-only.
    pub recall_plus_answer_latency: Latency,
}

fn role_tally<'a>(us: impl Iterator<Item = &'a LlmUsage>) -> RoleTally {
    let us: Vec<&LlmUsage> = us.collect();
    RoleTally {
        calls: us.len(),
        prompt_tokens: us.iter().map(|u| u.prompt_tokens).sum(),
        completion_tokens: us.iter().map(|u| u.completion_tokens).sum(),
        cost_usd: us.iter().filter_map(|u| u.cost_usd).sum(),
        cost_reported_calls: us.iter().filter(|u| u.cost_reported).count(),
        cost_unknown_calls: us.iter().filter(|u| u.cost_usd.is_none()).count(),
        retries: us.iter().map(|u| u.attempts.saturating_sub(1) as u64).sum(),
        latency: metrics::latency(&us.iter().map(|u| u.ms).collect::<Vec<_>>()),
    }
}

pub fn aggregate(results: &[ItemResult], wall_secs: f64, concurrency: usize) -> Aggregate {
    let qs: Vec<&QuestionResult> = results.iter().flat_map(|r| r.questions.iter()).collect();
    let mut per_metric: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut per_type: BTreeMap<String, BTreeMap<String, Vec<f64>>> = BTreeMap::new();
    let mut qa_all = vec![];
    let mut qa_type: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    for q in &qs {
        for (k, v) in &q.metrics {
            per_metric.entry(k.clone()).or_default().push(*v);
            per_type.entry(q.qtype.clone()).or_default().entry(k.clone()).or_default().push(*v);
        }
        if let Some(qa) = &q.qa {
            let v = qa.correct as u8 as f64;
            qa_all.push(v);
            let t = if q.abstention { "abstention".to_string() } else { q.qtype.clone() };
            qa_type.entry(t).or_default().push(v);
        }
    }
    let lat: Vec<f64> = qs.iter().map(|q| q.recall_ms).collect();
    let qa_qs: Vec<(&QuestionResult, &QaResult)> = qs.iter().filter_map(|q| q.qa.as_ref().map(|a| (*q, a))).collect();
    let ens: Vec<&ItemEnrich> = results.iter().filter_map(|r| r.enrich.as_ref()).collect();
    let enrich = (!ens.is_empty()).then(|| {
        let jobs: Vec<&memhouse_core::types::EnrichOutcome> = ens.iter().flat_map(|e| e.jobs.iter()).collect();
        let called: Vec<&memhouse_core::types::EnrichOutcome> = jobs.iter().copied().filter(|j| !j.cached && !j.skipped).collect();
        EnrichTally {
            model: jobs.iter().find(|j| !j.model.is_empty()).map(|j| j.model.clone()).unwrap_or_default(),
            jobs: jobs.len(),
            llm_calls: called.len(),
            cached: jobs.iter().filter(|j| j.cached).count(),
            skipped: jobs.iter().filter(|j| j.skipped).count(),
            failed: ens.iter().map(|e| e.failed).sum(),
            facts: ens.iter().map(|e| e.facts).sum(),
            calls: role_tally(called.iter().map(|j| &j.usage)),
            lag: metrics::latency(&jobs.iter().map(|j| j.lag_ms).collect::<Vec<_>>()),
            recall_during: metrics::latency(&ens.iter().filter_map(|e| e.recall_during_ms).collect::<Vec<_>>()),
            recall_during_pending_jobs: ens.iter().filter(|e| e.recall_during_ms.is_some()).map(|e| e.pending_at_recall).sum(),
        }
    });
    let llm = (!qa_qs.is_empty()).then(|| {
        let answer = role_tally(qa_qs.iter().map(|(_, a)| &a.answer_usage));
        let judge = role_tally(qa_qs.iter().map(|(_, a)| &a.judge_usage));
        LlmTally {
            total_cost_usd: answer.cost_usd + judge.cost_usd,
            recall_plus_answer_latency: metrics::latency(&qa_qs.iter().map(|(q, a)| q.recall_ms + a.answer_usage.ms).collect::<Vec<_>>()),
            answer,
            judge,
        }
    });
    let rounds: usize = results.iter().map(|r| r.rounds).sum();
    let ingest_ms: f64 = results.iter().map(|r| r.ingest_ms).sum();
    let _ = wall_secs;
    Aggregate {
        questions: qs.len(),
        scored: qs.iter().filter(|q| !q.metrics.is_empty()).count(),
        retrieval: per_metric.iter().map(|(k, v)| (k.clone(), metrics::bootstrap(v, 2000))).collect(),
        by_type: per_type.iter().map(|(t, ms)| (t.clone(), ms.iter().map(|(k, v)| (k.clone(), metrics::bootstrap(v, 1000))).collect())).collect(),
        qa_accuracy: if qa_all.is_empty() { None } else { Some(metrics::bootstrap(&qa_all, 2000)) },
        qa_by_type: qa_type.iter().map(|(k, v)| (k.clone(), metrics::bootstrap(v, 1000))).collect(),
        recall_latency: metrics::latency(&lat),
        search_latency: metrics::latency(&qs.iter().map(|q| q.search_ms).collect::<Vec<_>>()),
        query_embed_latency: metrics::latency(&qs.iter().map(|q| q.embed_ms).collect::<Vec<_>>()),
        ingest_rounds: rounds,
        ingest_ms_total: ingest_ms,
        // Ingest runs on `concurrency` workers at once; per-worker time × workers ≈ wall time.
        rounds_per_second: if ingest_ms > 0.0 { rounds as f64 / (ingest_ms / 1000.0 / concurrency.max(1) as f64) } else { 0.0 },
        llm,
        enrich,
    }
}
