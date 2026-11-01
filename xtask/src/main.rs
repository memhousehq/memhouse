//! Development tasks for MemHouse (goal G01 of draft_plan/development-plan.md).
//!
//! `cargo xtask ci` is the one local CI entry point: fmt, clippy, unit tests, release build, the
//! end-to-end script, and the benchmark guard (which includes the governance suite). It stops at
//! the first failing step. `cargo xtask install-hooks` runs it before every `git push`.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::Instant;

const USAGE: &str = "\
usage: cargo xtask <task> [options]

tasks:
  ci              fmt, clippy, tests, release build, e2e, benchmark guard
    --tier <n>      guard tier: 1 (default, free) or 2 (adds cached enrichment, ~$0.01)
    --fix           apply rustfmt instead of checking it
    --skip-e2e      skip scripts/e2e.sh (no Docker needed)
    --skip-guard    skip the benchmark guard (no benchmark database needed)
  install-hooks   install a git pre-push hook that runs `cargo xtask ci`
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
        Some("install-hooks") => install_hooks(&root),
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
    let (mut fix, mut skip_e2e, mut skip_guard) = (false, false, false);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--tier" => tier = it.next().ok_or("--tier needs a value")?.clone(),
            "--fix" => fix = true,
            "--skip-e2e" => skip_e2e = true,
            "--skip-guard" => skip_guard = true,
            other => return Err(format!("unknown option '{other}'\n{USAGE}")),
        }
    }
    let bin = root.join("target/release/memhouse");
    let mut steps: Vec<Step> = vec![];
    let mut run = |name: &'static str, mut cmd: Command| -> Result<(), String> {
        eprintln!("\n== {name}");
        let t = Instant::now();
        let ok = cmd.current_dir(root).status().map_err(|e| format!("{name}: {e}"))?.success();
        steps.push(Step { name, secs: t.elapsed().as_secs_f64(), ok });
        if ok {
            Ok(())
        } else {
            Err(format!("step '{name}' failed"))
        }
    };

    let started = Instant::now();
    let result = (|| {
        run("fmt", cargo(if fix { &["fmt", "--all"] } else { &["fmt", "--all", "--", "--check"] }))?;
        // Release profile throughout, so clippy, tests and the binary share one build.
        run("clippy", cargo(&["clippy", "--workspace", "--all-targets", "--release", "--", "-D", "warnings"]))?;
        run("unit tests", cargo(&["test", "--workspace", "--release"]))?;
        run("release build", cargo(&["build", "--release", "-p", "memhouse-cli"]))?;
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
            let r = run("e2e", cmd);
            let _ = std::fs::remove_dir_all(&home);
            r?;
        }
        if !skip_guard {
            let mut cmd = Command::new(&bin);
            cmd.args(["bench", "guard", "--tier", &tier]);
            run("benchmark guard", cmd)?;
        }
        Ok::<(), String>(())
    })();

    eprintln!("\n== summary ({:.0} s)", started.elapsed().as_secs_f64());
    for s in &steps {
        eprintln!("  {} {:<16} {:>6.1} s", if s.ok { "✓" } else { "✗" }, s.name, s.secs);
    }
    result
}

fn cargo(args: &[&str]) -> Command {
    let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
    c.args(args);
    c
}

/// The developer's downloaded embedding models, if any: `$MEMHOUSE_HOME/models` or `~/.memhouse/models`.
fn model_cache() -> Option<PathBuf> {
    let home = std::env::var_os("MEMHOUSE_HOME").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".memhouse")))?;
    let m = home.join("models");
    m.is_dir().then_some(m)
}

fn install_hooks(root: &Path) -> Result<(), String> {
    let out = Command::new("git").args(["rev-parse", "--git-path", "hooks"]).current_dir(root).output().map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err("not a git repository".into());
    }
    let dir = root.join(String::from_utf8_lossy(&out.stdout).trim());
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let hook = dir.join("pre-push");
    if hook.exists() && !std::fs::read_to_string(&hook).unwrap_or_default().contains("cargo xtask ci") {
        let backup = dir.join("pre-push.bak");
        std::fs::rename(&hook, &backup).map_err(|e| e.to_string())?;
        eprintln!("existing pre-push hook moved to {}", backup.display());
    }
    std::fs::write(&hook, "#!/bin/sh\n# Installed by `cargo xtask install-hooks`. Skip once with `git push --no-verify`.\nexec cargo xtask ci\n").map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    }
    eprintln!("installed {}", hook.display());
    Ok(())
}
