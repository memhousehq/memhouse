// SPDX-License-Identifier: Apache-2.0
//! HTTP gateway: REST API, streamable-HTTP MCP endpoint and the Memory Browser page.

pub mod mcp;

use axum::extract::{Path, Query, Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
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
    Ok(Engine::new(Arc::new(store), embedder, reranker, cfg).with_chat(chat))
}

pub struct ApiError(anyhow::Error);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let msg = format!("{:#}", self.0);
        let code = if msg.contains("not found") {
            StatusCode::NOT_FOUND
        } else if msg.contains("required") || msg.contains("limit is") || msg.contains("empty") || msg.contains("expected") {
            StatusCode::BAD_REQUEST
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        };
        (code, Json(json!({ "error": msg }))).into_response()
    }
}

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(e: E) -> Self {
        ApiError(e.into())
    }
}

type ApiResult<T> = Result<Json<T>, ApiError>;

#[derive(Clone)]
struct AppState {
    engine: Engine,
    keys: Arc<Vec<String>>,
}

fn actor_from(headers: &HeaderMap) -> String {
    headers.get("x-memhouse-actor").and_then(|v| v.to_str().ok()).map(|s| s.chars().take(80).collect()).unwrap_or_else(|| "rest".into())
}

async fn auth(State(st): State<AppState>, req: Request, next: Next) -> Response {
    if st.keys.is_empty() {
        return (StatusCode::UNAUTHORIZED, Json(json!({"error": "no API keys configured; run `memhouse init`"}))).into_response();
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
        _ => (StatusCode::UNAUTHORIZED, Json(json!({"error": "missing or invalid API key (Authorization: Bearer <key>)"}))).into_response(),
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn router(engine: Engine) -> Router {
    let st = AppState { keys: Arc::new(engine.cfg.server.api_keys.clone()), engine };
    let api = Router::new()
        .route("/v1/memories", post(remember).get(list))
        .route("/v1/memories/{id}", get(get_memory).patch(update).delete(forget))
        .route("/v1/ingest", post(ingest))
        .route("/v1/recall", post(recall))
        .route("/v1/subjects", get(subjects))
        .route("/v1/subjects/{subject}", axum::routing::delete(erase_subject))
        .route("/v1/stats", get(stats))
        .route("/v1/enrich/status", get(enrich_status))
        .route("/v1/audit", get(audit))
        .route("/mcp", post(mcp_http))
        .layer(middleware::from_fn_with_state(st.clone(), auth));
    Router::new()
        .route("/health", get(|| async { Json(json!({"status": "ok", "version": env!("CARGO_PKG_VERSION")})) }))
        .route("/", get(browser))
        .merge(api)
        .with_state(st)
        .layer(tower_http::cors::CorsLayer::permissive())
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

async fn enrich_status(State(st): State<AppState>) -> ApiResult<EnrichStatus> {
    let t = st.engine.cfg.memory.tenant.clone();
    Ok(Json(st.engine.store.enrich_status(&t, None).await?))
}

async fn remember(State(st): State<AppState>, headers: HeaderMap, Json(mut req): Json<RememberRequest>) -> ApiResult<RememberResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    Ok(Json(st.engine.remember(req).await?))
}

async fn ingest(State(st): State<AppState>, headers: HeaderMap, Json(mut req): Json<IngestRequest>) -> ApiResult<IngestResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    Ok(Json(st.engine.ingest(req).await?))
}

async fn recall(State(st): State<AppState>, headers: HeaderMap, Json(mut req): Json<RecallRequest>) -> ApiResult<RecallResult> {
    req.actor.get_or_insert_with(|| actor_from(&headers));
    Ok(Json(st.engine.recall(req).await?))
}

#[derive(Deserialize)]
struct ListParams {
    subject: Option<String>,
    kind: Option<String>,
    limit: Option<usize>,
    offset: Option<usize>,
    all: Option<bool>,
}

async fn list(State(st): State<AppState>, Query(p): Query<ListParams>) -> ApiResult<Vec<Memory>> {
    let kinds = p.kind.as_deref().and_then(MemoryKind::parse).map(|k| vec![k]);
    Ok(Json(st.engine.list(None, p.subject, kinds, p.limit.unwrap_or(50), p.offset.unwrap_or(0), p.all.unwrap_or(false)).await?))
}

async fn get_memory(State(st): State<AppState>, Path(id): Path<Uuid>) -> ApiResult<Memory> {
    let t = st.engine.cfg.memory.tenant.clone();
    st.engine.store.get(&t, id).await?.map(Json).ok_or_else(|| ApiError(anyhow::anyhow!("memory {id} not found")))
}

#[derive(Deserialize)]
struct UpdateBody {
    content: String,
}

async fn update(State(st): State<AppState>, headers: HeaderMap, Path(id): Path<Uuid>, Json(b): Json<UpdateBody>) -> ApiResult<RememberResult> {
    Ok(Json(st.engine.update(None, id, b.content, Some(actor_from(&headers))).await?))
}

async fn forget(State(st): State<AppState>, headers: HeaderMap, Path(id): Path<Uuid>) -> ApiResult<serde_json::Value> {
    let ok = st.engine.forget(None, id, Some(actor_from(&headers))).await?;
    if !ok {
        return Err(ApiError(anyhow::anyhow!("memory {id} not found")));
    }
    Ok(Json(json!({ "deleted": id })))
}

async fn erase_subject(State(st): State<AppState>, headers: HeaderMap, Path(subject): Path<String>) -> ApiResult<serde_json::Value> {
    let n = st.engine.forget_subject(None, &subject, Some(actor_from(&headers))).await?;
    Ok(Json(json!({ "subject": subject, "deleted": n })))
}

async fn subjects(State(st): State<AppState>) -> ApiResult<serde_json::Value> {
    let t = st.engine.cfg.memory.tenant.clone();
    let s = st.engine.store.subjects(&t, 500).await?;
    Ok(Json(json!(s.into_iter().map(|(s, n)| json!({"subject": s, "memories": n})).collect::<Vec<_>>())))
}

async fn stats(State(st): State<AppState>) -> ApiResult<Stats> {
    let t = st.engine.cfg.memory.tenant.clone();
    Ok(Json(st.engine.store.stats(&t).await?))
}

#[derive(Deserialize)]
struct AuditParams {
    limit: Option<usize>,
}

async fn audit(State(st): State<AppState>, Query(p): Query<AuditParams>) -> ApiResult<Vec<AuditEvent>> {
    let t = st.engine.cfg.memory.tenant.clone();
    Ok(Json(st.engine.store.audit_log(&t, p.limit.unwrap_or(100).min(1000)).await?))
}

async fn mcp_http(State(st): State<AppState>, headers: HeaderMap, Json(msg): Json<serde_json::Value>) -> Response {
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
