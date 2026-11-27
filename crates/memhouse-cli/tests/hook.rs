// SPDX-License-Identifier: Apache-2.0
//! The harness hook commands end to end (TR-TPL-03): `memhouse hook file-opened`, `file-edited`
//! and `post-commit` run as a harness and git run them, fed the hook input each harness
//! documents, against a server on a throwaway Lite file. What is checked: the memories linked
//! to the file reach the harness in its own output form, an edit and a commit mark them stale,
//! and a hook that cannot reach MemHouse, or is refused by it, exits 0 and adds nothing.

use memhouse_conformance::fakes::HashEmbedder;
use memhouse_core::types::*;
use memhouse_core::{Config, Engine, Store};
use memhouse_store_sqlite::SqliteStore;
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::Arc;

const KEY: &str = "mh_hook_test_key"; // secret-scan: allow (fake fixture)

fn hook(home: &Path, args: &[&str], stdin: Option<&Value>) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_memhouse"))
        .args(args)
        .env("MEMHOUSE_HOME", home)
        .env_remove("MEMHOUSE_CONFIG")
        .env_remove("MEMHOUSE_URL")
        .env_remove("MEMHOUSE_HOOK_KEY")
        .env_remove("MEMHOUSE_MCP_KEY")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start memhouse");
    let mut pipe = child.stdin.take().unwrap();
    if let Some(v) = stdin {
        pipe.write_all(v.to_string().as_bytes()).unwrap();
    }
    drop(pipe);
    child.wait_with_output().expect("wait for memhouse")
}

fn text(out: &Output) -> (String, String) {
    (String::from_utf8_lossy(&out.stdout).trim().to_string(), String::from_utf8_lossy(&out.stderr).trim().to_string())
}

fn git(repo: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(repo).args(["-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

async fn serve(dir: &Path) -> (Engine, String) {
    let mut cfg = Config::default();
    memhouse_server::lite_defaults(&mut cfg, &dir.join("memhouse.db"));
    cfg.server.api_keys = vec![KEY.into()];
    cfg.embedding.dim = 64;
    let embedder = Arc::new(HashEmbedder::new(64));
    let store = Arc::new(SqliteStore::open(&dir.join("memhouse.db"), "").unwrap());
    store.migrate(64, &embedder.id).await.unwrap();
    let engine = Engine::new(store, embedder, None, cfg);
    engine.policy_for(&engine.cfg.memory.tenant).await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let router = memhouse_server::router(engine.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    (engine, url)
}

async fn recalled(engine: &Engine, id: uuid::Uuid) -> bool {
    let r =
        engine.recall(RecallRequest { subject: Some("repo:widgets".into()), query: "money amounts in the ledger are integer cents".into(), ..Default::default() }).await.unwrap();
    r.hits.iter().any(|h| h.memory.id == id)
}

#[tokio::test(flavor = "multi_thread")]
async fn the_hooks_of_two_harnesses_and_git() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let repo = home.join("widgets");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    // A real repository when git is installed (the post-commit hook needs it); the file hooks
    // need none, so without git a bare `.git` directory stands in and that part is skipped.
    let has_git = git(&repo, &["init", "-q"]).is_some();
    if !has_git {
        std::fs::create_dir_all(repo.join(".git")).unwrap();
    }
    let file = repo.join("src/ledger.rs");
    std::fs::write(&file, "pub struct Ledger;\n").unwrap();
    let hash = memhouse_core::staleness::git_blob_hash(b"pub struct Ledger;\n", Default::default());
    if has_git {
        // The hash computed in process is git's own.
        assert_eq!(git(&repo, &["hash-object", "src/ledger.rs"]).as_deref(), Some(hash.as_str()));
        git(&repo, &["add", "."]).unwrap();
        git(&repo, &["commit", "-q", "-m", "one"]).unwrap();
    }
    let (engine, url) = serve(&home).await;
    let key_file = home.join("agent.key");
    std::fs::write(&key_file, format!("{KEY}\n")).unwrap();
    let key_file = key_file.display().to_string();
    let stored = engine
        .remember(RememberRequest {
            subject: Some("repo:widgets".into()),
            content: "Money amounts in the ledger are integer cents, never floats.".into(),
            tags: vec!["convention".into()],
            code_refs: vec![CodeRef::new("src/ledger.rs", &hash)],
            wait: true,
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(stored.status, MemoryStatus::Committed, "{stored:?}");

    // Claude Code: PostToolUse of Read, as its hooks reference gives the input.
    let claude = json!({
        "session_id": "abc123", "transcript_path": "/tmp/transcript.jsonl", "cwd": repo, "permission_mode": "default",
        "hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": { "file_path": file },
        "tool_response": { "type": "text" }, "tool_use_id": "toolu_01", "duration_ms": 3
    });
    let out = hook(&home, &["hook", "file-opened", "--format", "claude-code", "--url", &url, "--key-file", &key_file], Some(&claude));
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "{stderr}");
    let answer: Value = serde_json::from_str(&stdout).unwrap_or_else(|e| panic!("not JSON ({e}): {stdout:?} / {stderr}"));
    assert_eq!(answer["hookSpecificOutput"]["hookEventName"], "PostToolUse", "{answer}");
    let context = answer["hookSpecificOutput"]["additionalContext"].as_str().unwrap();
    assert!(context.contains("integer cents") && context.contains("src/ledger.rs") && context.contains("repo:widgets"), "{context}");
    assert!(!context.contains("earlier version"), "{context}");

    // A tool call about no file, and a file outside any repository: nothing is asked or added.
    let bash = json!({ "hook_event_name": "PostToolUse", "cwd": repo, "tool_name": "Bash", "tool_input": { "command": "ls" } });
    let out = hook(&home, &["hook", "file-opened", "--url", &url, "--key-file", &key_file], Some(&bash));
    assert_eq!((out.status.success(), text(&out).0.as_str()), (true, ""));

    // Gemini CLI: AfterTool of replace, a path relative to the working directory, after the edit.
    std::fs::write(&file, "pub struct Ledger { cents: i64 }\n").unwrap();
    let gemini = json!({
        "session_id": "s1", "transcript_path": "/tmp/t.json", "cwd": repo, "hook_event_name": "AfterTool", "timestamp": "2026-11-27T10:00:00Z",
        "tool_name": "replace", "tool_input": { "file_path": "src/ledger.rs", "old_string": "pub struct Ledger;", "new_string": "pub struct Ledger { cents: i64 }" },
        "tool_response": { "llmContent": "ok", "returnDisplay": "ok" }
    });
    assert!(recalled(&engine, stored.id).await);
    let out = hook(&home, &["hook", "file-edited", "--format", "gemini", "--url", &url, "--key-file", &key_file], Some(&gemini));
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "{stderr}");
    let answer: Value = serde_json::from_str(&stdout).unwrap_or_else(|e| panic!("not JSON ({e}): {stdout:?} / {stderr}"));
    assert_eq!(answer["hookSpecificOutput"]["hookEventName"], "AfterTool", "{answer}");
    let context = answer["hookSpecificOutput"]["additionalContext"].as_str().unwrap();
    assert!(context.contains("earlier version") && context.contains("integer cents"), "{context}");
    // The edit made the memory stale: default recall leaves it out, and the audit log says why.
    assert!(!recalled(&engine, stored.id).await, "a stale memory was recalled");
    let audit = engine.store.audit_log(&engine.cfg.memory.tenant, 50).await.unwrap();
    assert!(audit.iter().any(|e| e.action == "memory.stale" && e.memory_id == Some(stored.id) && e.detail["why"]["event"] == "file.edited"), "{audit:?}");

    // Fail open: a server that is not there, and a key that is refused. Exit 0, nothing added.
    let out = hook(&home, &["hook", "file-opened", "--format", "gemini", "--url", "http://127.0.0.1:9", "--key-file", &key_file, "--timeout-ms", "3000"], Some(&gemini));
    let (stdout, stderr) = text(&out);
    assert_eq!((out.status.code(), stdout.as_str()), (Some(0), "{}"), "{stderr}");
    assert!(stderr.contains("memhouse hook:") && stderr.contains("does not block"), "{stderr}");
    let wrong = home.join("wrong.key");
    std::fs::write(&wrong, "mh_not_a_key\n").unwrap();
    let out = hook(&home, &["hook", "file-opened", "--url", &url, "--key-file", &wrong.display().to_string()], Some(&claude));
    let (stdout, stderr) = text(&out);
    assert_eq!((out.status.code(), stdout.as_str()), (Some(0), ""), "{stderr}");
    assert!(stderr.contains("401"), "{stderr}");
    // No key at all: the hook does not fall back to any other credential.
    let out = hook(&home, &["hook", "file-opened", "--url", &url], Some(&claude));
    assert_eq!((out.status.code(), text(&out).0.as_str()), (Some(0), ""));
    assert!(text(&out).1.contains("no API key"));
    // Input that is not what any harness sends: nothing happens, and nothing fails.
    let out = hook(&home, &["hook", "file-edited", "--url", &url, "--key-file", &key_file], Some(&json!(["not", "an", "object"])));
    assert_eq!((out.status.code(), text(&out).0.as_str()), (Some(0), ""));

    if !has_git {
        eprintln!("git is not installed: the post-commit part was not run");
        return;
    }
    // Revalidate, then commit the edit and a rename: the post-commit hook reports both.
    let m = engine.store.get(&engine.cfg.memory.tenant, stored.id).await.unwrap().unwrap();
    engine.revalidate(&engine.cfg.memory.tenant, &m, None, "test").await.unwrap();
    assert!(recalled(&engine, stored.id).await, "a revalidated memory was not recalled");
    git(&repo, &["commit", "-q", "-am", "two"]).unwrap();
    let out = hook(&home, &["hook", "post-commit", "--repo", &repo.display().to_string(), "--url", &url, "--key-file", &key_file], None);
    let (stdout, stderr) = text(&out);
    // The commit holds the content the memory was revalidated against: nothing to flag.
    assert_eq!((out.status.code(), stdout.as_str()), (Some(0), ""), "{stderr}");
    assert!(recalled(&engine, stored.id).await);
    git(&repo, &["mv", "src/ledger.rs", "src/book.rs"]).unwrap();
    std::fs::write(repo.join("src/book.rs"), "pub struct Ledger { cents: i64 }\n// moved\npub fn total() {}\n").unwrap();
    git(&repo, &["commit", "-q", "-am", "three"]).unwrap();
    let out = hook(&home, &["hook", "post-commit", "--repo", &repo.display().to_string(), "--url", &url, "--key-file", &key_file], None);
    let (stdout, stderr) = text(&out);
    assert!(out.status.success() && stdout.contains("1 memories") && stdout.contains("repo:widgets"), "{stdout} / {stderr}");
    assert!(!recalled(&engine, stored.id).await);
    // The reference followed the rename.
    let refs = engine.store.representations(&engine.cfg.memory.tenant, stored.id).await.unwrap().1;
    assert_eq!((refs.len(), refs[0].path.as_str(), refs[0].stale_since.is_some()), (1, "src/book.rs", true), "{refs:?}");

    // The installer writes the hook once, and leaves a hook that is not its own alone.
    let out = hook(&home, &["hook", "install-git", "--repo", &repo.display().to_string(), "--key-file", &key_file], None);
    assert!(out.status.success(), "{}", text(&out).1);
    let installed = std::fs::read_to_string(repo.join(".git/hooks/post-commit")).unwrap();
    assert!(installed.contains("hook post-commit") && installed.contains("|| true") && !installed.contains(KEY), "{installed}");
    std::fs::write(repo.join(".git/hooks/post-commit"), "#!/bin/sh\necho mine\n").unwrap();
    let out = hook(&home, &["hook", "install-git", "--repo", &repo.display().to_string(), "--key-file", &key_file], None);
    assert!(out.status.success() && text(&out).0.contains("left as it is"));
    assert_eq!(std::fs::read_to_string(repo.join(".git/hooks/post-commit")).unwrap(), "#!/bin/sh\necho mine\n");
}
