//! Human-readable reports (Markdown) from a run summary, plus side-by-side comparison of runs.

use crate::baselines;
use crate::governance::GovernanceReport;
use crate::metrics::Estimate;
use crate::runner::Aggregate;
use serde::{Deserialize, Serialize};
use std::fmt::Write;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunConfig {
    pub memhouse_version: String,
    pub embedder: String,
    pub reranker: Option<String>,
    pub mode: String,
    pub candidates_per_retriever: usize,
    pub rrf_k: f32,
    pub keyword_weight: f32,
    pub vector_weight: f32,
    /// Query analysis probes, if on (absent in runs made before it existed).
    #[serde(default)]
    pub query_analysis: Option<String>,
    pub concurrency: usize,
    pub selection: String,
    pub answer_model: Option<String>,
    pub judge_model: Option<String>,
    pub answer_k: Option<usize>,
    #[serde(default)]
    pub answer_prompt: Option<u8>,
    #[serde(default)]
    pub enrich_model: Option<String>,
    pub host: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Summary {
    pub run_id: String,
    pub label: Option<String>,
    pub dataset: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub wall_seconds: f64,
    pub config: RunConfig,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub results: Option<Aggregate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub governance: Option<GovernanceReport>,
}

fn pct(e: &Estimate) -> String {
    if e.n == 0 {
        return "–".into();
    }
    format!("{:.1} [{:.1}–{:.1}]", e.mean * 100.0, e.lo * 100.0, e.hi * 100.0)
}

fn get<'a>(a: &'a Aggregate, k: &str) -> Option<&'a Estimate> {
    a.retrieval.get(k)
}

pub fn markdown(s: &Summary) -> String {
    let mut o = String::new();
    let title = s.label.as_deref().map(|l| format!(" — {l}")).unwrap_or_default();
    let _ = writeln!(o, "# MemHouse benchmark: {}{}\n", s.dataset, title);
    let _ = writeln!(o, "Run `{}` · {} · {:.0} s wall time\n", s.run_id, s.created_at.format("%Y-%m-%d %H:%M UTC"), s.wall_seconds);
    let c = &s.config;
    let _ = writeln!(o, "| Setting | Value |\n|---|---|");
    let _ = writeln!(o, "| MemHouse | {} |", c.memhouse_version);
    let _ = writeln!(o, "| Embedder | `{}` |", c.embedder);
    let _ = writeln!(o, "| Reranker | {} |", c.reranker.as_deref().map(|r| format!("`{r}`")).unwrap_or_else(|| "off".into()));
    let _ = writeln!(o, "| Retrieval | {} (RRF k={}, keyword w={}, vector w={}, {} candidates per retriever) |", c.mode, c.rrf_k, c.keyword_weight, c.vector_weight, c.candidates_per_retriever);
    let _ = writeln!(o, "| Query analysis | {} |", c.query_analysis.as_deref().unwrap_or("off"));
    let _ = writeln!(o, "| Selection | {} |", c.selection);
    if let Some(m) = &c.answer_model {
        let _ = writeln!(o, "| Answer model | `{m}` (top {} rounds{}, answer prompt v{}) |", c.answer_k.unwrap_or(0), c.enrich_model.as_ref().map(|e| format!(" + facts from `{e}`")).unwrap_or_default(), c.answer_prompt.unwrap_or(1));
        let _ = writeln!(o, "| Judge model | `{}` |", c.judge_model.clone().unwrap_or_default());
    }
    let _ = writeln!(o, "| Host | {} |\n", c.host);

    if let Some(a) = &s.results {
        let _ = writeln!(o, "## Retrieval quality\n");
        let _ = writeln!(o, "{} questions, {} scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.\n", a.questions, a.scored);
        let has_session = a.retrieval.contains_key("session/recall_any@5");
        if has_session {
            let _ = writeln!(o, "**Session level** (rounds collapsed to their sessions, LongMemEval definition)\n");
            let _ = writeln!(o, "| k | recall_any@k | recall_all@k | nDCG@k |\n|---|---|---|---|");
            for k in [1, 3, 5, 10] {
                let row = |m: &str| get(a, &format!("session/{m}@{k}")).map(pct).unwrap_or_else(|| "–".into());
                let _ = writeln!(o, "| {k} | {} | {} | {} |", row("recall_any"), row("recall_all"), row("ndcg"));
            }
            let _ = writeln!(o);
        }
        if a.retrieval.contains_key("round/recall_any@5") {
            let _ = writeln!(o, "**Round / turn level** (a round is relevant if it contains an evidence message)\n");
            let _ = writeln!(o, "| k | recall_any@k | recall_all@k | nDCG@k |\n|---|---|---|---|");
            for k in [1, 3, 5, 10, 30, 50] {
                let row = |m: &str| get(a, &format!("round/{m}@{k}")).map(pct).unwrap_or_else(|| "–".into());
                let _ = writeln!(o, "| {k} | {} | {} | {} |", row("recall_any"), row("recall_all"), row("ndcg"));
            }
            let _ = writeln!(o);
        }
        let _ = writeln!(o, "**By question type**\n");
        let key = if has_session { "session/recall_all@5" } else { "round/recall_all@10" };
        let key2 = if has_session { "session/recall_all@10" } else { "round/recall_all@50" };
        let _ = writeln!(o, "| Type | n | {key} | {key2} | QA accuracy |\n|---|---|---|---|---|");
        for (t, ms) in &a.by_type {
            let n = ms.get(key).map(|e| e.n).unwrap_or(0);
            let qa = a.qa_by_type.get(t).map(pct).unwrap_or_else(|| "–".into());
            let _ = writeln!(o, "| {t} | {n} | {} | {} | {qa} |", ms.get(key).map(pct).unwrap_or_default(), ms.get(key2).map(pct).unwrap_or_default());
        }
        if let Some(e) = a.qa_by_type.get("abstention") {
            let _ = writeln!(o, "| abstention | {} | – | – | {} |", e.n, pct(e));
        }
        let _ = writeln!(o);

        if let Some(qa) = &a.qa_accuracy {
            let _ = writeln!(o, "## Answer accuracy (LLM judge)\n");
            let _ = writeln!(o, "**{}** over {} questions, judged by `{}` with the benchmark's judging protocol.\n", pct(qa), qa.n, c.judge_model.clone().unwrap_or_default());
        }
        if let Some(e) = &a.enrich {
            let _ = writeln!(o, "## Background enrichment (async LLM fact extraction)\n");
            let _ = writeln!(o, "| Metric | Value |\n|---|---|");
            let _ = writeln!(o, "| Model | `{}` |", e.model);
            let _ = writeln!(o, "| Jobs (one per ingested session) | {} ({} LLM calls, {} from cache, {} skipped as too short, {} failed) |", e.jobs, e.llm_calls, e.cached, e.skipped, e.failed);
            let _ = writeln!(o, "| Facts stored | {} |", e.facts);
            let _ = writeln!(o, "| Tokens | {} prompt + {} completion |", e.calls.prompt_tokens, e.calls.completion_tokens);
            let _ = writeln!(o, "| **Cost** | **${:.4}** (${:.6} per LLM call; {} of {} calls priced by the provider) |", e.calls.cost_usd.max(0.0), e.calls.cost_usd.max(0.0) / e.llm_calls.max(1) as f64, e.calls.cost_reported_calls, e.calls.calls);
            let _ = writeln!(o, "| LLM call latency | p50 {:.0} · p95 {:.0} · p99 {:.0} ms |", e.calls.latency.p50_ms, e.calls.latency.p95_ms, e.calls.latency.p99_ms);
            let _ = writeln!(o, "| Lag, ingest to facts searchable | p50 {:.1} s · p95 {:.1} s |", e.lag.p50_ms / 1000.0, e.lag.p95_ms / 1000.0);
            if e.recall_during.n > 0 {
                let _ = writeln!(o, "| Recall while jobs were still pending (does not wait) | p50 {:.0} · p95 {:.0} ms over {} recalls, {} jobs pending |", e.recall_during.p50_ms, e.recall_during.p95_ms, e.recall_during.n, e.recall_during_pending_jobs);
            }
            let _ = writeln!(o);
        }
        if let Some(t) = &a.llm {
            let _ = writeln!(o, "## LLM usage and cost\n");
            let _ = writeln!(o, "| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |\n|---|---|---|---|---|---|---|---|---|");
            for (role, model, r) in [("answer", &c.answer_model, &t.answer), ("judge", &c.judge_model, &t.judge)] {
                let src = if r.cost_unknown_calls == r.calls && r.calls > 0 {
                    "unknown (no price; pass --answer-price / --judge-price)".to_string()
                } else if r.cost_reported_calls == r.calls {
                    "reported by provider".to_string()
                } else if r.cost_reported_calls == 0 && r.cost_unknown_calls == 0 {
                    "list price × tokens".to_string()
                } else {
                    format!("{} reported, {} from price table, {} unknown", r.cost_reported_calls, r.calls - r.cost_reported_calls - r.cost_unknown_calls, r.cost_unknown_calls)
                };
                let _ = writeln!(
                    o,
                    "| {role} | `{}` | {} | {} | {} | {:.4} | {src} | {} | {:.0} / {:.0} / {:.0} ms |",
                    model.clone().unwrap_or_default(), r.calls, r.prompt_tokens, r.completion_tokens, r.cost_usd, r.retries, r.latency.p50_ms, r.latency.p95_ms, r.latency.p99_ms
                );
            }
            let n = t.answer.calls.max(1) as f64;
            let _ = writeln!(o, "| **total** | | {} | {} | {} | **{:.4}** | | | |\n", t.answer.calls + t.judge.calls, t.answer.prompt_tokens + t.judge.prompt_tokens, t.answer.completion_tokens + t.judge.completion_tokens, t.total_cost_usd);
            let _ = writeln!(o, "Per question: {:.0} prompt + {:.0} completion tokens to the answer model, ${:.5} in all.\n", t.answer.prompt_tokens as f64 / n, t.answer.completion_tokens as f64 / n, t.total_cost_usd / n);
            let (r, ra, al) = (&a.recall_latency, &t.recall_plus_answer_latency, &t.answer.latency);
            let _ = writeln!(o, "**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):\n");
            let _ = writeln!(o, "| | p50 | p95 | p99 |\n|---|---|---|---|");
            let _ = writeln!(o, "| Memory recall only (local, no external call) | {:.0} ms | {:.0} ms | {:.0} ms |", r.p50_ms, r.p95_ms, r.p99_ms);
            let _ = writeln!(o, "| Answer-model call alone (network + provider) | {:.0} ms | {:.0} ms | {:.0} ms |", al.p50_ms, al.p95_ms, al.p99_ms);
            let _ = writeln!(o, "| Recall + answer (what an agent waits for) | {:.0} ms | {:.0} ms | {:.0} ms |\n", ra.p50_ms, ra.p95_ms, ra.p99_ms);
        }

        let l = &a.recall_latency;
        let _ = writeln!(o, "## Latency and throughput\n");
        let _ = writeln!(o, "| Metric | Value |\n|---|---|");
        let _ = writeln!(o, "| Recall (end to end: query embedding + one SQL statement per probe{}) | p50 {:.1} ms · p95 {:.1} ms · p99 {:.1} ms · n={} |", if c.reranker.is_some() { " + rerank" } else { "" }, l.p50_ms, l.p95_ms, l.p99_ms, l.n);
        let sl = &a.search_latency;
        let el = &a.query_embed_latency;
        let _ = writeln!(o, "| — of which SQL hybrid search (Postgres) | p50 {:.1} ms · p95 {:.1} ms · p99 {:.1} ms |", sl.p50_ms, sl.p95_ms, sl.p99_ms);
        let _ = writeln!(o, "| — of which query embedding (CPU, shared with concurrent ingest) | p50 {:.1} ms · p95 {:.1} ms |", el.p50_ms, el.p95_ms);
        let _ = writeln!(o, "| Ingest | {} rounds, {:.0} rounds/s with {} workers (includes embedding on CPU, cache hits for repeated sessions) |\n", a.ingest_rounds, a.rounds_per_second, c.concurrency);

        let refs: Vec<_> = baselines::RETRIEVAL.iter().filter(|_| s.dataset.starts_with("longmemeval")).collect();
        if !refs.is_empty() && has_session {
            let _ = writeln!(o, "## Reference: published retrieval results\n");
            let _ = writeln!(o, "From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's \"Recall@k\" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).\n");
            let _ = writeln!(o, "| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |\n|---|---|---|---|---|---|");
            if let (Some(r5), Some(n5), Some(r10), Some(n10)) = (get(a, "session/recall_all@5"), get(a, "session/ndcg@5"), get(a, "session/recall_all@10"), get(a, "session/ndcg@10")) {
                let _ = writeln!(o, "| **MemHouse (this run, {})** | session | **{:.1}** | **{:.1}** | **{:.1}** | **{:.1}** |", s.dataset, r5.mean * 100.0, n5.mean * 100.0, r10.mean * 100.0, n10.mean * 100.0);
            }
            if let (Some(r5), Some(n5), Some(r10), Some(n10)) = (get(a, "round/recall_all@5"), get(a, "round/ndcg@5"), get(a, "round/recall_all@10"), get(a, "round/ndcg@10")) {
                let _ = writeln!(o, "| **MemHouse (this run, {})** | round | **{:.1}** | **{:.1}** | **{:.1}** | **{:.1}** |", s.dataset, r5.mean * 100.0, n5.mean * 100.0, r10.mean * 100.0, n10.mean * 100.0);
            }
            for r in refs {
                let _ = writeln!(o, "| {} | {} | {:.1} | {:.1} | {:.1} | {:.1} |", r.system, r.granularity, r.r5 * 100.0, r.n5 * 100.0, r.r10 * 100.0, r.n10 * 100.0);
            }
            let _ = writeln!(o);
        }
        let qa_refs: Vec<_> = baselines::QA.iter().filter(|r| s.dataset.starts_with(r.dataset) || r.dataset == s.dataset).collect();
        if !qa_refs.is_empty() {
            let _ = writeln!(o, "## Reference: published answer accuracy on {}\n", qa_refs[0].dataset);
            let _ = writeln!(o, "Mostly vendor-reported, with different answer and judge models; use for orientation only.\n");
            let _ = writeln!(o, "| System | Accuracy % | Models | Reported by |\n|---|---|---|---|");
            if let Some(qa) = &a.qa_accuracy {
                let _ = writeln!(o, "| **MemHouse (this run)** | **{:.1}** | {} | this tool |", qa.mean * 100.0, c.answer_model.clone().unwrap_or_default());
            }
            for r in qa_refs {
                let _ = writeln!(o, "| {} | {:.1} | {} | [{}]({}) |", r.system, r.score, r.models, r.who, r.source);
            }
            let _ = writeln!(o);
        }
        let _ = writeln!(o, "Published search latencies (Mem0 paper, LoCoMo, hosted services incl. network): {}.\n",
            baselines::LATENCY.iter().map(|l| format!("{} p50 {:.0} / p95 {:.0} ms", l.system, l.p50_ms, l.p95_ms)).collect::<Vec<_>>().join("; "));
    }

    if let Some(g) = &s.governance {
        let _ = writeln!(o, "## Governance and safety gates\n");
        let _ = writeln!(o, "**{} of {} checks passed** ({:.0} ms). Deterministic checks, never decided by a model.\n", g.passed, g.passed + g.failed, g.took_ms);
        let _ = writeln!(o, "| | Check | Requirement | Result | Target | Detail |\n|---|---|---|---|---|---|");
        for c in &g.checks {
            let _ = writeln!(o, "| {} | {} | {} | {} | {} | {} |", if c.passed { "✅ pass" } else { "❌ FAIL" }, c.title, c.requirement, c.value, c.target, c.detail.replace('|', "/"));
        }
        let _ = writeln!(o);
    }
    o
}

/// Compare several runs on their headline metrics.
pub fn compare(runs: &[Summary]) -> String {
    let mut o = String::new();
    let _ = writeln!(o, "# MemHouse benchmark comparison\n");
    let keys = [
        "session/recall_any@5", "session/recall_all@5", "session/recall_all@10", "session/ndcg@10",
        "round/recall_all@10", "round/ndcg@10",
    ];
    let _ = write!(o, "| Run | Dataset | n | {} | QA acc | recall p50 / p95 ms |\n|---|---|---|", keys.join(" | "));
    for _ in keys {
        let _ = write!(o, "---|");
    }
    let _ = writeln!(o, "---|---|");
    for s in runs {
        let Some(a) = &s.results else { continue };
        let label = s.label.clone().unwrap_or_else(|| s.run_id.clone());
        let _ = write!(o, "| {} ({}{}) | {} | {} |", label, s.config.mode, if s.config.reranker.is_some() { "+rerank" } else { "" }, s.dataset, a.scored);
        for k in keys {
            let _ = write!(o, " {} |", a.retrieval.get(k).map(|e| format!("{:.1}", e.mean * 100.0)).unwrap_or_else(|| "–".into()));
        }
        let _ = writeln!(
            o,
            " {} | {:.1} / {:.1} |",
            a.qa_accuracy.as_ref().map(|e| format!("{:.1}{}", e.mean * 100.0, a.llm.as_ref().map(|t| format!(" (${:.2})", t.total_cost_usd)).unwrap_or_default())).unwrap_or_else(|| "–".into()),
            a.recall_latency.p50_ms,
            a.recall_latency.p95_ms
        );
    }
    o
}
