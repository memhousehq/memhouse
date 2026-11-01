// SPDX-License-Identifier: Apache-2.0
//! `memhouse bench`: the validation tool shipped with MemHouse. Runs public long-term memory
//! benchmarks (LongMemEval, LoCoMo) and the governance/safety gates against a real engine, and
//! writes reproducible reports.

pub mod baselines;
pub mod datasets;
pub mod governance;
pub mod guard;
pub mod metrics;
pub mod report;
pub mod runner;

use anyhow::Context;
use clap::{Args, Subcommand};
use memhouse_core::config::LlmConfig;
use memhouse_core::types::RetrievalMode;
use memhouse_core::Config;
use std::io::Write;
use std::path::PathBuf;

#[derive(Subcommand, Debug)]
pub enum BenchCmd {
    /// List available datasets and suites
    List,
    /// Download a public dataset into ~/.memhouse/bench-data
    Download {
        /// longmemeval-s, longmemeval-m, longmemeval-oracle, locomo
        dataset: String,
        #[arg(long)]
        force: bool,
    },
    /// Run a benchmark dataset and/or the governance suite
    Run(Box<RunArgs>),
    /// Regression guard: run the benchmark tiers and compare them with bench/baselines.json
    Guard(guard::GuardArgs),
    /// Rebuild report.md for a results directory, or compare several runs
    Report {
        /// One or more results directories (bench-results/<run>)
        dirs: Vec<PathBuf>,
    },
}

#[derive(Args, Debug, Clone)]
pub struct RunArgs {
    /// Dataset to run (see `memhouse bench list`)
    #[arg(long)]
    pub dataset: Option<String>,
    /// Suite to run: governance
    #[arg(long)]
    pub suite: Option<String>,
    /// Maximum number of conversations
    #[arg(long)]
    pub limit: Option<usize>,
    /// Take every n-th conversation (e.g. --stride 10 = a 50-question stratified sample of LongMemEval)
    #[arg(long, default_value_t = 1)]
    pub stride: usize,
    #[arg(long, default_value_t = 0)]
    pub offset: usize,
    /// Only abstention questions (LongMemEval `_abs`)
    #[arg(long)]
    pub abstention_only: bool,
    /// Only these question types (comma separated)
    #[arg(long)]
    pub types: Option<String>,
    /// hybrid, dense or keyword
    #[arg(long, default_value = "hybrid")]
    pub mode: String,
    /// Use the cross-encoder reranker
    #[arg(long)]
    pub rerank: bool,
    /// Reranker model (local)
    #[arg(long)]
    pub rerank_model: Option<String>,
    /// Local embedding model for this run (a separate benchmark database is used per model)
    #[arg(long)]
    pub embedding_model: Option<String>,
    #[arg(long, default_value_t = 4)]
    pub concurrency: usize,
    /// Keep benchmark memories after the run
    #[arg(long)]
    pub keep: bool,
    /// Results directory (default ./bench-results)
    #[arg(long)]
    pub out: Option<PathBuf>,
    #[arg(long)]
    pub label: Option<String>,
    /// Use this database instead of the automatic benchmark database
    #[arg(long)]
    pub database_url: Option<String>,
    /// Also generate answers and judge them with an LLM (needs an OpenAI-compatible or Anthropic endpoint)
    #[arg(long)]
    pub qa: bool,
    /// openai (OpenAI-compatible: OpenAI, Ollama, vLLM, LM Studio, OpenRouter) or anthropic
    #[arg(long, default_value = "openai")]
    pub llm_provider: String,
    #[arg(long)]
    pub llm_base_url: Option<String>,
    #[arg(long, default_value = "gpt-4o-mini")]
    pub answer_model: String,
    /// Judge model (LongMemEval's protocol uses GPT-4o)
    #[arg(long, default_value = "gpt-4o")]
    pub judge_model: String,
    /// Environment variable holding the LLM API key
    #[arg(long, default_value = "OPENAI_API_KEY")]
    pub llm_key_env: String,
    /// Answer-model price in USD per million tokens, "prompt,completion" (used when the provider
    /// reports no cost; OpenRouter reports it)
    #[arg(long)]
    pub answer_price: Option<String>,
    /// Judge-model price in USD per million tokens, "prompt,completion"
    #[arg(long)]
    pub judge_price: Option<String>,
    /// Stop the QA run once LLM spend passes this many USD
    #[arg(long)]
    pub max_cost_usd: Option<f64>,
    /// Extract facts with a small LLM in the background (async pipeline) before asking questions
    #[arg(long)]
    pub enrich: bool,
    #[arg(long, default_value = "qwen/qwen3.7-flash")]
    pub enrich_model: String,
    #[arg(long, default_value_t = 8)]
    pub enrich_workers: usize,
    /// Stop enrichment LLM calls once they have cost this much (USD)
    #[arg(long, default_value_t = 2.0)]
    pub enrich_max_cost_usd: f64,
    /// Enrichment-model price in USD per million tokens, "prompt,completion"
    #[arg(long)]
    pub enrich_price: Option<String>,
    /// Answer prompt version (1 = short direct answer, 2 = guidance per question type)
    #[arg(long, default_value_t = 2)]
    pub answer_prompt: u8,
    /// Derived facts given to the answer model, besides --answer-k rounds
    #[arg(long, default_value_t = 50)]
    pub answer_facts: usize,
    /// Memories given to the answer model
    #[arg(long, default_value_t = 10)]
    pub answer_k: usize,
    /// Fused candidates per retriever
    #[arg(long)]
    pub candidates: Option<usize>,
    #[arg(long)]
    pub keyword_weight: Option<f32>,
    #[arg(long)]
    pub vector_weight: Option<f32>,
    /// Turn off query analysis (time-window and sub-query probes), for ablations
    #[arg(long)]
    pub no_analysis: bool,
    #[arg(long)]
    pub window_weight: Option<f32>,
    /// Extra weight for the top N hits of the time-window probe: --window-top N --window-top-weight W
    #[arg(long)]
    pub window_top: Option<usize>,
    #[arg(long)]
    pub window_top_weight: Option<f32>,
    #[arg(long)]
    pub subquery_weight: Option<f32>,
}

fn slug(s: &str) -> String {
    s.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' }).collect::<String>().trim_matches('_').to_string()
}

/// Create (if needed) a dedicated benchmark database next to the user's one, so benchmark data
/// never mixes with real memories and each embedding model gets its own schema dimension.
async fn bench_database(base_url: &str, model: &str) -> anyhow::Result<String> {
    let db = format!("memhouse_bench_{}", slug(model)).chars().take(60).collect::<String>();
    let pool = sqlx::postgres::PgPoolOptions::new().max_connections(1).connect(base_url).await?;
    let exists: bool = sqlx::query_scalar(&format!("SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '{db}')")).fetch_one(&pool).await?;
    if !exists {
        sqlx::raw_sql(&format!("CREATE DATABASE \"{db}\"")).execute(&pool).await.with_context(|| format!("creating benchmark database {db} (or pass --database-url)"))?;
    }
    let (head, _) = base_url.rsplit_once('/').ok_or_else(|| anyhow::anyhow!("unexpected database url"))?;
    let tail = base_url.rsplit_once('/').map(|(_, t)| t).unwrap_or("");
    let query = tail.split_once('?').map(|(_, q)| format!("?{q}")).unwrap_or_default();
    Ok(format!("{head}/{db}{query}"))
}

fn host_info() -> String {
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    format!("{} {} · {} CPU threads · embeddings on CPU", std::env::consts::OS, std::env::consts::ARCH, cpus)
}

pub async fn main(cmd: BenchCmd, cfg: Config) -> anyhow::Result<()> {
    match cmd {
        BenchCmd::List => {
            println!("Datasets (memhouse bench download <name>; memhouse bench run --dataset <name>):");
            for d in datasets::DATASETS {
                let have = if datasets::data_dir().join(d.file).exists() { "downloaded" } else { d.size };
                println!("  {:<20} {}  [{}]", d.name, d.title, have);
            }
            println!("\nSuites (memhouse bench run --suite <name>):");
            println!(
                "  {:<20} deterministic governance and safety gates: injection, PII, isolation, deletion, supersession, validity, audit, recall scope and exactness",
                "governance"
            );
            Ok(())
        }
        BenchCmd::Download { dataset, force } => {
            datasets::download(&dataset, force).await?;
            Ok(())
        }
        BenchCmd::Report { dirs } => {
            let mut runs = vec![];
            for d in &dirs {
                let s: report::Summary = serde_json::from_str(&std::fs::read_to_string(d.join("summary.json")).with_context(|| format!("reading {}/summary.json", d.display()))?)?;
                std::fs::write(d.join("report.md"), report::markdown(&s))?;
                runs.push(s);
            }
            if runs.len() == 1 {
                println!("{}", report::markdown(&runs[0]));
            } else {
                println!("{}", report::compare(&runs));
            }
            Ok(())
        }
        BenchCmd::Run(args) => {
            let (summary, _) = run_to(*args, cfg, false).await?;
            if let Some(g) = &summary.governance {
                if g.failed > 0 {
                    anyhow::bail!("{} governance gate(s) failed", g.failed);
                }
            }
            Ok(())
        }
        BenchCmd::Guard(args) => guard::run(args, cfg).await,
    }
}

/// Run one benchmark and write its results directory. `quiet` skips printing the report.
pub async fn run_to(args: RunArgs, mut cfg: Config, quiet: bool) -> anyhow::Result<(report::Summary, PathBuf)> {
    if args.dataset.is_none() && args.suite.is_none() {
        anyhow::bail!("give --dataset <name> and/or --suite governance (see `memhouse bench list`)");
    }
    if let Some(m) = &args.embedding_model {
        let (_, dim, _) = memhouse_models::local::resolve_embedding(m)?;
        cfg.embedding.provider = "local".into();
        cfg.embedding.model = m.clone();
        cfg.embedding.dim = dim;
        if !m.contains("bge") {
            cfg.embedding.query_prefix = None;
        }
    }
    if args.rerank {
        cfg.rerank.enabled = true;
        if let Some(m) = &args.rerank_model {
            cfg.rerank.model = m.clone();
        }
    }
    if let Some(c) = args.candidates {
        cfg.memory.candidates = c;
    }
    if let Some(w) = args.keyword_weight {
        cfg.memory.keyword_weight = w;
    }
    if let Some(w) = args.vector_weight {
        cfg.memory.vector_weight = w;
    }
    if args.no_analysis {
        cfg.memory.query_analysis = false;
    }
    if let Some(w) = args.window_weight {
        cfg.memory.window_weight = w;
    }
    if let Some(n) = args.window_top {
        cfg.memory.window_top = n;
    }
    if let Some(w) = args.window_top_weight {
        cfg.memory.window_top_weight = w;
    }
    if let Some(w) = args.subquery_weight {
        cfg.memory.subquery_weight = w;
    }
    if args.enrich {
        cfg.enrich.enabled = true;
        cfg.enrich.llm.model = args.enrich_model.clone();
        cfg.enrich.llm.api_key_env = Some(args.llm_key_env.clone());
        if let Some(b) = &args.llm_base_url {
            cfg.enrich.llm.base_url = b.clone();
        }
        cfg.enrich.workers = args.enrich_workers;
        cfg.enrich.max_cost_usd = args.enrich_max_cost_usd;
    }
    cfg.memory.tenant = "bench".into();
    cfg.memory.recency_weight = 0.0;
    cfg.governance.audit_reads = false;
    cfg.database.max_connections = cfg.database.max_connections.max(args.concurrency as u32 * 2 + 4);
    cfg.database.url = match &args.database_url {
        Some(u) => u.clone(),
        None => bench_database(&cfg.database.url, &format!("{}_{}", cfg.embedding.provider, cfg.embedding.model)).await?,
    };
    let mode = match args.mode.as_str() {
        "hybrid" => RetrievalMode::Hybrid,
        "dense" => RetrievalMode::Dense,
        "keyword" => RetrievalMode::Keyword,
        m => anyhow::bail!("unknown mode '{m}'"),
    };
    eprintln!("Benchmark database: {}", memhouse_store_postgres::redact_url(&cfg.database.url));
    let engine = memhouse_server::build_engine(cfg.clone(), true).await?;
    let engine = if args.enrich {
        let chat = memhouse_models::enrich_chat(&cfg, price(args.enrich_price.as_deref(), &args.enrich_model)?)?;
        engine.with_chat(chat)
    } else {
        engine
    };
    let run_id = format!("{}-{}", chrono::Utc::now().format("%Y%m%d-%H%M%S"), &uuid::Uuid::new_v4().to_string()[..6]);
    let name = args.dataset.clone().unwrap_or_else(|| args.suite.clone().unwrap_or_default());
    let out_dir = args.out.clone().unwrap_or_else(|| PathBuf::from("bench-results")).join(format!(
        "{}_{}{}",
        run_id,
        name,
        args.label.as_deref().map(|l| format!("_{}", slug(l))).unwrap_or_default()
    ));
    std::fs::create_dir_all(&out_dir)?;

    let qa = if args.qa {
        let base =
            args.llm_base_url.clone().unwrap_or_else(|| if args.llm_provider == "anthropic" { "https://api.anthropic.com/v1".into() } else { "https://api.openai.com/v1".into() });
        let mk = |model: &str, max_tokens: u32| LlmConfig {
            provider: args.llm_provider.clone(),
            base_url: base.clone(),
            model: model.to_string(),
            api_key_env: Some(args.llm_key_env.clone()),
            max_tokens,
            temperature: 0.0,
            extra: None,
        };
        Some(runner::QaSetup {
            answer: memhouse_models::Llm::new(&mk(&args.answer_model, if args.answer_prompt >= 2 { 1000 } else { 600 }))?
                .with_price(price(args.answer_price.as_deref(), &args.answer_model)?),
            judge: memhouse_models::Llm::new(&mk(&args.judge_model, 10))?.with_price(price(args.judge_price.as_deref(), &args.judge_model)?),
            answer_k: args.answer_k,
            answer_facts: if args.enrich { args.answer_facts } else { 0 },
            prompt_version: args.answer_prompt,
            max_cost_usd: args.max_cost_usd,
            spent_micro_usd: Default::default(),
        })
    } else {
        None
    };

    let started = std::time::Instant::now();
    let mut summary = report::Summary {
        run_id: run_id.clone(),
        label: args.label.clone(),
        dataset: name.clone(),
        created_at: chrono::Utc::now(),
        wall_seconds: 0.0,
        config: report::RunConfig {
            memhouse_version: env!("CARGO_PKG_VERSION").into(),
            embedder: engine.embedder.id().into(),
            reranker: if args.rerank { engine.reranker.as_ref().map(|r| r.id().to_string()) } else { None },
            mode: args.mode.clone(),
            candidates_per_retriever: cfg.memory.candidates,
            rrf_k: cfg.memory.rrf_k,
            keyword_weight: cfg.memory.keyword_weight,
            vector_weight: cfg.memory.vector_weight,
            query_analysis: cfg.memory.query_analysis.then(|| {
                format!("window w={}, top {} +{}, sub-query w={}", cfg.memory.window_weight, cfg.memory.window_top, cfg.memory.window_top_weight, cfg.memory.subquery_weight)
            }),
            concurrency: args.concurrency,
            selection: format!(
                "limit={} stride={} offset={} types={}",
                args.limit.map(|l| l.to_string()).unwrap_or_else(|| "all".into()),
                args.stride,
                args.offset,
                args.types.clone().unwrap_or_else(|| "all".into())
            ),
            answer_model: qa.as_ref().map(|q| q.answer.id()),
            judge_model: qa.as_ref().map(|q| q.judge.id()),
            answer_k: qa.as_ref().map(|q| q.answer_k),
            answer_prompt: qa.as_ref().map(|q| q.prompt_version),
            enrich_model: args.enrich.then(|| args.enrich_model.clone()),
            host: host_info(),
        },
        results: None,
        governance: None,
    };

    if args.suite.as_deref() == Some("governance") {
        eprintln!("Running governance and safety suite ...");
        let g = governance::run(&engine, &run_id).await?;
        for c in &g.checks {
            eprintln!("  {} {:<22} {}", if c.passed { "✓" } else { "✗" }, c.id, c.value);
        }
        summary.governance = Some(g);
    } else if let Some(s) = &args.suite {
        anyhow::bail!("unknown suite '{s}'");
    }

    if let Some(ds) = &args.dataset {
        datasets::info(ds)?;
        let spec = runner::RunSpec {
            dataset: ds.clone(),
            selection: datasets::Selection {
                limit: args.limit,
                stride: args.stride,
                offset: args.offset,
                types: args.types.as_ref().map(|t| t.split(',').map(|s| s.trim().to_string()).collect()),
                abstention_only: args.abstention_only,
            },
            mode,
            rerank: args.rerank,
            concurrency: args.concurrency,
            keep: args.keep,
            run_id: run_id.clone(),
            qa,
            enrich: args.enrich,
        };
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let workers = if args.enrich { engine.spawn_enrichment(args.enrich_workers, stop.clone(), Default::default()) } else { vec![] };
        let mut items_file = std::io::BufWriter::new(std::fs::File::create(out_dir.join("items.jsonl"))?);
        let results = runner::run(engine.clone(), spec, |r| {
            writeln!(items_file, "{}", serde_json::to_string(r)?)?;
            Ok(())
        })
        .await;
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for w in workers {
            let _ = w.await;
        }
        let results = results?;
        items_file.flush()?;
        summary.results = Some(runner::aggregate(&results, started.elapsed().as_secs_f64(), args.concurrency));
    }

    summary.wall_seconds = started.elapsed().as_secs_f64();
    std::fs::write(out_dir.join("summary.json"), serde_json::to_string_pretty(&summary)?)?;
    let md = report::markdown(&summary);
    std::fs::write(out_dir.join("report.md"), &md)?;
    if !quiet {
        println!("{md}");
    }
    eprintln!("Results written to {}", out_dir.display());
    Ok((summary, out_dir))
}

/// USD per million (prompt, completion) tokens: the explicit flag, else list prices for common
/// models (by model name, with or without an OpenRouter `vendor/` prefix), else unknown.
fn price(flag: Option<&str>, model: &str) -> anyhow::Result<Option<(f64, f64)>> {
    if let Some(f) = flag {
        let (a, b) = f.split_once(',').context("price must be \"prompt,completion\" USD per 1M tokens")?;
        return Ok(Some((a.trim().parse()?, b.trim().parse()?)));
    }
    let name = model.rsplit('/').next().unwrap_or(model);
    Ok(match name {
        "gpt-4o-mini" => Some((0.15, 0.60)),
        "gpt-4o" => Some((2.50, 10.00)),
        "gpt-4.1" => Some((2.00, 8.00)),
        "gpt-4.1-mini" => Some((0.40, 1.60)),
        "gpt-4.1-nano" => Some((0.10, 0.40)),
        _ => None,
    })
}
