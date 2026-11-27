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
    /// The workers not yet known to have ended.
    workers: Vec<JoinHandle<()>>,
    /// `None` once it has ended.
    retention: Option<JoinHandle<()>>,
    /// How long [`Background::stop`] lets a worker finish its job before cancelling it.
    grace: std::time::Duration,
}

/// The time a worker gets to finish its current job at shutdown.
const GRACE: std::time::Duration = std::time::Duration::from_secs(10);

impl Background {
    /// Start the workers on the current tokio runtime.
    pub fn start(engine: &Engine) -> Background {
        let stop = Arc::new(AtomicBool::new(false));
        let mut workers = if enrichment_runs(engine) { engine.spawn_enrichment(engine.cfg.enrich.workers, stop.clone(), Default::default()) } else { vec![] };
        // The write pipeline's workers resume proposals left by a restart (TR-LT-05).
        workers.extend(engine.spawn_intake(engine.cfg.intake.workers, stop.clone()));
        let e = engine.clone();
        // One task for everything that runs on a clock, so one handle stops it all: the hourly
        // retention pass (which also carries out deletions whose legal hold was released), the
        // anchors of the audit head (GOV-12) and the SIEM export (GOV-15).
        let retention = tokio::spawn(async move {
            let passes = async {
                loop {
                    if let Err(err) = e.apply_retention().await {
                        tracing::warn!("retention: {err:#}");
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
                }
            };
            let anchors = async {
                let path = e.cfg.governance.audit_anchor_path.clone();
                if path.is_empty() {
                    return std::future::pending::<()>().await;
                }
                loop {
                    if let Err(err) = crate::governance::anchor_to(&e, std::path::Path::new(&path), "system").await {
                        tracing::warn!("audit anchor: {err:#}");
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(e.cfg.governance.audit_anchor_secs.max(60))).await;
                }
            };
            let siem = async {
                if !e.cfg.siem.enabled() {
                    return std::future::pending::<()>().await;
                }
                crate::siem::Exporter::new(&e).run().await
            };
            tokio::join!(passes, anchors, siem);
        });
        Background { stop, workers, retention: Some(retention), grace: GRACE }
    }

    /// Stop the workers, and return when none of them runs any more.
    ///
    /// Each worker stops after its current job. One that is still busy ten seconds on (a slow
    /// model call) is cancelled where it waits, and its end is awaited too. What it leaves is
    /// what a process that died there would leave, and is taken up the same way (TR-LT-05):
    ///
    /// - a proposal of the write pipeline stays claimed and is run again from its start once
    ///   the claim lapses (`intake.lease_secs`). Its records reach the store in one
    ///   transaction at the end of the job, so nothing of it is half stored;
    /// - an enrichment job stays claimed for its lease (five minutes) and is then run again.
    ///   A model answer it had already got is in the cache, and its facts are stored in one
    ///   transaction, so the second run pays for no call twice and stores no fact twice.
    ///
    /// Not covered: the writes that the request path finishes on tasks of its own right after
    /// answering (`Engine::nudge`). Those tasks are not this value's, see [`Embedded::shutdown`].
    ///
    /// The value keeps its workers until they have ended: if the future is dropped before it
    /// returns, calling `stop` again waits for the workers that are left, with a new grace
    /// period.
    pub async fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // It checks no flag: it sleeps an hour between passes. Cancelled first, so that the
        // grace period is the workers' alone.
        if let Some(retention) = self.retention.as_mut() {
            retention.abort();
            let _ = retention.await;
            self.retention = None;
        }
        // A handle leaves the list only once its task has ended (a handle must not be awaited
        // again after that), so dropping this future loses none.
        let deadline = tokio::time::Instant::now() + self.grace;
        while let Some(worker) = self.workers.last_mut() {
            if tokio::time::timeout_at(deadline, worker).await.is_err() {
                break;
            }
            self.workers.pop();
        }
        if !self.workers.is_empty() {
            tracing::warn!("{} worker(s) still busy {} s after shutdown began: cancelled; their jobs are run again after their lease", self.workers.len(), self.grace.as_secs());
            for worker in &self.workers {
                worker.abort();
            }
            while let Some(worker) = self.workers.last_mut() {
                let _ = worker.await;
                self.workers.pop();
            }
        }
    }
}

/// Dropped without [`Background::stop`] (an embedding process that never closed): the workers
/// still stop after their current job, and release the store.
impl Drop for Background {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(retention) = &self.retention {
            retention.abort();
        }
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

    /// The router alone, with no background worker: for a command that makes a request or two
    /// and exits (the harness hooks), which must not start a retention pass or take queued
    /// work from the deployment's own workers. Requests pass the same middleware as ever.
    pub fn request_only(engine: Engine) -> Embedded {
        let key = engine.cfg.server.api_keys.first().cloned();
        Embedded { router: router(engine), key, background: tokio::sync::Mutex::new(None), closed: AtomicBool::new(false) }
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

    /// Stop the background workers and refuse further requests. Returns when no worker runs
    /// any more: each ends after its current job, and one still busy ten seconds on is
    /// cancelled, its job to be run again after its lease ([`Background::stop`]).
    ///
    /// Safe to call more than once, also at the same time: every call returns only when the
    /// workers have ended. That holds after a call that was dropped before it returned too:
    /// the workers stay with this value until they have ended, and the next call waits for
    /// those that are left.
    ///
    /// One thing can still run after it returns. A write whose request was answered just
    /// before is finished on a task of the engine's own (`Engine::nudge`), which this value
    /// does not hold: that task ends when the write's job does, and keeps the store open
    /// until then. The store is closed when the value is dropped and no such task is left.
    pub async fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        // Held until the workers have ended: a call that arrives meanwhile waits here.
        let mut background = self.background.lock().await;
        if let Some(b) = background.as_mut() {
            b.stop().await;
        }
        // Only now: had this call been dropped while it waited, the next would find them.
        *background = None;
    }

    /// Whether [`Embedded::shutdown`] was called: requests are refused from then on.
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// Sets its flag when dropped: a task that owns one has ended, finished or cancelled.
    struct Ended(Arc<AtomicBool>);
    impl Drop for Ended {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    /// A stand-in for the workers: `worker` gets the stop flag, as a real one does.
    fn background<F: std::future::Future<Output = ()> + Send + 'static>(grace: Duration, worker: impl FnOnce(Arc<AtomicBool>) -> F) -> Background {
        let stop = Arc::new(AtomicBool::new(false));
        let retention = tokio::spawn(std::future::pending::<()>());
        Background { workers: vec![tokio::spawn(worker(stop.clone()))], stop, retention: Some(retention), grace }
    }

    /// A worker that, once told to stop, needs `rest` to finish its job, then sets `done`.
    fn finishing(rest: Duration, done: Arc<AtomicBool>) -> impl FnOnce(Arc<AtomicBool>) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        move |stop| {
            Box::pin(async move {
                while !stop.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                tokio::time::sleep(rest).await;
                done.store(true, Ordering::SeqCst);
            })
        }
    }

    fn embedded(background: Background) -> Embedded {
        Embedded { router: Router::new(), key: None, background: tokio::sync::Mutex::new(Some(background)), closed: AtomicBool::new(false) }
    }

    #[tokio::test]
    async fn stop_waits_for_a_worker_to_finish_its_job() {
        let done = Arc::new(AtomicBool::new(false));
        let mut b = background(Duration::from_secs(10), finishing(Duration::from_millis(150), done.clone()));
        b.stop().await;
        assert!(done.load(Ordering::SeqCst), "stop returned before the worker had finished");
        assert!(b.workers.is_empty() && b.retention.is_none());
        // Nothing is left to wait for.
        b.stop().await;
    }

    #[tokio::test]
    async fn a_worker_still_busy_after_the_grace_period_is_cancelled_before_stop_returns() {
        let ended = Arc::new(AtomicBool::new(false));
        let owned = Ended(ended.clone());
        // Never finishes, whatever the flag says: a model call that does not return.
        let mut b = background(Duration::from_millis(100), |_stop| async move {
            let _owned = owned;
            std::future::pending::<()>().await
        });
        let started = std::time::Instant::now();
        b.stop().await;
        assert!(started.elapsed() >= Duration::from_millis(100), "the worker was not given its grace period");
        assert!(ended.load(Ordering::SeqCst), "stop returned while the worker's task was still there");
        assert!(b.workers.is_empty());
    }

    #[tokio::test]
    async fn a_shutdown_that_was_dropped_leaves_the_workers_to_the_next_call() {
        let done = Arc::new(AtomicBool::new(false));
        let lite = embedded(background(Duration::from_secs(10), finishing(Duration::from_millis(200), done.clone())));
        // The caller gives up on the first call while it waits for the worker.
        assert!(tokio::time::timeout(Duration::from_millis(20), lite.shutdown()).await.is_err());
        assert!(lite.is_closed() && !done.load(Ordering::SeqCst));
        // The second still has the worker to wait for, and does.
        lite.shutdown().await;
        assert!(done.load(Ordering::SeqCst), "the second shutdown returned while the worker was still running");
        assert!(lite.background.lock().await.is_none());
    }
}
