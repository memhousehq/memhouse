// SPDX-License-Identifier: Apache-2.0
//! Model Context Protocol server (JSON-RPC 2.0). The same handler serves stdio (for agents that
//! launch `memhouse mcp`) and streamable HTTP (`POST /mcp`). It only calls the engine (AP-2).
//!
//! API v1 tools (`remember`, `recall`, `revise`, `forget`, `ingest`, `list_memories`, INT-02) take
//! a subset of the REST request bodies, with input schemas generated from the same types, and
//! return the REST response as `structuredContent` plus a rendered text block (INT-04). The
//! pre-v1 names (`memory_recall`, ...) stay callable with their old behaviour until the sunset.

use memhouse_core::caller::Caller;
use memhouse_core::error;
use memhouse_core::types::*;
use schemars::generate::SchemaSettings;
use schemars::JsonSchema;
use serde_json::{json, Map, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

pub const PROTOCOL_VERSION: &str = "2025-06-18";
const SUPPORTED_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];

fn kinds_schema() -> Value {
    json!({"type": "string", "enum": MemoryKind::ALL.iter().map(|k| k.as_str()).collect::<Vec<_>>()})
}

/// Pre-v1 tool names and the v1 tool that replaces each.
pub const LEGACY_TOOLS: &[(&str, &str)] = &[
    ("memory_recall", "recall"),
    ("memory_remember", "remember"),
    ("memory_update", "revise"),
    ("memory_forget", "forget"),
    ("memory_log_conversation", "ingest"),
    ("memory_list", "list_memories"),
];

/// The inline JSON Schema of a type, cut to `props` and made friendly to tool-calling models
/// (no `null` alternatives, no numeric formats), with `required` as given.
fn input_schema<T: JsonSchema>(props: &[&str], required: &[&str], overrides: Value) -> Value {
    let root = inline_schema::<T>();
    let all = root.get("properties").and_then(Value::as_object).cloned().unwrap_or_default();
    let mut picked = Map::new();
    for p in props {
        let mut v = all.get(*p).cloned().unwrap_or_else(|| panic!("{} has no property {p}", std::any::type_name::<T>()));
        simplify(&mut v);
        if let Some(o) = overrides.get(*p).and_then(Value::as_object) {
            for (k, x) in o {
                v[k] = x.clone();
            }
        }
        picked.insert(p.to_string(), v);
    }
    json!({"type": "object", "properties": picked, "required": required})
}

/// The inline JSON Schema of a type, as the tool's `outputSchema`.
fn inline_schema<T: JsonSchema>() -> Value {
    let gen = SchemaSettings::draft2020_12()
        .with(|s| {
            s.inline_subschemas = true;
            s.meta_schema = None;
        })
        .into_generator();
    let mut v = serde_json::to_value(gen.into_root_schema_for::<T>()).expect("schema serializes");
    if let Some(o) = v.as_object_mut() {
        o.remove("title");
    }
    v
}

fn simplify(v: &mut Value) {
    if let Some(o) = v.as_object_mut() {
        if let Some(Value::Array(ts)) = o.get("type").cloned() {
            let rest: Vec<Value> = ts.into_iter().filter(|t| t != "null").collect();
            o.insert("type".into(), if rest.len() == 1 { rest[0].clone() } else { Value::Array(rest) });
        }
        if let Some(Value::Array(alts)) = o.get("anyOf").cloned() {
            let rest: Vec<Value> = alts.into_iter().filter(|a| a.get("type") != Some(&json!("null"))).collect();
            if rest.len() == 1 {
                o.remove("anyOf");
                if let Some(inner) = rest[0].as_object() {
                    for (k, x) in inner {
                        o.entry(k.clone()).or_insert_with(|| x.clone());
                    }
                }
            }
        }
        if o.get("format").and_then(Value::as_str).is_some_and(|f| !matches!(f, "date-time" | "uuid")) {
            o.remove("format");
        }
        for x in o.values_mut() {
            simplify(x);
        }
    } else if let Some(a) = v.as_array_mut() {
        for x in a {
            simplify(x);
        }
    }
}

const DATE_HINT: &str = "ISO-8601 date-time, or a date (2026-10-14).";

/// The API v1 tools.
pub fn tools() -> &'static Value {
    static TOOLS: std::sync::LazyLock<Value> = std::sync::LazyLock::new(build_tools);
    &TOOLS
}

fn build_tools() -> Value {
    let date = json!({"description": DATE_HINT});
    json!([
        {
            "name": "recall",
            "title": "Recall memories",
            "description": "Search long-term memory for anything relevant to a question or task. Call this before answering questions that may depend on earlier conversations, the user's preferences, or project knowledge. Returns the most relevant memories with ids, dates, kinds and provenance.",
            "inputSchema": input_schema::<RecallRequest>(&["query", "subject", "k", "kinds", "tags", "scope", "as_of", "token_budget", "include_candidates", "exact"], &["query"],
                json!({"k": {"minimum": 1, "maximum": 50, "description": "Number of memories to return (default 10)."}, "as_of": {"description": format!("Recall what was true at this time. {DATE_HINT}")}})),
            "outputSchema": inline_schema::<RecallResult>(),
            "annotations": {"readOnlyHint": true}
        },
        {
            "name": "remember",
            "title": "Remember",
            "description": "Store one durable memory: a fact, preference, procedure, decision or commitment worth knowing in future sessions. Write it so it stands alone (who, what, when). Don't store secrets or one-off chatter. Text that tries to instruct the agent reading it (prompt injection) is quarantined; plans and guesses are held until confirmed (store a to-do as kind commitment). Returns the new record's id at once, as a candidate; it is recallable within seconds.",
            "inputSchema": input_schema::<RememberRequest>(&["content", "kind", "subject", "tags", "occurred_at", "valid_to", "expires_at", "labels", "scope", "request_key", "wait"], &["content"],
                json!({"occurred_at": date, "valid_to": date, "expires_at": date})),
            "outputSchema": inline_schema::<RememberResult>()
        },
        {
            "name": "revise",
            "title": "Revise a memory",
            "description": "Replace a memory whose information changed or was wrong with a corrected version. The old version is kept for audit but is no longer recalled. Use this instead of storing a contradicting memory.",
            "inputSchema": input_schema::<ReviseRequest>(&["id", "content", "kind", "tags", "valid_to", "request_key", "wait"], &["id", "content"],
                json!({"id": {"description": "Id of the memory to revise (from recall)."}, "valid_to": date})),
            "outputSchema": inline_schema::<RememberResult>()
        },
        {
            "name": "forget",
            "title": "Forget",
            "description": "Permanently delete memories, for example when the user asks you to forget something: one memory by id, or everything about a subject, a user, an agent or a source. Name exactly one. Use dry_run to see how many would go.",
            "inputSchema": input_schema::<ForgetRequest>(&["id", "subject", "user", "agent", "source", "dry_run", "request_key"], &[], json!({})),
            "outputSchema": inline_schema::<ForgetResult>(),
            "annotations": {"destructiveHint": true}
        },
        {
            "name": "ingest",
            "title": "Save conversation",
            "description": "Save conversation turns as episodic memory so they can be recalled later, e.g. at the end of a session.",
            "inputSchema": input_schema::<IngestRequest>(&["messages", "session_id", "session_time", "subject", "request_key", "wait"], &["messages"], json!({"session_time": date})),
            "outputSchema": inline_schema::<IngestResult>()
        },
        {
            "name": "list_memories",
            "title": "List recent memories",
            "description": "List the most recent memories of a subject, newest first. Pass next_cursor back as cursor for more.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "subject": {"type": "string", "description": "Whose memories; defaults to the configured subject."},
                    "kinds": {"type": "array", "items": kinds_schema(), "description": "Only these kinds."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20."},
                    "cursor": {"type": "string", "description": "next_cursor of the previous call."}
                }
            },
            "outputSchema": inline_schema::<MemoryPage>(),
            "annotations": {"readOnlyHint": true}
        }
    ])
}

/// Arguments of a v1 tool as its REST request: only the tool's own properties are read, and
/// dates may be given without a time.
fn request<T: serde::de::DeserializeOwned>(name: &str, args: &Value) -> anyhow::Result<T> {
    let tool = tools().as_array().and_then(|ts| ts.iter().find(|t| t["name"] == name).cloned()).expect("v1 tool");
    let allowed = tool["inputSchema"]["properties"].as_object().cloned().unwrap_or_default();
    let mut picked = Map::new();
    for (k, v) in args.as_object().into_iter().flatten() {
        if allowed.contains_key(k) && !v.is_null() {
            let v = match v.as_str() {
                Some(d) if allowed[k].get("format") == Some(&json!("date-time")) && chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").is_ok() => json!(format!("{d}T00:00:00Z")),
                _ => v.clone(),
            };
            picked.insert(k.clone(), v);
        }
    }
    serde_json::from_value(Value::Object(picked)).map_err(|e| error::invalid(format!("{name}: {e}")))
}

async fn call_v1(c: &Caller, name: &str, args: &Value) -> anyhow::Result<Option<(String, Value)>> {
    Ok(Some(match name {
        "recall" => {
            let mut req: RecallRequest = request(name, args)?;
            req.render = true;
            let subject = req.subject.clone().unwrap_or_else(|| c.engine.cfg.memory.default_subject.clone());
            let mut r = c.recall(req).await?;
            let text = r.rendered.take().unwrap_or_else(|| memhouse_core::engine::render(&subject, &r.hits));
            (text, serde_json::to_value(&r)?)
        }
        "remember" => {
            let mut req: RememberRequest = request(name, args)?;
            req.source = Some("mcp".into());
            let r = c.remember(req).await?;
            (remembered_text(&r), serde_json::to_value(&r)?)
        }
        "revise" => {
            let req: ReviseRequest = request(name, args)?;
            let old = req.id;
            let r = c.revise(req).await?;
            let text = match (r.superseded, &r.note, r.status) {
                (Some(_), _, _) => format!("Revised: {} now replaces {old}", r.id),
                (None, Some(n), _) => format!("Not revised: {n} (id {})", r.id),
                (None, None, MemoryStatus::Candidate) => format!("Accepted: {} replaces {old} once the write gate has run", r.id),
                (None, None, s) => format!("Stored {} ({}); {old} was not superseded", r.id, s.as_str()),
            };
            (text, serde_json::to_value(&r)?)
        }
        "forget" => {
            let req: ForgetRequest = request(name, args)?;
            let r = c.forget(req).await?;
            let text = if r.dry_run {
                format!("Would delete {} memories ({} {})", r.deleted, r.scope.as_str(), r.value)
            } else {
                format!("Deleted {} memories ({} {})", r.deleted, r.scope.as_str(), r.value)
            };
            (text, serde_json::to_value(&r)?)
        }
        "ingest" => {
            let mut req: IngestRequest = request(name, args)?;
            req.source = Some("mcp".into());
            let r = c.ingest(req).await?;
            let text = if r.queued {
                format!("Accepted {} rounds ({} already stored); they are recallable once the write pipeline has stored them", r.ids.len(), r.deduplicated)
            } else {
                format!("Saved {} rounds ({} quarantined, {} already stored)", r.stored, r.quarantined, r.deduplicated)
            };
            (text, serde_json::to_value(&r)?)
        }
        "list_memories" => {
            let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(20).clamp(1, 100) as usize;
            let subject = arg_str(args, "subject").unwrap_or_else(|| c.engine.cfg.memory.default_subject.clone());
            let page = c.list(subject, arg_kinds(args, "kinds")?, false, limit, arg_str(args, "cursor").as_deref()).await?;
            let text = if page.items.is_empty() {
                "No memories yet.".into()
            } else {
                page.items.iter().map(|m| format!("- [{}] ({}, {}) {}", m.id, m.kind, m.created_at.format("%Y-%m-%d"), m.content.replace('\n', " "))).collect::<Vec<_>>().join("\n")
            };
            (text, serde_json::to_value(&page)?)
        }
        _ => return Ok(None),
    }))
}

fn remembered_text(r: &RememberResult) -> String {
    let redacted = if r.redactions.is_empty() { String::new() } else { format!("; redacted: {}", r.redactions.join(", ")) };
    match (&r.note, r.status) {
        (Some(n), _) => format!("{n} (id {})", r.id),
        // The default answer: queued, the write gate decides within seconds (CORE-02).
        (None, MemoryStatus::Candidate) => format!("Accepted (id {}, candidate until the write gate has run){redacted}", r.id),
        (None, _) => format!("Remembered (id {}){redacted}", r.id),
    }
}

/// The pre-v1 tools, listed only with `server.mcp_legacy_tools`.
pub fn legacy_tools() -> Value {
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

async fn call_tool(c: &Caller, name: &str, args: &Value) -> anyhow::Result<(String, Value)> {
    if let Some(done) = call_v1(c, name, args).await? {
        return Ok(done);
    }
    call_legacy(c, name, args).await
}

async fn call_legacy(c: &Caller, name: &str, args: &Value) -> anyhow::Result<(String, Value)> {
    match name {
        "memory_recall" => {
            let query = arg_str(args, "query").ok_or_else(|| anyhow::anyhow!("query is required"))?;
            let r = c
                .recall(RecallRequest {
                    subject: arg_str(args, "subject"),
                    query,
                    k: args.get("k").and_then(|v| v.as_u64()).map(|v| v as usize),
                    kinds: arg_kinds(args, "kinds")?,
                    tags: args.get("tags").map(|_| arg_tags(args)),
                    as_of: arg_time(args, "as_of")?,
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
            let r = c
                .remember(RememberRequest {
                    subject: arg_str(args, "subject"),
                    content,
                    kind,
                    tags: arg_tags(args),
                    occurred_at: arg_time(args, "occurred_at")?,
                    valid_to: arg_time(args, "valid_to")?,
                    source: Some("mcp".into()),
                    // The pre-v1 tool answered once the memory was stored; it still does.
                    wait: true,
                    ..Default::default()
                })
                .await?;
            Ok((remembered_text(&r), serde_json::to_value(&r)?))
        }
        "memory_update" => {
            let id = arg_str(args, "id").ok_or_else(|| anyhow::anyhow!("id is required"))?;
            let id = uuid::Uuid::parse_str(&id).map_err(|_| anyhow::anyhow!("id must be a memory id from memory_recall"))?;
            let content = arg_str(args, "content").ok_or_else(|| anyhow::anyhow!("content is required"))?;
            let r = c.revise(ReviseRequest { id, content, wait: true, ..Default::default() }).await?;
            Ok((format!("Updated: {} now replaces {}", r.id, id), serde_json::to_value(&r)?))
        }
        "memory_forget" => {
            let id = arg_str(args, "id").ok_or_else(|| anyhow::anyhow!("id is required"))?;
            let id = uuid::Uuid::parse_str(&id).map_err(|_| anyhow::anyhow!("id must be a memory id"))?;
            let ok = match c.forget(ForgetRequest { id: Some(id), ..Default::default() }).await {
                Ok(_) => true,
                Err(e) if error::code_of(&e) == error::ErrorCode::NotFound => false,
                Err(e) => return Err(e),
            };
            Ok((if ok { format!("Deleted {id}") } else { format!("No memory {id}") }, json!({ "deleted": ok })))
        }
        "memory_log_conversation" => {
            let messages: Vec<Message> = serde_json::from_value(args.get("messages").cloned().unwrap_or(json!([])))?;
            let r = c
                .ingest(IngestRequest {
                    subject: arg_str(args, "subject"),
                    session_id: arg_str(args, "session_id"),
                    messages,
                    source: Some("mcp".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?;
            Ok((format!("Saved {} rounds ({} quarantined, {} already stored)", r.stored, r.quarantined, r.deduplicated), serde_json::to_value(&r)?))
        }
        "memory_list" => {
            let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(20) as usize;
            let subject = arg_str(args, "subject").or_else(|| Some(c.engine.cfg.memory.default_subject.clone()));
            let ms = c.list_offset(subject, arg_kinds(args, "kinds")?, false, limit.clamp(1, 100), 0).await?;
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

/// Handle one JSON-RPC message from a verified caller. Returns `None` for notifications.
pub async fn handle(c: &Caller, msg: Value) -> Option<Value> {
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
                "instructions": memhouse_core::templates::guidance(&c.engine.cfg)
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => {
            let mut list = tools().as_array().cloned().unwrap_or_default();
            if c.engine.cfg.server.mcp_legacy_tools {
                list.extend(legacy_tools().as_array().cloned().unwrap_or_default());
            }
            Ok(json!({ "tools": list }))
        }
        "resources/list" => Ok(json!({ "resources": [] })),
        "resources/templates/list" => Ok(json!({ "resourceTemplates": [] })),
        "prompts/list" => Ok(json!({ "prompts": [] })),
        "tools/call" => {
            let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            match call_tool(c, name, &args).await {
                Ok((text, structured)) => Ok(json!({
                    "content": [{ "type": "text", "text": text }],
                    "structuredContent": structured,
                    "isError": false
                })),
                Err(e) => Ok(json!({ "content": [{ "type": "text", "text": format!("Error ({}): {e:#}", error::code_of(&e).as_str()) }], "isError": true })),
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
pub async fn serve_stdio(c: Caller) -> anyhow::Result<()> {
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
                    if let Some(r) = handle(&c, m).await {
                        out.push(r);
                    }
                }
                out
            }
            Ok(m) => handle(&c, m).await.into_iter().collect(),
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The v1 tools are the INT-02 names; their inputs are fields of the REST bodies, without
    /// `null` alternatives; every legacy name maps to a v1 tool.
    #[test]
    fn v1_tools_follow_the_rest_types() {
        let tools = tools().as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["recall", "remember", "revise", "forget", "ingest", "list_memories"]);
        for t in tools {
            assert_eq!(t["outputSchema"]["type"], "object", "{}", t["name"]);
            let text = t["inputSchema"].to_string();
            assert!(!text.contains("\"null\""), "{} input schema has a null alternative", t["name"]);
        }
        for (old, new) in LEGACY_TOOLS {
            assert!(names.contains(new), "{old} → {new}");
            assert!(legacy_tools().as_array().unwrap().iter().any(|t| t["name"] == *old));
        }
    }

    #[test]
    fn tool_arguments_are_read_as_requests() {
        let r: RecallRequest = request("recall", &json!({"query": "q", "as_of": "2026-10-14", "tenant": "other", "mode": "keyword"})).unwrap();
        assert_eq!(r.as_of.unwrap().to_rfc3339(), "2026-10-14T00:00:00+00:00");
        // Fields the tool doesn't offer are not read, whatever the model sends.
        assert!(r.tenant.is_none() && r.mode.is_none());
        let e = request::<RecallRequest>("recall", &json!({"k": 3})).unwrap_err();
        assert_eq!(error::code_of(&e), error::ErrorCode::InvalidRequest);
        let f: ForgetRequest = request("forget", &json!({"all": true, "confirm": "default", "user": "ana"})).unwrap();
        assert!(!f.all && f.user.as_deref() == Some("ana"));
    }
}
