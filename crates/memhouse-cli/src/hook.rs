// SPDX-License-Identifier: Apache-2.0
//! `memhouse hook file-opened | file-edited | post-commit`: the commands a coding harness's
//! hook configuration and git's `post-commit` hook run (TPL-05, TR-TPL-03), and their
//! installers. The work is in `memhouse_server::hook`; here are the command line, the two ways
//! to reach the API (a running server over HTTP, or this deployment in process), and the rule
//! that a hook never fails its caller: it prints what it has and exits 0.

use anyhow::Context;
use clap::{Args, Subcommand};
use memhouse_server::hook::{self, Format, HookEvent, HookOpts, Transport};
use serde_json::{json, Value};
use std::io::{IsTerminal, Read};
use std::path::{Path, PathBuf};

#[derive(Args, Clone)]
pub struct Reach {
    /// A running MemHouse server (`http://127.0.0.1:7077`); without it the deployment of the
    /// configuration file is opened in this process
    #[arg(long, env = "MEMHOUSE_URL")]
    url: Option<String>,
    /// A file that holds the agent's API key (`memhouse connect <agent> --hooks` writes one)
    #[arg(long)]
    key_file: Option<PathBuf>,
    /// The agent's API key, when no key file is given
    #[arg(long, env = "MEMHOUSE_HOOK_KEY", hide_env_values = true)]
    key: Option<String>,
    /// Give up after this long; the hook then adds nothing
    #[arg(long, default_value_t = 10_000)]
    timeout_ms: u64,
}

#[derive(Args, Clone)]
pub struct FileArgs {
    /// The repository's subject (default: repo:<name of the file's git repository>)
    #[arg(long)]
    subject: Option<String>,
    /// The form of the answer: claude-code, gemini, text or json
    #[arg(long, default_value = "claude-code")]
    format: String,
    /// A file, instead of a harness's hook input on stdin (repeatable)
    #[arg(long = "path")]
    paths: Vec<PathBuf>,
    /// What the agent is doing: procedures that match it are added
    #[arg(long)]
    query: Option<String>,
    #[command(flatten)]
    reach: Reach,
}

#[derive(Subcommand)]
pub enum HookCmd {
    /// The agent read a file: print the memories linked to it (reads the harness's hook JSON on stdin)
    FileOpened(FileArgs),
    /// The agent edited a file: mark what was written about its earlier content, and print it
    FileEdited(FileArgs),
    /// After a commit: report its changed, deleted and renamed files, so memories about them are checked
    PostCommit {
        #[arg(long)]
        subject: Option<String>,
        /// The repository (default: the current directory's)
        #[arg(long)]
        repo: Option<PathBuf>,
        /// Compare with this revision instead of the commit's first parent
        #[arg(long)]
        from: Option<String>,
        /// The commit (default HEAD)
        #[arg(long, default_value = "HEAD")]
        to: String,
        #[command(flatten)]
        reach: Reach,
    },
    /// Install the post-commit hook in a git repository (an existing hook is left as it is)
    InstallGit {
        /// The repository (default: the current directory's)
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long)]
        subject: Option<String>,
        /// The key file the hook reads (default: the one `memhouse connect <agent> --hooks` wrote for --agent)
        #[arg(long)]
        key_file: Option<PathBuf>,
        /// The agent whose key the hook uses
        #[arg(long, default_value = "git")]
        agent: String,
        /// Print the hook instead of writing it
        #[arg(long)]
        print: bool,
    },
}

/// The API over HTTP.
struct Http {
    base: String,
    key: String,
    http: reqwest::Client,
}

#[async_trait::async_trait]
impl Transport for Http {
    async fn post(&self, path: &str, body: &Value) -> anyhow::Result<(u16, Value)> {
        let resp = self
            .http
            .post(format!("{}{path}", self.base))
            .bearer_auth(&self.key)
            .json(body)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("cannot reach {}: {}", self.base, e.without_url()))?;
        let status = resp.status().as_u16();
        Ok((status, resp.json().await.unwrap_or(Value::Null)))
    }
}

/// The key a hook sends. Always its own: a hook never falls back to the deployment's
/// bootstrap key, which would make every agent an administrator.
fn key_of(reach: &Reach) -> anyhow::Result<String> {
    let key = match &reach.key_file {
        Some(f) => std::fs::read_to_string(f).with_context(|| format!("reading the key file {}", f.display()))?,
        None => reach.key.clone().or_else(|| std::env::var("MEMHOUSE_MCP_KEY").ok()).unwrap_or_default(),
    };
    let key = key.trim().to_string();
    anyhow::ensure!(!key.is_empty(), "no API key: give --key-file (written by `memhouse connect <agent> --hooks`) or set MEMHOUSE_HOOK_KEY");
    Ok(key)
}

async fn transport(cfg_path: &Option<PathBuf>, reach: &Reach) -> anyhow::Result<Box<dyn Transport>> {
    let key = key_of(reach)?;
    if let Some(url) = &reach.url {
        let http = reqwest::Client::builder().timeout(std::time::Duration::from_millis(reach.timeout_ms)).build()?;
        return Ok(Box::new(Http { base: url.trim_end_matches('/').to_string(), key, http }));
    }
    let path = cfg_path.clone().unwrap_or_else(memhouse_core::config::default_config_path);
    anyhow::ensure!(path.exists(), "no configuration at {}: run `memhouse up`, or give --url for a running server", path.display());
    let engine = memhouse_server::build_engine(memhouse_core::Config::load(Some(&path))?, false).await?;
    Ok(Box::new(hook::InProcess { api: memhouse_server::Embedded::request_only(engine), key }))
}

/// The harness's hook input: one JSON object on stdin. Nothing is read from a terminal.
///
/// Read on a thread of its own: a harness that never closes the pipe must not hold the hook
/// past its deadline. A read is not something the deadline's timer can interrupt, so the
/// waiting is done here, on a channel, and the thread is left behind when the time is up (the
/// process ends without waiting for it).
async fn stdin_json() -> Option<Value> {
    if std::io::stdin().is_terminal() {
        return None;
    }
    let (done, read) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let _ = done.send(std::io::stdin().read_to_string(&mut text).ok().map(|_| text));
    });
    serde_json::from_str(read.await.ok()??.trim()).ok()
}

async fn file_hook(cfg_path: &Option<PathBuf>, event: HookEvent, a: &FileArgs, format: Format) -> anyhow::Result<String> {
    let input = if a.paths.is_empty() { stdin_json().await } else { None };
    let opts = HookOpts { subject: a.subject.clone(), paths: a.paths.clone(), query: a.query.clone(), cwd: None };
    // Before anything is opened: most tool calls are about no file of a repository.
    let Some(asked) = hook::touched(event, input.as_ref(), &opts).await? else { return Ok(format.nothing().to_string()) };
    let api = transport(cfg_path, &a.reach).await?;
    hook::run_asked(api.as_ref(), &asked, format).await
}

/// Run a hook command. The three hooks always succeed (fail open): what went wrong is one
/// line on stderr. Only the installer reports an error as a command does.
pub async fn run(cfg_path: &Option<PathBuf>, cmd: HookCmd) -> anyhow::Result<()> {
    let (result, format, timeout_ms) = match &cmd {
        HookCmd::FileOpened(a) | HookCmd::FileEdited(a) => {
            let event = if matches!(cmd, HookCmd::FileOpened(_)) { HookEvent::FileOpened } else { HookEvent::FileEdited };
            // An unknown format is the installer's mistake, not a reason to stop the agent.
            let format = Format::parse(&a.format);
            let work = async {
                let format = format.ok_or_else(|| anyhow::anyhow!("unknown --format {:?}: use claude-code, gemini, text or json", a.format))?;
                file_hook(cfg_path, event, a, format).await
            };
            (within(a.reach.timeout_ms, work).await, format.unwrap_or_default(), a.reach.timeout_ms)
        }
        HookCmd::PostCommit { subject, repo, from, to, reach } => {
            let work = async {
                let dir = repo.clone().unwrap_or(std::env::current_dir()?);
                let repo = hook::find_repo(&dir).ok_or_else(|| anyhow::anyhow!("{} is not in a git repository", dir.display()))?;
                let api = transport(cfg_path, reach).await?;
                hook::run_post_commit(api.as_ref(), &repo, subject.as_deref(), from.as_deref(), to).await
            };
            (within(reach.timeout_ms, work).await, Format::Text, reach.timeout_ms)
        }
        HookCmd::InstallGit { repo, subject, key_file, agent, print } => return install_git(cfg_path, repo.as_deref(), subject.as_deref(), key_file.as_deref(), agent, *print),
    };
    let _ = timeout_ms;
    let (stdout, stderr) = hook::fail_open(result, format);
    if let Some(e) = stderr {
        eprintln!("{e}");
    }
    if !stdout.is_empty() {
        println!("{stdout}");
    }
    Ok(())
}

async fn within(ms: u64, work: impl std::future::Future<Output = anyhow::Result<String>>) -> anyhow::Result<String> {
    match tokio::time::timeout(std::time::Duration::from_millis(ms.max(1)), work).await {
        Ok(r) => r,
        Err(_) => Err(anyhow::anyhow!("no answer within {ms} ms")),
    }
}

/// Where `memhouse connect <agent> --hooks` keeps the key its hooks read: one file per agent
/// and deployment. The installation's own configuration (`config.toml` under `MEMHOUSE_HOME`)
/// has `<agent>.key`; a deployment named by another configuration file has a file of its own,
/// named after that path, so connecting it does not replace the key the first one's hooks read.
pub fn key_file_of(cfg_path: &Option<PathBuf>, agent: &str) -> PathBuf {
    let canonical = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    let own = canonical(&memhouse_core::config::home_dir().join("config.toml"));
    let name = match cfg_path.as_deref().map(canonical).filter(|p| *p != own) {
        Some(other) => format!("{agent}-{}.key", &memhouse_core::engine::content_hash(&other.to_string_lossy())[..8]),
        None => format!("{agent}.key"),
    };
    memhouse_core::config::home_dir().join("hook-keys").join(name)
}

/// Write a key for the hooks to read: a file of the user's alone, in a directory of the
/// user's alone. The key is never put on a command line, where other processes could read it.
pub fn write_key_file(cfg_path: &Option<PathBuf>, agent: &str, key: &str) -> anyhow::Result<PathBuf> {
    let file = key_file_of(cfg_path, agent);
    let dir = file.parent().expect("has a parent");
    std::fs::create_dir_all(dir)?;
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        open.mode(0o600);
    }
    use std::io::Write;
    let mut f = open.open(&file).with_context(|| format!("writing {}", file.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // Also when the file was there with wider permissions.
        f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    writeln!(f, "{key}")?;
    Ok(file)
}

fn quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:=@".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// The command line a hook configuration runs: this binary, this configuration, the hook, and
/// the key file. No secret is in it.
pub fn command_line(cfg_path: &Option<PathBuf>, hook: &str, format: Option<&str>, key_file: &Path, subject: Option<&str>) -> anyhow::Result<String> {
    let exe = std::env::current_exe()?.canonicalize()?;
    let mut parts = vec![quote(&exe.display().to_string())];
    // Always named: a harness may run its hooks with a cleaned environment (Gemini CLI does),
    // where neither MEMHOUSE_HOME nor MEMHOUSE_CONFIG would lead to this installation.
    let config = cfg_path.clone().unwrap_or_else(memhouse_core::config::default_config_path);
    parts.extend(["--config".into(), quote(&std::fs::canonicalize(&config).unwrap_or(config).display().to_string())]);
    parts.extend(["hook".into(), hook.into()]);
    if let Some(f) = format {
        parts.extend(["--format".into(), f.into()]);
    }
    parts.extend(["--key-file".into(), quote(&key_file.display().to_string())]);
    if let Some(s) = subject {
        parts.extend(["--subject".into(), quote(s)]);
    }
    Ok(parts.join(" "))
}

/// Claude Code's hook configuration for the two file hooks (settings.json, `hooks.PostToolUse`;
/// format as documented at code.claude.com/docs/en/hooks on 27 November 2026). `PostToolUse`:
/// the hook runs after the tool, so it cannot hold a read or an edit back.
pub fn claude_code_entries(opened: &str, edited: &str) -> Vec<(&'static str, Value)> {
    let entry = |matcher: &str, command: &str| json!({ "matcher": matcher, "hooks": [{ "type": "command", "command": command, "timeout": 15 }] });
    vec![("PostToolUse", entry("Read", opened)), ("PostToolUse", entry("Edit|Write|MultiEdit|NotebookEdit", edited))]
}

/// Gemini CLI's hook configuration (settings.json, `hooks.AfterTool`; format as documented at
/// geminicli.com/docs/hooks on 27 November 2026, pages dated April 2026). Timeouts are in
/// milliseconds there.
pub fn gemini_entries(opened: &str, edited: &str) -> Vec<(&'static str, Value)> {
    let entry = |matcher: &str, name: &str, command: &str| json!({ "matcher": matcher, "hooks": [{ "name": name, "type": "command", "command": command, "timeout": 15000 }] });
    vec![("AfterTool", entry("read_file", "memhouse-file-opened", opened)), ("AfterTool", entry("write_file|replace", "memhouse-file-edited", edited))]
}

/// The words of a command line that is one plain command: no pipe, list, redirection,
/// substitution or expansion outside quotes. `None` for anything else, so that a command
/// with a part of the user's (`memhouse hook file-opened ... && ./lint.sh`) is never read as
/// only ours. Quoting as [`quote`] writes it and as a hand-written line may have it.
fn plain_words(command: &str) -> Option<Vec<String>> {
    let mut words: Vec<String> = vec![];
    let mut word: Option<String> = None;
    let mut chars = command.trim().chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' => words.extend(word.take()),
            '\'' => {
                let w = word.get_or_insert_with(String::new);
                loop {
                    match chars.next()? {
                        '\'' => break,
                        c => w.push(c),
                    }
                }
            }
            '"' => {
                let w = word.get_or_insert_with(String::new);
                loop {
                    match chars.next()? {
                        '"' => break,
                        '$' | '`' | '\\' => return None,
                        c => w.push(c),
                    }
                }
            }
            // An escaped quote, as `quote` writes one; any other backslash is a path's.
            '\\' if chars.peek() == Some(&'\'') => word.get_or_insert_with(String::new).push(chars.next()?),
            '&' | '|' | ';' | '<' | '>' | '(' | ')' | '$' | '`' | '\n' | '\r' | '#' | '*' | '?' | '~' | '{' | '}' | '!' => return None,
            c => word.get_or_insert_with(String::new).push(c),
        }
    }
    words.extend(word);
    Some(words)
}

/// Whether a command line is one of MemHouse's file hooks and nothing else: one plain command
/// ([`plain_words`]) whose program is a binary called `memhouse` (whatever directory it is
/// in), with `--config <file>` or not, running `hook file-opened` or `hook file-edited` with
/// options only. Another program's command with the same words (`mytool hook file-opened`)
/// is not, and neither is ours with anything of the user's attached to it.
fn our_command(command: &str) -> bool {
    let Some(words) = plain_words(command) else { return false };
    let Some((program, rest)) = words.split_first() else { return false };
    let name = program.rsplit(['/', '\\']).next().unwrap_or_default();
    let rest = match rest {
        [flag, _, rest @ ..] if flag == "--config" => rest,
        rest => rest,
    };
    // Only the options `command_line` writes, each with its value: a line with any other
    // (`--path`, `--timeout-ms`) was edited by hand and is the user's.
    let generated = |options: &[String]| options.chunks(2).all(|o| matches!(o, [flag, _] if matches!(flag.as_str(), "--format" | "--key-file" | "--subject")));
    matches!(name, "memhouse" | "memhouse.exe")
        && matches!(rest, [hook, which, options @ ..] if hook == "hook" && matches!(which.as_str(), "file-opened" | "file-edited") && generated(options))
}

/// Whether a hook group of a settings file is one this command wrote: every handler in it is
/// a MemHouse file hook ([`our_command`]). A group with anything else in it is the user's.
fn ours(group: &Value) -> bool {
    let handlers = group["hooks"].as_array().cloned().unwrap_or_default();
    !handlers.is_empty() && handlers.iter().all(|h| h["command"].as_str().is_some_and(our_command))
}

/// Merge hook groups into a settings document: groups this command wrote earlier are
/// replaced, every other entry of the file is kept as it is.
pub fn merge_hooks(root: &mut Value, entries: &[(&'static str, Value)]) -> anyhow::Result<()> {
    anyhow::ensure!(root.is_object(), "expected a JSON object at the top of the settings file");
    let hooks = root.as_object_mut().expect("checked").entry("hooks").or_insert_with(|| json!({}));
    anyhow::ensure!(hooks.is_object(), "expected \"hooks\" to be an object");
    for event in entries.iter().map(|(e, _)| *e).collect::<std::collections::BTreeSet<_>>() {
        let groups = hooks.as_object_mut().expect("checked").entry(event).or_insert_with(|| json!([]));
        let list = groups.as_array_mut().ok_or_else(|| anyhow::anyhow!("expected \"hooks.{event}\" to be an array"))?;
        list.retain(|g| !ours(g));
        list.extend(entries.iter().filter(|(e, _)| *e == event).map(|(_, g)| g.clone()));
    }
    Ok(())
}

/// Write hook groups into a harness's settings file, with a backup beside it. A file that is
/// not plain JSON is not touched: the snippet is printed instead.
pub fn install_hooks(file: &Path, entries: &[(&'static str, Value)], print_only: bool) -> anyhow::Result<bool> {
    let snippet = || -> anyhow::Result<String> {
        let mut v = json!({});
        merge_hooks(&mut v, entries)?;
        Ok(serde_json::to_string_pretty(&v)?)
    };
    if print_only {
        println!("{}:\n{}", file.display(), snippet()?);
        return Ok(false);
    }
    let existing = if file.exists() { std::fs::read_to_string(file)? } else { String::new() };
    let mut root: Value = if existing.trim().is_empty() {
        json!({})
    } else {
        match serde_json::from_str(&existing) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("! {} is not plain JSON ({e}); not modifying it. Merge this yourself:", file.display());
                println!("{}", snippet()?);
                return Ok(false);
            }
        }
    };
    merge_hooks(&mut root, entries).with_context(|| format!("{}", file.display()))?;
    if let Some(dir) = file.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    if file.exists() {
        std::fs::copy(file, file.with_extension(format!("{}.memhouse.bak", file.extension().and_then(|e| e.to_str()).unwrap_or("json"))))?;
    }
    std::fs::write(file, serde_json::to_string_pretty(&root)? + "\n")?;
    Ok(true)
}

/// The line that marks a post-commit hook as ours.
const GIT_MARKER: &str = "# memhouse post-commit hook";

/// Install `post-commit` in a repository's hooks directory. A hook that is already there and
/// is not ours is never overwritten: the line to add to it is printed.
fn install_git(cfg_path: &Option<PathBuf>, repo: Option<&Path>, subject: Option<&str>, key_file: Option<&Path>, agent: &str, print: bool) -> anyhow::Result<()> {
    let dir = repo.map(Path::to_path_buf).unwrap_or(std::env::current_dir()?);
    let found = hook::find_repo(&dir).ok_or_else(|| anyhow::anyhow!("{} is not in a git repository", dir.display()))?;
    let key_file = key_file.map(Path::to_path_buf).unwrap_or_else(|| key_file_of(cfg_path, agent));
    if !key_file.exists() && !print {
        anyhow::bail!("no key file at {}: run `memhouse connect <agent> --hooks` first and name that agent with --agent, or give --key-file", key_file.display());
    }
    // The hook runs from the repository, not from here: a relative path is made absolute now.
    let key_file = std::fs::canonicalize(&key_file).or_else(|_| std::path::absolute(&key_file)).unwrap_or(key_file);
    let line = format!("{} || true", command_line(cfg_path, "post-commit", None, &key_file, subject)?);
    let script = format!("#!/bin/sh\n{GIT_MARKER} (written by `memhouse hook install-git`).\n# Reports the commit's files to MemHouse; it never fails the commit.\n{line}\n");
    // Where git looks for hooks: `core.hooksPath` when set, else the repository's own directory
    // (a linked worktree shares its repository's). git knows; without it, the default.
    let asked = git_at(&found.root).args(["rev-parse", "--git-path", "hooks"]).output().ok().filter(|o| o.status.success());
    let hooks_dir = match asked {
        Some(o) => found.root.join(String::from_utf8_lossy(&o.stdout).trim()),
        None => found.root.join(".git/hooks"),
    };
    let file = hooks_dir.join("post-commit");
    if print {
        println!("{}:\n{script}", file.display());
        return Ok(());
    }
    if let Ok(existing) = std::fs::read_to_string(&file) {
        if !existing.contains(GIT_MARKER) {
            println!("{} already exists and is not MemHouse's: it was left as it is. Add this line to it:\n\n{line}\n", file.display());
            return Ok(());
        }
    }
    std::fs::create_dir_all(&hooks_dir)?;
    std::fs::write(&file, script)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755))?;
    }
    println!("✓ git: wrote {} ({})", file.display(), subject.map(String::from).unwrap_or_else(|| found.subject()));
    Ok(())
}

/// git for the repository at `root`, whatever repository the environment names (as it does
/// under a git hook).
fn git_at(root: &std::path::Path) -> std::process::Command {
    let mut git = std::process::Command::new("git");
    for name in memhouse_server::hook::GIT_REPOSITORY_ENV {
        git.env_remove(name);
    }
    git.arg("-C").arg(root);
    git
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hooks_are_merged_without_clobbering() {
        let mut root = json!({
            "permissions": {"allow": ["Bash(ls:*)"]},
            "hooks": {
                "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "./lint.sh"}]}],
                "Stop": [{"hooks": [{"type": "command", "command": "./done.sh"}]}]
            }
        });
        // Another program's hook with the same words is the user's, and stays.
        root["hooks"]["PostToolUse"].as_array_mut().unwrap().push(json!({"matcher": "Read", "hooks": [{"type": "command", "command": "mytool hook file-opened --all"}]}));
        assert!(our_command("'/opt/my tools/memhouse' --config /c hook file-opened --key-file /k") && our_command("C:\\bin\\memhouse.exe hook file-edited"));
        assert!(!our_command("mytool hook file-opened") && !our_command("/bin/memhouse-wrapper hook file-opened") && !our_command("/bin/memhouse mcp"));
        // Ours with a command of the user's attached is the user's: never replaced.
        for theirs in [
            "memhouse hook file-opened --key-file /k && ./lint.sh",
            "memhouse hook file-opened --key-file /k; ./lint.sh",
            "memhouse hook file-edited | tee /tmp/log",
            "memhouse hook file-edited $(./extra.sh)",
            "memhouse hook file-opened ./lint.sh",
            "memhouse hook file-opened --path /repo/file",
            "memhouse hook file-edited --format claude-code --key-file /k --timeout-ms 700",
            "memhouse hook file-edited --key-file",
            "memhouse hook file-opened 'unterminated",
        ] {
            assert!(!our_command(theirs), "{theirs}");
        }
        // A quoted program with letters outside ASCII, ours or not, is read without a panic.
        assert!(!our_command("'/opt/校验' --check") && our_command("'/opt/工具/memhouse' hook file-opened --key-file '/k y/it'\\''s'"));
        let mut chained =
            json!({"hooks": {"PostToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "memhouse hook file-opened --key-file /k && ./lint.sh"}]}]}});
        merge_hooks(&mut chained, &claude_code_entries("memhouse hook file-opened", "memhouse hook file-edited")).unwrap();
        let commands: Vec<&str> = chained["hooks"]["PostToolUse"].as_array().unwrap().iter().map(|g| g["hooks"][0]["command"].as_str().unwrap()).collect();
        assert!(commands.contains(&"memhouse hook file-opened --key-file /k && ./lint.sh") && commands.len() == 3, "{commands:?}");
        let entries = claude_code_entries("/bin/memhouse hook file-opened --format claude-code --key-file /k", "/bin/memhouse hook file-edited --format claude-code --key-file /k");
        merge_hooks(&mut root, &entries).unwrap();
        let again = root.clone();
        // A second run replaces its own groups and nothing else.
        merge_hooks(&mut root, &claude_code_entries("/bin/memhouse hook file-opened --key-file /other", "/bin/memhouse hook file-edited --key-file /other")).unwrap();
        let post = root["hooks"]["PostToolUse"].as_array().unwrap();
        assert_eq!(post.len(), 4, "{root}");
        assert_eq!(post[0]["hooks"][0]["command"], "./lint.sh");
        assert_eq!(post[1]["hooks"][0]["command"], "mytool hook file-opened --all");
        assert_eq!((post[2]["matcher"].as_str(), post[3]["matcher"].as_str()), (Some("Read"), Some("Edit|Write|MultiEdit|NotebookEdit")));
        assert!(post[2]["hooks"][0]["command"].as_str().unwrap().contains("/other"));
        assert_eq!(root["hooks"]["Stop"], again["hooks"]["Stop"]);
        assert_eq!(root["permissions"], again["permissions"]);
        // A settings file whose hooks are not what the format says is refused, not rewritten.
        assert!(merge_hooks(&mut json!({"hooks": {"PostToolUse": "x"}}), &entries).is_err());
        let gemini = gemini_entries("m hook file-opened", "m hook file-edited");
        let mut g = json!({"mcpServers": {"memhouse": {}}});
        merge_hooks(&mut g, &gemini).unwrap();
        assert_eq!(g["hooks"]["AfterTool"].as_array().unwrap().len(), 2);
        assert_eq!(g["hooks"]["AfterTool"][0]["hooks"][0]["timeout"], 15000);
        assert!(g["mcpServers"]["memhouse"].is_object());
    }
}
