// SPDX-License-Identifier: Apache-2.0
//! `memhouse policy …`: behaviour policy specs (G08). The CLI holds the database credentials, so
//! it acts as the operator; approvals and rollbacks still name the person who made them, and every
//! change is audited.

use clap::Subcommand;
use memhouse_core::policy::{self, PolicyDiffRequest, PolicySpec, PolicyTarget, SpecStatus};
use memhouse_core::{Config, Engine};
use std::path::{Path, PathBuf};

#[derive(Subcommand)]
pub enum PolicyCmd {
    /// The running policy, every spec version and the activations
    Status,
    /// Compile a spec (TOML or JSON) without storing it; needs no database
    Validate { file: PathBuf },
    /// Compare two policies: by default the running one and a spec file
    Diff {
        /// A spec file to compare (not stored)
        file: Option<PathBuf>,
        /// `default` or a version (default: the running policy)
        #[arg(long)]
        from: Option<String>,
        /// `default` or a version, instead of a file
        #[arg(long)]
        to: Option<String>,
    },
    /// Store a spec as the next version; it runs only once approved
    Propose {
        file: PathBuf,
        /// Why the change is proposed
        #[arg(long)]
        note: Option<String>,
        /// Who proposes it (default: cli:$USER)
        #[arg(long)]
        by: Option<String>,
    },
    /// Approve a proposed version and activate it
    Approve {
        /// The version, e.g. 3 or v3
        version: String,
        /// The approver's name, recorded with the version and in the audit log
        #[arg(long)]
        approver: String,
    },
    /// Activate an earlier policy: --to a version or `default`, else the one active before
    Rollback {
        #[arg(long)]
        to: Option<String>,
        /// Who rolls back, recorded in the audit log
        #[arg(long)]
        approver: String,
    },
    /// Print a stored spec as TOML, or the running compiled policy as JSON
    Show { version: Option<String> },
}

fn read_spec(file: &Path) -> anyhow::Result<PolicySpec> {
    let text = std::fs::read_to_string(file).map_err(|e| anyhow::anyhow!("reading {}: {e}", file.display()))?;
    policy::parse_spec(&text)
}

fn version(s: &str) -> anyhow::Result<u32> {
    match PolicyTarget::parse(s)? {
        PolicyTarget::Version(n) => Ok(n),
        PolicyTarget::Default => anyhow::bail!("name a version, e.g. 3"),
    }
}

/// `validate` compiles against the configuration alone, so it runs in CI without a database.
pub fn validate(cfg: &Config, tenant: Option<String>, file: &Path) -> anyhow::Result<()> {
    let spec = read_spec(file)?;
    let tenant = tenant.unwrap_or_else(|| spec.scope.tenant.clone());
    match policy::compile(&spec, cfg, &tenant, None) {
        Ok(c) => {
            println!("✓ {} compiles for tenant {tenant} ({})", file.display(), c.version);
            for ch in policy::diff(&policy::default_policy(cfg, &tenant).policy, &c.policy).iter().filter(|c| !c.path.starts_with("spec")) {
                println!("  {}: {} → {}", ch.path, ch.from, ch.to);
            }
            Ok(())
        }
        Err(v) => Err(policy::violations_error(&v)),
    }
}

pub async fn run(eng: &Engine, tenant: Option<String>, cmd: PolicyCmd) -> anyhow::Result<()> {
    let tenant = tenant.unwrap_or_else(|| eng.cfg.memory.tenant.clone());
    match cmd {
        PolicyCmd::Validate { file } => validate(&eng.cfg, Some(tenant), &file)?,
        PolicyCmd::Status => {
            let s = eng.policy_status(&tenant).await?;
            match s.active {
                Some(n) => println!("tenant {tenant}: v{n} active, running {}", s.running.version),
                None => println!("tenant {tenant}: default policy (configuration), running {}", s.running.version),
            }
            if let Some(w) = &s.warning {
                println!("! {w}");
            }
            if !s.specs.is_empty() {
                println!("\nversions:");
            }
            for r in &s.specs {
                let approved = match (&r.approved_by, r.approved_at) {
                    (Some(b), Some(at)) => format!(", approved by {b} {}", at.format("%Y-%m-%d %H:%M")),
                    _ => String::new(),
                };
                let mark = if s.active == Some(r.version) { "*" } else { " " };
                println!("{mark} v{:<4} {:<9} {:<24} proposed by {} {}{approved}", r.version, r.status.as_str(), r.name, r.proposed_by, r.proposed_at.format("%Y-%m-%d %H:%M"));
            }
            if !s.history.is_empty() {
                println!("\nactivations (newest first):");
            }
            for a in &s.history {
                let what = a.version.map(|v| format!("v{v}")).unwrap_or_else(|| "default".into());
                println!("  {} {:<8} {:<8} by {:<20} {}", a.at.format("%Y-%m-%d %H:%M:%S"), a.action, what, a.by, a.compiled);
            }
        }
        PolicyCmd::Diff { file, from, to } => {
            let spec = file.as_deref().map(read_spec).transpose()?;
            anyhow::ensure!(spec.is_some() != to.is_some(), "give a spec file or --to, not both");
            let d = eng.policy_diff(&tenant, &PolicyDiffRequest { from, to, spec }).await?;
            println!("{} → {}", d.from, d.to);
            if d.changes.is_empty() {
                println!("  no differences");
            }
            for c in d.changes {
                println!("  {}: {} → {}", c.path, c.from, c.to);
            }
        }
        PolicyCmd::Propose { file, note, by } => {
            let spec = read_spec(&file)?;
            let by = by.unwrap_or_else(|| format!("cli:{}", std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_else(|_| "operator".into())));
            let r = eng.policy_propose(&tenant, &spec, &by, note.as_deref()).await?;
            println!("proposed v{} ({}) for tenant {tenant}", r.version, r.name);
            println!("Review it with `memhouse policy diff --to v{}`; activate it with `memhouse policy approve {} --approver <name>`", r.version, r.version);
        }
        PolicyCmd::Approve { version: v, approver } => {
            let n = version(&v)?;
            let c = eng.policy_approve(&tenant, n, &approver).await?;
            println!("✓ v{n} approved by {approver} and active for tenant {tenant}: {}", c.version);
        }
        PolicyCmd::Rollback { to, approver } => {
            let to = to.as_deref().map(PolicyTarget::parse).transpose()?;
            let c = eng.policy_rollback(&tenant, to, &approver).await?;
            let what = c.policy.spec.as_ref().and_then(|s| s.version).map(|v| format!("v{v}")).unwrap_or_else(|| "the default policy".into());
            println!("✓ rolled back to {what} for tenant {tenant}: {}", c.version);
        }
        PolicyCmd::Show { version: None } => {
            let s = eng.policy_status(&tenant).await?;
            println!("{}", serde_json::to_string_pretty(&s.running)?);
        }
        PolicyCmd::Show { version: Some(v) } => {
            let n = version(&v)?;
            let r = eng.policy_source.spec(&tenant, n).await?.ok_or_else(|| anyhow::anyhow!("policy v{n} not found"))?;
            let spec: PolicySpec = serde_json::from_value(r.spec)?;
            let state = if r.status == SpecStatus::Approved { format!("approved by {}", r.approved_by.unwrap_or_default()) } else { "proposed".into() };
            println!("# v{n}, {state}; proposed by {}{}", r.proposed_by, r.note.map(|n| format!(": {n}")).unwrap_or_default());
            print!("{}", toml::to_string_pretty(&spec)?);
        }
    }
    Ok(())
}
