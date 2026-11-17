// SPDX-License-Identifier: Apache-2.0
//! `memhouse lang …`: language packs (G36). `check` validates a pack file, and with `--tests`
//! runs its labelled test set, without a database; `list` and `detect` read the configuration.

use clap::Subcommand;
use memhouse_core::lang::{self, Languages, Pack, PackError};
use memhouse_core::Config;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Subcommand)]
pub enum LangCmd {
    /// The packs: built-in and the operator's (language.packs_dir), and which are enabled
    List,
    /// Validate a pack file; problems are reported as file:line: message
    Check {
        file: PathBuf,
        /// A labelled test set for the pack (a suite file with `statement`, `injection`,
        /// `covers` and `ids` labels); exits with status 1 unless the pack passes it
        #[arg(long)]
        tests: Option<PathBuf>,
        /// Print every item the pack got wrong
        #[arg(long, short)]
        verbose: bool,
    },
    /// Print the JSON Schema of the pack format
    Schema,
    /// Which of the enabled languages a text is detected as
    Detect { text: String },
}

fn problems(e: PackError) -> anyhow::Error {
    for p in &e.0 {
        eprintln!("{p}");
    }
    anyhow::anyhow!("{} problem{} found", e.0.len(), if e.0.len() == 1 { "" } else { "s" })
}

pub fn run(cfg_path: Option<&Path>, cmd: LangCmd) -> anyhow::Result<()> {
    match cmd {
        LangCmd::Schema => println!("{}", serde_json::to_string_pretty(&lang::schema())?),
        LangCmd::Check { file, tests, verbose } => {
            let name = file.display().to_string();
            let src = std::fs::read_to_string(&file).map_err(|e| anyhow::anyhow!("{name}: {e}"))?;
            let pack = Arc::new(Pack::parse(&src, &name).map_err(problems)?);
            println!("{name}: valid ({} — {}, text search \"{}\", {:?})", pack.code(), pack.file.name, pack.file.text_search, pack.file.status);
            if let Some(t) = tests {
                let suite = memhouse_bench::suites::load(&t)?;
                if suite.language.as_deref().is_some_and(|l| l != pack.code()) {
                    anyhow::bail!("{}: the test set is for language {:?}, the pack is {:?}", t.display(), suite.language.as_deref().unwrap_or(""), pack.code());
                }
                let languages = Languages::of(vec![pack.clone()], 0);
                let report = memhouse_core::langcheck::check(&languages, &pack, &suite);
                println!("{}", report.summary());
                let shown = if verbose { report.failures.len() } else { report.failures.len().min(10) };
                for f in &report.failures[..shown] {
                    println!("  {f}");
                }
                if shown < report.failures.len() {
                    println!("  … and {} more (--verbose)", report.failures.len() - shown);
                }
                let missing = memhouse_core::langcheck::missing_types(&suite);
                if !missing.is_empty() {
                    anyhow::bail!("the test set has no statement labelled {}", missing.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
                }
                if !report.passes() {
                    anyhow::bail!("{} does not pass its test set", pack.code());
                }
                println!("{}: passes its test set", pack.code());
            }
        }
        LangCmd::List => {
            let cfg = Config::load(cfg_path)?;
            let all = lang::available(&cfg.language)?;
            let default = if cfg.language.default.is_empty() { cfg.language.enabled.first().cloned().unwrap_or_default() } else { cfg.language.default.clone() };
            println!("{:<8} {:<12} {:<8} {:<12} {:<9} SOURCE", "CODE", "LANGUAGE", "STATUS", "TEXT SEARCH", "ENABLED");
            for (code, (source, src)) in &all {
                let p = Pack::parse(src, source).map_err(problems)?;
                let enabled = match (cfg.language.enabled.contains(code), *code == default) {
                    (true, true) => "default",
                    (true, false) => "yes",
                    _ => "",
                };
                println!("{:<8} {:<12} {:<8} {:<12} {:<9} {}", code, p.file.name, format!("{:?}", p.file.status).to_lowercase(), p.file.text_search, enabled, source);
            }
            for code in cfg.language.enabled.iter().filter(|c| !all.contains_key(*c)) {
                println!("{code:<8} enabled, but there is no pack for it");
            }
        }
        LangCmd::Detect { text } => {
            let cfg = Config::load(cfg_path)?;
            let languages = Languages::load(&cfg.language)?;
            let d = languages.detect(&text, None);
            println!("{}{}", d.pack.code(), if d.sure { "" } else { " (not sure: the default language; every enabled pack's markers apply)" });
        }
    }
    Ok(())
}
