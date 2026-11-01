//! Model Context Protocol server (JSON-RPC 2.0). The same handler serves stdio (for agents that
//! launch `memhouse mcp`) and streamable HTTP (`POST /mcp`). It only calls the engine (AP-2).

use memhouse_core::types::*;
use memhouse_core::Engine;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

pub const PROTOCOL_VERSION: &str = "2025-06-18";
const SUPPORTED_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];

fn kinds_schema() -> Value {
    json!({"type": "string", "enum": MemoryKind::ALL.iter().map(|k| k.as_str()).collect::<Vec<_>>()})
}

pub fn tools() -> Value {
    json!([
        {
            "name": "memory_recall",
            "title": "Recall memories",
            "description": "Search long-term memory for anything relevant to a question or task. Call this before answering questions that may depend on earlier conversations, the user's preferences, or project knowledge. Returns the most relevant memories with ids, dates and kinds.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "What you need to know, in natural language."},
                    "subject": {"type": "string", "description": "Whose memory to search (e.g. user:alice, customer:42, repo:api). Defaults to the configured subject."},
                    "k": {"type": "integer", "minimum": 1, "maximum": 50, "description": "Number of memories to return (default 10)."},
                    "kinds": {"type": "array", "items": kinds_schema(), "description": "Restrict to these kinds."},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "as_of": {"type": "string", "format": "date-time", "description": "Recall what was true at this time."}
                },
                "required": ["query"]
            },
            "annotations": {"readOnlyHint": true}
        },
        {
            "name": "memory_remember",
            "title": "Remember",
            "description": "Store one durable memory: a fact, preference, procedure, decision or commitment worth knowing in future sessions. Write it so it stands alone (who, what, when). Don't store secrets or one-off chatter. Instructions aimed at an agent are quarantined.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "The memory, self-contained, ideally one fact."},
                    "kind": kinds_schema(),
                    "subject": {"type": "string"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "occurred_at": {"type": "string", "format": "date-time", "description": "When it happened, if known."},
                    "valid_to": {"type": "string", "format": "date-time", "description": "When it stops being true (e.g. a due date or expiry)."}
                },
                "required": ["content"]
            }
        },
        {
            "name": "memory_update",
            "title": "Correct a memory",
            "description": "Replace a memory whose information changed or was wrong. The old version is kept for audit but is no longer recalled.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Id of the memory to replace (from memory_recall)."},
                    "content": {"type": "string", "description": "The corrected memory."}
                },
                "required": ["id", "content"]
            }
        },
        {
            "name": "memory_forget",
            "title": "Forget",
            "description": "Permanently delete a memory by id, for example when the user asks you to forget something.",
            "inputSchema": {
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"]
            },
            "annotations": {"destructiveHint": true}
        },
        {
            "name": "memory_log_conversation",
            "title": "Save conversation",
            "description": "Save conversation turns as episodic memory so they can be recalled later, e.g. at the end of a session.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "messages": {"type": "array", "items": {"type": "object", "properties": {"role": {"type": "string"}, "content": {"type": "string"}}, "required": ["role", "content"]}},
                    "session_id": {"type": "string"},
                    "subject": {"type": "string"}
                },
                "required": ["messages"]
            }
        },
        {
            "name": "memory_list",
            "title": "List recent memories",
            "description": "List the most recent memories for a subject.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "subject": {"type": "string"},
                    "kinds": {"type": "array", "items": kinds_schema()},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100}
                }
            },
            "annotations": {"readOnlyHint": true}
        }
    ])
}

fn fmt_hit(h: &Hit) -> String {
    let m = &h.memory;
    let when = m.occurred_at.map(|t| t.format("%Y-%m-%d").to_string()).unwrap_or_else(|| m.created_at.format("%Y-%m-%d").to_string());
    let tags = if m.tags.is_empty() { String::new() } else { format!(" #{}", m.tags.join(" #")) };
    format!("- [{}] ({}, {}{}) {}", m.id, m.kind, when, tags, m.content.replace('\n', "\n  "))
}

fn arg_str(args: &Value, k: &str) -> Option<String> {
    args.get(k).and_then(|v| v.as_str()).map(|s| s.to_string()).filter(|s| !s.is_empty())
}

fn arg_time(args: &Value, k: &str) -> anyhow::Result<Option<chrono::DateTime<chrono::Utc>>> {
    match arg_str(args, k) {
        None => Ok(None),
        Some(s) => {
            if let Ok(t) = chrono::DateTime::parse_from_rfc3339(&s) {
                return Ok(Some(t.with_timezone(&chrono::Utc)));
            }
            if let Ok(d) = chrono::NaiveDate::parse_from_str(&s, "%Y-%m-%d") {
                return Ok(Some(d.and_hms_opt(0, 0, 0).unwrap().and_utc()));
            }
            anyhow::bail!("{k}: expected an ISO-8601 date or date-time, got '{s}'")
        }
    }
}

fn arg_kinds(args: &Value, k: &str) -> anyhow::Result<Option<Vec<MemoryKind>>> {
    match args.get(k).and_then(|v| v.as_array()) {
        None => Ok(None),
        Some(a) => a.iter().map(|v| v.as_str().and_then(MemoryKind::parse).ok_or_else(|| anyhow::anyhow!("unknown kind {v}"))).collect::<anyhow::Result<Vec<_>>>().map(Some),
    }
}

fn arg_tags(args: &Value) -> Vec<String> {
    args.get("tags").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|t| t.as_str().map(String::from)).collect()).unwrap_or_default()
}

async fn call_tool(engine: &Engine, name: &str, args: &Value, actor: &str) -> anyhow::Result<(String, Value)> {
    let actor = Some(format!("mcp:{actor}"));
    match name {
        "memory_recall" => {
            let query = arg_str(args, "query").ok_or_else(|| anyhow::anyhow!("query is required"))?;
            let r = engine
                .recall(RecallRequest {
                    subject: arg_str(args, "subject"),
                    query,
                    k: args.get("k").and_then(|v| v.as_u64()).map(|v| v as usize),
                    kinds: arg_kinds(args, "kinds")?,
                    tags: args.get("tags").map(|_| arg_tags(args)),
                    as_of: arg_time(args, "as_of")?,
                    actor,
                    ..Default::default()
                })
                .await?;
            let text = if r.hits.is_empty() {
                "No relevant memories found.".to_string()
            } else {
                format!("{} memories (most relevant first):\n{}", r.hits.len(), r.hits.iter().map(fmt_hit).collect::<Vec<_>>().join("\n"))
            };
            let structured = json!({
                "memories": r.hits.iter().map(|h| json!({
                    "id": h.memory.id, "kind": h.memory.kind, "content": h.memory.content,
                    "occurred_at": h.memory.occurred_at, "tags": h.memory.tags, "score": h.score
                })).collect::<Vec<_>>()
            });
            Ok((text, structured))
        }
        "memory_remember" => {
            let content = arg_str(args, "content").ok_or_else(|| anyhow::anyhow!("content is required"))?;
            let kind = match arg_str(args, "kind") {
                Some(k) => Some(MemoryKind::parse(&k).ok_or_else(|| anyhow::anyhow!("unknown kind '{k}'"))?),
                None => None,
            };
            let r = engine
                .remember(RememberRequest {
                    subject: arg_str(args, "subject"),
                    content,
                    kind,
                    tags: arg_tags(args),
                    occurred_at: arg_time(args, "occurred_at")?,
                    valid_to: arg_time(args, "valid_to")?,
                    source: Some("mcp".into()),
                    actor,
                    ..Default::default()
                })
                .await?;
            let text = match (&r.note, r.deduplicated) {
                (Some(n), _) => format!("{n} (id {})", r.id),
                (None, _) => format!("Remembered (id {}){}", r.id, if r.redactions.is_empty() { String::new() } else { format!("; redacted: {}", r.redactions.join(", ")) }),
            };
            Ok((text, serde_json::to_value(&r)?))
        }
        "memory_update" => {
            let id = arg_str(args, "id").ok_or_else(|| anyhow::anyhow!("id is required"))?;
            let id = uuid::Uuid::parse_str(&id).map_err(|_| anyhow::anyhow!("id must be a memory id from memory_recall"))?;
            let content = arg_str(args, "content").ok_or_else(|| anyhow::anyhow!("content is required"))?;
            let r = engine.update(None, id, content, actor).await?;
            Ok((format!("Updated: {} now replaces {}", r.id, id), serde_json::to_value(&r)?))
        }
        "memory_forget" => {
            let id = arg_str(args, "id").ok_or_else(|| anyhow::anyhow!("id is required"))?;
            let id = uuid::Uuid::parse_str(&id).map_err(|_| anyhow::anyhow!("id must be a memory id"))?;
            let ok = engine.forget(None, id, actor).await?;
            Ok((if ok { format!("Deleted {id}") } else { format!("No memory {id}") }, json!({ "deleted": ok })))
        }
        "memory_log_conversation" => {
            let messages: Vec<Message> = serde_json::from_value(args.get("messages").cloned().unwrap_or(json!([])))?;
            let r = engine
                .ingest(IngestRequest {
                    subject: arg_str(args, "subject"),
                    session_id: arg_str(args, "session_id"),
                    messages,
                    source: Some("mcp".into()),
                    actor,
                    ..Default::default()
                })
                .await?;
            Ok((format!("Saved {} rounds ({} quarantined, {} already stored)", r.stored, r.quarantined, r.deduplicated), serde_json::to_value(&r)?))
        }
        "memory_list" => {
            let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(20) as usize;
            let subject = arg_str(args, "subject").or_else(|| Some(engine.cfg.memory.default_subject.clone()));
            let ms = engine.list(None, subject, arg_kinds(args, "kinds")?, limit, 0, false).await?;
            let text = if ms.is_empty() {
                "No memories yet.".into()
            } else {
                ms.iter().map(|m| format!("- [{}] ({}, {}) {}", m.id, m.kind, m.created_at.format("%Y-%m-%d"), m.content.replace('\n', " "))).collect::<Vec<_>>().join("\n")
            };
            Ok((text, json!({ "count": ms.len() })))
        }
        other => anyhow::bail!("unknown tool '{other}'"),
    }
}

/// Handle one JSON-RPC message. Returns `None` for notifications.
pub async fn handle(engine: &Engine, msg: Value, actor: &str) -> Option<Value> {
    let id = msg.get("id").cloned();
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = msg.get("params").cloned().unwrap_or(json!({}));
    let id = id?; // notifications (no id) get no response

    let result: Result<Value, (i64, String)> = match method {
        "initialize" => {
            let requested = params.get("protocolVersion").and_then(|v| v.as_str()).unwrap_or(PROTOCOL_VERSION);
            let version = if SUPPORTED_VERSIONS.contains(&requested) { requested } else { PROTOCOL_VERSION };
            Ok(json!({
                "protocolVersion": version,
                "capabilities": { "tools": { "listChanged": false } },
                "serverInfo": { "name": "memhouse", "title": "MemHouse memory", "version": env!("CARGO_PKG_VERSION") },
                "instructions": memhouse_core::templates::guidance(&engine.cfg)
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools() })),
        "resources/list" => Ok(json!({ "resources": [] })),
        "resources/templates/list" => Ok(json!({ "resourceTemplates": [] })),
        "prompts/list" => Ok(json!({ "prompts": [] })),
        "tools/call" => {
            let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            match call_tool(engine, name, &args, actor).await {
                Ok((text, structured)) => Ok(json!({
                    "content": [{ "type": "text", "text": text }],
                    "structuredContent": structured,
                    "isError": false
                })),
                Err(e) => Ok(json!({ "content": [{ "type": "text", "text": format!("Error: {e:#}") }], "isError": true })),
            }
        }
        _ => Err((-32601, format!("method not found: {method}"))),
    };
    Some(match result {
        Ok(r) => json!({ "jsonrpc": "2.0", "id": id, "result": r }),
        Err((code, message)) => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }),
    })
}

/// Serve MCP over stdin/stdout, one JSON message per line. Logs go to stderr.
pub async fn serve_stdio(engine: Engine, actor: String) -> anyhow::Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut stdout = tokio::io::stdout();
    let mut lines = stdin.lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let parsed: Result<Value, _> = serde_json::from_str(&line);
        let responses: Vec<Value> = match parsed {
            Ok(Value::Array(batch)) => {
                let mut out = vec![];
                for m in batch {
                    if let Some(r) = handle(&engine, m, &actor).await {
                        out.push(r);
                    }
                }
                out
            }
            Ok(m) => handle(&engine, m, &actor).await.into_iter().collect(),
            Err(e) => vec![json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": format!("parse error: {e}")}})],
        };
        for r in responses {
            stdout.write_all(serde_json::to_string(&r)?.as_bytes()).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
    }
    Ok(())
}
