// SPDX-License-Identifier: Apache-2.0
//! The OpenAPI 3.1 description of API v1, generated from the request and response types, plus
//! the two checks built on it: response validation for the contract tests, and the breaking-change
//! check that keeps v1 compatible (QUAL-09). Published at `/v1/openapi.json` and in `api/`.

use memhouse_core::error::ErrorBody;
use memhouse_core::types::*;
use schemars::generate::SchemaSettings;
use schemars::{JsonSchema, SchemaGenerator};
use serde_json::{json, Map, Value};

/// The API version, separate from the crate version. Minor and patch releases only add.
pub const API_VERSION: &str = "1.4.0";

/// Routes kept from before v1, with the route that replaces each. They answer as before and add
/// `Deprecation`, `Sunset` and `Link` headers; they are removed no earlier than [`SUNSET`].
pub struct Deprecated {
    pub method: &'static str,
    pub path: &'static str,
    pub successor: &'static str,
}

pub const DEPRECATED: &[Deprecated] = &[
    Deprecated { method: "POST", path: "/v1/memories", successor: "/v1/remember" },
    Deprecated { method: "GET", path: "/v1/memories", successor: "/v1/subjects/{subject}/memories" },
    Deprecated { method: "PATCH", path: "/v1/memories/{id}", successor: "/v1/revise" },
    Deprecated { method: "DELETE", path: "/v1/memories/{id}", successor: "/v1/forget" },
    Deprecated { method: "DELETE", path: "/v1/subjects/{subject}", successor: "/v1/forget" },
];

/// When the pre-v1 routes and MCP tool names were deprecated, and the earliest date they go.
pub const DEPRECATED_ON: &str = "2026-11-02";
pub const SUNSET: &str = "2027-11-02";

/// Health check body.
#[derive(serde::Serialize, JsonSchema)]
pub struct Health {
    pub status: String,
    /// The server version.
    pub version: String,
    /// The API version (`API_VERSION`).
    pub api_version: String,
}

/// A subject and its number of committed memories.
#[derive(serde::Serialize, JsonSchema)]
pub struct SubjectCount {
    pub subject: String,
    pub memories: i64,
}

/// The pre-v1 delete response.
#[derive(serde::Serialize, JsonSchema)]
pub struct LegacyDeleted {
    pub deleted: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum Stability {
    Stable,
    Preview,
    Deprecated,
}

struct Op {
    method: &'static str,
    path: &'static str,
    id: &'static str,
    summary: &'static str,
    description: &'static str,
    tag: &'static str,
    stability: Stability,
    body: Option<Value>,
    ok: Value,
    params: Vec<Value>,
    /// Takes `Idempotency-Key`.
    idempotent: bool,
    errors: &'static [u16],
    open: bool,
}

fn generator() -> SchemaGenerator {
    SchemaSettings::draft2020_12()
        .with(|s| {
            s.definitions_path = "/components/schemas".into();
            s.meta_schema = None;
        })
        .into_generator()
}

fn path_param(name: &str, description: &str) -> Value {
    json!({"name": name, "in": "path", "required": true, "description": description, "schema": {"type": "string"}})
}

fn query_param(name: &str, description: &str, schema: Value) -> Value {
    json!({"name": name, "in": "query", "required": false, "description": description, "schema": schema})
}

fn ops(g: &mut SchemaGenerator) -> Vec<Op> {
    let s = |v: schemars::Schema| serde_json::to_value(v).expect("schema serializes");
    let remember_req = s(g.subschema_for::<RememberRequest>());
    let remember_res = s(g.subschema_for::<RememberResult>());
    let recall_req = s(g.subschema_for::<RecallRequest>());
    let recall_res = s(g.subschema_for::<RecallResult>());
    let revise_req = s(g.subschema_for::<ReviseRequest>());
    let forget_req = s(g.subschema_for::<ForgetRequest>());
    let forget_res = s(g.subschema_for::<ForgetResult>());
    let ingest_req = s(g.subschema_for::<IngestRequest>());
    let ingest_res = s(g.subschema_for::<IngestResult>());
    let memory = s(g.subschema_for::<Memory>());
    let page = s(g.subschema_for::<MemoryPage>());
    let memories = s(g.subschema_for::<Vec<Memory>>());
    let health = s(g.subschema_for::<Health>());
    let subjects = s(g.subschema_for::<Vec<SubjectCount>>());
    let stats = s(g.subschema_for::<Stats>());
    let audit = s(g.subschema_for::<Vec<AuditEvent>>());
    let enrich = s(g.subschema_for::<EnrichStatus>());
    let legacy_deleted = s(g.subschema_for::<LegacyDeleted>());
    let relabel_req = s(g.subschema_for::<RelabelRequest>());
    let review_req = s(g.subschema_for::<ReviewRequest>());
    let review_res = s(g.subschema_for::<ReviewResult>());
    let token_req = s(g.subschema_for::<TokenRequest>());
    let token_res = s(g.subschema_for::<memhouse_core::identity::TokenResponse>());
    let whoami = s(g.subschema_for::<WhoAmI>());
    let explanation = s(g.subschema_for::<RecallExplanation>());
    use memhouse_core::policy as pol;
    let policy_status = s(g.subschema_for::<pol::PolicyStatus>());
    let spec_req = s(g.subschema_for::<pol::PolicySpecRequest>());
    let spec_rec = s(g.subschema_for::<pol::PolicySpecRecord>());
    let validation = s(g.subschema_for::<pol::PolicyValidation>());
    let diff_req = s(g.subschema_for::<pol::PolicyDiffRequest>());
    let diff_res = s(g.subschema_for::<pol::PolicyDiff>());
    let compiled = s(g.subschema_for::<pol::CompiledPolicy>());
    let rollback_req = s(g.subschema_for::<pol::RollbackRequest>());
    s(g.subschema_for::<ErrorBody>());
    let id_param = || path_param("id", "A memory id.");
    let subject_param = || path_param("subject", "A subject, e.g. `customer:acme` (URL-encoded).");
    use Stability::*;
    vec![
        Op {
            method: "post",
            path: "/v1/remember",
            id: "remember",
            summary: "Propose a memory",
            description: "Runs the write gate (redaction, injection screen, deduplication) and returns the record's id and state at once. The state is `committed` or `quarantined` today and may be `candidate` from G10; read it with `GET /v1/memories/{id}`.",
            tag: "memory",
            stability: Stable,
            body: Some(remember_req.clone()),
            ok: remember_res.clone(),
            params: vec![],
            idempotent: true,
            errors: &[400, 401, 409, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/recall",
            id: "recall",
            summary: "Retrieve memories for a context",
            description: "Ranked memories of one subject with ids and provenance, filtered by scope, kind, tags and as-of time, cut to a token budget; with `render` also as a text block for a prompt.",
            tag: "memory",
            stability: Stable,
            body: Some(recall_req),
            ok: recall_res,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/revise",
            id: "revise",
            summary: "Supersede a memory with a new version",
            description: "The current version becomes `superseded` and stays for audit and as-of recall; the new version records `supersedes`. Revising a version that is not `committed` is a conflict.",
            tag: "memory",
            stability: Stable,
            body: Some(revise_req),
            ok: remember_res.clone(),
            params: vec![],
            idempotent: true,
            errors: &[400, 401, 404, 409, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/forget",
            id: "forget",
            summary: "Delete memories by record, subject, user, agent, source or tenant",
            description: "Permanent deletion with every derived representation (vectors, extracted facts, cached extractions) and a deletion-ledger row; one audit event per call.",
            tag: "memory",
            stability: Stable,
            body: Some(forget_req),
            ok: forget_res,
            params: vec![],
            idempotent: true,
            errors: &[400, 401, 404, 409, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/ingest",
            id: "ingest",
            summary: "Store a conversation as episodic memory",
            description: "One record per user/assistant round; queues background enrichment when it is on.",
            tag: "memory",
            stability: Stable,
            body: Some(ingest_req),
            ok: ingest_res,
            params: vec![],
            idempotent: true,
            errors: &[400, 401, 409, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/memories/{id}",
            id: "getMemory",
            summary: "Read one memory and its state",
            description: "Any state, including superseded and quarantined.",
            tag: "memory",
            stability: Stable,
            body: None,
            ok: memory.clone(),
            params: vec![id_param()],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/subjects/{subject}/memories",
            id: "listMemories",
            summary: "List a subject's memories, newest first",
            description: "Keyset-paged: pass `next_cursor` back as `cursor`.",
            tag: "memory",
            stability: Stable,
            body: None,
            ok: page,
            params: vec![
                subject_param(),
                query_param("kinds", "Comma-separated kinds.", json!({"type": "string"})),
                query_param("include_inactive", "Also superseded, quarantined, rejected and expired records.", json!({"type": "boolean"})),
                query_param("limit", "1 to 1000 (default 50).", json!({"type": "integer", "minimum": 1, "maximum": 1000})),
                query_param("cursor", "`next_cursor` of the previous page.", json!({"type": "string"})),
            ],
            idempotent: false,
            errors: &[400, 401, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/labels",
            id: "relabel",
            summary: "Set a memory's sensitivity labels",
            description: "Replaces the labels of the current record: no new version, no re-embedding (ACC-04). Needs `memory:label`; labels denied to the caller can't be set.",
            tag: "memory",
            stability: Stable,
            body: Some(relabel_req),
            ok: memory.clone(),
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/review",
            id: "review",
            summary: "Commit or reject a candidate",
            description: "For proposals that wait for review (`access.admission = \"review\"`). Needs `memory:review`. A revision whose predecessor is no longer current is rejected instead of committed.",
            tag: "memory",
            stability: Stable,
            body: Some(review_req),
            ok: review_res,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 404, 409, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/tokens",
            id: "issueToken",
            summary: "Issue a short-lived agent token",
            description: "A signed token for an agent principal, with the verified user it acts for and narrower permissions; at most an hour (GOV-13). Revoking the issuing key revokes it. Needs `token:issue`.",
            tag: "identity",
            stability: Stable,
            body: Some(token_req),
            ok: token_res,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/whoami",
            id: "whoami",
            summary: "The verified identity of this credential",
            description: "Principal, tenant, acting user, permissions, subjects and denied labels; needs no permission.",
            tag: "identity",
            stability: Stable,
            body: None,
            ok: whoami,
            params: vec![],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/recalls/{id}/explanation",
            id: "explainRecall",
            summary: "Why a recall returned what it did",
            description: "The returned records with their ranking signals, and the records that matched but were left out, each with its reason: status, access, label, validity, filter, budget or rank (GOV-04). For the principal that recalled, or any principal with `audit:read`; others get 404. Records excluded for status, access or labels are listed by id only to `audit:read`, otherwise counted in `hidden`. The id is `recall_id` of the recall's response.",
            tag: "memory",
            stability: Stable,
            body: None,
            ok: explanation,
            params: vec![path_param("id", "A recall id (`recall_id`).")],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/metrics",
            id: "metrics",
            summary: "Prometheus metrics",
            description: "Text exposition format 0.0.4; needs `ops:read` (Prometheus: `authorization: {credentials: <key>}`). Request counts and latency by route, operation counts and latency, recall latency per stage and statements per recall, writes by state, refused calls, enrichment queue, lag, tokens and spend. Labels hold no subjects, users or content.",
            tag: "operations",
            stability: Preview,
            body: None,
            ok: json!({"type": "string"}),
            params: vec![],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/subjects",
            id: "listSubjects",
            summary: "Subjects with committed memories (up to 500)",
            description: "Preview: paging and per-principal filtering arrive with G06 and G20.",
            tag: "operations",
            stability: Preview,
            body: None,
            ok: subjects,
            params: vec![],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/stats",
            id: "stats",
            summary: "Counts for the configured tenant",
            description: "Preview.",
            tag: "operations",
            stability: Preview,
            body: None,
            ok: stats,
            params: vec![],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/policies",
            id: "policies",
            summary: "The tenant's policy: running, versions and history",
            description: "The compiled policy that runs now, every spec version with its status, proposer and approver, and the activations, newest first (POL-08). Needs `policy:read`.",
            tag: "policy",
            stability: Stable,
            body: None,
            ok: policy_status,
            params: vec![],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/policies",
            id: "proposePolicy",
            summary: "Propose a policy spec",
            description: "Stores the spec as the tenant's next version, `proposed`; it runs only once approved (POL-03). A spec that would loosen governance, or is otherwise invalid, is refused with every problem listed and the refusal is audited (POL-04). Needs `policy:propose`.",
            tag: "policy",
            stability: Stable,
            body: Some(spec_req.clone()),
            ok: spec_rec,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/policies/validate",
            id: "validatePolicy",
            summary: "Compile a spec without storing it",
            description: "Whether the spec compiles for the caller's tenant under its governance, and the compiled policy or the violations. Needs `policy:read`.",
            tag: "policy",
            stability: Stable,
            body: Some(spec_req),
            ok: validation,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/policies/diff",
            id: "diffPolicies",
            summary: "Compare two policies",
            description: "The settings that differ between two compiled policies: the running one, the default, a stored version or an unstored spec. Needs `policy:read`.",
            tag: "policy",
            stability: Stable,
            body: Some(diff_req),
            ok: diff_res,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/policies/{version}/approve",
            id: "approvePolicy",
            summary: "Approve a proposed version and activate it",
            description: "The caller is recorded as the named approver. The spec is compiled again under the governance in force now; engines run it within seconds, without a restart. Needs `policy:approve`.",
            tag: "policy",
            stability: Stable,
            body: None,
            ok: compiled.clone(),
            params: vec![path_param("version", "The spec version, e.g. `3`.")],
            idempotent: false,
            errors: &[400, 401, 404, 409, 500],
            open: false,
        },
        Op {
            method: "post",
            path: "/v1/policies/rollback",
            id: "rollbackPolicy",
            summary: "Activate an earlier policy",
            description: "Activates an approved version, the default policy, or (with no `to`) the policy active before the current one, if it compiles under the governance in force now. An unapproved version is refused and the refusal audited (POL-03). Needs `policy:approve`.",
            tag: "policy",
            stability: Stable,
            body: Some(rollback_req),
            ok: compiled,
            params: vec![],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/audit",
            id: "audit",
            summary: "Newest audit events",
            description: "Preview: becomes an admin route with G06.",
            tag: "operations",
            stability: Preview,
            body: None,
            ok: audit,
            params: vec![query_param("limit", "1 to 1000 (default 100).", json!({"type": "integer", "minimum": 1, "maximum": 1000}))],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/enrich/status",
            id: "enrichStatus",
            summary: "Background enrichment queue",
            description: "Preview.",
            tag: "operations",
            stability: Preview,
            body: None,
            ok: enrich,
            params: vec![],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/health",
            id: "health",
            summary: "Liveness and versions",
            description: "No authentication.",
            tag: "operations",
            stability: Stable,
            body: None,
            ok: health,
            params: vec![],
            idempotent: false,
            errors: &[],
            open: true,
        },
        Op {
            method: "get",
            path: "/v1/openapi.json",
            id: "openapi",
            summary: "This document",
            description: "No authentication.",
            tag: "operations",
            stability: Stable,
            body: None,
            ok: json!({"type": "object"}),
            params: vec![],
            idempotent: false,
            errors: &[],
            open: true,
        },
        Op {
            method: "post",
            path: "/v1/memories",
            id: "rememberLegacy",
            summary: "Deprecated: use POST /v1/remember",
            description: "Same body and response as `remember`.",
            tag: "deprecated",
            stability: Deprecated,
            body: Some(remember_req),
            ok: remember_res.clone(),
            params: vec![],
            idempotent: true,
            errors: &[400, 401, 409, 500],
            open: false,
        },
        Op {
            method: "get",
            path: "/v1/memories",
            id: "listMemoriesLegacy",
            summary: "Deprecated: use GET /v1/subjects/{subject}/memories",
            description: "Offset paging over every subject; returns a bare array.",
            tag: "deprecated",
            stability: Deprecated,
            body: None,
            ok: memories,
            params: vec![
                query_param("subject", "", json!({"type": "string"})),
                query_param("kind", "One kind.", json!({"type": "string"})),
                query_param("limit", "", json!({"type": "integer", "minimum": 1, "maximum": 1000})),
                query_param("offset", "", json!({"type": "integer", "minimum": 0})),
                query_param("all", "Also inactive records.", json!({"type": "boolean"})),
            ],
            idempotent: false,
            errors: &[400, 401, 500],
            open: false,
        },
        Op {
            method: "patch",
            path: "/v1/memories/{id}",
            id: "reviseLegacy",
            summary: "Deprecated: use POST /v1/revise",
            description: "Body `{content}`.",
            tag: "deprecated",
            stability: Deprecated,
            body: Some(json!({"type": "object", "properties": {"content": {"type": "string"}}, "required": ["content"]})),
            ok: remember_res,
            params: vec![id_param()],
            idempotent: true,
            errors: &[400, 401, 404, 409, 500],
            open: false,
        },
        Op {
            method: "delete",
            path: "/v1/memories/{id}",
            id: "forgetLegacy",
            summary: "Deprecated: use POST /v1/forget with `id`",
            description: "Returns `{deleted: <id>}`.",
            tag: "deprecated",
            stability: Deprecated,
            body: None,
            ok: legacy_deleted.clone(),
            params: vec![id_param()],
            idempotent: false,
            errors: &[400, 401, 404, 500],
            open: false,
        },
        Op {
            method: "delete",
            path: "/v1/subjects/{subject}",
            id: "eraseSubjectLegacy",
            summary: "Deprecated: use POST /v1/forget with `subject`",
            description: "Returns `{subject, deleted: <count>}`.",
            tag: "deprecated",
            stability: Deprecated,
            body: None,
            ok: legacy_deleted,
            params: vec![subject_param()],
            idempotent: false,
            errors: &[401, 500],
            open: false,
        },
    ]
}

fn error_response(code: u16) -> Value {
    let what = match code {
        400 => "Invalid request (`invalid_request`).",
        401 => "Missing, wrong, expired or revoked key or token (`unauthorized`).",
        403 => "The caller may not do this (`forbidden`): a missing permission, another tenant, subject, label, user or scope.",
        404 => "Not found (`not_found`).",
        409 => "Conflict with the stored state (`conflict`).",
        _ => "Internal failure (`internal`).",
    };
    json!({"description": what, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorBody"}}}})
}

/// The OpenAPI document. Deterministic: the same build gives the same bytes.
pub fn spec() -> Value {
    let mut g = generator();
    let ops = ops(&mut g);
    let mut paths = Map::new();
    for op in &ops {
        let mut o = json!({
            "operationId": op.id,
            "summary": op.summary,
            "description": op.description,
            "tags": [op.tag],
            "x-stability": match op.stability { Stability::Stable => "stable", Stability::Preview => "preview", Stability::Deprecated => "deprecated" },
        });
        let mut params = op.params.clone();
        if !op.open {
            params.push(json!({"$ref": "#/components/parameters/User"}));
        }
        if op.idempotent {
            params.push(json!({"$ref": "#/components/parameters/IdempotencyKey"}));
        }
        if !op.open && op.method != "get" {
            params.push(json!({"$ref": "#/components/parameters/Actor"}));
        }
        if !params.is_empty() {
            o["parameters"] = json!(params);
        }
        if let Some(b) = &op.body {
            o["requestBody"] = json!({"required": true, "content": {"application/json": {"schema": b}}});
        }
        let mut responses = Map::new();
        let media = if op.path == "/metrics" { "text/plain" } else { "application/json" };
        responses.insert("200".into(), json!({"description": "OK", "content": {media: {"schema": op.ok}}}));
        for c in op.errors {
            responses.insert(c.to_string(), error_response(*c));
        }
        if !op.open {
            responses.insert("403".into(), error_response(403));
        }
        o["responses"] = Value::Object(responses);
        if op.open {
            o["security"] = json!([]);
        }
        if op.stability == Stability::Deprecated {
            o["deprecated"] = json!(true);
            let d = DEPRECATED.iter().find(|d| d.path == op.path && d.method.eq_ignore_ascii_case(op.method)).expect("deprecated route listed");
            o["x-successor"] = json!(d.successor);
            o["x-sunset"] = json!(SUNSET);
        }
        paths.entry(op.path.to_string()).or_insert_with(|| json!({}))[op.method] = o;
    }
    json!({
        "openapi": "3.1.0",
        "jsonSchemaDialect": "https://json-schema.org/draft/2020-12/schema",
        "info": {
            "title": "MemHouse API",
            "version": API_VERSION,
            "summary": "Governed long-term memory for AI agents.",
            "description": "API v1. Stability policy: docs/api-stability.md. Operations marked `x-stability: preview` may change in a minor release; `stable` ones only gain optional fields and new operations within v1.",
            "license": {"name": "Apache-2.0", "identifier": "Apache-2.0"}
        },
        "servers": [{"url": "http://127.0.0.1:7077", "description": "default `memhouse serve`"}],
        "security": [{"bearer": []}, {"apiKey": []}],
        "tags": [
            {"name": "memory", "description": "The core operations (CORE-01)."},
            {"name": "identity", "description": "Who is calling: tokens and the verified identity (GOV-01, GOV-13)."},
            {"name": "operations", "description": "Health, counts and audit."},
            {"name": "policy", "description": "Behaviour policy: structured specs, compiled under governance, approved, versioned and rolled back (POL-01, POL-03, POL-04, POL-08)."},
            {"name": "deprecated", "description": format!("Routes from before v1, deprecated on {DEPRECATED_ON}, removed no earlier than {SUNSET}.")}
        ],
        "paths": paths,
        "components": {
            "schemas": g.take_definitions(true),
            "parameters": {
                "IdempotencyKey": {"name": "Idempotency-Key", "in": "header", "required": false, "description": "1 to 255 characters. A repeat with the same key and request returns the first response; the same key with another request is a 409. Same as the body's `request_key`.", "schema": {"type": "string", "minLength": 1, "maxLength": 255}},
                "Actor": {"name": "x-memhouse-actor", "in": "header", "required": false, "deprecated": true, "description": "Ignored since 1.1: the audit actor and `provenance.agent` are the authenticated principal.", "schema": {"type": "string", "maxLength": 80}},
                "User": {"name": "x-memhouse-user", "in": "header", "required": false, "description": "The user the call acts for. Accepted only from admins and from agents trusted to act for users (`act_as`); a user's key always acts for that user, a token for its own user.", "schema": {"type": "string"}}
            },
            "securitySchemes": {
                "bearer": {"type": "http", "scheme": "bearer", "description": "`Authorization: Bearer <key or token>`: a principal's API key (`mh_…`, from `memhouse key create`), a short-lived agent token (`mht.…`, from `POST /v1/tokens`), or a bootstrap key from `[server] api_keys`."},
                "apiKey": {"type": "apiKey", "in": "header", "name": "x-api-key"}
            }
        }
    })
}

/// The schema of a component, by name.
pub fn component<'a>(spec: &'a Value, name: &str) -> Option<&'a Value> {
    spec.pointer(&format!("/components/schemas/{name}"))
}

/// The 200 response schema of an operation.
pub fn response_schema<'a>(spec: &'a Value, method: &str, path: &str) -> Option<&'a Value> {
    spec.get("paths")?.get(path)?.get(method)?.pointer("/responses/200/content/application~1json/schema")
}

/// The response schema for a status of an operation (`None` when the status isn't documented).
pub fn status_schema<'a>(spec: &'a Value, method: &str, path: &str, status: u16) -> Option<&'a Value> {
    let content = spec.get("paths")?.get(path)?.get(method)?.get("responses")?.get(status.to_string())?.get("content")?;
    content.get("application/json").or_else(|| content.get("text/plain"))?.get("schema")
}

/// Validate `value` against `schema` (the JSON Schema subset the generator emits: `$ref`,
/// `type`, `properties`, `required`, `additionalProperties`, `items`, `prefixItems`, `enum`,
/// `const`, `anyOf`, `oneOf`, `allOf`, bounds and the `uuid` and `date-time` formats).
pub fn validate(spec: &Value, schema: &Value, value: &Value) -> Result<(), String> {
    let mut errors = vec![];
    check(spec, schema, value, "$", &mut errors, 0);
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

fn type_matches(t: &str, v: &Value) -> bool {
    match t {
        "null" => v.is_null(),
        "boolean" => v.is_boolean(),
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        "number" => v.is_number(),
        "integer" => v.is_i64() || v.is_u64() || v.as_f64().is_some_and(|f| f.fract() == 0.0),
        _ => false,
    }
}

fn check(spec: &Value, schema: &Value, v: &Value, at: &str, errors: &mut Vec<String>, depth: usize) {
    if depth > 64 {
        errors.push(format!("{at}: schema nests too deep"));
        return;
    }
    let s = match schema {
        Value::Bool(true) => return,
        Value::Bool(false) => return errors.push(format!("{at}: no value allowed")),
        Value::Object(o) => o,
        _ => return errors.push(format!("{at}: bad schema")),
    };
    if let Some(r) = s.get("$ref").and_then(Value::as_str) {
        match r.strip_prefix('#').and_then(|p| spec.pointer(p)) {
            Some(target) => check(spec, target, v, at, errors, depth + 1),
            None => errors.push(format!("{at}: unresolved {r}")),
        }
    }
    if let Some(t) = s.get("type") {
        let ok = match t {
            Value::String(t) => type_matches(t, v),
            Value::Array(ts) => ts.iter().filter_map(Value::as_str).any(|t| type_matches(t, v)),
            _ => true,
        };
        if !ok {
            return errors.push(format!("{at}: expected {t}, got {}", short(v)));
        }
    }
    if let Some(e) = s.get("enum").and_then(Value::as_array) {
        if !e.contains(v) {
            errors.push(format!("{at}: {} is not one of {}", short(v), Value::Array(e.clone())));
        }
    }
    if let Some(c) = s.get("const") {
        if c != v {
            errors.push(format!("{at}: expected {c}"));
        }
    }
    if let (Some(n), Some(min)) = (v.as_f64(), s.get("minimum").and_then(Value::as_f64)) {
        if n < min {
            errors.push(format!("{at}: {n} is below {min}"));
        }
    }
    if let (Some(n), Some(max)) = (v.as_f64(), s.get("maximum").and_then(Value::as_f64)) {
        if n > max {
            errors.push(format!("{at}: {n} is above {max}"));
        }
    }
    if let (Some(text), Some(f)) = (v.as_str(), s.get("format").and_then(Value::as_str)) {
        let ok = match f {
            "uuid" => uuid::Uuid::parse_str(text).is_ok(),
            "date-time" => chrono::DateTime::parse_from_rfc3339(text).is_ok(),
            _ => true,
        };
        if !ok {
            errors.push(format!("{at}: '{text}' is not a {f}"));
        }
    }
    if let Some(all) = s.get("allOf").and_then(Value::as_array) {
        for sub in all {
            check(spec, sub, v, at, errors, depth + 1);
        }
    }
    for (key, exactly_one) in [("anyOf", false), ("oneOf", true)] {
        if let Some(alts) = s.get(key).and_then(Value::as_array) {
            let passing = alts
                .iter()
                .filter(|sub| {
                    let mut e = vec![];
                    check(spec, sub, v, at, &mut e, depth + 1);
                    e.is_empty()
                })
                .count();
            if passing == 0 || (exactly_one && passing > 1) {
                errors.push(format!("{at}: {} alternatives of {key} match {}", passing, short(v)));
            }
        }
    }
    if let Some(o) = v.as_object() {
        let props = s.get("properties").and_then(Value::as_object);
        if let Some(req) = s.get("required").and_then(Value::as_array) {
            for r in req.iter().filter_map(Value::as_str) {
                if !o.contains_key(r) {
                    errors.push(format!("{at}: missing required '{r}'"));
                }
            }
        }
        for (k, val) in o {
            match props.and_then(|p| p.get(k)) {
                Some(ps) => check(spec, ps, val, &format!("{at}.{k}"), errors, depth + 1),
                None => {
                    if let Some(extra) = s.get("additionalProperties") {
                        check(spec, extra, val, &format!("{at}.{k}"), errors, depth + 1);
                    }
                }
            }
        }
    }
    if let Some(a) = v.as_array() {
        let prefix = s.get("prefixItems").and_then(Value::as_array);
        for (i, item) in a.iter().enumerate() {
            let sub = prefix.and_then(|p| p.get(i)).or_else(|| s.get("items"));
            if let Some(sub) = sub {
                check(spec, sub, item, &format!("{at}[{i}]"), errors, depth + 1);
            }
        }
    }
}

fn short(v: &Value) -> String {
    let t = v.to_string();
    if t.chars().count() > 60 {
        format!("{}…", t.chars().take(60).collect::<String>())
    } else {
        t
    }
}

/// Changes from `old` to `new` that would break a v1 client (QUAL-09): a removed operation,
/// parameter, schema or property, a new required parameter or property, a property no longer
/// required, a changed type or reference, a removed enum value. Additions of optional fields,
/// operations, schemas and enum values are allowed (clients must ignore what they don't know).
pub fn breaking_changes(old: &Value, new: &Value) -> Vec<String> {
    let mut out = vec![];
    let empty = Map::new();
    let paths = |s: &Value| s.get("paths").and_then(Value::as_object).cloned().unwrap_or_default();
    let (old_paths, new_paths) = (paths(old), paths(new));
    for (path, methods) in &old_paths {
        for (method, op) in methods.as_object().unwrap_or(&empty) {
            let Some(nop) = new_paths.get(path).and_then(|m| m.get(method)) else {
                out.push(format!("{} {path}: operation removed", method.to_uppercase()));
                continue;
            };
            let at = format!("{} {path}", method.to_uppercase());
            let names = |o: &Value| -> Vec<(String, bool)> {
                o.get("parameters")
                    .and_then(Value::as_array)
                    .map(|ps| {
                        ps.iter()
                            .map(|p| {
                                let name = p.get("name").or_else(|| p.get("$ref")).and_then(Value::as_str).unwrap_or("").to_string();
                                (name, p.get("required").and_then(Value::as_bool).unwrap_or(false))
                            })
                            .collect()
                    })
                    .unwrap_or_default()
            };
            let (op_params, nop_params) = (names(op), names(nop));
            for (n, _) in &op_params {
                if !nop_params.iter().any(|(m, _)| m == n) {
                    out.push(format!("{at}: parameter {n} removed"));
                }
            }
            for (n, required) in &nop_params {
                if *required && !op_params.iter().any(|(m, r)| m == n && *r) {
                    out.push(format!("{at}: parameter {n} is now required"));
                }
            }
            let body = |o: &Value| o.pointer("/requestBody/content/application~1json/schema").cloned();
            match (body(op), body(nop)) {
                (Some(a), Some(b)) => compare(&a, &b, &format!("{at} body"), &mut out),
                (None, Some(_)) => out.push(format!("{at}: now needs a body")),
                (Some(_), None) => out.push(format!("{at}: body removed")),
                (None, None) => {}
            }
            let ok = |o: &Value| o.pointer("/responses/200/content/application~1json/schema").cloned();
            if let (Some(a), Some(b)) = (ok(op), ok(nop)) {
                compare(&a, &b, &format!("{at} response"), &mut out);
            }
        }
    }
    let schemas = |s: &Value| s.pointer("/components/schemas").and_then(Value::as_object).cloned().unwrap_or_default();
    let (old_s, new_s) = (schemas(old), schemas(new));
    for (name, schema) in &old_s {
        match new_s.get(name) {
            Some(n) => compare(schema, n, name, &mut out),
            None => out.push(format!("schema {name} removed")),
        }
    }
    out
}

fn compare(old: &Value, new: &Value, at: &str, out: &mut Vec<String>) {
    let (Some(o), Some(n)) = (old.as_object(), new.as_object()) else {
        if old != new {
            out.push(format!("{at}: changed"));
        }
        return;
    };
    for key in ["$ref", "type", "format"] {
        if o.get(key) != n.get(key) {
            out.push(format!("{at}: {key} changed from {} to {}", o.get(key).unwrap_or(&Value::Null), n.get(key).unwrap_or(&Value::Null)));
        }
    }
    let set = |m: &Map<String, Value>, k: &str| -> Vec<Value> { m.get(k).and_then(Value::as_array).cloned().unwrap_or_default() };
    let (oreq, nreq) = (set(o, "required"), set(n, "required"));
    for r in &nreq {
        if !oreq.contains(r) {
            out.push(format!("{at}: {r} is now required"));
        }
    }
    for r in &oreq {
        if !nreq.contains(r) {
            out.push(format!("{at}: {r} is no longer required"));
        }
    }
    let nenum = set(n, "enum");
    for e in set(o, "enum") {
        if !nenum.contains(&e) {
            out.push(format!("{at}: enum value {e} removed"));
        }
    }
    let consts = |m: &Map<String, Value>| -> Vec<Value> { ["oneOf", "anyOf"].iter().flat_map(|k| set(m, k)).filter_map(|a| a.get("const").cloned()).collect() };
    let nconsts = consts(n);
    for c in consts(o) {
        if !nconsts.contains(&c) {
            out.push(format!("{at}: value {c} removed"));
        }
    }
    let empty = Map::new();
    let oprops = o.get("properties").and_then(Value::as_object).unwrap_or(&empty);
    let nprops = n.get("properties").and_then(Value::as_object).unwrap_or(&empty);
    for (k, v) in oprops {
        match nprops.get(k) {
            Some(nv) => compare(v, nv, &format!("{at}.{k}"), out),
            None => out.push(format!("{at}.{k}: removed")),
        }
    }
    if let (Some(a), Some(b)) = (o.get("items"), n.get("items")) {
        compare(a, b, &format!("{at}[]"), out);
    }
    for key in ["anyOf", "oneOf"] {
        let (a, b) = (set(o, key), set(n, key));
        if a.iter().all(|x| x.get("const").is_none()) && !a.is_empty() {
            if a.len() != b.len() {
                out.push(format!("{at}: {key} changed"));
            } else {
                for (i, (x, y)) in a.iter().zip(&b).enumerate() {
                    compare(x, y, &format!("{at}.{key}[{i}]"), out);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PUBLISHED: &str = include_str!("../../../api/openapi.json");
    const BASELINE: &str = include_str!("../../../api/baseline/openapi-1.0.0.json");

    fn pretty(v: &Value) -> String {
        serde_json::to_string_pretty(v).unwrap() + "\n"
    }

    /// `api/openapi.json` is the generated document. Regenerate it with
    /// `MEMHOUSE_WRITE_OPENAPI=1 cargo test -p memhouse-server openapi`.
    #[test]
    fn published_spec_is_current() {
        let current = pretty(&spec());
        if std::env::var_os("MEMHOUSE_WRITE_OPENAPI").is_some() {
            std::fs::write(concat!(env!("CARGO_MANIFEST_DIR"), "/../../api/openapi.json"), &current).unwrap();
            return;
        }
        assert!(current == PUBLISHED, "api/openapi.json is out of date: regenerate it with MEMHOUSE_WRITE_OPENAPI=1 cargo test -p memhouse-server openapi");
    }

    /// The release baseline of v1; nothing in the current document may break it (QUAL-09).
    #[test]
    fn no_breaking_change_since_baseline() {
        let baseline: Value = serde_json::from_str(BASELINE).unwrap();
        let breaks = breaking_changes(&baseline, &spec());
        assert!(breaks.is_empty(), "breaking changes against api/baseline/openapi-1.0.0.json:\n{}", breaks.join("\n"));
    }

    #[test]
    fn breaking_change_check_catches_breaks() {
        let base = spec();
        let mutate = |f: &dyn Fn(&mut Value)| {
            let mut v = base.clone();
            f(&mut v);
            breaking_changes(&base, &v)
        };
        let removed_op = mutate(&|v| {
            v["paths"].as_object_mut().unwrap().remove("/v1/revise");
        });
        assert!(removed_op.iter().any(|b| b.contains("POST /v1/revise: operation removed")), "{removed_op:?}");
        let removed_prop = mutate(&|v| {
            v["components"]["schemas"]["RememberResult"]["properties"].as_object_mut().unwrap().remove("status");
        });
        assert!(removed_prop.iter().any(|b| b.contains("RememberResult.status: removed")), "{removed_prop:?}");
        let new_required = mutate(&|v| {
            v["components"]["schemas"]["RecallRequest"]["required"].as_array_mut().unwrap().push(json!("subject"));
        });
        assert!(new_required.iter().any(|b| b.contains("\"subject\" is now required")), "{new_required:?}");
        let removed_value = mutate(&|v| {
            let kinds = &mut v["components"]["schemas"]["MemoryKind"];
            for key in ["oneOf", "enum"] {
                if let Some(a) = kinds.get_mut(key).and_then(Value::as_array_mut) {
                    a.pop();
                }
            }
        });
        assert!(removed_value.iter().any(|b| b.contains("removed")), "{removed_value:?}");
        let type_change = mutate(&|v| {
            v["components"]["schemas"]["ForgetResult"]["properties"]["deleted"]["type"] = json!("string");
        });
        assert!(type_change.iter().any(|b| b.contains("type changed")), "{type_change:?}");
        // Additions are fine.
        let added = mutate(&|v| {
            v["components"]["schemas"]["RememberResult"]["properties"]["extra"] = json!({"type": "string"});
            v["paths"]["/v1/new"] = json!({"get": {"responses": {}}});
        });
        assert!(added.is_empty(), "{added:?}");
    }

    #[test]
    fn validator_reads_the_generated_schemas() {
        let s = spec();
        let page = response_schema(&s, "get", "/v1/subjects/{subject}/memories").unwrap();
        let memory = json!({
            "id": "01a197b3-f332-7363-82e1-219723e7663e", "tenant": "default", "subject": "user:a", "kind": "semantic",
            "status": "committed", "content": "x", "valid_from": "2026-10-14T15:00:00Z", "labels": [], "tags": [],
            "source": "rest", "confidence": 1.0, "metadata": {}, "created_at": "2026-10-14T15:00:00Z"
        });
        validate(&s, page, &json!({"items": [memory.clone()]})).unwrap();
        let mut bad = memory.clone();
        bad["kind"] = json!("gossip");
        assert!(validate(&s, page, &json!({"items": [bad]})).is_err());
        let mut bad = memory;
        bad["id"] = json!("not-a-uuid");
        assert!(validate(&s, page, &json!({"items": [bad]})).is_err());
        let err = status_schema(&s, "post", "/v1/remember", 400).unwrap();
        validate(&s, err, &json!({"error": "content is empty", "code": "invalid_request"})).unwrap();
        assert!(validate(&s, err, &json!({"error": "x", "code": "teapot"})).is_err());
    }

    /// ADR 0008: what stable operations use maps to protobuf: no tuples, no untagged unions of
    /// object shapes, type unions only with null.
    #[test]
    fn stable_types_map_to_protobuf() {
        let s = spec();
        let mut todo: Vec<String> = vec![];
        let refs = |v: &Value, todo: &mut Vec<String>| {
            let mut stack = vec![v.clone()];
            while let Some(x) = stack.pop() {
                match x {
                    Value::Object(o) => {
                        if let Some(r) = o.get("$ref").and_then(Value::as_str) {
                            todo.push(r.trim_start_matches("#/components/schemas/").to_string());
                        }
                        stack.extend(o.into_iter().map(|(_, v)| v));
                    }
                    Value::Array(a) => stack.extend(a),
                    _ => {}
                }
            }
        };
        for methods in s["paths"].as_object().unwrap().values() {
            for op in methods.as_object().unwrap().values() {
                if op["x-stability"] == "stable" {
                    refs(&op["requestBody"], &mut todo);
                    refs(&op["responses"]["200"], &mut todo);
                }
            }
        }
        let mut seen = std::collections::BTreeSet::new();
        let mut problems = vec![];
        while let Some(name) = todo.pop() {
            if !seen.insert(name.clone()) {
                continue;
            }
            let schema = component(&s, &name).unwrap_or_else(|| panic!("{name}")).clone();
            let text = schema.to_string();
            if text.contains("prefixItems") {
                problems.push(format!("{name}: a tuple"));
            }
            let mut stack = vec![schema.clone()];
            while let Some(x) = stack.pop() {
                if let Value::Object(o) = &x {
                    if let Some(Value::Array(ts)) = o.get("type") {
                        if ts.len() != 2 || !ts.contains(&json!("null")) {
                            problems.push(format!("{name}: type union {ts:?}"));
                        }
                    }
                    for key in ["oneOf", "anyOf"] {
                        if let Some(Value::Array(alts)) = o.get(key) {
                            let shapes = alts.iter().filter(|a| a.get("const").is_none() && a.get("type") != Some(&json!("null"))).count();
                            if shapes > 1 {
                                problems.push(format!("{name}: {key} of {shapes} shapes"));
                            }
                        }
                    }
                    stack.extend(o.values().cloned());
                } else if let Value::Array(a) = x {
                    stack.extend(a);
                }
            }
            refs(&schema, &mut todo);
        }
        assert!(problems.is_empty(), "{problems:?}");
        assert!(seen.contains("Memory") && seen.contains("WhoAmI"), "{seen:?}");
    }

    #[test]
    fn every_deprecated_route_is_documented() {
        let s = spec();
        for d in DEPRECATED {
            let op = &s["paths"][d.path][d.method.to_lowercase()];
            assert_eq!(op["deprecated"], json!(true), "{} {}", d.method, d.path);
            assert!(s["paths"].get(d.successor).is_some(), "successor {} is not a path", d.successor);
        }
    }
}
