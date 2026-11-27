// SPDX-License-Identifier: Apache-2.0
//! Harness hook adapters (TPL-05, TR-TPL-03): what `memhouse hook file-opened`, `file-edited`
//! and `post-commit` do. A coding harness runs the command when its agent reads or edits a file,
//! and git runs it after a commit. The adapter reads the harness's hook input, works out the
//! file's path in its repository and its content hash, calls the API, and prints the memories
//! in the form the harness adds to the agent's context.
//!
//! The adapters only call the API (AP-2). They hold no rule of their own: what a caller may
//! see, and what is stale, is decided by the server that answers `POST /v1/code/touched` and
//! `POST /v1/code/changed`. And they fail open for the developer: whatever goes wrong, the
//! outcome is an empty answer and a line for stderr, never a blocked read, edit or commit
//! ([`fail_open`]).
//!
//! Hook input formats (looked up on 27 November 2026):
//! - Claude Code, `PostToolUse` and `PreToolUse` (code.claude.com/docs/en/hooks): JSON on
//!   stdin with `hook_event_name`, `cwd`, `tool_name` and `tool_input.file_path`; context is
//!   returned as `hookSpecificOutput.additionalContext` with the event's name.
//! - Gemini CLI, `AfterTool` (geminicli.com/docs/hooks/reference, page dated 10 April 2026):
//!   JSON on stdin with `hook_event_name`, `cwd`, `tool_name` and `tool_input.file_path`;
//!   context is returned as `hookSpecificOutput.additionalContext`, and stdout must hold
//!   nothing but that JSON object.

use memhouse_core::staleness::{git_blob_hash, normalize_path, touched_text, ObjectFormat};
use memhouse_core::types::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Which hook ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookEvent {
    FileOpened,
    FileEdited,
}

/// The form of the answer on stdout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Format {
    /// Claude Code: `{"hookSpecificOutput": {"hookEventName": ..., "additionalContext": ...}}`,
    /// or nothing when there is nothing to add.
    #[default]
    ClaudeCode,
    /// Gemini CLI: the same object; `{}` when there is nothing to add (its stdout is always
    /// one JSON object).
    Gemini,
    /// The text block alone.
    Text,
    /// The API's response as it came.
    Json,
}

impl Format {
    pub fn parse(s: &str) -> Option<Format> {
        Some(match s {
            "claude-code" | "claude" => Format::ClaudeCode,
            "gemini" | "gemini-cli" => Format::Gemini,
            "text" => Format::Text,
            "json" => Format::Json,
            _ => return None,
        })
    }

    /// The event name a harness expects back when its input named none.
    fn default_event(&self) -> &'static str {
        match self {
            Format::Gemini => "AfterTool",
            _ => "PostToolUse",
        }
    }

    /// What is printed when there is nothing to say (also after a failure).
    pub fn nothing(&self) -> &'static str {
        match self {
            Format::Gemini => "{}",
            _ => "",
        }
    }
}

/// Context a harness accepts in one piece: Claude Code moves more than 10,000 characters of
/// `additionalContext` to a file and shows a preview.
pub const MAX_CONTEXT_CHARS: usize = 8000;

/// A git repository found from a path inside it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repo {
    /// The working tree's root, canonical.
    pub root: PathBuf,
    /// The repository's name: the directory that holds its `.git` (for a linked worktree, the
    /// main checkout's directory, so every worktree of a repository shares one subject).
    pub name: String,
    pub objects: ObjectFormat,
}

impl Repo {
    /// The coding template's subject for this repository.
    pub fn subject(&self) -> String {
        format!("repo:{}", self.name)
    }

    /// A file's path as code references store it: relative to the root, `/` separators.
    /// `None` for a file outside the repository or inside its `.git`.
    pub fn relative(&self, file: &Path) -> Option<String> {
        let rel = file.strip_prefix(&self.root).ok()?;
        let parts: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
        if parts.first().is_some_and(|p| p == ".git") {
            return None;
        }
        normalize_path(&parts.join("/"))
    }
}

/// The repository a path belongs to, found by walking up to the nearest `.git`, without a git
/// binary. A linked worktree (`.git` is a file naming its git directory) is followed to the
/// repository it belongs to for the name and the object format.
pub fn find_repo(from: &Path) -> Option<Repo> {
    let start = std::fs::canonicalize(from).ok()?;
    let mut dir: &Path = if start.is_dir() { &start } else { start.parent()? };
    loop {
        let dot = dir.join(".git");
        let common = if dot.is_dir() {
            Some(dot.clone())
        } else if dot.is_file() {
            // `gitdir: <path>`: a linked worktree or a submodule. A worktree's git directory
            // names the repository's own in `commondir`.
            let text = std::fs::read_to_string(&dot).ok()?;
            let git_dir = dir.join(text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim());
            let common = std::fs::read_to_string(git_dir.join("commondir")).ok().map(|c| git_dir.join(c.trim()));
            Some(std::fs::canonicalize(common.unwrap_or(git_dir)).ok()?)
        } else {
            None
        };
        if let Some(common) = common {
            let own = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned());
            let name = if common.file_name().is_some_and(|n| n == ".git") { common.parent().and_then(own) } else { None }.or_else(|| own(dir))?;
            // `[extensions] objectformat = sha256` marks a SHA-256 repository.
            let config = std::fs::read_to_string(common.join("config")).unwrap_or_default().to_lowercase();
            let sha256 = config.lines().any(|l| {
                let l: String = l.split_whitespace().collect();
                l == "objectformat=sha256"
            });
            return Some(Repo { root: dir.to_path_buf(), name, objects: if sha256 { ObjectFormat::Sha256 } else { ObjectFormat::Sha1 } });
        }
        dir = dir.parent()?;
    }
}

/// The file a harness's tool call was about: `tool_input.file_path` (Claude Code's Read, Edit
/// and Write; Gemini CLI's `read_file`, `write_file` and `replace`), with the other names
/// tools have used for it, or a top-level `file_path`.
pub fn tool_path(input: &Value) -> Option<String> {
    let named = |v: &Value| ["file_path", "path", "absolute_path", "notebook_path"].iter().find_map(|k| v[*k].as_str().filter(|s| !s.is_empty()).map(String::from));
    named(&input["tool_input"]).or_else(|| input["file_path"].as_str().filter(|s| !s.is_empty()).map(String::from))
}

/// What one hook run asks the API, and how its answer is printed.
#[derive(Debug, Clone)]
pub struct Touched {
    pub request: FileTouchedRequest,
    /// The subject asked about, for the text block.
    pub subject: String,
    pub paths: Vec<String>,
    /// The harness's own name for the event, returned to it with the context.
    pub hook_event_name: Option<String>,
}

/// Options of a file hook, from the command line.
#[derive(Debug, Clone, Default)]
pub struct HookOpts {
    /// The subject; by default `repo:<name>` of the file's repository.
    pub subject: Option<String>,
    /// Files given on the command line instead of a harness's input.
    pub paths: Vec<PathBuf>,
    /// What the agent is doing, when the caller knows.
    pub query: Option<String>,
    /// The directory relative paths are read from, when the input names none.
    pub cwd: Option<PathBuf>,
}

/// The largest file a hook reads to hash it; a larger one is looked up by its path alone.
pub const MAX_HASHED_BYTES: u64 = 64 * 1024 * 1024;

/// Build the API request for a file hook from the harness's input (or the paths in `opts`).
/// `None` when there is nothing to ask: no file named, or none inside a git repository.
pub async fn touched(event: HookEvent, input: Option<&Value>, opts: &HookOpts) -> anyhow::Result<Option<Touched>> {
    let cwd = input.and_then(|i| i["cwd"].as_str()).map(PathBuf::from).or_else(|| opts.cwd.clone()).or_else(|| std::env::current_dir().ok()).unwrap_or_default();
    let named: Vec<PathBuf> = if opts.paths.is_empty() { input.and_then(tool_path).map(PathBuf::from).into_iter().collect() } else { opts.paths.clone() };
    let mut repo: Option<Repo> = None;
    let mut files = vec![];
    for p in named {
        let abs = if p.is_absolute() { p } else { cwd.join(p) };
        // A file that is not there (never written, or removed since) has nothing to compare.
        let Ok(file) = std::fs::canonicalize(&abs) else { continue };
        if !file.is_file() {
            continue;
        }
        let Some(found) = find_repo(&file) else { continue };
        // One request is about one repository: files of another are left out.
        let repo = repo.get_or_insert(found.clone());
        if repo.root != found.root {
            continue;
        }
        let Some(path) = repo.relative(&file) else { continue };
        let state = match blob_hash(repo, &file).await {
            Some(hash) => FileState::present(path, hash),
            // Unreadable or too large to hash: looked up, nothing recorded about it.
            None => FileState { path, ..Default::default() },
        };
        if !files.iter().any(|f: &FileState| f.path == state.path) {
            files.push(state);
        }
    }
    let Some(repo) = repo.filter(|_| !files.is_empty()) else { return Ok(None) };
    let subject = opts.subject.clone().unwrap_or_else(|| repo.subject());
    let paths = files.iter().map(|f| f.path.clone()).collect();
    let request = FileTouchedRequest {
        subject: Some(subject.clone()),
        event: if event == HookEvent::FileOpened { FileEvent::Opened } else { FileEvent::Edited },
        files,
        query: opts.query.clone(),
        ..Default::default()
    };
    Ok(Some(Touched { request, subject, paths, hook_event_name: input.and_then(|i| i["hook_event_name"].as_str()).map(String::from) }))
}

/// The content hash of a file as git would store it, or `None` for a file that can't be read
/// or is larger than [`MAX_HASHED_BYTES`].
///
/// git is asked when it is installed (`git hash-object`): it applies the repository's
/// conversions (line endings under `core.autocrlf`, clean filters such as Git LFS), so the
/// hash is the one a commit of the file records and the post-commit hook reports. Without a
/// git binary the hash is computed here from the bytes on disk, which is the same hash
/// wherever git stores the file as it is.
pub async fn blob_hash(repo: &Repo, file: &Path) -> Option<String> {
    use std::io::Read;
    if std::fs::metadata(file).ok()?.len() > MAX_HASHED_BYTES {
        return None;
    }
    if let Ok(out) = git(&repo.root, &[std::ffi::OsStr::new("hash-object"), std::ffi::OsStr::new("--"), file.as_os_str()]).await {
        let hash = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if out.status.success() && hash.len() >= 40 && hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Some(hash);
        }
    }
    // No more than the limit is ever read, also when the file grew after its size was taken.
    let mut bytes = Vec::new();
    std::fs::File::open(file).ok()?.take(MAX_HASHED_BYTES + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_HASHED_BYTES).then(|| git_blob_hash(&bytes, repo.objects))
}

/// Run git in a repository. The process is killed when the future is dropped, so a hook's
/// deadline also ends a git that hangs; and it acts on the repository named, not on one a
/// calling git hook points at.
pub async fn git<S: AsRef<std::ffi::OsStr>>(root: &Path, args: &[S]) -> anyhow::Result<std::process::Output> {
    let mut git = tokio::process::Command::new("git");
    for name in GIT_REPOSITORY_ENV {
        git.env_remove(name);
    }
    Ok(git.arg("-C").arg(root).args(args).stdin(std::process::Stdio::null()).kill_on_drop(true).output().await?)
}

/// The answer of `POST /v1/code/touched` as the harness takes it.
pub fn touched_output(format: Format, asked: &Touched, response: &Value) -> anyhow::Result<String> {
    if format == Format::Json {
        return Ok(response.to_string());
    }
    let result: FileTouchedResult = serde_json::from_value(response.clone())?;
    let mut text = touched_text(&asked.subject, &asked.paths, &result);
    if text.chars().count() > MAX_CONTEXT_CHARS {
        // Cut between lines, and say so: the rest is one tool call away.
        let mut kept = String::new();
        for line in text.lines() {
            if kept.chars().count() + line.chars().count() + 1 > MAX_CONTEXT_CHARS - 120 {
                break;
            }
            kept.push_str(line);
            kept.push('\n');
        }
        text = format!("{kept}(more memories are linked to this file: call the MemHouse tool file_memories for all of them)");
    }
    if text.is_empty() {
        return Ok(format.nothing().to_string());
    }
    Ok(match format {
        Format::Text => text,
        _ => json!({ "hookSpecificOutput": { "hookEventName": asked.hook_event_name.clone().unwrap_or_else(|| format.default_event().into()), "additionalContext": text } })
            .to_string(),
    })
}

/// One record of `git diff --raw -z`: `:<mode> <mode> <hash> <hash> <status>` then one path,
/// or two for a rename or a copy. Submodule entries (mode 160000) are skipped: their hash is
/// a commit, not a file's content.
pub fn parse_raw_diff(raw: &[u8]) -> Vec<FileState> {
    let mut parts = raw.split(|b| *b == 0).map(|p| String::from_utf8_lossy(p).into_owned());
    let mut out = vec![];
    while let Some(head) = parts.next() {
        let Some(head) = head.strip_prefix(':') else { continue };
        let f: Vec<&str> = head.split(' ').collect();
        let (Some(new_mode), Some(new_hash), Some(status)) = (f.get(1), f.get(3), f.get(4)) else { continue };
        let Some(first) = parts.next() else { break };
        let second = if status.starts_with('R') || status.starts_with('C') { parts.next() } else { None };
        if *new_mode == "160000" || f.first() == Some(&"160000") {
            continue;
        }
        let state = match (status.chars().next(), second) {
            (Some('D'), _) => FileState::deleted(first),
            (Some('R'), Some(to)) => FileState::renamed(first, to, *new_hash),
            (Some('C'), Some(to)) => FileState::present(to, *new_hash),
            (Some('A' | 'M' | 'T'), _) => FileState::present(first, *new_hash),
            _ => continue,
        };
        out.push(state);
    }
    out
}

/// The files a commit changed, deleted or renamed, from git (`git diff --raw`): `to` against
/// `from`, or against its first parent, or everything it holds when it has none. Runs the git
/// binary, which a post-commit hook has by definition.
pub async fn commit_files(repo: &Repo, from: Option<&str>, to: &str) -> anyhow::Result<(String, Vec<FileState>)> {
    let sha = String::from_utf8_lossy(&git(&repo.root, &["rev-parse", "--verify", "-q", to]).await?.stdout).trim().to_string();
    anyhow::ensure!(!sha.is_empty(), "git knows no commit {to} in {}", repo.root.display());
    let parent = format!("{sha}^");
    let out = match from {
        Some(f) => git(&repo.root, &["diff", "--raw", "-z", "-M", "--no-abbrev", f, &sha]).await?,
        None if git(&repo.root, &["rev-parse", "--verify", "-q", &parent]).await?.status.success() => {
            git(&repo.root, &["diff", "--raw", "-z", "-M", "--no-abbrev", &parent, &sha]).await?
        }
        None => git(&repo.root, &["diff-tree", "--root", "-r", "--raw", "-z", "-M", "--no-abbrev", "--no-commit-id", &sha]).await?,
    };
    anyhow::ensure!(out.status.success(), "git diff failed: {}", String::from_utf8_lossy(&out.stderr).trim());
    Ok((sha, parse_raw_diff(&out.stdout)))
}

/// The API requests for a commit's files, at most `MAX_FILES` in each.
pub fn changed_requests(subject: &str, reason: &str, files: &[FileState]) -> Vec<FilesChangedRequest> {
    files.chunks(MAX_FILES).map(|c| FilesChangedRequest { subject: Some(subject.to_string()), files: c.to_vec(), reason: Some(reason.to_string()), ..Default::default() }).collect()
}

/// How a hook reaches the API: over HTTP to a running server, or in process through
/// [`crate::Embedded`]. Either way the request is one the server authenticates and decides.
#[async_trait::async_trait]
pub trait Transport: Send + Sync {
    /// `POST path` with a JSON body; the status and the response body.
    async fn post(&self, path: &str, body: &Value) -> anyhow::Result<(u16, Value)>;
}

/// The API called in this process, with the hook's own credential on every request.
pub struct InProcess {
    pub api: crate::Embedded,
    pub key: String,
}

#[async_trait::async_trait]
impl Transport for InProcess {
    async fn post(&self, path: &str, body: &Value) -> anyhow::Result<(u16, Value)> {
        let headers = [("authorization".to_string(), format!("Bearer {}", self.key))];
        let (status, bytes) = self.api.request("POST", path, &headers, Some(body.to_string().as_bytes())).await?;
        Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
    }
}

async fn ask(api: &dyn Transport, path: &str, body: &Value) -> anyhow::Result<Value> {
    let (status, answer) = api.post(path, body).await?;
    anyhow::ensure!(status == 200, "MemHouse answered {status}: {}", answer["error"].as_str().unwrap_or("no message"));
    Ok(answer)
}

/// A file hook, start to finish: the request from the harness's input, the API call, the
/// answer in the harness's form. Errors are the caller's to swallow ([`fail_open`]).
pub async fn run_touched(api: &dyn Transport, event: HookEvent, input: Option<&Value>, opts: &HookOpts, format: Format) -> anyhow::Result<String> {
    let Some(asked) = touched(event, input, opts).await? else { return Ok(format.nothing().to_string()) };
    run_asked(api, &asked, format).await
}

/// The API call and the answer for a request already built ([`touched`]).
pub async fn run_asked(api: &dyn Transport, asked: &Touched, format: Format) -> anyhow::Result<String> {
    let answer = ask(api, "/v1/code/touched", &serde_json::to_value(&asked.request)?).await?;
    touched_output(format, asked, &answer)
}

/// The post-commit hook: report the commit's files, and say what was flagged.
///
/// Every batch is attempted. A file the API would refuse (a path over its limit) is left out
/// of its batch instead of failing it, and a batch that fails does not stop the ones after
/// it: the error then names the commit and what was not reported, after the rest was.
pub async fn run_post_commit(api: &dyn Transport, repo: &Repo, subject: Option<&str>, from: Option<&str>, to: &str) -> anyhow::Result<String> {
    let (sha, files) = commit_files(repo, from, to).await?;
    let subject = subject.map(String::from).unwrap_or_else(|| repo.subject());
    report_commit(api, &subject, &sha, files).await
}

/// Report a commit's files (see [`run_post_commit`]).
pub async fn report_commit(api: &dyn Transport, subject: &str, sha: &str, files: Vec<FileState>) -> anyhow::Result<String> {
    let (valid, refused): (Vec<FileState>, Vec<FileState>) = files.into_iter().partition(|f| memhouse_core::staleness::observed_files(std::slice::from_ref(f)).is_ok());
    // Per memory, over all batches: whether it was stale before the first change reported
    // for it and whether it is after the last. A memory one batch flags and a later one
    // clears is neither.
    let mut net: std::collections::BTreeMap<String, (bool, bool)> = Default::default();
    let mut failed: Vec<String> = vec![];
    let batches = changed_requests(subject, &format!("commit {sha}"), &valid);
    let n = batches.len();
    for (i, req) in batches.into_iter().enumerate() {
        match ask(api, "/v1/code/changed", &serde_json::to_value(&req)?).await {
            Ok(answer) => {
                for c in answer["changes"].as_array().into_iter().flatten() {
                    let (Some(id), was, is) = (c["id"].as_str(), c["was_stale"].as_bool().unwrap_or(false), c["stale"].as_bool().unwrap_or(false)) else { continue };
                    net.entry(id.to_string()).and_modify(|e| e.1 = is).or_insert((was, is));
                }
            }
            Err(e) => failed.push(format!("batch {} of {n} ({} files): {e:#}", i + 1, req.files.len())),
        }
    }
    let flagged = net.values().filter(|(was, is)| !was && *is).count();
    let cleared = net.values().filter(|(was, is)| *was && !is).count();
    let said = match (flagged, cleared) {
        (0, 0) => String::new(),
        _ => format!("memhouse: {flagged} memories about files of this commit need revalidation, {cleared} are current again ({subject})"),
    };
    if failed.is_empty() && refused.is_empty() {
        return Ok(said);
    }
    let mut what = failed;
    if !refused.is_empty() {
        what.push(format!("{} file(s) the API does not accept were left out (a path over {MAX_PATH_LEN} characters, or outside the repository)", refused.len()));
    }
    anyhow::bail!("commit {sha} was not fully reported for {subject}: {}{}", what.join("; "), if said.is_empty() { String::new() } else { format!(". Reported: {said}") })
}

/// A hook never fails its caller: an error becomes the format's empty answer on stdout and
/// one line for stderr. The command that prints them exits 0 either way, so a read, an edit
/// or a commit goes on whether MemHouse answered or not.
pub fn fail_open(result: anyhow::Result<String>, format: Format) -> (String, Option<String>) {
    match result {
        Ok(out) => (out, None),
        Err(e) => (format.nothing().to_string(), Some(format!("memhouse hook: {e:#} (nothing was added; the hook does not block)"))),
    }
}

/// The environment variables by which git is told which repository to act on. A git hook runs
/// with them set, and a git started from it with `-C <dir>` would still act on the hook's
/// repository, so they are removed from every git this module and the CLI start.
pub const GIT_REPOSITORY_ENV: [&str; 8] =
    ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_diff_records() {
        let (a, b, z) = ("a".repeat(40), "b".repeat(40), "0".repeat(40));
        let raw = format!(
            ":100644 100644 {a} {b} M\0src/changed.rs\0:100644 000000 {a} {z} D\0src/gone.rs\0:100644 100644 {a} {b} R087\0src/old.rs\0src/new.rs\0:000000 100644 {z} {b} A\0src/added.rs\0:160000 160000 {a} {b} M\0vendor/sub\0"
        );
        assert_eq!(
            parse_raw_diff(raw.as_bytes()),
            vec![
                FileState::present("src/changed.rs", &b),
                FileState::deleted("src/gone.rs"),
                FileState::renamed("src/old.rs", "src/new.rs", &b),
                FileState::present("src/added.rs", &b)
            ]
        );
        assert!(parse_raw_diff(b"").is_empty());
    }

    /// Answers every batch but the second, and counts what it was sent.
    struct SecondFails(std::sync::Mutex<Vec<usize>>);

    #[async_trait::async_trait]
    impl Transport for SecondFails {
        async fn post(&self, _path: &str, body: &Value) -> anyhow::Result<(u16, Value)> {
            let mut seen = self.0.lock().unwrap();
            seen.push(body["files"].as_array().map(|f| f.len()).unwrap_or(0));
            // The first batch flags two memories; the third clears one of them again.
            Ok(match seen.len() {
                2 => (503, json!({"error": "try again"})),
                3 => (200, json!({"flagged": 0, "cleared": 1, "changes": [{"id": "m1", "path": "a.rs", "cleared": true, "stale": false, "was_stale": true}]})),
                _ => (
                    200,
                    json!({"flagged": 2, "cleared": 0, "changes": [{"id": "m1", "path": "a.rs", "flagged": true, "stale": true}, {"id": "m2", "path": "b.rs", "flagged": true, "stale": true}]}),
                ),
            })
        }
    }

    #[tokio::test]
    async fn a_failed_batch_does_not_stop_the_ones_after_it() {
        let mut files: Vec<FileState> = (0..2 * MAX_FILES + 5).map(|i| FileState::present(format!("src/f{i}.rs"), "h")).collect();
        // One path the API would refuse: left out, not sent, and named in the error.
        files.push(FileState::present("x".repeat(MAX_PATH_LEN + 1), "h"));
        let api = SecondFails(Default::default());
        let e = report_commit(&api, "repo:big", "abc123", files).await.unwrap_err().to_string();
        assert_eq!(*api.0.lock().unwrap(), vec![MAX_FILES, MAX_FILES, 5], "every batch is attempted, without the refused file");
        assert!(
            e.contains("commit abc123") && e.contains("batch 2 of 3") && e.contains("503") && e.contains("1 file(s) the API does not accept")
                // Net over the batches: one memory flagged and cleared again is neither.
                && e.contains("1 memories about files of this commit need revalidation, 0 are current again"),
            "{e}"
        );
        // Nothing refused and nothing failed: the plain summary.
        let ok = report_commit(&SecondFails(Default::default()), "repo:big", "abc123", vec![FileState::present("a.rs", "h")]).await.unwrap();
        assert!(ok.contains("2 memories"), "{ok}");
    }

    #[test]
    fn the_file_of_a_tool_call() {
        // Claude Code, PostToolUse of Read; Gemini CLI, AfterTool of read_file.
        let claude = json!({"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": {"file_path": "/repo/src/a.rs"}});
        let gemini = json!({"hook_event_name": "AfterTool", "tool_name": "read_file", "tool_input": {"file_path": "src/a.rs"}});
        assert_eq!(tool_path(&claude).as_deref(), Some("/repo/src/a.rs"));
        assert_eq!(tool_path(&gemini).as_deref(), Some("src/a.rs"));
        assert_eq!(tool_path(&json!({"tool_name": "Bash", "tool_input": {"command": "ls"}})), None);
    }

    #[tokio::test]
    async fn a_repository_is_found_without_git() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("widgets");
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("src/deep")).unwrap();
        std::fs::write(root.join("src/deep/a.rs"), b"hello\n").unwrap();
        let repo = find_repo(&root.join("src/deep/a.rs")).unwrap();
        assert_eq!((repo.name.as_str(), repo.subject().as_str(), repo.objects), ("widgets", "repo:widgets", ObjectFormat::Sha1));
        assert_eq!(repo.relative(&root.join("src/deep/a.rs")).as_deref(), Some("src/deep/a.rs"));
        assert_eq!(repo.relative(&root.join(".git/config")), None);
        // A linked worktree belongs to the repository its git directory names.
        let wt = dir.path().canonicalize().unwrap().join("elsewhere");
        std::fs::create_dir_all(root.join(".git/worktrees/elsewhere")).unwrap();
        std::fs::write(root.join(".git/worktrees/elsewhere/commondir"), "../..\n").unwrap();
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", root.join(".git/worktrees/elsewhere").display())).unwrap();
        std::fs::write(wt.join("b.rs"), b"x").unwrap();
        assert_eq!(find_repo(&wt.join("b.rs")).unwrap().name, "widgets");
        // A SHA-256 repository hashes with SHA-256.
        std::fs::write(root.join(".git/config"), "[extensions]\n\tobjectFormat = sha256\n").unwrap();
        assert_eq!(find_repo(&root).unwrap().objects, ObjectFormat::Sha256);
        // Outside any repository: nothing to ask.
        let lone = dir.path().join("lone.txt");
        std::fs::write(&lone, b"x").unwrap();
        let none = touched(HookEvent::FileOpened, Some(&json!({"tool_input": {"file_path": lone}})), &HookOpts::default()).await.unwrap();
        assert!(none.is_none() || !none.unwrap().subject.contains("widgets"));
    }

    #[tokio::test]
    async fn the_request_of_a_file_hook() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("widgets");
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/a.rs"), b"hello\n").unwrap();
        let input = json!({"hook_event_name": "PostToolUse", "cwd": root, "tool_name": "Edit", "tool_input": {"file_path": "src/a.rs", "old_string": "x", "new_string": "y"}});
        let asked = touched(HookEvent::FileEdited, Some(&input), &HookOpts::default()).await.unwrap().unwrap();
        assert_eq!(asked.request.subject.as_deref(), Some("repo:widgets"));
        assert_eq!(asked.request.event, FileEvent::Edited);
        // `printf 'hello\n' | git hash-object --stdin`.
        assert_eq!(asked.request.files, vec![FileState::present("src/a.rs", "ce013625030ba8dba906f756967f9e9ca394464a")]);
        let out = touched_output(Format::ClaudeCode, &asked, &json!({"memories": [], "needs_revalidation": []})).unwrap();
        assert_eq!(out, "");
        assert_eq!(touched_output(Format::Gemini, &asked, &json!({"memories": [], "needs_revalidation": []})).unwrap(), "{}");
        let (out, err) = fail_open(Err(anyhow::anyhow!("connection refused")), Format::Gemini);
        assert!(out == "{}" && err.unwrap().contains("connection refused"));
    }
}
