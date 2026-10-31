//! `memhouse connect <agent>`: write the agent's MCP configuration in one command (TR-TPL-04),
//! then verify that the configured command answers a real recall over MCP.

use anyhow::Context;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub struct Agent {
    pub name: &'static str,
    pub title: &'static str,
}

pub const AGENTS: &[Agent] = &[
    Agent { name: "claude-code", title: "Claude Code" },
    Agent { name: "claude-desktop", title: "Claude Desktop" },
    Agent { name: "cursor", title: "Cursor" },
    Agent { name: "vscode", title: "VS Code (GitHub Copilot agent mode)" },
    Agent { name: "windsurf", title: "Windsurf" },
    Agent { name: "codex", title: "OpenAI Codex CLI" },
    Agent { name: "gemini", title: "Gemini CLI" },
    Agent { name: "zed", title: "Zed" },
    Agent { name: "goose", title: "Goose" },
    Agent { name: "http", title: "Any MCP client over HTTP (OpenAI Agents SDK, LangGraph, n8n...)" },
];

pub struct Launch {
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl Launch {
    fn env_json(&self) -> Value {
        Value::Object(self.env.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect())
    }
    fn std_entry(&self) -> Value {
        let mut v = json!({ "command": self.command, "args": self.args });
        if !self.env.is_empty() {
            v["env"] = self.env_json();
        }
        v
    }
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

fn claude_desktop_path() -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Application Support/Claude/claude_desktop_config.json")
    } else if cfg!(target_os = "windows") {
        dirs::config_dir().unwrap_or_else(home).join("Claude/claude_desktop_config.json")
    } else {
        dirs::config_dir().unwrap_or_else(|| home().join(".config")).join("Claude/claude_desktop_config.json")
    }
}

/// Merge `entry` at `path_keys` into a JSON config file, keeping a backup. Refuses to touch
/// files it can't parse (e.g. JSON with comments) and prints the snippet instead.
fn merge_json(file: &Path, path_keys: &[&str], entry: Value) -> anyhow::Result<bool> {
    let mut root: Value = if file.exists() {
        let text = std::fs::read_to_string(file)?;
        if text.trim().is_empty() {
            json!({})
        } else {
            match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("! {} is not plain JSON ({e}); not modifying it. Add this yourself:", file.display());
                    let mut snippet = entry;
                    for k in path_keys.iter().rev() {
                        snippet = json!({ *k: snippet });
                    }
                    println!("{}", serde_json::to_string_pretty(&snippet)?);
                    return Ok(false);
                }
            }
        }
    } else {
        json!({})
    };
    {
        let mut cur = &mut root;
        for (i, k) in path_keys.iter().enumerate() {
            if !cur.is_object() {
                anyhow::bail!("{}: expected an object at {}", file.display(), path_keys[..i].join("."));
            }
            let last = i == path_keys.len() - 1;
            let obj = cur.as_object_mut().unwrap();
            if last {
                obj.insert(k.to_string(), entry.clone());
                break;
            }
            cur = obj.entry(k.to_string()).or_insert_with(|| json!({}));
        }
    }
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if file.exists() {
        let bak = file.with_extension(format!("{}.memhouse.bak", file.extension().and_then(|e| e.to_str()).unwrap_or("json")));
        std::fs::copy(file, &bak)?;
    }
    std::fs::write(file, serde_json::to_string_pretty(&root)? + "\n")?;
    Ok(true)
}

fn toml_str(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}

fn write_codex(launch: &Launch) -> anyhow::Result<PathBuf> {
    let file = home().join(".codex/config.toml");
    let existing = std::fs::read_to_string(&file).unwrap_or_default();
    let mut doc: toml::Table = if existing.trim().is_empty() { toml::Table::new() } else { existing.parse().context("parsing ~/.codex/config.toml")? };
    let servers = doc.entry("mcp_servers").or_insert_with(|| toml::Value::Table(Default::default()));
    let mut entry = toml::Table::new();
    entry.insert("command".into(), toml::Value::String(launch.command.clone()));
    entry.insert("args".into(), toml::Value::Array(launch.args.iter().cloned().map(toml::Value::String).collect()));
    if !launch.env.is_empty() {
        entry.insert("env".into(), toml::Value::Table(launch.env.iter().map(|(k, v)| (k.clone(), toml::Value::String(v.clone()))).collect()));
    }
    servers.as_table_mut().context("mcp_servers is not a table")?.insert("memhouse".into(), toml::Value::Table(entry));
    if let Some(d) = file.parent() {
        std::fs::create_dir_all(d)?;
    }
    if file.exists() {
        std::fs::copy(&file, file.with_extension("toml.memhouse.bak"))?;
    }
    std::fs::write(&file, toml::to_string_pretty(&doc)?)?;
    Ok(file)
}

pub struct ConnectOpts {
    pub agent: String,
    pub launch: Launch,
    pub print_only: bool,
    pub project: bool,
    pub http_url: String,
    pub api_key: Option<String>,
}

pub fn connect(o: &ConnectOpts) -> anyhow::Result<()> {
    let l = &o.launch;
    let print = |what: &str, v: Value| -> anyhow::Result<()> {
        println!("{what}:\n{}", serde_json::to_string_pretty(&v)?);
        Ok(())
    };
    match o.agent.as_str() {
        "claude-code" => {
            let scope = if o.project { "project" } else { "user" };
            let mut args = vec!["mcp".to_string(), "add".into(), "--scope".into(), scope.into()];
            for (k, v) in &l.env {
                args.push("-e".into());
                args.push(format!("{k}={v}"));
            }
            args.push("memhouse".into());
            args.push("--".into());
            args.push(l.command.clone());
            args.extend(l.args.iter().cloned());
            if o.print_only || which("claude").is_none() {
                if which("claude").is_none() && !o.print_only {
                    eprintln!("`claude` CLI not found on PATH; run this once it is installed:");
                }
                println!("claude {}", args.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" "));
                if o.project {
                    print("or add to .mcp.json", json!({"mcpServers": {"memhouse": l.std_entry()}}))?;
                }
                return Ok(());
            }
            let _ = Command::new("claude").args(["mcp", "remove", "--scope", scope, "memhouse"]).stdout(Stdio::null()).stderr(Stdio::null()).status();
            let st = Command::new("claude").args(&args).status().context("running `claude mcp add`")?;
            if !st.success() {
                anyhow::bail!("`claude mcp add` failed");
            }
            println!("✓ Claude Code: memhouse added ({scope} scope)");
        }
        "claude-desktop" => {
            let f = claude_desktop_path();
            if o.print_only {
                return print(&f.display().to_string(), json!({"mcpServers": {"memhouse": l.std_entry()}}));
            }
            if merge_json(&f, &["mcpServers", "memhouse"], l.std_entry())? {
                println!("✓ Claude Desktop: wrote {} (restart Claude Desktop to load it)", f.display());
            }
        }
        "cursor" => {
            let f = if o.project { PathBuf::from(".cursor/mcp.json") } else { home().join(".cursor/mcp.json") };
            if o.print_only {
                return print(&f.display().to_string(), json!({"mcpServers": {"memhouse": l.std_entry()}}));
            }
            if merge_json(&f, &["mcpServers", "memhouse"], l.std_entry())? {
                println!("✓ Cursor: wrote {}", f.display());
            }
        }
        "windsurf" => {
            let f = home().join(".codeium/windsurf/mcp_config.json");
            if o.print_only {
                return print(&f.display().to_string(), json!({"mcpServers": {"memhouse": l.std_entry()}}));
            }
            if merge_json(&f, &["mcpServers", "memhouse"], l.std_entry())? {
                println!("✓ Windsurf: wrote {}", f.display());
            }
        }
        "vscode" => {
            let f = PathBuf::from(".vscode/mcp.json");
            let mut e = l.std_entry();
            e["type"] = json!("stdio");
            if o.print_only {
                return print(&f.display().to_string(), json!({"servers": {"memhouse": e}}));
            }
            if merge_json(&f, &["servers", "memhouse"], e)? {
                println!("✓ VS Code: wrote {} in this workspace", f.display());
            }
        }
        "gemini" => {
            let f = if o.project { PathBuf::from(".gemini/settings.json") } else { home().join(".gemini/settings.json") };
            if o.print_only {
                return print(&f.display().to_string(), json!({"mcpServers": {"memhouse": l.std_entry()}}));
            }
            if merge_json(&f, &["mcpServers", "memhouse"], l.std_entry())? {
                println!("✓ Gemini CLI: wrote {}", f.display());
            }
        }
        "codex" => {
            if o.print_only {
                println!("~/.codex/config.toml:\n[mcp_servers.memhouse]\ncommand = {}\nargs = [{}]", toml_str(&l.command), l.args.iter().map(|a| toml_str(a)).collect::<Vec<_>>().join(", "));
                return Ok(());
            }
            let f = write_codex(l)?;
            println!("✓ Codex: wrote {}", f.display());
        }
        "zed" => {
            print(
                "Add to ~/.config/zed/settings.json",
                json!({"context_servers": {"memhouse": {"command": l.command, "args": l.args, "env": l.env_json()}}}),
            )?;
        }
        "goose" => {
            println!(
                "Add to ~/.config/goose/config.yaml:\nextensions:\n  memhouse:\n    type: stdio\n    enabled: true\n    cmd: {}\n    args: [{}]\n    timeout: 300",
                l.command,
                l.args.iter().map(|a| toml_str(a)).collect::<Vec<_>>().join(", ")
            );
        }
        "http" => {
            let key = o.api_key.clone().unwrap_or_else(|| "<api key from `memhouse key`>".into());
            println!("Start the server with `memhouse serve`, then point any MCP client at:\n");
            println!("  URL:     {}/mcp", o.http_url);
            println!("  Header:  Authorization: Bearer {key}\n");
            print(
                "Example (mcp.json style)",
                json!({"mcpServers": {"memhouse": {"type": "http", "url": format!("{}/mcp", o.http_url), "headers": {"Authorization": format!("Bearer {key}")}}}}),
            )?;
            println!("\nREST: POST {}/v1/recall  {{\"subject\":\"user:alice\",\"query\":\"...\"}}", o.http_url);
        }
        other => anyhow::bail!(
            "unknown agent '{other}'. Supported: {}",
            AGENTS.iter().map(|a| a.name).collect::<Vec<_>>().join(", ")
        ),
    }
    Ok(())
}

pub fn which(bin: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|p| p.join(bin)).find(|p| p.is_file())
}

fn shell_quote(s: &str) -> String {
    if s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:=@".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// Launch the configured MCP command exactly as an agent would and run a real recall through it.
pub fn verify(launch: &Launch) -> anyhow::Result<String> {
    let mut child = Command::new(&launch.command)
        .args(&launch.args)
        .envs(launch.env.iter().cloned())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("starting {}", launch.command))?;
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    let msgs = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"memhouse-verify","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_recall","arguments":{"query":"memhouse connection check","k":1}}}),
    ];
    for m in &msgs {
        writeln!(stdin, "{m}")?;
    }
    stdin.flush()?;
    let mut tools = 0;
    let mut recall_ok = false;
    let mut line = String::new();
    for _ in 0..3 {
        line.clear();
        if out.read_line(&mut line)? == 0 {
            break;
        }
        let v: Value = serde_json::from_str(&line).context("MCP server wrote a non-JSON line to stdout")?;
        match v["id"].as_i64() {
            Some(2) => tools = v["result"]["tools"].as_array().map(|a| a.len()).unwrap_or(0),
            Some(3) => {
                if v["result"]["isError"].as_bool() == Some(true) {
                    let msg = v["result"]["content"][0]["text"].as_str().unwrap_or("").to_string();
                    drop(stdin);
                    let _ = child.kill();
                    anyhow::bail!("recall over MCP failed: {msg}");
                }
                recall_ok = v["result"].is_object();
            }
            _ => {}
        }
    }
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    if tools == 0 || !recall_ok {
        anyhow::bail!("MCP handshake incomplete (tools: {tools}, recall: {recall_ok})");
    }
    Ok(format!("{tools} tools, recall OK"))
}
