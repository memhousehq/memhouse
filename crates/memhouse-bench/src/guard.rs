//! `memhouse bench guard`: the regression guard every development goal ends with
//! (draft_plan/development-plan.md, section 3). Runs the benchmark tiers and compares each metric
//! with `bench/baselines.json`; fails if any metric moved past its threshold.

use crate::report::Summary;
use crate::{run_to, RunArgs};
use anyhow::Context;
use clap::{Args, Parser};
use memhouse_core::Config;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Args, Debug, Clone)]
pub struct GuardArgs {
    /// Highest tier to run: 1 = governance + free retrieval runs, 2 = also LoCoMo with cached enrichment (~$0.01)
    #[arg(long, default_value_t = 1)]
    pub tier: u8,
    #[arg(long, default_value = "bench/baselines.json")]
    pub baselines: PathBuf,
    /// Where the guard's run directories and report go
    #[arg(long, default_value = "bench-results/guard")]
    pub out: PathBuf,
    /// Record this run's values as the new baselines (thresholds are kept). Only after a deliberate improvement.
    #[arg(long)]
    pub update: bool,
    /// Report latency but don't fail on it, for a machine known to be busy. Quality and governance still gate.
    #[arg(long)]
    pub skip_latency: bool,
    /// Extra `bench run` arguments applied to every run, e.g. `-- --vector-weight 0` to check the guard trips
    #[arg(last = true)]
    pub extra: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Baselines {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub measured_at: String,
    pub embedding_model: String,
    pub governance: GovernanceBase,
    pub runs: Vec<RunBase>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GovernanceBase {
    /// Every check must pass, and there must be at least this many (a removed check is a regression).
    pub min_checks: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunBase {
    pub name: String,
    pub tier: u8,
    /// `bench run` arguments for this run (the embedding model is added from the file).
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    pub checks: Vec<CheckBase>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckBase {
    /// A retrieval metric (`session/recall_all@5`), `qa_accuracy`, or `recall_p95_ms`.
    pub metric: String,
    pub baseline: f64,
    /// Fail if the value falls by more than this (absolute, same unit as the metric).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_drop: Option<f64>,
    /// Fail if the value rises by more than this many percent (latency).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_rise_pct: Option<f64>,
    /// Absolute slack for `max_rise_pct` in the metric's unit: the limit is the larger of the two.
    /// Keeps millisecond-scale timings from failing on scheduler noise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_rise: Option<f64>,
}

#[derive(Parser)]
struct RunArgv {
    #[command(flatten)]
    args: RunArgs,
}

struct Row {
    run: String,
    metric: String,
    baseline: f64,
    value: Option<f64>,
    limit: String,
    pass: bool,
}

fn metric(s: &Summary, name: &str) -> Option<f64> {
    let r = s.results.as_ref()?;
    match name {
        "recall_p95_ms" => Some(r.recall_latency.p95_ms),
        "recall_p50_ms" => Some(r.recall_latency.p50_ms),
        "search_p50_ms" => Some(r.search_latency.p50_ms),
        "search_p95_ms" => Some(r.search_latency.p95_ms),
        "qa_accuracy" => r.qa_accuracy.as_ref().map(|e| e.mean),
        k => r.retrieval.get(k).map(|e| e.mean),
    }
}

fn judge(c: &CheckBase, v: Option<f64>) -> (String, bool) {
    match (v, c.max_drop, c.max_rise_pct) {
        (None, _, _) => ("metric missing".into(), false),
        (Some(v), Some(d), _) => (format!("≥ {:.4}", c.baseline - d), v >= c.baseline - d - 1e-9),
        (Some(v), None, Some(p)) => {
            let max = (c.baseline * (1.0 + p / 100.0)).max(c.baseline + c.min_rise.unwrap_or(0.0));
            (format!("≤ {max:.1}"), v <= max)
        }
        (Some(_), None, None) => ("no threshold".into(), true),
    }
}

fn fmt(metric: &str, v: f64) -> String {
    if metric.ends_with("_ms") {
        format!("{v:.1} ms")
    } else {
        format!("{:.1}", v * 100.0)
    }
}

pub async fn run(g: GuardArgs, cfg: Config) -> anyhow::Result<()> {
    if g.update && !g.extra.is_empty() {
        anyhow::bail!("--update can't be combined with extra run arguments");
    }
    let text = std::fs::read_to_string(&g.baselines).with_context(|| format!("reading {}", g.baselines.display()))?;
    let mut base: Baselines = serde_json::from_str(&text).with_context(|| format!("parsing {}", g.baselines.display()))?;
    let started = std::time::Instant::now();
    let mut rows: Vec<Row> = vec![];
    let common = |label: &str| -> Vec<String> {
        let mut v =
            vec!["run".into(), "--embedding-model".into(), base.embedding_model.clone(), "--out".into(), g.out.display().to_string(), "--label".into(), format!("guard-{label}")];
        v.extend(g.extra.iter().cloned());
        v
    };

    // Governance: every check passes, and none has gone missing.
    let mut argv = common("governance");
    argv.extend(["--suite".into(), "governance".into()]);
    let a = RunArgv::try_parse_from(&argv)?.args;
    eprintln!("guard: governance suite");
    let (s, dir) = run_to(a, cfg.clone(), true).await?;
    let gov = s.governance.as_ref().context("governance report missing")?;
    for c in gov.checks.iter().filter(|c| !c.passed) {
        rows.push(Row { run: "governance".into(), metric: c.id.clone(), baseline: 1.0, value: Some(0.0), limit: "pass".into(), pass: false });
    }
    rows.push(Row {
        run: "governance".into(),
        metric: "checks passed".into(),
        baseline: base.governance.min_checks as f64,
        value: Some(gov.passed as f64),
        limit: format!("all of ≥ {}", base.governance.min_checks),
        pass: gov.failed == 0 && gov.checks.len() >= base.governance.min_checks,
    });
    if g.update {
        base.governance.min_checks = base.governance.min_checks.max(gov.checks.len());
        base.governance.source = Some(rel(&dir));
    }

    for rb in base.runs.iter_mut().filter(|r| r.tier <= g.tier) {
        let mut argv = common(&slug(&rb.name));
        argv.extend(rb.args.iter().cloned());
        let a = RunArgv::try_parse_from(&argv).with_context(|| format!("arguments of guard run '{}'", rb.name))?.args;
        eprintln!("guard: {} (tier {})", rb.name, rb.tier);
        let (s, dir) = run_to(a.clone(), cfg.clone(), true).await?;
        let mut values: Vec<Option<f64>> = rb.checks.iter().map(|c| metric(&s, &c.metric)).collect();
        // Timings move with machine load; quality metrics are deterministic. If only timings
        // failed, run once more and keep the better timing before deciding.
        let fails: Vec<bool> = rb.checks.iter().zip(&values).map(|(c, v)| !judge(c, *v).1).collect();
        let latency_only = fails.iter().any(|f| *f) && rb.checks.iter().zip(&fails).all(|(c, f)| !*f || is_latency(&c.metric));
        if latency_only && !g.skip_latency {
            eprintln!("guard: {} — only timings over their limit; re-running once", rb.name);
            let (s2, _) = run_to(a, cfg.clone(), true).await?;
            for (c, v) in rb.checks.iter().zip(values.iter_mut()) {
                if is_latency(&c.metric) {
                    if let (Some(a), Some(b)) = (*v, metric(&s2, &c.metric)) {
                        *v = Some(a.min(b));
                    }
                }
            }
        }
        for (c, v) in rb.checks.iter_mut().zip(values) {
            let (mut limit, mut pass) = judge(c, v);
            if g.skip_latency && is_latency(&c.metric) {
                limit = format!("{limit} (not gated)");
                pass = true;
            }
            rows.push(Row { run: rb.name.clone(), metric: c.metric.clone(), baseline: c.baseline, value: v, limit, pass });
            if g.update {
                if let Some(v) = v {
                    c.baseline = (v * 10_000.0).round() / 10_000.0;
                }
            }
        }
        if g.update {
            rb.source = Some(rel(&dir));
        }
    }

    let failed = rows.iter().filter(|r| !r.pass).count();
    let latency_failed = rows.iter().filter(|r| !r.pass && is_latency(&r.metric)).count();
    let mut md = format!(
        "# Benchmark guard\n\nTier {} · baselines {} (measured {}) · {:.0} s{}\n\n| | Run | Metric | Baseline | Now | Limit |\n|---|---|---|---|---|---|\n",
        g.tier,
        g.baselines.display(),
        base.measured_at,
        started.elapsed().as_secs_f64(),
        if g.extra.is_empty() { String::new() } else { format!(" · extra args: `{}`", g.extra.join(" ")) }
    );
    for r in &rows {
        let (b, v) = if r.run == "governance" {
            (format!("{}", r.baseline), r.value.map(|v| format!("{v}")).unwrap_or_default())
        } else {
            (fmt(&r.metric, r.baseline), r.value.map(|v| fmt(&r.metric, v)).unwrap_or_else(|| "–".into()))
        };
        md.push_str(&format!("| {} | {} | {} | {} | {} | {} |\n", if r.pass { "✅" } else { "❌" }, r.run, r.metric, b, v, r.limit));
    }
    md.push_str(&if failed == 0 {
        "\n**Guard passed.**\n".to_string()
    } else {
        format!(
            "\n**Guard failed: {failed} metric(s) past their threshold.** If only the LongMemEval 50-question sample tripped, confirm on the full set \
             (`memhouse bench run --dataset longmemeval-s --embedding-model {}`) before calling it a regression.{}\n",
            base.embedding_model,
            if latency_failed == failed { " Only timings failed: check the machine's load (`uptime`) and rerun; on a busy machine use `--skip-latency`." } else { "" }
        )
    });
    std::fs::create_dir_all(&g.out)?;
    let report = g.out.join(format!("guard-{}.md", chrono::Utc::now().format("%Y%m%d-%H%M%S")));
    std::fs::write(&report, &md)?;
    println!("{md}");
    eprintln!("Guard report: {}", report.display());

    if g.update {
        base.measured_at = chrono::Utc::now().format("%Y-%m-%d").to_string();
        std::fs::write(&g.baselines, serde_json::to_string_pretty(&base)? + "\n")?;
        eprintln!("Baselines updated in {}", g.baselines.display());
        return Ok(());
    }
    if failed > 0 {
        anyhow::bail!("benchmark guard failed ({failed} metric(s))");
    }
    Ok(())
}

fn is_latency(metric: &str) -> bool {
    metric.ends_with("_ms")
}

fn rel(p: &Path) -> String {
    p.display().to_string()
}

fn slug(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' }).collect()
}
