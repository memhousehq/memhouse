// SPDX-License-Identifier: Apache-2.0
//! HTTP gateway: REST API, streamable-HTTP MCP endpoint and the Memory Browser page.

pub mod mcp;
pub mod openapi;

use axum::extract::{FromRequest, FromRequestParts, MatchedPath, Path, Query, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use memhouse_core::error::{self, ErrorBody, ErrorCode};
use memhouse_core::types::*;
use memhouse_core::{Config, Engine, Store};
use memhouse_store_postgres::PgStore;
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use uuid::Uuid;

/// Connect to Postgres, load models, run migrations: everything a transport needs.
pub async fn build_engine(cfg: Config, show_progress: bool) -> anyhow::Result<Engine> {
    let embedder = memhouse_models::build_embedder(&cfg, show_progress)?;
    if embedder.dim() != cfg.embedding.dim {
        anyhow::bail!("embedding model {} produces {} dimensions but embedding.dim is {}", embedder.id(), embedder.dim(), cfg.embedding.dim);
    }
    let reranker = memhouse_models::build_reranker(&cfg, show_progress)?;
    let store = PgStore::connect(&cfg.database.url, cfg.database.max_connections, cfg.embedding.passage_prefix.as_deref().unwrap_or("")).await?;
    store.migrate(embedder.dim(), embedder.id()).await?;
    let chat = memhouse_models::enrich_chat(&cfg, None)?;
    let engine = Engine::new(Arc::new(store), embedder, reranker, cfg).with_chat(chat);
    // Records name the policy that admitted them; the policy itself is kept with them.
    engine.store.policy_put(&engine.policy()).await?;
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
    keys: Arc<Vec<String>>,
}

fn actor_from(headers: &HeaderMap) -> String {
    headers.get("x-memhouse-actor").and_then(|v| v.to_str().ok()).map(|s| s.chars().take(80).collect()).unwrap_or_else(|| "rest".into())
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

async fn auth(State(st): State<AppState>, req: Request, next: Next) -> Response {
    if st.keys.is_empty() {
        return unauthorized("no API keys configured; run `memhouse init`");
    }
    let given = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|s| s.trim().to_string())
        .or_else(|| req.headers().get("x-api-key").and_then(|v| v.to_str().ok()).map(String::from));
    match given {
        Some(k) if st.keys.iter().any(|x| constant_time_eq(x.as_bytes(), k.as_bytes())) => next.run(req).await,
        _ => unauthorized("missing or invalid API key (Authorization: Bearer <key>)"),
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
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
    let st = AppState { keys: Arc::new(engine.cfg.server.api_keys.clone()), engine };
    let api = Router::new()
        // API v1
        .route("/v1/remember", post(remember))
        .route("/v1/recall", post(recall))
        .route("/v1/revise", post(revise))
        .route("/v1/forget", post(forget))
        .route("/v1/ingest", post(ingest))
        .route("/v1/memories/{id}", get(get_memory).patch(update).delete(forget_legacy))
        .route("/v1/subjects/{subject}/memories", get(list_page))
        // Preview (may change in a minor release)
        .route("/v1/subjects", get(subjects))
        .route("/v1/stats", get(stats))
        .route("/v1/enrich/status", get(enrich_status))
        .route("/v1/audit", get(audit))
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
    let workers = if engine.cfg.enrich.enabled && engine.chat.is_some() && engine.cfg.enrich.workers > 0 {
        eprintln!("Enrichment: {} workers, model {}", engine.cfg.enrich.workers, engine.cfg.enrich.llm.model);
        engine.spawn_enrichment(engine.cfg.enrich.workers, stop.clone(), Default::default())
    } else {
        vec![]
    };
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

async fn health() -> Json<openapi::Health> {
    Json(openapi::Health { status: "ok".into(), version: env!("CARGO_PKG_VERSION").into(), api_version: openapi::API_VERSION.into() })
}

async fn enrich_status(State(st): State<AppState>) -> ApiResult<EnrichStatus> {
    let t = st.engine.cfg.memory.tenant.clone();
    Ok(Json(st.engine.store.enrich_status(&t, None).await?))
}

async fn remember(State(st): State<AppState>, headers: HeaderMap, Body(mut req): Body<RememberRequest>) -> ApiResult<RememberResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(st.engine.remember(req).await?))
}

async fn revise(State(st): State<AppState>, headers: HeaderMap, Body(mut req): Body<ReviseRequest>) -> ApiResult<RememberResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(st.engine.revise(req).await?))
}

async fn forget(State(st): State<AppState>, headers: HeaderMap, Body(mut req): Body<ForgetRequest>) -> ApiResult<ForgetResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(st.engine.forget_by(req).await?))
}

async fn ingest(State(st): State<AppState>, headers: HeaderMap, Body(mut req): Body<IngestRequest>) -> ApiResult<IngestResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    request_key(&headers, &mut req.request_key)?;
    Ok(Json(st.engine.ingest(req).await?))
}

async fn recall(State(st): State<AppState>, headers: HeaderMap, Body(mut req): Body<RecallRequest>) -> ApiResult<RecallResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    Ok(Json(st.engine.recall(req).await?))
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

async fn list_page(State(st): State<AppState>, PathParam(subject): PathParam<String>, QueryParams(p): QueryParams<PageParams>) -> ApiResult<MemoryPage> {
    let kinds = p.kinds.as_deref().map(parse_kinds).transpose()?;
    Ok(Json(st.engine.list_page(None, subject, kinds, p.include_inactive.unwrap_or(false), p.limit.unwrap_or(50), p.cursor.as_deref()).await?))
}

#[derive(Deserialize)]
struct ListParams {
    subject: Option<String>,
    kind: Option<String>,
    limit: Option<usize>,
    offset: Option<usize>,
    all: Option<bool>,
}

async fn list(State(st): State<AppState>, QueryParams(p): QueryParams<ListParams>) -> ApiResult<Vec<Memory>> {
    let kinds = p.kind.as_deref().and_then(MemoryKind::parse).map(|k| vec![k]);
    Ok(Json(st.engine.list(None, p.subject, kinds, p.limit.unwrap_or(50), p.offset.unwrap_or(0), p.all.unwrap_or(false)).await?))
}

async fn get_memory(State(st): State<AppState>, PathParam(id): PathParam<Uuid>) -> ApiResult<Memory> {
    let t = st.engine.cfg.memory.tenant.clone();
    st.engine.store.get(&t, id).await?.map(Json).ok_or_else(|| ApiError(error::not_found(format!("memory {id} not found"))))
}

#[derive(Deserialize)]
struct UpdateBody {
    content: String,
}

async fn update(State(st): State<AppState>, headers: HeaderMap, PathParam(id): PathParam<Uuid>, Body(b): Body<UpdateBody>) -> ApiResult<RememberResult> {
    let mut key = None;
    request_key(&headers, &mut key)?;
    let req = ReviseRequest { id, content: b.content, actor: Some(actor_from(&headers)), request_key: key, ..Default::default() };
    Ok(Json(st.engine.revise(req).await?))
}

async fn forget_legacy(State(st): State<AppState>, headers: HeaderMap, PathParam(id): PathParam<Uuid>) -> ApiResult<serde_json::Value> {
    let ok = st.engine.forget(None, id, Some(actor_from(&headers))).await?;
    if !ok {
        return Err(ApiError(error::not_found(format!("memory {id} not found"))));
    }
    Ok(Json(json!({ "deleted": id })))
}

async fn erase_subject(State(st): State<AppState>, headers: HeaderMap, PathParam(subject): PathParam<String>) -> ApiResult<serde_json::Value> {
    let n = st.engine.forget_subject(None, &subject, Some(actor_from(&headers))).await?;
    Ok(Json(json!({ "subject": subject, "deleted": n })))
}

async fn subjects(State(st): State<AppState>) -> ApiResult<Vec<openapi::SubjectCount>> {
    let t = st.engine.cfg.memory.tenant.clone();
    let s = st.engine.store.subjects(&t, 500).await?;
    Ok(Json(s.into_iter().map(|(subject, memories)| openapi::SubjectCount { subject, memories }).collect()))
}

async fn stats(State(st): State<AppState>) -> ApiResult<Stats> {
    let t = st.engine.cfg.memory.tenant.clone();
    Ok(Json(st.engine.store.stats(&t).await?))
}

#[derive(Deserialize)]
struct AuditParams {
    limit: Option<usize>,
}

async fn audit(State(st): State<AppState>, QueryParams(p): QueryParams<AuditParams>) -> ApiResult<Vec<AuditEvent>> {
    let t = st.engine.cfg.memory.tenant.clone();
    Ok(Json(st.engine.store.audit_log(&t, p.limit.unwrap_or(100).clamp(1, 1000)).await?))
}

async fn mcp_http(State(st): State<AppState>, headers: HeaderMap, Body(msg): Body<serde_json::Value>) -> Response {
    let actor = actor_from(&headers);
    let out = match msg {
        serde_json::Value::Array(batch) => {
            let mut v = vec![];
            for m in batch {
                if let Some(r) = mcp::handle(&st.engine, m, &actor).await {
                    v.push(r);
                }
            }
            if v.is_empty() {
                None
            } else {
                Some(serde_json::Value::Array(v))
            }
        }
        m => mcp::handle(&st.engine, m, &actor).await,
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
