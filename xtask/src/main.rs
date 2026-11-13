// SPDX-License-Identifier: Apache-2.0
//! Development tasks for MemHouse (goals G01 and G02 of docs/roadmap.md).
//!
//! `cargo xtask ci` is the one local CI entry point: fmt, licence headers, secret scan,
//! dependency policy, clippy, unit tests, release build, the end-to-end script, and the benchmark
//! guard (which includes the governance suite). It stops at the first failing step.
//! `cargo xtask install-hooks` runs the secret scan before every commit, checks the DCO sign-off on
//! every commit message, and runs the CI before every `git push`.

mod links;
mod secrets;
mod spdx;

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::Instant;

const USAGE: &str = "\
usage: cargo xtask <task> [options]

tasks:
  ci              fmt, SPDX headers, secret scan, cargo-deny, clippy, tests, release build, e2e, benchmark guard
    --tier <n>      guard tier: 1 (default, free) or 2 (adds cached enrichment, ~$0.01)
    --fix           apply rustfmt and add missing SPDX headers instead of checking them
    --skip-e2e      skip scripts/e2e.sh (no Docker needed)
    --skip-guard    skip the benchmark guard (no benchmark database needed)
    --skip-latency  report the guard's timings without failing on them (a machine known to be busy);
                    MEMHOUSE_CI_SKIP_LATENCY=1 does the same where no option can be passed (the pre-push hook)
  spdx [--fix]    check (or add) SPDX licence identifiers
  links           check relative links and #anchors in the Markdown docs
    --external      also list the external links (not fetched)
  secrets         scan for credentials: the working tree (default), --staged changes, or the whole --history
    --repo <path>   scan another repository (e.g. ../other-repo)
  install-hooks   pre-commit secret scan, commit-msg DCO check, pre-push `cargo xtask ci`
    --repo <path>   install the secret-scan and DCO hooks into another repository (no pre-push CI)
";

struct Step {
    name: &'static str,
    secs: f64,
    ok: bool,
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = workspace_root();
    let result = match args.first().map(String::as_str) {
        Some("ci") => ci(&root, &args[1..]),
        Some("spdx") => spdx_task(&root, args[1..].iter().any(|a| a == "--fix")),
        Some("links") => links_task(&root, args[1..].iter().any(|a| a == "--external")),
        Some("secrets") => secrets_task(&root, &args[1..]),
        Some("install-hooks") => install_hooks(&root, &args[1..]),
        _ => {
            eprint!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("xtask: {e}");
            ExitCode::FAILURE
        }
    }
}

fn workspace_root() -> PathBuf {
    // xtask/ sits directly under the workspace root.
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().expect("workspace root").to_path_buf()
}

fn ci(root: &Path, args: &[String]) -> Result<(), String> {
    let mut tier = "1".to_string();
    let (mut fix, mut skip_e2e, mut skip_guard, mut skip_latency) = (false, false, false, false);
    // The pre-push hook passes no options: on a machine known to be busy, the environment says so.
    // Only timings stop gating; every quality metric and every other step still does.
    if std::env::var("MEMHOUSE_CI_SKIP_LATENCY").is_ok_and(|v| v == "1") {
        skip_latency = true;
    }
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--tier" => tier = it.next().ok_or("--tier needs a value")?.clone(),
            "--fix" => fix = true,
            "--skip-e2e" => skip_e2e = true,
            "--skip-guard" => skip_guard = true,
            "--skip-latency" => skip_latency = true,
            other => return Err(format!("unknown option '{other}'\n{USAGE}")),
        }
    }
    let bin = root.join("target/release/memhouse");
    let mut steps: Vec<Step> = vec![];
    let mut record = |name: &'static str, t: Instant, ok: bool| -> Result<(), String> {
        steps.push(Step { name, secs: t.elapsed().as_secs_f64(), ok });
        if ok {
            Ok(())
        } else {
            Err(format!("step '{name}' failed"))
        }
    };
    let run = |name: &'static str, mut cmd: Command, record: &mut dyn FnMut(&'static str, Instant, bool) -> Result<(), String>| -> Result<(), String> {
        eprintln!("\n== {name}");
        let t = Instant::now();
        let ok = cmd.current_dir(root).status().map_err(|e| format!("{name}: {e}"))?.success();
        record(name, t, ok)
    };

    let started = Instant::now();
    let result = (|| {
        run("fmt", cargo(if fix { &["fmt", "--all"] } else { &["fmt", "--all", "--", "--check"] }), &mut record)?;
        eprintln!("\n== spdx headers");
        let t = Instant::now();
        let ok = spdx_task(root, fix).map_err(|e| eprintln!("{e}")).is_ok();
        record("spdx headers", t, ok)?;
        eprintln!("\n== links");
        let t = Instant::now();
        let ok = links_task(root, false).map_err(|e| eprintln!("{e}")).is_ok();
        record("links", t, ok)?;
        eprintln!("\n== secret scan");
        let t = Instant::now();
        let ok = report(secrets::scan_tree(root)?, "working tree").is_ok();
        record("secret scan", t, ok)?;
        if which("cargo-deny").is_none() {
            eprintln!("\n== dependency policy\ncargo-deny is not installed: `cargo install cargo-deny --locked`");
            record("dependency policy", Instant::now(), false)?;
        }
        // A banned crate reached through anything but its listed wrapper is an error (deny.toml).
        run("dependency policy", cargo(&["deny", "--all-features", "check", "-D", "unmatched-wrapper"]), &mut record)?;
        // Release profile throughout, so clippy, tests and the binary share one build.
        run("clippy", cargo(&["clippy", "--workspace", "--all-targets", "--release", "--", "-D", "warnings"]), &mut record)?;
        run("unit tests", cargo(&["test", "--workspace", "--release"]), &mut record)?;
        run("release build", cargo(&["build", "--release", "-p", "memhouse-cli"]), &mut record)?;
        if !skip_e2e {
            // A throwaway home so the script never touches the developer's config; the model
            // cache is shared to avoid a download per run.
            let home = std::env::temp_dir().join(format!("memhouse-e2e-{}", std::process::id()));
            let mut cmd = Command::new("bash");
            cmd.arg("scripts/e2e.sh").env("BIN", &bin).env("MEMHOUSE_HOME", home.join("home"));
            if !skip_guard {
                cmd.env("SKIP_GOVERNANCE", "1"); // the guard runs the governance suite
            }
            if let Some(models) = model_cache() {
                cmd.env("MEMHOUSE_MODEL_CACHE", models);
            }
            let r = run("e2e", cmd, &mut record);
            let _ = std::fs::remove_dir_all(&home);
            r?;
        }
        if !skip_guard {
            let mut cmd = Command::new(&bin);
            cmd.args(["bench", "guard", "--tier", &tier]);
            if skip_latency {
                cmd.arg("--skip-latency");
            }
            run("benchmark guard", cmd, &mut record)?;
        }
        Ok::<(), String>(())
    })();

    eprintln!("\n== summary ({:.0} s)", started.elapsed().as_secs_f64());
    for s in &steps {
        eprintln!("  {} {:<18} {:>6.1} s", if s.ok { "✓" } else { "✗" }, s.name, s.secs);
    }
    result
}

fn cargo(args: &[&str]) -> Command {
    let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
    c.args(args);
    c
}

fn which(bin: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|p| std::env::split_paths(&p).map(|d| d.join(bin)).find(|f| f.is_file()))
}

/// Tracked and untracked-but-not-ignored files, relative to `repo`.
fn files(repo: &Path) -> Result<Vec<String>, String> {
    let out = Command::new("git").args(["ls-files", "-co", "--exclude-standard"]).current_dir(repo).output().map_err(|e| format!("git: {e}"))?;
    Ok(String::from_utf8_lossy(&out.stdout).lines().filter(|f| repo.join(f).is_file()).map(String::from).collect())
}

fn links_task(root: &Path, external: bool) -> Result<(), String> {
    let (problems, ext) = links::check(root, &files(root)?);
    for p in &problems {
        eprintln!("  {p}");
    }
    if external {
        for e in &ext {
            println!("{e}");
        }
    }
    if problems.is_empty() {
        eprintln!("links: ok ({} external not fetched)", ext.len());
        Ok(())
    } else {
        Err(format!("{} broken link(s) in the docs", problems.len()))
    }
}

fn spdx_task(root: &Path, fix: bool) -> Result<(), String> {
    let problems = spdx::check(root, &files(root)?, fix)?;
    for p in &problems {
        eprintln!("  {p}");
    }
    if problems.is_empty() {
        eprintln!("SPDX headers: ok");
        Ok(())
    } else {
        Err(format!("{} file(s) with a missing or wrong SPDX licence identifier", problems.len()))
    }
}

fn report(found: Vec<secrets::Finding>, what: &str) -> Result<(), String> {
    for f in &found {
        eprintln!("  {}  {}  {}  [fingerprint {}]", f.place, f.rule, f.preview, f.fingerprint);
    }
    if found.is_empty() {
        eprintln!("secret scan ({what}): nothing found");
        Ok(())
    } else {
        Err(format!(
            "secret scan ({what}): {} possible secret(s). Remove them (and rotate any real key, see docs/security/secrets.md), \
             or mark a test fixture with `secret-scan: allow`",
            found.len()
        ))
    }
}

fn secrets_task(root: &Path, args: &[String]) -> Result<(), String> {
    let mut repo = root.to_path_buf();
    let (mut staged, mut history) = (false, false);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--repo" => repo = PathBuf::from(it.next().ok_or("--repo needs a path")?),
            "--staged" => staged = true,
            "--history" => history = true,
            other => return Err(format!("unknown option '{other}'\n{USAGE}")),
        }
    }
    let label = repo.display().to_string();
    if history {
        report(secrets::scan_history(&repo)?, &format!("{label}, full history"))
    } else if staged {
        report(secrets::scan_staged(&repo)?, &format!("{label}, staged changes"))
    } else {
        report(secrets::scan_tree(&repo)?, &format!("{label}, working tree"))
    }
}

/// The developer's downloaded embedding models, if any: `$MEMHOUSE_HOME/models` or `~/.memhouse/models`.
fn model_cache() -> Option<PathBuf> {
    let home = std::env::var_os("MEMHOUSE_HOME").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".memhouse")))?;
    let m = home.join("models");
    m.is_dir().then_some(m)
}

fn install_hooks(root: &Path, args: &[String]) -> Result<(), String> {
    let repo = match args {
        [flag, path] if flag == "--repo" => std::fs::canonicalize(path).map_err(|e| format!("{path}: {e}"))?,
        [] => root.to_path_buf(),
        _ => return Err(USAGE.into()),
    };
    let product = repo == root;
    let out = Command::new("git").args(["rev-parse", "--git-path", "hooks"]).current_dir(&repo).output().map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(format!("{} is not a git repository", repo.display()));
    }
    let dir = repo.join(String::from_utf8_lossy(&out.stdout).trim());
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    // A hook runs in the checkout git is working on: the repository's own directory or one of
    // its worktrees. The product's hooks build xtask from that checkout and check that tree, so
    // a push from a worktree is checked as it is, not as the main checkout happens to be. Another
    // repository's hooks call back into this checkout for xtask and scan their own tree.
    let top = "\"$(git rev-parse --show-toplevel)\"";
    let xtask = if product {
        "cargo run --quiet --manifest-path \"$(git rev-parse --show-toplevel)/Cargo.toml\" --package xtask --".to_string()
    } else {
        format!("cargo run --quiet --manifest-path \"{}/Cargo.toml\" --package xtask --", root.display())
    };
    let mut hooks = vec![
        ("pre-commit", format!("# Secret scan of staged changes. Bypass only for a false positive: git commit --no-verify\nexec {xtask} secrets --repo {top} --staged\n")),
        (
            "commit-msg",
            "# DCO: every commit is signed off (git commit -s). See CONTRIBUTING.md.\n\
             grep -qE '^Signed-off-by: .+ <[^>]+@[^>]+>' \"$1\" || { echo \"commit message has no Signed-off-by line: use git commit -s (see CONTRIBUTING.md)\" >&2; exit 1; }\n"
                .to_string(),
        ),
    ];
    if product {
        hooks.push(("pre-push", format!("# Skip once with `git push --no-verify`.\nexec {xtask} ci\n")));
    }
    for (name, body) in hooks {
        let hook = dir.join(name);
        if hook.exists() && !std::fs::read_to_string(&hook).unwrap_or_default().contains("Installed by `cargo xtask install-hooks`") {
            let backup = dir.join(format!("{name}.bak"));
            std::fs::rename(&hook, &backup).map_err(|e| e.to_string())?;
            eprintln!("existing {name} hook moved to {}", backup.display());
        }
        // Git runs hooks with a minimal PATH (GUI clients especially), so add the rustup bin dir.
        let script = format!("#!/bin/sh\n# Installed by `cargo xtask install-hooks`.\nPATH=\"${{CARGO_HOME:-$HOME/.cargo}}/bin:$PATH\"\n{body}");
        std::fs::write(&hook, script).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
        }
        eprintln!("installed {}", hook.display());
    }
    Ok(())
}
