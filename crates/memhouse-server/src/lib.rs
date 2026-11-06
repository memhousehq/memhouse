// SPDX-License-Identifier: Apache-2.0
//! HTTP gateway: REST API, streamable-HTTP MCP endpoint and the Memory Browser page.

pub mod mcp;
pub mod openapi;
pub mod telemetry;

use axum::extract::{FromRequest, FromRequestParts, MatchedPath, Path, Query, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use memhouse_core::caller::Caller;
use memhouse_core::error::{self, ErrorBody, ErrorCode};
use memhouse_core::identity::Identity;
use memhouse_core::policy::{CompiledPolicy, PolicyDiff, PolicyDiffRequest, PolicySpecRecord, PolicySpecRequest, PolicyStatus, PolicyValidation, RollbackRequest};
use memhouse_core::types::*;
use memhouse_core::{Config, Engine, Store};
use memhouse_store_postgres::PgStore;
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use uuid::Uuid;

/// Connect to Postgres, load models, run migrations: everything a transport needs.
pub async fn build_engine(cfg: Config, show_progress: bool) -> anyhow::Result<Engine> {
    cfg.check_floor()?;
    let embedder = memhouse_models::build_embedder(&cfg, show_progress)?;
    if embedder.dim() != cfg.embedding.dim {
        anyhow::bail!("embedding model {} produces {} dimensions but embedding.dim is {}", embedder.id(), embedder.dim(), cfg.embedding.dim);
    }
    let reranker = memhouse_models::build_reranker(&cfg, show_progress)?;
    let store = PgStore::connect(&cfg.database.url, cfg.database.max_connections, cfg.embedding.passage_prefix.as_deref().unwrap_or("")).await?;
    store.migrate(embedder.dim(), embedder.id()).await?;
    let chat = memhouse_models::enrich_chat(&cfg, None)?;
    let classifier = memhouse_models::classifier_chat(&cfg)?;
    let mut engine = Engine::new(Arc::new(store), embedder, reranker, cfg).with_chat(chat);
    if let Some(chat) = classifier {
        engine = engine.with_classifier(Arc::new(memhouse_core::classify::ChatClassifier { chat }));
    }
    // Records name the policy that admitted them; the policy itself is kept with them (and the
    // active policy is compiled now, so a spec that no longer compiles is reported at start).
    engine.policy_for(&engine.cfg.memory.tenant).await?;
    Ok(engine)
}

/// An engine on the configured embedder without the start-up identity check, for
/// `memhouse reembed`, which exists to move a database from its old embedder to this one.
pub async fn build_reembed_engine(cfg: Config, show_progress: bool) -> anyhow::Result<Engine> {
    let embedder = memhouse_models::build_embedder(&cfg, show_progress)?;
    if embedder.dim() != cfg.embedding.dim {
        anyhow::bail!("embedding model {} produces {} dimensions but embedding.dim is {}", embedder.id(), embedder.dim(), cfg.embedding.dim);
    }
    let store = PgStore::connect(&cfg.database.url, cfg.database.max_connections, cfg.embedding.passage_prefix.as_deref().unwrap_or("")).await?;
    Ok(Engine::new(Arc::new(store), embedder, None, cfg))
}

/// An error response: `{"error": <message>, "code": <stable code>}` with the code's status.
pub struct ApiError(anyhow::Error);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = error::body_of(&self.0);
        if body.code == ErrorCode::Internal {
            tracing::error!("{}", body.error);
        }
        let status = StatusCode::from_u16(body.code.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        if body.code == ErrorCode::Unavailable {
            // PERF-07: a write refused because intake is down is safe to retry.
            return (status, [(axum::http::header::RETRY_AFTER, "1")], Json(body)).into_response();
        }
        (status, Json(body)).into_response()
    }
}

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(e: E) -> Self {
        ApiError(e.into())
    }
}

type ApiResult<T> = Result<Json<T>, ApiError>;

/// A JSON body whose decoding errors are API errors (`invalid_request`), not plain text.
pub struct Body<T>(pub T);

impl<S: Send + Sync, T: serde::de::DeserializeOwned> FromRequest<S> for Body<T> {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        Json::<T>::from_request(req, state).await.map(|Json(v)| Body(v)).map_err(|e| ApiError(error::invalid(e.body_text())))
    }
}

/// Path parameters, with the same error shape.
pub struct PathParam<T>(pub T);

impl<S: Send + Sync, T: serde::de::DeserializeOwned + Send> FromRequestParts<S> for PathParam<T> {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut axum::http::request::Parts, state: &S) -> Result<Self, Self::Rejection> {
        Path::<T>::from_request_parts(parts, state).await.map(|Path(v)| PathParam(v)).map_err(|e| ApiError(error::invalid(e.body_text())))
    }
}

/// Query parameters, with the same error shape.
pub struct QueryParams<T>(pub T);

impl<S: Send + Sync, T: serde::de::DeserializeOwned> FromRequestParts<S> for QueryParams<T> {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut axum::http::request::Parts, state: &S) -> Result<Self, Self::Rejection> {
        Query::<T>::from_request_parts(parts, state).await.map(|Query(v)| QueryParams(v)).map_err(|e| ApiError(error::invalid(e.body_text())))
    }
}

#[derive(Clone)]
struct AppState {
    engine: Engine,
}

/// The verified caller of a request. Handlers reach the engine only through it, so every
/// operation is authorized (security baseline rule 1).
pub struct Who(pub Caller);

impl FromRequestParts<AppState> for Who {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut axum::http::request::Parts, st: &AppState) -> Result<Self, Self::Rejection> {
        let id = parts.extensions.get::<Identity>().cloned().ok_or_else(|| ApiError(error::unauthorized("not authenticated")))?;
        Ok(Who(st.engine.caller(id)))
    }
}

/// The `Idempotency-Key` header as the request's `request_key` (CORE-06). Both may be sent only
/// when they agree.
fn request_key(headers: &HeaderMap, body: &mut Option<String>) -> Result<(), ApiError> {
    let Some(h) = headers.get("idempotency-key") else { return Ok(()) };
    let h = h.to_str().map_err(|_| ApiError(error::invalid("Idempotency-Key must be visible ASCII")))?.to_string();
    match body {
        Some(b) if *b != h => Err(ApiError(error::invalid("the Idempotency-Key header and request_key differ"))),
        _ => {
            *body = Some(h);
            Ok(())
        }
    }
}

fn unauthorized(msg: &str) -> Response {
    (StatusCode::UNAUTHORIZED, Json(ErrorBody { error: msg.into(), code: ErrorCode::Unauthorized })).into_response()
}

/// The credential of a request: `Authorization: Bearer <key or token>` or `x-api-key`.
pub fn credential(headers: &HeaderMap) -> Option<String> {
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|s| s.trim().to_string())
        .or_else(|| headers.get("x-api-key").and_then(|v| v.to_str().ok()).map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
}

/// Authenticate every request (GOV-01): a key or token verified against the store, and the user
/// it states (`x-memhouse-user`). A failure is audited (`auth.failed`) and nothing else runs.
async fn auth(State(st): State<AppState>, mut req: Request, next: Next) -> Response {
    let asserted = req.headers().get("x-memhouse-user").and_then(|v| v.to_str().ok()).map(String::from);
    let route = req.extensions().get::<MatchedPath>().map(|p| p.as_str().to_string()).unwrap_or_default();
    let failure = match credential(req.headers()) {
        None => memhouse_core::identity::AuthFailure { reason: "no credential", key_id: None, principal: None },
        Some(c) => match st.engine.auth.authenticate(&c, asserted.as_deref()).await {
            Ok(id) => {
                req.extensions_mut().insert(id);
                return next.run(req).await;
            }
            Err(f) => f,
        },
    };
    memhouse_core::metrics::inc("memhouse_refused_total", &[("kind", "auth"), ("reason", failure.reason)], 1.0);
    let detail = json!({ "reason": failure.reason, "key": failure.key_id, "route": route });
    let actor = failure.principal.clone().unwrap_or_else(|| "anonymous".into());
    if let Err(e) = st.engine.store.audit(&actor, "auth.failed", &st.engine.cfg.memory.tenant, None, None, detail).await {
        tracing::error!("audit of a failed authentication: {e:#}");
    }
    unauthorized(&format!("{} (send Authorization: Bearer <key or token>)", failure.reason))
}

/// Mark the pre-v1 routes: `Deprecation` (RFC 9745), `Sunset` (RFC 8594) and a `Link` to the
/// route that replaces it.
async fn deprecation(req: Request, next: Next) -> Response {
    let method = req.method().as_str().to_string();
    let path = req.extensions().get::<MatchedPath>().map(|p| p.as_str().to_string());
    let mut resp = next.run(req).await;
    if let Some(d) = path.and_then(|p| openapi::DEPRECATED.iter().find(|d| d.path == p && d.method == method)) {
        let day = |s: &str| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").expect("date constant").and_hms_opt(0, 0, 0).expect("midnight").and_utc();
        let h = resp.headers_mut();
        let mut put = |name: &'static str, value: String| {
            if let Ok(v) = HeaderValue::from_str(&value) {
                h.insert(name, v);
            }
        };
        put("deprecation", format!("@{}", day(openapi::DEPRECATED_ON).timestamp()));
        put("sunset", day(openapi::SUNSET).format("%a, %d %b %Y %H:%M:%S GMT").to_string());
        put("link", format!("<{}>; rel=\"successor-version\"", d.successor));
    }
    resp
}

pub fn router(engine: Engine) -> Router {
    let st = AppState { engine };
    let api = Router::new()
        // API v1
        .route("/v1/remember", post(remember))
        .route("/v1/recall", post(recall))
        .route("/v1/revise", post(revise))
        .route("/v1/forget", post(forget))
        .route("/v1/ingest", post(ingest))
        .route("/v1/memories/{id}", get(get_memory).patch(update).delete(forget_legacy))
        .route("/v1/subjects/{subject}/memories", get(list_page))
        .route("/v1/labels", post(relabel))
        .route("/v1/review", post(review))
        .route("/v1/tokens", post(issue_token))
        .route("/v1/whoami", get(whoami))
        .route("/v1/recalls/{id}/explanation", get(explanation))
        .route("/metrics", get(metrics))
        // Preview (may change in a minor release)
        .route("/v1/subjects", get(subjects))
        .route("/v1/stats", get(stats))
        .route("/v1/enrich/status", get(enrich_status))
        .route("/v1/audit", get(audit))
        .route("/v1/policies", get(policies).post(policy_propose))
        .route("/v1/policies/validate", post(policy_validate))
        .route("/v1/policies/diff", post(policy_diff))
        .route("/v1/policies/rollback", post(policy_rollback))
        .route("/v1/policies/{version}/approve", post(policy_approve))
        // Pre-v1 aliases (see `openapi::DEPRECATED`)
        .route("/v1/memories", post(remember).get(list))
        .route("/v1/subjects/{subject}", axum::routing::delete(erase_subject))
        .route("/mcp", post(mcp_http))
        .layer(middleware::from_fn(deprecation))
        .layer(middleware::from_fn_with_state(st.clone(), auth));
    Router::new()
        .route("/health", get(health))
        .route("/v1/openapi.json", get(|| async { Json(openapi::spec()) }))
        .route("/", get(browser))
        .merge(api)
        .fallback(|| async { ApiError(error::not_found("no such route")) })
        .with_state(st)
        .layer(middleware::from_fn(http_metrics))
        .layer(tower_http::trace::TraceLayer::new_for_http().make_span_with(|req: &Request| {
            // The route template, never the concrete path: subjects and ids stay out of span names.
            let route = req.extensions().get::<MatchedPath>().map(|p| p.as_str().to_string()).unwrap_or_else(|| "unmatched".into());
            tracing::info_span!("http.request", http.request.method = %req.method(), http.route = %route, otel.name = %format!("{} {route}", req.method()))
        }))
        .layer(tower_http::cors::CorsLayer::permissive())
}

/// Serve the API on a listener the caller bound (tests and embedding applications).
pub async fn serve_listener(listener: tokio::net::TcpListener, engine: Engine) -> anyhow::Result<()> {
    axum::serve(listener, router(engine)).await?;
    Ok(())
}

pub async fn serve(engine: Engine) -> anyhow::Result<()> {
    let bind = engine.cfg.server.bind.clone();
    let listener = tokio::net::TcpListener::bind(&bind).await.map_err(|e| anyhow::anyhow!("cannot listen on {bind}: {e}"))?;
    tracing::info!("MemHouse listening on http://{bind}");
    eprintln!("MemHouse is running on http://{bind}  (Memory Browser: http://{bind}/ , MCP: http://{bind}/mcp)");
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut workers = if engine.cfg.enrich.enabled && engine.chat.is_some() && engine.cfg.enrich.workers > 0 {
        eprintln!("Enrichment: {} workers, model {}", engine.cfg.enrich.workers, engine.cfg.enrich.llm.model);
        engine.spawn_enrichment(engine.cfg.enrich.workers, stop.clone(), Default::default())
    } else {
        vec![]
    };
    // The write pipeline's workers resume proposals left by a restart (TR-LT-05).
    workers.extend(engine.spawn_intake(engine.cfg.intake.workers, stop.clone()));
    axum::serve(listener, router(engine))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for w in workers {
        let _ = w.await;
    }
    Ok(())
}

/// Count and time every request by route template and status.
async fn http_metrics(req: Request, next: Next) -> Response {
    let start = std::time::Instant::now();
    let method = req.method().as_str().to_string();
    let route = req.extensions().get::<MatchedPath>().map(|p| p.as_str().to_string()).unwrap_or_else(|| "unmatched".into());
    let resp = next.run(req).await;
    let status = resp.status().as_u16().to_string();
    memhouse_core::metrics::inc("memhouse_http_requests_total", &[("method", &method), ("route", &route), ("status", &status)], 1.0);
    memhouse_core::metrics::observe("memhouse_http_request_duration_seconds", &[("route", &route)], start.elapsed().as_secs_f64());
    resp
}

/// Prometheus metrics (needs `ops:read`): the process registry, plus gauges read at scrape time.
async fn metrics(Who(c): Who) -> Result<Response, ApiError> {
    c.decide(&memhouse_core::access::AccessRequest::new(memhouse_core::access::Operation::Metrics)).await?;
    use memhouse_core::metrics::set;
    let q = c.engine.store.enrich_status(&c.who.principal.tenant, None).await?;
    for (state, n) in [("pending", q.pending), ("running", q.running), ("done", q.done), ("failed", q.failed)] {
        set("memhouse_enrich_jobs", &[("state", state)], n as f64);
    }
    set("memhouse_enrich_queue_lag_seconds", &[], q.oldest_pending_secs.unwrap_or(0.0));
    // TR-IN-06: the intake backlog and its lag.
    let i = c.engine.intake_status(Some(&c.who.principal.tenant)).await?;
    for (state, n) in [("pending", i.pending), ("running", i.running), ("done", i.done), ("dead", i.dead)] {
        set("memhouse_intake_proposals", &[("state", state)], n as f64);
    }
    set("memhouse_intake_lag_seconds", &[], i.oldest_pending_secs.unwrap_or(0.0));
    set("memhouse_build_info", &[("version", env!("CARGO_PKG_VERSION")), ("api_version", openapi::API_VERSION)], 1.0);
    let body = memhouse_core::metrics::render();
    Ok(([(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")], body).into_response())
}

async fn explanation(Who(c): Who, PathParam(id): PathParam<Uuid>) -> ApiResult<RecallExplanation> {
    Ok(Json(c.explain(id).await?))
}

async fn health() -> Json<openapi::Health> {
    Json(openapi::Health { status: "ok".into(), version: env!("CARGO_PKG_VERSION").into(), api_version: openapi::API_VERSION.into() })
}

async fn enrich_status(Who(c): Who) -> ApiResult<EnrichStatus> {
    Ok(Json(c.enrich_status().await?))
}

async fn remember(Who(c): Who, headers: HeaderMap, Body(mut req): Body<RememberRequest>) -> ApiResult<RememberResult> {
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(c.remember(req).await?))
}

async fn revise(Who(c): Who, headers: HeaderMap, Body(mut req): Body<ReviseRequest>) -> ApiResult<RememberResult> {
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(c.revise(req).await?))
}

async fn forget(Who(c): Who, headers: HeaderMap, Body(mut req): Body<ForgetRequest>) -> ApiResult<ForgetResult> {
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(c.forget(req).await?))
}

async fn ingest(Who(c): Who, headers: HeaderMap, Body(mut req): Body<IngestRequest>) -> ApiResult<IngestResult> {
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(c.ingest(req).await?))
}

async fn recall(Who(c): Who, Body(req): Body<RecallRequest>) -> ApiResult<RecallResult> {
    Ok(Json(c.recall(req).await?))
}

async fn relabel(Who(c): Who, Body(req): Body<RelabelRequest>) -> ApiResult<Memory> {
    Ok(Json(c.relabel(req).await?))
}

async fn review(Who(c): Who, Body(req): Body<ReviewRequest>) -> ApiResult<ReviewResult> {
    Ok(Json(c.review(req).await?))
}

async fn issue_token(Who(c): Who, Body(req): Body<TokenRequest>) -> ApiResult<memhouse_core::identity::TokenResponse> {
    Ok(Json(c.issue_token(req).await?))
}

async fn whoami(Who(c): Who) -> ApiResult<WhoAmI> {
    Ok(Json(c.whoami().await?))
}

async fn policies(Who(c): Who) -> ApiResult<PolicyStatus> {
    Ok(Json(c.policy_status().await?))
}

async fn policy_propose(Who(c): Who, Body(req): Body<PolicySpecRequest>) -> ApiResult<PolicySpecRecord> {
    Ok(Json(c.policy_propose(&req).await?))
}

async fn policy_validate(Who(c): Who, Body(req): Body<PolicySpecRequest>) -> ApiResult<PolicyValidation> {
    Ok(Json(c.policy_validate(&req.spec).await?))
}

async fn policy_diff(Who(c): Who, Body(req): Body<PolicyDiffRequest>) -> ApiResult<PolicyDiff> {
    Ok(Json(c.policy_diff(&req).await?))
}

async fn policy_approve(Who(c): Who, PathParam(version): PathParam<u32>) -> ApiResult<CompiledPolicy> {
    Ok(Json(c.policy_approve(version).await?))
}

async fn policy_rollback(Who(c): Who, Body(req): Body<RollbackRequest>) -> ApiResult<CompiledPolicy> {
    Ok(Json(c.policy_rollback(&req).await?))
}

fn parse_kinds(list: &str) -> Result<Vec<MemoryKind>, ApiError> {
    list.split(',').filter(|k| !k.trim().is_empty()).map(|k| MemoryKind::parse(k).ok_or_else(|| ApiError(error::invalid(format!("unknown kind '{k}'"))))).collect()
}

#[derive(Deserialize)]
struct PageParams {
    kinds: Option<String>,
    include_inactive: Option<bool>,
    limit: Option<usize>,
    cursor: Option<String>,
}

async fn list_page(Who(c): Who, PathParam(subject): PathParam<String>, QueryParams(p): QueryParams<PageParams>) -> ApiResult<MemoryPage> {
    let kinds = p.kinds.as_deref().map(parse_kinds).transpose()?;
    Ok(Json(c.list(subject, kinds, p.include_inactive.unwrap_or(false), p.limit.unwrap_or(50), p.cursor.as_deref()).await?))
}

#[derive(Deserialize)]
struct ListParams {
    subject: Option<String>,
    kind: Option<String>,
    limit: Option<usize>,
    offset: Option<usize>,
    all: Option<bool>,
}

/// The pre-v1 list: offset paging, optionally over every subject the caller may use.
async fn list(Who(c): Who, QueryParams(p): QueryParams<ListParams>) -> ApiResult<Vec<Memory>> {
    let kinds = p.kind.as_deref().and_then(MemoryKind::parse).map(|k| vec![k]);
    Ok(Json(c.list_offset(p.subject, kinds, p.all.unwrap_or(false), p.limit.unwrap_or(50), p.offset.unwrap_or(0)).await?))
}

async fn get_memory(Who(c): Who, PathParam(id): PathParam<Uuid>) -> ApiResult<Memory> {
    Ok(Json(c.get(id).await?))
}

#[derive(Deserialize)]
struct UpdateBody {
    content: String,
}

async fn update(Who(c): Who, headers: HeaderMap, PathParam(id): PathParam<Uuid>, Body(b): Body<UpdateBody>) -> ApiResult<RememberResult> {
    let mut key = None;
    request_key(&headers, &mut key)?;
    // The pre-v1 update answered with the stored revision; it still waits for the gate.
    Ok(Json(c.revise(ReviseRequest { id, content: b.content, request_key: key, wait: true, ..Default::default() }).await?))
}

async fn forget_legacy(Who(c): Who, PathParam(id): PathParam<Uuid>) -> ApiResult<serde_json::Value> {
    c.forget(ForgetRequest { id: Some(id), ..Default::default() }).await?;
    Ok(Json(json!({ "deleted": id })))
}

async fn erase_subject(Who(c): Who, PathParam(subject): PathParam<String>) -> ApiResult<serde_json::Value> {
    let r = c.forget(ForgetRequest { subject: Some(subject.clone()), ..Default::default() }).await?;
    Ok(Json(json!({ "subject": subject, "deleted": r.deleted })))
}

async fn subjects(Who(c): Who) -> ApiResult<Vec<openapi::SubjectCount>> {
    Ok(Json(c.subjects().await?.into_iter().map(|(subject, memories)| openapi::SubjectCount { subject, memories }).collect()))
}

async fn stats(Who(c): Who) -> ApiResult<Stats> {
    Ok(Json(c.stats().await?))
}

#[derive(Deserialize)]
struct AuditParams {
    limit: Option<usize>,
}

async fn audit(Who(c): Who, QueryParams(p): QueryParams<AuditParams>) -> ApiResult<Vec<AuditEvent>> {
    Ok(Json(c.audit_log(p.limit.unwrap_or(100).clamp(1, 1000)).await?))
}

async fn mcp_http(Who(c): Who, Body(msg): Body<serde_json::Value>) -> Response {
    let out = match msg {
        serde_json::Value::Array(batch) => {
            let mut v = vec![];
            for m in batch {
                if let Some(r) = mcp::handle(&c, m).await {
                    v.push(r);
                }
            }
            if v.is_empty() {
                None
            } else {
                Some(serde_json::Value::Array(v))
            }
        }
        m => mcp::handle(&c, m).await,
    };
    match out {
        Some(v) => Json(v).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

async fn browser() -> Html<&'static str> {
    Html(include_str!("browser.html"))
}

/// Keep a handle to the trait so downstream crates can name it without importing core.
pub type DynStore = Arc<dyn Store>;

#[cfg(test)]
mod tests {
    /// Data must never be interpolated into inline JavaScript in the Memory Browser: HTML escaping
    /// doesn't protect a JS string inside an attribute (the browser decodes entities first), so a
    /// subject name like `x');alert(1);('` would run script and could read the stored API key.
    #[test]
    fn browser_never_interpolates_data_into_inline_handlers() {
        let html = include_str!("browser.html");
        for (i, line) in html.lines().enumerate() {
            for attr in ["onclick=\"", "onchange=\"", "oninput=\"", "onkeydown=\"", "onsubmit=\""] {
                let mut rest = line;
                while let Some(p) = rest.find(attr) {
                    let handler = &rest[p + attr.len()..];
                    let handler = &handler[..handler.find('"').unwrap_or(handler.len())];
                    // UUIDs from the server (m.id) are the only allowed interpolation.
                    let bad = handler.contains("${") && !handler.contains("${m.id}");
                    assert!(!bad, "browser.html:{}: data interpolated into an inline handler: {handler}", i + 1);
                    rest = &rest[p + attr.len()..];
                }
            }
        }
    }
}
