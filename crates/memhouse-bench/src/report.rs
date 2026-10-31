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
    pub concurrency: usize,
    pub selection: String,
    pub answer_model: Option<String>,
    pub judge_model: Option<String>,
    pub answer_k: Option<usize>,
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
    let _ = writeln!(o, "| Selection | {} |", c.selection);
    if let Some(m) = &c.answer_model {
        let _ = writeln!(o, "| Answer model | `{m}` (top {} memories) |", c.answer_k.unwrap_or(0));
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

        let l = &a.recall_latency;
        let _ = writeln!(o, "## Latency and throughput\n");
        let _ = writeln!(o, "| Metric | Value |\n|---|---|");
        let _ = writeln!(o, "| Recall (end to end: query embedding + one SQL statement{}) | p50 {:.1} ms · p95 {:.1} ms · p99 {:.1} ms · n={} |", if c.reranker.is_some() { " + rerank" } else { "" }, l.p50_ms, l.p95_ms, l.p99_ms, l.n);
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
            a.qa_accuracy.as_ref().map(|e| format!("{:.1}", e.mean * 100.0)).unwrap_or_else(|| "–".into()),
            a.recall_latency.p50_ms,
            a.recall_latency.p95_ms
        );
    }
    o
}
