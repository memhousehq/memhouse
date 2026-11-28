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

mod backup;
mod connect;
mod eval;
mod governance;
mod hook;
mod lang;
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
        /// The Lite profile: one SQLite file under MEMHOUSE_HOME, no Docker and no database server
        #[arg(long)]
        lite: bool,
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
    /// Run the HTTP server: REST API, MCP over HTTP at /mcp, the admin console at /
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
        /// Also install the file hooks (claude-code, gemini): memories linked to a file are
        /// shown to the agent when it reads or edits the file
        #[arg(long)]
        hooks: bool,
    },
    /// Harness and git hooks of the coding template: file-opened, file-edited, post-commit
    Hook {
        #[command(subcommand)]
        cmd: hook::HookCmd,
    },
    /// List supported agents and templates
    Agents,
    /// Check configuration, database, model and MCP round-trip
    Doctor,
    /// Ask a running server for /health; exits 0 when it answers (the container image's health check: it has no shell and no curl)
    Health {
        /// The server's base URL (default: `[server] bind` on this host)
        #[arg(long)]
        url: Option<String>,
    },
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
    /// Evaluation suites: add, list, replay, and the regression gate
    Eval {
        /// Tenant (default: the configured one)
        #[arg(long, global = true)]
        tenant: Option<String>,
        #[command(subcommand)]
        cmd: eval::EvalCmd,
    },
    /// Language packs: list them, check a pack file against its test set, detect a text's language
    Lang {
        #[command(subcommand)]
        cmd: lang::LangCmd,
    },
    /// Behaviour policy: validate, diff, propose, approve and roll back specs
    Policy {
        /// Tenant (default: the configured one)
        #[arg(long, global = true)]
        tenant: Option<String>,
        #[command(subcommand)]
        cmd: policy::PolicyCmd,
    },
    /// Share one agent's agent-scoped memory with another: add, list and revoke grants
    Grant {
        #[command(subcommand)]
        cmd: principals::GrantCmd,
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
        /// The session the memory belongs to (working memory is visible only inside it)
        #[arg(long)]
        session: Option<String>,
        /// A file of a git repository the memory is about (repeatable): the memory is linked to
        /// it at its current content, and without --subject is stored for repo:<name>
        #[arg(long = "file")]
        files: Vec<PathBuf>,
    },
    /// Promote memories to another type (working to semantic, episodic to procedural, ...)
    Promote {
        /// Ids of the memories to promote
        #[arg(required = true)]
        ids: Vec<String>,
        /// The type of the new memory: semantic, preference, procedural, taxonomic or episodic
        #[arg(long, short)]
        kind: String,
        /// Its text (required for several sources; default: the source's text)
        #[arg(long, short)]
        content: Option<String>,
        /// Why, for the audit log
        #[arg(long)]
        reason: Option<String>,
    },
    /// Search memory
    Recall {
        query: String,
        #[arg(long, short)]
        subject: Option<String>,
        /// Recall inside this session: its working memory comes first
        #[arg(long)]
        session: Option<String>,
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
    Revise {
        id: String,
        content: String,
        /// Print the result as JSON
        #[arg(long)]
        json: bool,
    },
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
        /// Candidates held because their source is not trusted: of this source, or of every untrusted source with '*'
        #[arg(long)]
        untrusted: Option<String>,
        /// Count what would be deleted, delete nothing
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        yes: bool,
        /// Print the result as JSON
        #[arg(long)]
        json: bool,
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
        /// Print the result as JSON
        #[arg(long)]
        json: bool,
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
    /// Back up a Lite installation: a consistent snapshot of the database, the canonical export and the deletion ledger.
    /// On Postgres (backed up with its own tools), `--ledger-only` writes the deletion ledger to keep beside the backups
    Backup {
        /// Directory to write the backup into (new or empty; created for this user alone)
        dir: PathBuf,
        /// Write only the deletion ledger (deletion-ledger.jsonl), for a later `restore --ledger`
        #[arg(long)]
        ledger_only: bool,
    },
    /// Restore a Lite backup, re-applying every deletion made since it was taken. On Postgres: re-apply
    /// a deletion ledger to a database restored with pg_restore, before it serves
    Restore {
        /// Directory written by `memhouse backup` (Lite)
        dir: Option<PathBuf>,
        /// State that nothing was deleted since the backup was taken: no ledger is re-applied, and the
        /// database is recorded as fit to serve (audited)
        #[arg(long)]
        no_ledger: bool,
        /// Replace the existing database (its deletion ledger is carried over)
        #[arg(long)]
        force: bool,
        /// A deletion ledger to re-apply as well (from `memhouse backup --ledger-only`, or a later backup's deletion-ledger.jsonl).
        /// Needed when there is no current database to take the ledger from (another machine, a lost file):
        /// without it, records deleted after the backup was taken come back
        #[arg(long)]
        ledger: Option<PathBuf>,
    },
    /// Move the installation to another database: Lite to Standard (or back), verified record by record, then the configuration is switched over
    Migrate {
        /// The database to move from: sqlite:<path> or postgres://… (default: the configured database)
        #[arg(long, env = "MEMHOUSE_MIGRATE_FROM", hide_env_values = true)]
        from: Option<String>,
        /// The database to move to: sqlite:<path> or postgres://…; it must be empty
        #[arg(long, env = "MEMHOUSE_MIGRATE_TO", hide_env_values = true)]
        to: String,
        /// Report counts, size, the estimated duration and what needs attention; change nothing
        #[arg(long)]
        dry_run: bool,
        /// Migrate without asking first
        #[arg(long)]
        yes: bool,
    },
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
    /// Audit log: show recent events, verify the hash chain, or anchor its head (`memhouse audit anchor`)
    Audit {
        #[command(subcommand)]
        cmd: Option<governance::AuditCmd>,
        #[arg(long)]
        verify: bool,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Legal holds: exempt a subject, user, source or scope from retention and deletion
    Hold {
        #[command(subcommand)]
        cmd: governance::HoldCmd,
    },
    /// Deletion requests and their completion certificates
    Deletion {
        #[command(subcommand)]
        cmd: governance::DeletionCmd,
    },
    /// Compliance evidence, mapped to SOC 2 and ISO 27001 controls
    Evidence {
        #[command(subcommand)]
        cmd: governance::EvidenceCmd,
    },
    /// Show counts
    Stats,
    /// Apply retention rules now, and carry out deletions whose legal hold was released
    Retention {
        /// Print the result as JSON
        #[arg(long)]
        json: bool,
    },
    /// Benchmark and validate memory quality, safety and latency
    Bench {
        #[command(subcommand)]
        cmd: memhouse_bench::BenchCmd,
    },
}

/// `memhouse connect <agent> --hooks`: the harness's hook configuration for file-opened and
/// file-edited (TR-TPL-03), merged into its settings file, and the key file the hooks read.
fn install_file_hooks(cfg_path: &Option<PathBuf>, agent: &str, key: &str, subject: Option<&str>, project: bool, print: bool) -> anyhow::Result<()> {
    let home = memhouse_core::config::user_home().unwrap_or_else(|| PathBuf::from("."));
    // A project file that is committed must not carry this machine's paths: Claude Code has a
    // local one beside it; Gemini CLI has only the project's settings file.
    let (file, format) = match agent {
        "claude-code" => (if project { PathBuf::from(".claude/settings.local.json") } else { home.join(".claude/settings.json") }, "claude-code"),
        "gemini" => (if project { PathBuf::from(".gemini/settings.json") } else { home.join(".gemini/settings.json") }, "gemini"),
        other => {
            println!(
                "  {other}: no hook installer (file hooks are installed for claude-code and gemini; any harness can run `memhouse hook file-opened --path <file> --format text`)"
            );
            return Ok(());
        }
    };
    let key_file = if print { hook::key_file_of(cfg_path, agent) } else { hook::write_key_file(cfg_path, agent, key)? };
    let line = |which: &str| hook::command_line(cfg_path, which, Some(format), &key_file, subject);
    let (opened, edited) = (line("file-opened")?, line("file-edited")?);
    let entries = if agent == "gemini" { hook::gemini_entries(&opened, &edited) } else { hook::claude_code_entries(&opened, &edited) };
    if hook::install_hooks(&file, &entries, print)? {
        println!("✓ {agent}: file hooks written to {} (key file {})", file.display(), key_file.display());
        println!("  for commits too: memhouse hook install-git --agent {agent}");
    }
    Ok(())
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

/// Where a server bound to `bind` is reached from its own host: a wildcard address is not one
/// to connect to, so it is read as the loopback address of its family.
fn health_url(bind: &str) -> String {
    let (host, port) = bind.rsplit_once(':').unwrap_or((bind, "7077"));
    let host = match host {
        "0.0.0.0" | "" => "127.0.0.1",
        "[::]" => "[::1]",
        h => h,
    };
    format!("http://{host}:{port}")
}

fn print_next_steps(path: &std::path::Path) {
    println!("\nMemHouse is ready. Config: {}\n", path.display());
    println!("Connect an agent (writes its MCP config and checks a recall):");
    println!("  memhouse connect claude-code      # or: cursor, claude-desktop, vscode, windsurf, codex, gemini, all");
    println!("Try it from the terminal:");
    println!("  memhouse remember \"Alice prefers email over phone\" --subject user:alice");
    println!("  memhouse recall \"how should I contact Alice?\" --subject user:alice");
    println!("Run the HTTP API and the admin console:");
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
        Cmd::Up { port, name, template, lite } => {
            // What the file says, without the environment's overrides: this command saves the
            // configuration again, and a key or database URL given in the environment for one
            // run must not end up in the file.
            let mut cfg = if path_or_default.exists() { Config::load_file(Some(&path_or_default))? } else { Config::default() };
            let fresh = !path_or_default.exists();
            // Whether this installation is Lite is what its file says: a URL the environment
            // gives for one run does not change the profile.
            let is_lite = memhouse_server::sqlite_path(&cfg.database.url).is_some();
            anyhow::ensure!(
                !lite || fresh || is_lite,
                "{} already configures a Postgres database; `memhouse up --lite` only sets up a new installation",
                path_or_default.display()
            );
            // Lite: the database is one file beside the configuration.
            let db = memhouse_core::config::home_dir().join("memhouse.db");
            if lite && fresh {
                memhouse_server::lite_defaults(&mut cfg, &db);
            }
            // A database URL in the environment that names the other profile, or another file
            // than a Lite installation's, would send the schema preparation below to a database
            // the saved configuration does not name: refused before anything is started,
            // written or opened.
            if let Some(conflict) = up::env_conflict(&cfg.database.url, Config::env_database_url().as_deref()) {
                anyhow::bail!(conflict);
            }
            if lite && fresh {
                if db.exists() {
                    eprintln!("Using the database that is already at {} (its memories are kept; this configuration gets a new API key).", db.display());
                }
                cfg.server.api_keys = vec![format!("mh_{}", random_token(32))];
            } else if is_lite {
                eprintln!("Using the SQLite database from {}.", path_or_default.display());
            } else if fresh || up::managed(&cfg).is_some() {
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
            let which = if memhouse_server::sqlite_path(&eng.cfg.database.url).is_some() { "SQLite file" } else { "Postgres" };
            println!("✓ {which} ready, schema migrated, {} memories stored", st.committed);
            print_next_steps(&path);
        }
        Cmd::Down => {
            let cfg = Config::load(cfg_path.as_deref())?;
            if memhouse_server::sqlite_path(&cfg.database.url).is_some() {
                println!("The Lite profile runs no database server: there is nothing to stop.");
                return Ok(());
            }
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
            // `serve` also runs the workers and the hourly retention pass.
            memhouse_server::serve(engine(cfg).await?).await?;
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
            // One pipeline worker: picks up writes another agent's process left behind.
            let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let workers = eng.spawn_intake(1, stop.clone());
            memhouse_server::mcp::serve_stdio(eng.caller(who)).await?;
            // Give this process's last writes a moment to finish their pipeline before exiting.
            // Bounded as a whole: a job waiting on a model call doesn't hold the exit.
            let two = std::time::Duration::from_secs(2);
            let _ = tokio::time::timeout(two, eng.settle_subject(None, &eng.cfg.memory.default_subject.clone(), two)).await;
            stop.store(true, std::sync::atomic::Ordering::Relaxed);
            drop(workers);
        }
        Cmd::Hook { cmd } => hook::run(&cfg_path, cmd).await?,
        Cmd::Connect { agent, subject, print, project, no_verify, hooks } => {
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
                    api_key: Some(key.clone()),
                })?;
                if hooks {
                    install_file_hooks(&cfg_path, a, &key, subject.as_deref(), project, print)?;
                }
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
        Cmd::Health { url } => {
            let base = match url {
                Some(u) => u,
                None => health_url(&Config::load(cfg_path.as_deref())?.server.bind),
            };
            let url = format!("{}/health", base.trim_end_matches('/'));
            let http = reqwest::Client::builder().timeout(std::time::Duration::from_secs(3)).build()?;
            let resp = http.get(&url).send().await.with_context(|| format!("no answer from {url}"))?;
            anyhow::ensure!(resp.status().is_success(), "{url} answered {}", resp.status());
            println!("{}", resp.text().await?);
        }
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
        Cmd::Lang { cmd } => lang::run(cfg_path.as_deref(), cmd)?,
        Cmd::Eval { tenant, cmd } => eval::run(&engine(Config::load(cfg_path.as_deref())?).await?, tenant, cmd).await?,
        Cmd::Policy { tenant, cmd } => policy::run(&engine(Config::load(cfg_path.as_deref())?).await?, tenant, cmd).await?,
        Cmd::Grant { cmd } => principals::grant(&engine(Config::load(cfg_path.as_deref())?).await?, cmd).await?,
        Cmd::Remember { content, subject, kind, tags, session, files } => {
            let kind = MemoryKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown kind '{kind}'"))?;
            // The files as a file hook would report them: path in the repository and git blob hash.
            let linked = if files.is_empty() {
                None
            } else {
                let opts = memhouse_server::hook::HookOpts { subject: subject.clone(), paths: files.clone(), ..Default::default() };
                let found = memhouse_server::hook::touched(memhouse_server::hook::HookEvent::FileOpened, None, &opts)
                    .await?
                    .filter(|t| t.paths.len() == files.len() && t.request.files.iter().all(|f| f.blob_hash.is_some()))
                    .ok_or_else(|| anyhow::anyhow!("--file: every file must exist, be readable and be inside one git repository"))?;
                Some(found)
            };
            let subject = subject.or_else(|| linked.as_ref().map(|t| t.subject.clone()));
            let code_refs = linked.iter().flat_map(|t| &t.request.files).map(|f| CodeRef::new(f.path.clone(), f.blob_hash.clone().unwrap_or_default())).collect();
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let scope = session.map(|s| Scope { session: Some(s), ..Default::default() });
            let r =
                eng.remember(RememberRequest { subject, content, kind: Some(kind), tags, scope, code_refs, actor: Some("cli".into()), wait: true, ..Default::default() }).await?;
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
        Cmd::Promote { ids, kind, content, reason } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let kind = MemoryKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown kind '{kind}'"))?;
            let sources = ids.iter().map(|i| uuid::Uuid::parse_str(i)).collect::<Result<Vec<_>, _>>()?;
            let r = eng.promote(PromoteRequest { sources, kind, content, reason, actor: Some("cli".into()), wait: true, ..Default::default() }).await?;
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
        Cmd::Recall { query, subject, session, k, rerank, json } => {
            let mut cfg = Config::load(cfg_path.as_deref())?;
            if rerank {
                cfg.rerank.enabled = true;
            }
            let eng = engine(cfg).await?;
            let scope = session.map(|s| Scope { session: Some(s), ..Default::default() });
            let r = eng.recall(RecallRequest { subject, query, k: Some(k), scope, actor: Some("cli".into()), ..Default::default() }).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&r)?);
            } else {
                for (i, h) in r.hits.iter().enumerate() {
                    let m = &h.memory;
                    let score = if h.working { "session".to_string() } else { format!("{:.3}", h.score) };
                    println!("{:>2}. [{score}] ({}, {}) {}", i + 1, m.kind, m.occurred_at.unwrap_or(m.created_at).format("%Y-%m-%d"), m.content.replace('\n', " ⏎ "));
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
        Cmd::Revise { id, content, json } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let r = eng.revise(ReviseRequest { id: uuid::Uuid::parse_str(&id)?, content, actor: Some("cli".into()), wait: true, ..Default::default() }).await?;
            match r.superseded {
                _ if json => println!("{}", serde_json::to_string_pretty(&r)?),
                Some(old) => println!("{} now replaces {old}", r.id),
                None => println!("stored {} ({}); {id} was not superseded{}", r.id, r.status.as_str(), r.note.map(|n| format!(": {n}")).unwrap_or_default()),
            }
        }
        Cmd::Forget { id, subject, user, agent, source, untrusted, dry_run, yes, json } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let id = id.map(|i| uuid::Uuid::parse_str(&i)).transpose()?;
            let req = ForgetRequest { id, subject, user, agent, source, untrusted, dry_run, actor: Some("cli".into()), ..Default::default() };
            if id.is_none() && !dry_run && !yes {
                let preview = eng.forget_by(ForgetRequest { dry_run: true, ..req.clone() }).await?;
                if preview.held > 0 {
                    eprintln!("{} of them are under a legal hold: they stay until the hold is released.", preview.held);
                }
                eprint!("Permanently delete {} memories ({} {})? [y/N] ", preview.deleted, preview.scope.as_str(), preview.value);
                std::io::stderr().flush()?;
                let mut a = String::new();
                std::io::stdin().lock().read_line(&mut a)?;
                if !a.trim().eq_ignore_ascii_case("y") {
                    return Ok(());
                }
            }
            match eng.forget_by(req).await {
                Ok(r) if json => println!("{}", serde_json::to_string_pretty(&r)?),
                Ok(r) if r.dry_run => {
                    println!(
                        "would delete {} memories ({} {}){}",
                        r.deleted,
                        r.scope.as_str(),
                        r.value,
                        if r.held > 0 { format!("; {} of them are under a legal hold and would stay", r.held) } else { String::new() }
                    )
                }
                Ok(r) => {
                    println!("deleted {} memories ({} {})", r.deleted, r.scope.as_str(), r.value);
                    // The certificate exists once the request is completed: one that is
                    // still open (something of its sample is still found) says so instead.
                    let completed = match r.deletion_id {
                        Some(d) => eng.deletion(&eng.cfg.memory.tenant, d).await.map(|x| x.status == memhouse_core::governance::DeletionStatus::Completed).unwrap_or(false),
                        None => false,
                    };
                    match (r.held, r.deletion_id) {
                        (0, Some(d)) if completed => println!("  certificate: memhouse deletion certificate {d}"),
                        (0, Some(d)) => println!(
                            "  deletion {d} is not complete yet: a trace of it is still found. `memhouse retention` checks again and completes it (`memhouse deletion list`)"
                        ),
                        (held, Some(d)) => println!("  {held} records are under a legal hold: deletion {d} completes when the hold is released"),
                        _ => {}
                    }
                }
                // With --json a missing record is an error (a non-zero exit), not a line of text.
                Err(e) if !json && memhouse_core::error::code_of(&e) == memhouse_core::error::ErrorCode::NotFound => println!("not found"),
                Err(e) => return Err(e),
            }
        }
        Cmd::Openapi => println!("{}", serde_json::to_string_pretty(&memhouse_server::openapi::spec())?),
        Cmd::Ingest { file, subject, session, json } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let messages: Vec<Message> = serde_json::from_str(&std::fs::read_to_string(&file)?)?;
            let r = eng.ingest(IngestRequest { subject, session_id: session, messages, actor: Some("cli".into()), wait: true, ..Default::default() }).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&r)?);
            } else {
                println!("stored {} rounds ({} quarantined, {} already present)", r.stored, r.quarantined, r.deduplicated);
            }
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
        Cmd::Backup { dir, ledger_only } => {
            let cfg = Config::load(cfg_path.as_deref())?;
            // Postgres is backed up with its own tools; its deletion ledger is written here, to
            // be re-applied after a restore (TR-WF-03).
            if ledger_only && memhouse_server::sqlite_path(&cfg.database.url).is_none() {
                governance::ledger_only(&cfg, &dir).await?
            } else {
                backup::backup(cfg, &dir, ledger_only).await?
            }
        }
        Cmd::Restore { dir, no_ledger, force, ledger } => {
            let cfg = Config::load(cfg_path.as_deref())?;
            if memhouse_server::sqlite_path(&cfg.database.url).is_none() {
                anyhow::ensure!(dir.is_none() && !force, "on Postgres, restore the database with pg_restore first; then `memhouse restore --ledger <file>` (or `--no-ledger`) re-applies the deletions made since the backup");
                governance::restore_postgres(&cfg, ledger.as_deref(), no_ledger).await?
            } else {
                match dir {
                    Some(dir) => {
                        anyhow::ensure!(
                            !no_ledger,
                            "`--no-ledger` is for a database put in place without `memhouse restore <backup>`; give either the backup's directory or `--no-ledger`"
                        );
                        backup::restore(cfg.clone(), &dir, force, ledger.as_deref()).await?;
                    }
                    None if ledger.is_some() => anyhow::bail!(
                        "`--ledger` re-applies a ledger to a backup being restored: give the backup's directory with it. `--no-ledger` alone records a database file put in place by hand; the two do not go together"
                    ),
                    None if force => anyhow::bail!("`--force` replaces an existing database with a backup: give the backup's directory with it"),
                    None => anyhow::ensure!(
                        no_ledger,
                        "name the directory written by `memhouse backup`; or `--no-ledger` to record a database file put in place by hand as fit to serve"
                    ),
                }
                // What `memhouse serve` compares the database with at its next start.
                governance::record_lite(&cfg, no_ledger).await?;
            }
        }
        Cmd::Migrate { from, to, dry_run, yes } => {
            use memhouse_server::migrate;
            let cfg = Config::load(cfg_path.as_deref())?;
            let req = migrate::Request {
                from: migrate::endpoint(from.as_deref().unwrap_or(&cfg.database.url))?,
                to: migrate::endpoint(&to)?,
                cfg,
                config_path: Some(path_or_default.clone()),
                progress: Some(std::sync::Arc::new(|m: &str| eprintln!("  {m}"))),
            };
            let plan = migrate::plan(&req).await?;
            println!("{}", migrate::describe_plan(&req, &plan).trim_end());
            // Not a success either way: a script that runs the dry run first stops here.
            anyhow::ensure!(!plan.blocked(), "the migration cannot run yet: see \"Needs attention\" above. Nothing was changed");
            if dry_run {
                return Ok(());
            }
            if !yes {
                eprint!("\nMigrate {} records to {}? The source is only read. [y/N] ", plan.source.record_total(), req.to.label);
                std::io::stderr().flush()?;
                let mut answer = String::new();
                std::io::stdin().lock().read_line(&mut answer)?;
                anyhow::ensure!(matches!(answer.trim(), "y" | "Y" | "yes"), "not migrated");
            }
            let (report, switch) = migrate::run(&req).await.map_err(|e| {
                e.context("the migration stopped before the switch-over: the configuration and the source are as they were. Run it again to resume, or start over with a new, empty target")
            })?;
            println!("\n{}", migrate::describe_report(&req, &report, &switch).trim_end());
        }
        Cmd::Reembed { dry_run, abort, batch, yes } => {
            use memhouse_core::reembed;
            let cfg = Config::load(cfg_path.as_deref())?;
            if abort {
                let store = memhouse_server::open_store(&cfg, 2).await?;
                let had = store.reembed_abort().await?;
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
        Cmd::Audit { cmd: Some(cmd), .. } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            governance::audit(&eng, cmd).await?;
        }
        Cmd::Hold { cmd } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            governance::hold(&eng, cmd).await?;
        }
        Cmd::Deletion { cmd } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            governance::deletion(&eng, cmd).await?;
        }
        Cmd::Evidence { cmd } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            governance::evidence(&eng, cmd).await?;
        }
        Cmd::Audit { cmd: None, verify, limit } => {
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
        Cmd::Retention { json } => {
            let eng = engine(Config::load(cfg_path.as_deref())?).await?;
            let r = eng.retention_run(Default::default()).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&r)?);
            } else {
                if r.busy {
                    println!("another retention pass of this tenant is running: nothing was done");
                    return Ok(());
                }
                // Two things, two lines: a record past its expiry is marked expired (and no
                // longer recalled); a purged record is removed.
                println!("purged {} records", r.purged);
                if r.expired > 0 {
                    println!("  {} records past their expiry marked expired", r.expired);
                }
                if !r.complete {
                    println!("  the pass was stopped before it finished; the next one continues it");
                }
                if r.resumed {
                    println!("  continued a pass that an earlier run left unfinished");
                }
                if r.partitions_dropped > 0 {
                    println!("  {} monthly partitions dropped whole", r.partitions_dropped);
                }
                if r.held > 0 {
                    println!("  {} records are past their retention and kept by a legal hold", r.held);
                }
                if r.deletions_completed > 0 {
                    println!("  {} pending deletions completed", r.deletions_completed);
                }
                if r.deletions_failed > 0 {
                    println!("  ! {} pending deletions could not be carried out (see the log); they stay open and are tried again", r.deletions_failed);
                }
            }
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
            // The files were checked against their pin when the models loaded just now (threat T19).
            let pins = [(eng.embedder.id(), &cfg.embedding.revision, &cfg.embedding.sha256)]
                .into_iter()
                .chain(eng.reranker.as_ref().map(|r| (r.id(), &cfg.rerank.revision, &cfg.rerank.sha256)));
            for (id, revision, sha256) in pins {
                match memhouse_models::pin_status(id, revision, sha256) {
                    Some(Ok(pinned)) => ok(&format!("model files verified: {pinned}")),
                    Some(Err(unpinned)) => bad(&format!("model {unpinned}")),
                    None => {}
                }
            }
            let packs: Vec<String> = eng.languages.packs().iter().map(|p| format!("{} ({})", p.code(), p.source)).collect();
            ok(&format!("languages {}; default {}", packs.join(", "), eng.languages.default_pack().code()));
            if let Some(w) = memhouse_core::lang::embedder_warning(&eng.languages.codes(), &cfg.embedding.model) {
                bad(&w);
            }
            let st = eng.store.stats(&cfg.memory.tenant).await?;
            ok(&format!("{} memories, {} subjects, {} audit events", st.committed, st.subjects, st.audit_events));
            match eng.store.audit_verify().await? {
                (n, None) => ok(&format!("audit chain intact ({n} events)")),
                (_, Some(id)) => bad(&format!("audit chain broken at event {id}")),
            }
            // The profile advisor (PROF-11): the same report as `GET /v1/advisor`.
            match eng.advisor(&cfg.memory.tenant).await {
                Ok(a) if a.status == "ok" => ok(&format!("profile {} {}", a.profile, a.line())),
                Ok(a) => bad(&format!("profile {} {}", a.profile, a.line())),
                Err(e) => bad(&format!("profile advisor: {e:#}")),
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

#[cfg(test)]
mod tests {
    use super::health_url;

    /// The container sets `MEMHOUSE_BIND=0.0.0.0:7077`; its health check must reach the server.
    #[test]
    fn a_wildcard_bind_is_checked_on_loopback() {
        assert_eq!(health_url("0.0.0.0:7077"), "http://127.0.0.1:7077");
        assert_eq!(health_url("[::]:8080"), "http://[::1]:8080");
        assert_eq!(health_url("127.0.0.1:7077"), "http://127.0.0.1:7077");
        assert_eq!(health_url("memhouse.internal:9000"), "http://memhouse.internal:9000");
    }
}
