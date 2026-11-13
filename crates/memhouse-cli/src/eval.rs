// SPDX-License-Identifier: Apache-2.0
//! `memhouse eval …`: a tenant's evaluation suites (G13, QUAL-04 and QUAL-05). Suites stored
//! here are replayed before a policy is approved, and on demand; every replay is kept with the
//! policy version it ran under. The CLI holds the database credentials, so it acts as the
//! operator; adding and removing a suite is audited.

use clap::Subcommand;
use memhouse_core::eval::{EvalRun, EvalTrigger};
use memhouse_core::Engine;
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum EvalCmd {
    /// Store a suite file (YAML or JSON) for the tenant, replacing one of the same name
    Add {
        file: PathBuf,
        /// Who adds it (default: cli:$USER)
        #[arg(long)]
        by: Option<String>,
    },
    /// The tenant's suites
    List,
    /// Remove a suite; its stored runs stay
    Remove {
        name: String,
        #[arg(long)]
        by: Option<String>,
    },
    /// Replay the tenant's suites (or one) under the running policy and store the results
    Run {
        /// Only this suite
        #[arg(long)]
        suite: Option<String>,
    },
    /// Stored replays, newest first, with the policy version each ran under
    Runs {
        #[arg(long)]
        suite: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        /// Print the runs as JSON
        #[arg(long)]
        json: bool,
    },
    /// The regression gate for an engine or model change: replay every suite and compare with
    /// its last stored replay; exits with status 1 if quality fell past the limits
    Gate,
}

fn who(by: Option<String>) -> String {
    by.unwrap_or_else(|| format!("cli:{}", std::env::var("USER").unwrap_or_else(|_| "operator".into())))
}

fn pct(v: Option<f64>) -> String {
    v.map(|v| format!("{:5.1}", v * 100.0)).unwrap_or_else(|| "    –".into())
}

fn line(r: &EvalRun) -> String {
    let m = &r.metrics;
    format!(
        "{}  {:<24} {:<26} storage F1 {}  retrieval F1 {}  stale {}  contamination {}  {}",
        r.created_at.format("%Y-%m-%d %H:%M"),
        r.suite,
        r.policy_version,
        pct(m.storage_f1),
        pct(m.retrieval_f1),
        pct(m.stale_rate),
        pct(m.contamination_rate),
        r.trigger.as_str()
    )
}

pub async fn run(eng: &Engine, tenant: Option<String>, cmd: EvalCmd) -> anyhow::Result<()> {
    let tenant = tenant.unwrap_or_else(|| eng.cfg.memory.tenant.clone());
    match cmd {
        EvalCmd::Add { file, by } => {
            let suite = memhouse_bench::suites::load(&file)?;
            let s = eng.eval_suite_put(&tenant, &suite, &who(by)).await?;
            println!("✓ suite {} stored for tenant {tenant}: {} conversations, {} turns (hash {})", s.name, suite.conversations.len(), suite.turns(), &s.hash[..12]);
            println!("  it is replayed before every policy approval ([eval] gate) and by `memhouse eval run`");
        }
        EvalCmd::List => {
            let suites = eng.store.eval_suites(&tenant).await?;
            if suites.is_empty() {
                println!("tenant {tenant} has no evaluation suite (add one with `memhouse eval add <file>`)");
            }
            for s in suites {
                println!(
                    "{:<24} {:>5} conversations {:>6} turns  hash {}  added by {} {}",
                    s.name,
                    s.suite.conversations.len(),
                    s.suite.turns(),
                    &s.hash[..12],
                    s.created_by,
                    s.created_at.format("%Y-%m-%d")
                );
            }
        }
        EvalCmd::Remove { name, by } => {
            if eng.eval_suite_delete(&tenant, &name, &who(by)).await? {
                println!("✓ suite {name} removed");
            } else {
                anyhow::bail!("tenant {tenant} has no suite named {name}");
            }
        }
        EvalCmd::Run { suite } => {
            let suites: Vec<_> = eng.store.eval_suites(&tenant).await?.into_iter().filter(|s| suite.as_ref().is_none_or(|n| *n == s.name)).collect();
            anyhow::ensure!(!suites.is_empty(), "no suite to run for tenant {tenant}");
            for s in suites {
                let r = eng.eval_record(&tenant, &s.suite, None, EvalTrigger::Manual).await?;
                println!("{}", line(&r));
            }
        }
        EvalCmd::Runs { suite, limit, json } => {
            let runs = eng.store.eval_runs(&tenant, suite.as_deref(), limit.clamp(1, 1000)).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&runs)?);
            } else {
                for r in &runs {
                    println!("{}", line(r));
                }
            }
        }
        EvalCmd::Gate => match eng.eval_gate_now(&tenant).await? {
            None => println!("nothing to compare with yet: the replays were stored as the reference"),
            Some(report) => {
                println!("{}", report.text(true));
                if !report.passed {
                    std::process::exit(1);
                }
            }
        },
    }
    Ok(())
}
