// SPDX-License-Identifier: Apache-2.0
//! `memhouse`: one binary to run, connect, operate and benchmark MemHouse.

// Replaces `std::println!` for this crate (defined before the modules so they use it too). The std
// macro panics when stdout is a closed pipe, as in `memhouse recall ... | head` or `| grep -q`; a
// command-line tool should stop quietly there instead. It exits 141 (128 + SIGPIPE), as a shell
// reports any tool stopped by a closed pipe, not 0: the command may not have finished its work
// (`memhouse reembed --yes` prints its plan before re-embedding).
macro_rules! println {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        if let Err(e) = writeln!(std::io::stdout(), $($arg)*) {
            if e.kind() == std::io::ErrorKind::BrokenPipe {
                std::process::exit(141);
            }
            panic!("failed printing to stdout: {e}");
        }
    }};
}

mod connect;
mod policy;
mod principals;
mod up;

use anyhow::Context;
use clap::{Parser, Subcommand};
use memhouse_core::config::default_config_path;
use memhouse_core::types::*;
use memhouse_core::{templates, Config};
use rand::RngExt;
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "memhouse", version, about = "Governed long-term memory for AI agents. Rust + Postgres.", long_about = None)]
struct Cli {
    /// Config file (default ~/.memhouse/config.toml, or $MEMHOUSE_CONFIG)
    #[arg(long, global = true, env = "MEMHOUSE_CONFIG")]
    config: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// One-step local setup: start Postgres+pgvector in Docker, write config, download the embedding model
    Up {
        #[arg(long, default_value_t = 54329)]
        port: u16,
        /// Docker container name (run several isolated instances side by side)
        #[arg(long, default_value = up::CONTAINER)]
        name: String,
        /// Use-case template: personal, coding, support, sales, success
        #[arg(long)]
        template: Option<String>,
    },
    /// Stop the managed Postgres container (data is kept)
    Down,
    /// Write a config for an existing Postgres (needs the pgvector extension available)
    Init {
        #[arg(long)]
        database_url: String,
        #[arg(long)]
        template: Option<String>,
        /// Embedding provider: local or openai (any OpenAI-compatible endpoint, e.g. Ollama)
        #[arg(long, default_value = "local")]
        embedding: String,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        dim: Option<usize>,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long)]
        api_key_env: Option<String>,
        /// Ask the API for `--dim` dimensions (models that can shorten vectors, e.g. text-embedding-3-*)
        #[arg(long)]
        request_dimensions: bool,
        /// Overwrite an existing config file
        #[arg(long)]
        force: bool,
    },
    /// Run the HTTP server: REST API, MCP over HTTP at /mcp, Memory Browser at /
    Serve {
        #[arg(long)]
        bind: Option<String>,
    },
    /// Run the MCP server over stdio (what agents launch). Needs the agent's key or token
    Mcp {
        /// Default subject for this agent (e.g. repo:myapp, user:alice)
        #[arg(long)]
        subject: Option<String>,
        /// The agent's API key or token (`memhouse connect` writes it into the agent's config)
        #[arg(long, env = "MEMHOUSE_MCP_KEY", hide_env_values = true)]
        key: Option<String>,
        /// Ignored: the audit actor is the key's principal
        #[arg(long, hide = true)]
        actor: Option<String>,
    },
    /// Connect an agent: writes its MCP config and verifies a recall
    Connect {
        /// claude-code, claude-desktop, cursor, vscode, windsurf, codex, gemini, zed, goose, http, all
        agent: String,
        #[arg(long)]
        subject: Option<String>,
        /// Print the configuration instead of writing it
        #[arg(long)]
        print: bool,
        /// Write project-level config (in the current directory) where the agent supports it
        #[arg(long)]
        project: bool,
        #[arg(long)]
        no_verify: bool,
    },
    /// List supported agents and templates
    Agents,
    /// Check configuration, database, model and MCP round-trip
    Doctor,
    /// Print the bootstrap API key, or manage principals' keys (create, list, revoke, rotate)
    Key {
        #[command(subcommand)]
        cmd: Option<principals::KeyCmd>,
    },
    /// Manage principals: agents, users and admins
    Principal {
        #[command(subcommand)]
        cmd: principals::PrincipalCmd,
    },
    /// Behaviour policy: validate, diff, propose, approve and roll back specs
    Policy {
        /// Tenant (default: the configured one)
        #[arg(long, global = true)]
        tenant: Option<String>,
        #[command(subcommand)]
        cmd: policy::PolicyCmd,
    },
    /// Store a memory
    Remember {
        content: String,
        #[arg(long, short)]
        subject: Option<String>,
        #[arg(long, short, default_value = "semantic")]
        kind: String,
        #[arg(long = "tag", short = 't')]
        tags: Vec<String>,
    },
    /// Search memory
    Recall {
        query: String,
        #[arg(long, short)]
        subject: Option<String>,
        #[arg(short, default_value_t = 10)]
        k: usize,
        #[arg(long)]
        rerank: bool,
        #[arg(long)]
        json: bool,
    },
    /// List recent memories
    List {
        #[arg(long, short)]
        subject: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[arg(long)]
        all: bool,
    },
    /// Replace a memory with a corrected version (the old one is kept as superseded)
    Revise { id: String, content: String },
    /// Delete one memory, or everything about a subject, user, agent or source
    Forget {
        id: Option<String>,
        #[arg(long)]
        subject: Option<String>,
        /// Records the user wrote through an agent or that are scoped to the user
        #[arg(long)]
        user: Option<String>,
        /// Records the agent wrote or that are scoped to it
        #[arg(long)]
        agent: Option<String>,
        /// Records with this source label
        #[arg(long)]
        source: Option<String>,
        /// Count what would be deleted, delete nothing
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        yes: bool,
    },
    /// Print the OpenAPI 3.1 document of the REST API
    Openapi,
    /// Ingest a conversation (JSON array of {role, content[, timestamp]}) as episodic memory
    Ingest {
        file: PathBuf,
        #[arg(long, short)]
        subject: Option<String>,
        #[arg(long)]
        session: Option<String>,
    },
    /// Export a tenant (or one subject) as Memory Format v2 JSONL (docs/memory-format.md)
    Export {
        #[arg(long, short)]
        subject: Option<String>,
        #[arg(long, short)]
        out: Option<PathBuf>,
        /// Tenant to export (default: [memory] tenant)
        #[arg(long)]
        tenant: Option<String>,
    },
    /// Import a Memory Format v1 or v2 file (ids, states, timestamps and provenance are kept; vectors are made with this config's model)
    Import { file: PathBuf },
    /// Re-embed every stored memory with the model now in [embedding] (after changing it)
    Reembed {
        /// Show what would be re-embedded and stop
        #[arg(long)]
        dry_run: bool,
        /// Drop an unfinished re-embedding; the current vectors are untouched
        #[arg(long)]
        abort: bool,
        /// Records per embedding call and database write
        #[arg(long, default_value_t = 256)]
        batch: usize,
        #[arg(long)]
        yes: bool,
    },
    /// Audit log: show recent events or verify the hash chain
    Audit {
        #[arg(long)]
        verify: bool,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Show counts
    Stats,
    /// Apply retention rules now
    Retention,
    /// Benchmark and validate memory quality, safety and latency
    Bench {
        #[command(subcommand)]
        cmd: memhouse_bench::BenchCmd,
    },
}

fn random_token(n: usize) -> String {
    const CHARS: &[u8] = b"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut r = rand::rng();
    (0..n).map(|_| CHARS[r.random_range(0..CHARS.len())] as char).collect()
}

fn self_launch(cfg_path: &Option<PathBuf>, subject: &Option<String>) -> anyhow::Result<connect::Launch> {
    let exe = std::env::current_exe()?.canonicalize()?;
    let mut args = vec!["mcp".to_string()];
    if let Some(s) = subject {
        args.push("--subject".into());
        args.push(s.clone());
    }
    let mut env = vec![];
    if let Some(p) = cfg_path {
        env.push(("MEMHOUSE_CONFIG".to_string(), std::fs::canonicalize(p).unwrap_or(p.clone()).display().to_string()));
    }
    Ok(connect::Launch { command: exe.display().to_string(), args, env })
}

fn self_launch_with_key(cfg_path: &Option<PathBuf>, subject: &Option<String>, key: &str) -> anyhow::Result<connect::Launch> {
    let mut l = self_launch(cfg_path, subject)?;
    l.env.push(("MEMHOUSE_MCP_KEY".into(), key.to_string()));
    Ok(l)
}

async fn engine(cfg: Config) -> anyhow::Result<memhouse_core::Engine> {
    memhouse_server::build_engine(cfg, true).await.map_err(|e| {
        let hint = if format!("{e:#}").contains("cannot connect") { " (is Postgres running? try `memhouse up` or `memhouse doctor`)" } else { "" };
        e.context(format!("starting the memory engine{hint}"))
    })
}

fn print_next_steps(path: &std::path::Path) {
    println!("\nMemHouse is ready. Config: {}\n", path.display());
    println!("Connect an agent (writes its MCP config and checks a recall):");
    println!("  memhouse connect claude-code      # or: cursor, claude-desktop, vscode, windsurf, codex, gemini, all");
    println!("Try it from the terminal:");
    println!("  memhouse remember \"Alice prefers email over phone\" --subject user:alice");
    println!("  memhouse recall \"how should I contact Alice?\" --subject user:alice");
    println!("Run the HTTP API and Memory Browser:");
    println!("  memhouse serve                     # http://127.0.0.1:7077");
    println!("Benchmark it:");
    println!("  memhouse bench run --suite governance && memhouse bench run --dataset longmemeval-s --limit 50");
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let filter = std::env::var("RUST_LOG").unwrap_or_else(|_| "warn,memhouse=info".into());
    // Telemetry settings come from the config file; a broken file is reported by the command.
    let telemetry_cfg = Config::load(cli.config.as_deref()).map(|c| c.telemetry).unwrap_or_default();
    let telemetry = match memhouse_server::telemetry::init(&telemetry_cfg, &filter) {
        Ok(t) => Some(t),
        Err(e) => {
            eprintln!("warning: tracing export not started: {e:#}");
            None
        }
    };
    let result = run(cli).await;
    drop(telemetry); // flush spans before exiting
    if let Err(e) = result {
        eprintln!("error: {e:#}");
        std::process::exit(1);
    }
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    let cfg_path = cli.config.clone();
    let path_or_default = cfg_path.clone().unwrap_or_else(default_config_path);
    match cli.cmd {
        Cmd::Up { port, name, template } => {
            let mut cfg = if path_or_default.exists() { Config::load(Some(&path_or_default))? } else { Config::default() };
            let fresh = !path_or_default.exists();
            if fresh || up::managed(&cfg).is_some() {
                let password = if fresh { random_token(24) } else { cfg.database.url.split(':').nth(2).and_then(|s| s.split('@').next()).unwrap_or("memhouse").to_string() };
                let container = if fresh { name.clone() } else { up::managed(&cfg).unwrap_or(up::CONTAINER).to_string() };
                let url = up::start(&container, port, &password, fresh)?;
                if fresh {
                    cfg.database.url = url.clone();
                    cfg.database.container = Some(container);
                    cfg.server.api_keys = vec![format!("mh_{}", random_token(32))];
                }
                eprintln!("Waiting for Postgres ...");
                up::wait_ready(&cfg.database.url, std::time::Duration::from_secs(90)).await?;
            } else {
                eprintln!("Using the database from {} (not managed by `memhouse up`).", path_or_default.display());
            }
            if let Some(t) = template {
                let t = templates::find(&t).ok_or_else(|| anyhow::anyhow!("unknown template '{t}'"))?;
                templates::apply(&mut cfg, t);
            }
            let path = cfg.save(Some(&path_or_default))?;
            eprintln!("Loading the embedding model ({}) and preparing the schema ...", cfg.embedding.model);
            let eng = engine(Config::load(Some(&path))?).await?;
            let st = eng.store.stats(&eng.cfg.memory.tenant).await?;
            println!("✓ Postgres ready, schema migrated, {} memories stored", st.committed);
            print_next_steps(&path);
        }
        Cmd::Down => {
            let cfg = Config::load(cfg_path.as_deref())?;
            up::stop(up::managed(&cfg).unwrap_or(up::CONTAINER))?
        }
        Cmd::Init { database_url, template, embedding, model, dim, base_url, api_key_env, request_dimensions, force } => {
            if path_or_default.exists() && !force {
                anyhow::bail!("{} already exists (use --force to overwrite)", path_or_default.display());
            }
            let mut cfg = Config::default();
            cfg.database.url = database_url;
            cfg.server.api_keys = vec![format!("mh_{}", random_token(32))];
            cfg.embedding.provider = embedding.clone();
            if embedding != "local" {
                cfg.embedding.query_prefix = None;
                cfg.embedding.model = model.clone().unwrap_or_else(|| "text-embedding-3-small".into());
                cfg.embedding.dim = dim.unwrap_or(1536);
                cfg.embedding.base_url = base_url;
                cfg.embedding.api_key_env = api_key_env.or_else(|| Some("OPENAI_API_KEY".into()));
                cfg.embedding.request_dimensions = request_dimensions;
            } else if let Some(m) = model {
                let (_, d, _) = memhouse_models::local::resolve_embedding(&m)?;
                cfg.embedding.model = m;
                cfg.embedding.dim = d;
                if !cfg.embedding.model.contains("bge") {
                    cfg.embedding.query_prefix = None;
                }
            }
            if let Some(t) = template {
                let t = templates::find(&t).ok_or_else(|| anyhow::anyhow!("unknown template '{t}'"))?;
                templates::apply(&mut cfg, t);
            }
            let path = cfg.save(Some(&path_or_default))?;
            let eng = engine(Config::load(Some(&path))?).await?;
            let _ = eng.store.stats(&eng.cfg.memory.tenant).await?;
            println!("✓ Connected and migrated");
            print_next_steps(&path);
        }
        Cmd::Serve { bind } => {
            let mut cfg = Config::load(cfg_path.as_deref())?;
            if let Some(b) = bind {
                cfg.server.bind = b;
            }
            let eng = engine(cfg).await?;
            let e2 = eng.clone();
            tokio::spawn(async move {
                loop {
                    if let Err(e) = e2.apply_retention().await {
                        tracing::warn!("retention: {e:#}");
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
                }
            });
            memhouse_server::serve(eng).await?;
        }
        Cmd::Mcp { subject, key, actor: _ } => {
            let mut cfg = Config::load(cfg_path.as_deref())?;
            if let Some(s) = subject {
                cfg.memory.default_subject = s;
            }
            let key =
                key.ok_or_else(|| anyhow::anyhow!("`memhouse mcp` needs the agent's key in MEMHOUSE_MCP_KEY; run `memhouse connect <agent>` to write it into the agent's config"))?;
            let eng = memhouse_server::build_engine(cfg, false).await?;
            let who =
                eng.auth.authenticate(&key, None).await.map_err(|f| anyhow::anyhow!("MEMHOUSE_MCP_KEY was refused: {f}; run `memhouse connect <agent>` again for a new key"))?;
            memhouse_server::mcp::serve_stdio(eng.caller(who)).await?;
        }
        Cmd::Connect { agent, subject, print, project, no_verify } => {
            let cfg = Config::load(cfg_path.as_deref())?;
            if !path_or_default.exists() && !print {
                anyhow::bail!("no config at {}; run `memhouse up` first", path_or_default.display());
            }
            let agents: Vec<String> = if agent == "all" { detected_agents() } else { vec![agent] };
            if agents.is_empty() {
                println!("No supported agents detected. Use e.g. `memhouse connect cursor --print`.");
            }
            // Each agent gets its own propose-only principal and key (GOV-01, GOV-08).
            let eng = engine(cfg.clone()).await?;
            let mut verify_with = None;
            for a in &agents {
                let key = principals::agent_key(&eng, a).await?;
                let mut launch = self_launch(&cfg_path, &subject)?;
                launch.env.push(("MEMHOUSE_MCP_KEY".into(), key.clone()));
                if a != "http" && a != "zed" && a != "goose" {
                    verify_with = Some(self_launch_with_key(&cfg_path, &subject, &key)?);
                }
                connect::connect(&connect::ConnectOpts {
                    agent: a.clone(),
                    launch,
                    print_only: print,
                    project,
                    http_url: format!("http://{}", cfg.server.bind),
                    api_key: Some(key),
                })?;
                println!("  {a} acts as agent:{a} (propose-only; `memhouse principal add agent:{a} --commit` grants direct commits)");
            }
            if let (false, false, Some(launch)) = (print, no_verify, verify_with) {
                match connect::verify(&launch) {
                    Ok(msg) => println!("✓ Verified the MCP server the agent will launch: {msg}"),
                    Err(e) => println!("✗ MCP check failed: {e:#}\n  Run `memhouse doctor` for details."),
                }
            }
        }
        Cmd::Agents => {
            println!("Agents (memhouse connect <name>):");
            for a in connect::AGENTS {
                println!("  {:<15} {}", a.name, a.title);
            }
            println!("\nTemplates (memhouse up --template <name>):");
            for t in templates::TEMPLATES {
                println!("  {:<15} {} — subjects like {}", t.name, t.title, t.subject_hint);
            }
        }
        Cmd::Doctor => doctor(&cfg_path).await?,
        Cmd::Key { cmd: None } => {
            let cfg = Config::load(cfg_path.as_deref())?;
            match cfg.server.api_keys.first() {
                Some(k) => println!("{k}"),
                None => anyhow::bail!("no bootstrap API key configured; run `memhouse up` or `memhouse init`, or create a principal's key with `memhouse key create`"),
            }
        }
        Cmd::Key { cmd: Some(c) } => principals::key(&engine(Config::load(cfg_path.as_deref())?).await?, c).await?,
        Cmd::Principal { cmd } => principals::principal(&engine(Config::load(cfg_path.as_deref())?).await?, cmd).await?,
        Cmd::Policy { tenant, cmd: policy::PolicyCmd::Validate { file } } => policy::validate(&Config::load(cfg_path.as_deref())?, tenant, &file)?,
        Cmd::Policy { tenant, cmd } => policy::run(&engine(Config::load(cfg_path.as_deref())?).await?, tenant, cmd).await?,
        Cmd::Remember { content, subject, kind, tags } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let kind = MemoryKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown kind '{kind}'"))?;
            let r = eng.remember(RememberRequest { subject, content, kind: Some(kind), tags, actor: Some("cli".into()), ..Default::default() }).await?;
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
        Cmd::Recall { query, subject, k, rerank, json } => {
            let mut cfg = Config::load(cfg_path.as_deref())?;
            if rerank {
                cfg.rerank.enabled = true;
            }
            let eng = engine(cfg).await?;
            let r = eng.recall(RecallRequest { subject, query, k: Some(k), actor: Some("cli".into()), ..Default::default() }).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&r)?);
            } else {
                for (i, h) in r.hits.iter().enumerate() {
                    let m = &h.memory;
                    println!("{:>2}. [{:.3}] ({}, {}) {}", i + 1, h.score, m.kind, m.occurred_at.unwrap_or(m.created_at).format("%Y-%m-%d"), m.content.replace('\n', " ⏎ "));
                    println!("    id {}", m.id);
                }
                println!("{} results in {:.1} ms", r.hits.len(), r.took_ms);
            }
        }
        Cmd::List { subject, limit, all } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let subject = subject.or_else(|| Some(eng.cfg.memory.default_subject.clone()));
            for m in eng.list(None, subject, None, limit, 0, all).await? {
                println!("{}  {:<11} {:<10} {}  {}", m.id, m.kind.as_str(), m.status.as_str(), m.created_at.format("%Y-%m-%d"), m.content.replace('\n', " "));
            }
        }
        Cmd::Revise { id, content } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let r = eng.revise(ReviseRequest { id: uuid::Uuid::parse_str(&id)?, content, actor: Some("cli".into()), ..Default::default() }).await?;
            match r.superseded {
                Some(old) => println!("{} now replaces {old}", r.id),
                None => println!("stored {} ({}); {id} was not superseded{}", r.id, r.status.as_str(), r.note.map(|n| format!(": {n}")).unwrap_or_default()),
            }
        }
        Cmd::Forget { id, subject, user, agent, source, dry_run, yes } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let id = id.map(|i| uuid::Uuid::parse_str(&i)).transpose()?;
            let req = ForgetRequest { id, subject, user, agent, source, dry_run, actor: Some("cli".into()), ..Default::default() };
            if id.is_none() && !dry_run && !yes {
                let preview = eng.forget_by(ForgetRequest { dry_run: true, ..req.clone() }).await?;
                eprint!("Permanently delete {} memories ({} {})? [y/N] ", preview.deleted, preview.scope.as_str(), preview.value);
                std::io::stderr().flush()?;
                let mut a = String::new();
                std::io::stdin().lock().read_line(&mut a)?;
                if !a.trim().eq_ignore_ascii_case("y") {
                    return Ok(());
                }
            }
            match eng.forget_by(req).await {
                Ok(r) if r.dry_run => println!("would delete {} memories ({} {})", r.deleted, r.scope.as_str(), r.value),
                Ok(r) => println!("deleted {} memories ({} {})", r.deleted, r.scope.as_str(), r.value),
                Err(e) if memhouse_core::error::code_of(&e) == memhouse_core::error::ErrorCode::NotFound => println!("not found"),
                Err(e) => return Err(e),
            }
        }
        Cmd::Openapi => println!("{}", serde_json::to_string_pretty(&memhouse_server::openapi::spec())?),
        Cmd::Ingest { file, subject, session } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let messages: Vec<Message> = serde_json::from_str(&std::fs::read_to_string(&file)?)?;
            let r = eng.ingest(IngestRequest { subject, session_id: session, messages, actor: Some("cli".into()), ..Default::default() }).await?;
            println!("stored {} rounds ({} quarantined, {} already present)", r.stored, r.quarantined, r.deduplicated);
        }
        Cmd::Export { subject, out, tenant } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let tenant = tenant.unwrap_or_else(|| eng.cfg.memory.tenant.clone());
            let mut w: Box<dyn Write> = match out {
                Some(p) => Box::new(std::io::BufWriter::new(std::fs::File::create(p)?)),
                None => Box::new(std::io::BufWriter::new(std::io::stdout())),
            };
            let r = memhouse_core::format::export(&eng, &mut *w, &tenant, subject.as_deref()).await?;
            w.flush()?;
            eprintln!("exported {} records, {} links and {} policies (Memory Format v{})", r.records, r.links, r.policies, memhouse_core::format::VERSION);
        }
        Cmd::Import { file } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let f = std::io::BufReader::new(std::fs::File::open(&file).with_context(|| format!("opening {}", file.display()))?);
            let r = memhouse_core::format::import(&eng, f, "cli").await?;
            println!("imported {} records ({} already present), {} links and {} policies from a v{} file", r.records, r.skipped, r.links, r.policies, r.version);
            if r.second_vectors_dropped > 0 {
                println!("  {} rounds kept only their main vector (their user-only text could not be recovered exactly)", r.second_vectors_dropped);
            }
        }
        Cmd::Reembed { dry_run, abort, batch, yes } => {
            use memhouse_core::reembed;
            let cfg = Config::load(cfg_path.as_deref())?;
            if abort {
                let store = memhouse_store_postgres::PgStore::connect(&cfg.database.url, 2, "").await?;
                let had = memhouse_core::Store::reembed_abort(&store).await?;
                println!("{}", if had { "✓ unfinished re-embedding dropped; the current vectors are unchanged" } else { "nothing to abort" });
                return Ok(());
            }
            let eng = memhouse_server::build_reembed_engine(cfg, true).await?;
            let to = reembed::target(&eng);
            let (from, unfinished) = eng.store.embedding_identity().await?;
            let from = from.ok_or_else(|| anyhow::anyhow!("this database has no memories yet (run `memhouse init` first)"))?;
            if from == to && unfinished.is_none() {
                println!("✓ every memory is already embedded with {to}");
                return Ok(());
            }
            let est = eng.store.reembed_estimate().await?;
            println!("from:    {from}");
            println!("to:      {to}");
            println!("records: {} ({} with a second vector), {} characters ≈ {} tokens to embed", est.records, est.second_vectors, est.characters, est.characters / 4);
            if est.done > 0 {
                println!("resumes: {} already done by an earlier run", est.done);
            }
            if let Some(u) = unfinished.as_ref().filter(|u| **u != to) {
                anyhow::bail!("an unfinished re-embedding to {u} exists; finish it with that configuration, or run `memhouse reembed --abort`");
            }
            if dry_run {
                return Ok(());
            }
            if !yes {
                eprint!("Re-embed {} memories? The old vectors are replaced at the end. [y/N] ", est.records);
                std::io::stderr().flush()?;
                let mut a = String::new();
                std::io::stdin().lock().read_line(&mut a)?;
                if !a.trim().eq_ignore_ascii_case("y") {
                    return Ok(());
                }
            }
            let started = std::time::Instant::now();
            let outcome = reembed::run(&eng, "cli", batch, |done, total| {
                let rate = done as f64 / started.elapsed().as_secs_f64().max(0.001);
                eprint!("\r  {done}/{total} records ({rate:.0}/s)   ");
            })
            .await?;
            eprintln!();
            match outcome {
                reembed::Outcome::Current(id) => println!("✓ every memory is already embedded with {id}"),
                reembed::Outcome::Done(r) => {
                    println!("✓ {} records re-embedded with {} in {:.1}s ({} passes)", r.records, r.to, r.seconds, r.passes);
                    if r.second_vectors_dropped > 0 {
                        println!("  {} rounds kept only their main vector (their user-only text could not be recovered exactly)", r.second_vectors_dropped);
                    }
                    println!("  Restart `memhouse serve` and MCP clients so they use the new model; processes on the old one now refuse to read or write.");
                }
            }
        }
        Cmd::Audit { verify, limit } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            if verify {
                let (n, broken) = eng.store.audit_verify().await?;
                match broken {
                    None => println!("✓ audit chain intact ({n} events)"),
                    Some(id) => anyhow::bail!("audit chain broken at event {id} (checked {n})"),
                }
            } else {
                for e in eng.store.audit_log(&eng.cfg.memory.tenant, limit).await? {
                    println!("{} {:<6} {:<18} {:<14} {:<20} {}", e.at.format("%Y-%m-%d %H:%M:%S"), e.id, e.action, e.actor, e.subject.unwrap_or_default(), e.detail);
                }
            }
        }
        Cmd::Stats => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            println!("{}", serde_json::to_string_pretty(&eng.store.stats(&eng.cfg.memory.tenant).await?)?);
        }
        Cmd::Retention => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            println!("purged {} records", eng.apply_retention().await?);
        }
        Cmd::Bench { cmd } => {
            let cfg = Config::load(cfg_path.as_deref())?;
            memhouse_bench::main(cmd, cfg).await?;
        }
    }
    Ok(())
}

fn detected_agents() -> Vec<String> {
    let home = memhouse_core::config::user_home().unwrap_or_default();
    let mut v = vec![];
    if connect::which("claude").is_some() {
        v.push("claude-code".into());
    }
    let desktop =
        if cfg!(target_os = "macos") { home.join("Library/Application Support/Claude") } else { memhouse_core::config::user_config_dir().unwrap_or_default().join("Claude") };
    if desktop.exists() {
        v.push("claude-desktop".into());
    }
    if home.join(".cursor").exists() {
        v.push("cursor".into());
    }
    if home.join(".codeium/windsurf").exists() {
        v.push("windsurf".into());
    }
    if home.join(".codex").exists() || connect::which("codex").is_some() {
        v.push("codex".into());
    }
    if home.join(".gemini").exists() || connect::which("gemini").is_some() {
        v.push("gemini".into());
    }
    v
}

async fn doctor(cfg_path: &Option<PathBuf>) -> anyhow::Result<()> {
    let path = cfg_path.clone().unwrap_or_else(default_config_path);
    let ok = |s: &str| println!("✓ {s}");
    let bad = |s: &str| println!("✗ {s}");
    if path.exists() {
        ok(&format!("config {}", path.display()));
    } else {
        bad(&format!("no config at {} — run `memhouse up`", path.display()));
        return Ok(());
    }
    let cfg = Config::load(Some(&path))?;
    if let Some(name) = up::managed(&cfg) {
        match up::container_state(name) {
            Some(s) if s == "running" => ok(&format!("container {name} running")),
            Some(s) => bad(&format!("container {name} is {s} — run `memhouse up`")),
            None => bad(&format!("container {name} missing — run `memhouse up`")),
        }
    }
    let t = std::time::Instant::now();
    match memhouse_server::build_engine(cfg.clone(), true).await {
        Ok(eng) => {
            ok(&format!("database {} reachable, schema ready ({:.1}s incl. model load)", memhouse_store_postgres::redact_url(&cfg.database.url), t.elapsed().as_secs_f32()));
            ok(&format!("embedder {} ({} dims)", eng.embedder.id(), eng.embedder.dim()));
            if let Some(r) = &eng.reranker {
                ok(&format!("reranker {}", r.id()));
            }
            let st = eng.store.stats(&cfg.memory.tenant).await?;
            ok(&format!("{} memories, {} subjects, {} audit events", st.committed, st.subjects, st.audit_events));
            match eng.store.audit_verify().await? {
                (n, None) => ok(&format!("audit chain intact ({n} events)")),
                (_, Some(id)) => bad(&format!("audit chain broken at event {id}")),
            }
        }
        Err(e) => {
            bad(&format!("engine: {e:#}"));
            return Ok(());
        }
    }
    // The round trip authenticates like an agent would, with the bootstrap key.
    match cfg.server.api_keys.first() {
        Some(k) => match connect::verify(&self_launch_with_key(cfg_path, &None, k)?) {
            Ok(m) => ok(&format!("MCP stdio round-trip: {m}")),
            Err(e) => bad(&format!("MCP stdio round-trip: {e:#}")),
        },
        None => bad("MCP stdio round-trip skipped: no bootstrap key to authenticate with"),
    }
    if cfg.server.api_keys.is_empty() {
        bad("no API key for the HTTP server (run `memhouse init --force` or set MEMHOUSE_API_KEY)");
    } else {
        ok("API key configured (`memhouse key`)");
    }
    Ok(())
}
