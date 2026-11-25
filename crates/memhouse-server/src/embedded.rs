// SPDX-License-Identifier: Apache-2.0
//! MemHouse inside another process, without a socket (TR-LT-01): the same router the server
//! runs, called in process. A request passes through the same authentication middleware,
//! authorizer, write gate and audit as one that arrived over HTTP, so the embedded library
//! offers exactly the REST API and nothing beside it.

use crate::{build_engine, router};
use axum::body::Body;
use axum::http::{header, Request};
use axum::Router;
use memhouse_core::{Config, Engine};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::task::JoinHandle;
use tower::ServiceExt;

/// What a served deployment runs beside its router: the enrichment workers (when configured),
/// the write pipeline's workers, and the hourly retention pass. `memhouse serve` and
/// [`Embedded`] both start exactly this.
pub struct Background {
    stop: Arc<AtomicBool>,
    workers: Vec<JoinHandle<()>>,
    retention: JoinHandle<()>,
}

impl Background {
    /// Start the workers on the current tokio runtime.
    pub fn start(engine: &Engine) -> Background {
        let stop = Arc::new(AtomicBool::new(false));
        let mut workers = if enrichment_runs(engine) { engine.spawn_enrichment(engine.cfg.enrich.workers, stop.clone(), Default::default()) } else { vec![] };
        // The write pipeline's workers resume proposals left by a restart (TR-LT-05).
        workers.extend(engine.spawn_intake(engine.cfg.intake.workers, stop.clone()));
        let e = engine.clone();
        let retention = tokio::spawn(async move {
            loop {
                if let Err(err) = e.apply_retention().await {
                    tracing::warn!("retention: {err:#}");
                }
                tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
            }
        });
        Background { stop, workers, retention }
    }

    /// Stop the workers. Each stops after its current job; one stuck on a model call is left
    /// behind after the grace period (its proposal is claimed again after `intake.lease_secs`).
    pub async fn stop(mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.retention.abort();
        let grace = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        for w in std::mem::take(&mut self.workers) {
            if tokio::time::timeout_at(grace, w).await.is_err() {
                tracing::warn!("a worker was still busy at shutdown; its job resumes after the lease");
                break;
            }
        }
    }
}

/// Dropped without [`Background::stop`] (an embedding process that never closed): the workers
/// still stop after their current job, and release the store.
impl Drop for Background {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.retention.abort();
    }
}

/// Whether this engine's configuration starts enrichment workers.
pub fn enrichment_runs(engine: &Engine) -> bool {
    engine.cfg.enrich.enabled && engine.chat.is_some() && engine.cfg.enrich.workers > 0
}

/// What makes a configuration a Lite one, as `memhouse up --lite` writes it: the database is
/// the SQLite file `db`, there is no managed container, and one model session keeps the local
/// embedder within its memory budget (ADR 0002). The API key is the caller's to set.
pub fn lite_defaults(cfg: &mut Config, db: &Path) {
    cfg.database.url = format!("sqlite:{}", db.display());
    cfg.database.container = None;
    cfg.embedding.sessions = 1;
}

/// The configuration of an embedded Lite deployment, as the language bindings open one.
///
/// - `db`: a SQLite file (created if it is not there), with the defaults of the Lite profile
///   ([`lite_defaults`]) and no configuration file. Nothing outside this process needs a key
///   for it, so the bootstrap key is a random one made for this process and kept in memory
///   only: there is still no open mode, and a request that names another credential is still
///   verified.
/// - `config`: a `config.toml`, read as every command reads it (the environment overrides it).
/// - neither: the installation's own configuration (`MEMHOUSE_CONFIG`, or `config.toml` under
///   `MEMHOUSE_HOME`), which must exist.
pub fn embedded_config(db: Option<&Path>, config: Option<&Path>) -> anyhow::Result<Config> {
    match (db, config) {
        (Some(_), Some(_)) => anyhow::bail!("give either the database file (path) or a configuration file (config), not both"),
        (Some(db), None) => {
            let mut cfg = Config::default();
            lite_defaults(&mut cfg, &std::path::absolute(db)?);
            cfg.server.api_keys = vec![process_key()];
            Ok(cfg)
        }
        (None, config) => {
            let path = config.map(Path::to_path_buf).unwrap_or_else(memhouse_core::config::default_config_path);
            // A missing file would otherwise mean the defaults, which name a Postgres server.
            anyhow::ensure!(path.is_file(), "no configuration file at {}: give the SQLite file to use (path), or a config.toml (config)", path.display());
            Config::load(Some(&path))
        }
    }
}

/// A bootstrap key for this process alone, in the shape `memhouse up` gives its keys.
fn process_key() -> String {
    use rand::RngExt;
    const CHARS: &[u8] = b"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut r = rand::rng();
    format!("mh_{}", (0..32).map(|_| CHARS[r.random_range(0..CHARS.len())] as char).collect::<String>())
}

/// A MemHouse deployment embedded in this process.
pub struct Embedded {
    router: Router,
    /// The first key of `[server] api_keys`, sent for a request that carries no credential.
    key: Option<String>,
    background: tokio::sync::Mutex<Option<Background>>,
    closed: AtomicBool,
}

impl Embedded {
    /// Open the deployment `cfg` describes: the store, the models, the migrations and the
    /// background workers of `memhouse serve`. Call it on a multi-threaded tokio runtime that
    /// lives as long as the value; the workers run on it.
    pub async fn open(cfg: Config) -> anyhow::Result<Embedded> {
        Ok(Embedded::from_engine(build_engine(cfg, false).await?))
    }

    /// Embed an engine built elsewhere (tests with stand-in models).
    pub fn from_engine(engine: Engine) -> Embedded {
        let key = engine.cfg.server.api_keys.first().cloned();
        let background = Background::start(&engine);
        Embedded { router: router(engine), key, background: tokio::sync::Mutex::new(Some(background)), closed: AtomicBool::new(false) }
    }

    /// One API request: `path` is the path and query of the REST API (`/v1/recall`), `body` a
    /// JSON document. Returns the status and the response body. A header may be given once:
    /// a name repeated in any letter case is an error, and nothing is sent.
    ///
    /// Authentication is the server's (GOV-01): the middleware verifies the credential of every
    /// request. The process that embeds MemHouse holds its configuration, and with it the
    /// bootstrap key, so a request with neither `Authorization` nor `x-api-key` is sent with
    /// that key, as a local client reading the same configuration would send it. A request that
    /// names a credential is verified as it stands: a wrong one is refused and audited.
    pub async fn request(&self, method: &str, path: &str, headers: &[(String, String)], body: Option<&[u8]>) -> anyhow::Result<(u16, Vec<u8>)> {
        anyhow::ensure!(!self.closed.load(Ordering::Acquire), "this embedded MemHouse is closed");
        // Header names are case-insensitive, and the API reads one value of each. Two entries
        // for one name (`Authorization` and `authorization` in a map whose order is arbitrary)
        // would make which credential is verified a matter of chance: refuse them.
        for (i, (name, _)) in headers.iter().enumerate() {
            anyhow::ensure!(
                !headers[..i].iter().any(|(k, _)| k.eq_ignore_ascii_case(name)),
                "invalid request: the header {} is given more than once (header names are case-insensitive)",
                name.to_ascii_lowercase()
            );
        }
        let mut req = Request::builder().method(method).uri(path);
        let named = |name: &str| headers.iter().any(|(k, _)| k.eq_ignore_ascii_case(name));
        for (k, v) in headers {
            req = req.header(k, v);
        }
        if body.is_some() && !named("content-type") {
            req = req.header(header::CONTENT_TYPE, "application/json");
        }
        if !named("authorization") && !named("x-api-key") {
            if let Some(key) = &self.key {
                req = req.header(header::AUTHORIZATION, format!("Bearer {key}"));
            }
        }
        let req = req.body(Body::from(body.map(<[u8]>::to_vec).unwrap_or_default())).map_err(|e| anyhow::anyhow!("invalid request: {e}"))?;
        let resp = match self.router.clone().oneshot(req).await {
            Ok(r) => r,
            Err(never) => match never {},
        };
        let status = resp.status().as_u16();
        // The limit is the response's own: everything comes from this process.
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await?;
        Ok((status, bytes.to_vec()))
    }

    /// Stop the background workers and refuse further requests. Safe to call more than once,
    /// also at the same time: every call returns only when the workers have stopped.
    /// The store is closed when the value is dropped.
    pub async fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        // Held until the workers have stopped: a call that arrives meanwhile waits here.
        let mut background = self.background.lock().await;
        if let Some(b) = background.take() {
            b.stop().await;
        }
    }

    /// Whether [`Embedded::shutdown`] was called: requests are refused from then on.
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }
}
