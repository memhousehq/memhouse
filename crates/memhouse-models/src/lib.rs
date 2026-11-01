//! Model clients: embedders, rerankers and chat models (TR-MS-01, TR-LT-06).
//! `local` runs ONNX models in-process (offline after the first download);
//! `openai` talks to any OpenAI-compatible endpoint (OpenAI, Ollama, vLLM, LM Studio...).

use anyhow::Context;
use async_trait::async_trait;
use memhouse_core::config::{Config, EmbeddingConfig, LlmConfig, RerankConfig};
use memhouse_core::{ChatModel, EmbedKind, Embedder, Reranker};
use serde_json::json;
use std::sync::Arc;

#[cfg(feature = "local")]
pub mod local {
    use super::*;
    use fastembed::{EmbeddingModel, RerankInitOptions, RerankerModel, TextEmbedding, TextInitOptions, TextRerank};
    use std::sync::Mutex;

    fn model_cache_dir(cfg_dir: &Option<std::path::PathBuf>) -> std::path::PathBuf {
        cfg_dir.clone().unwrap_or_else(|| memhouse_core::config::home_dir().join("models"))
    }

    pub fn resolve_embedding(name: &str) -> anyhow::Result<(EmbeddingModel, usize, String)> {
        let want = name.to_ascii_lowercase();
        let models = TextEmbedding::list_supported_models();
        let pick = models
            .iter()
            .find(|m| m.model_code.to_ascii_lowercase().ends_with(&format!("/{want}")))
            .or_else(|| models.iter().find(|m| m.model_code.to_ascii_lowercase() == want))
            .or_else(|| models.iter().find(|m| m.model_code.to_ascii_lowercase().contains(&want)));
        match pick {
            Some(m) => Ok((m.model.clone(), m.dim, m.model_code.clone())),
            None => anyhow::bail!(
                "unknown local embedding model '{name}'. Available: {}",
                models.iter().map(|m| m.model_code.rsplit('/').next().unwrap_or("").to_string()).collect::<Vec<_>>().join(", ")
            ),
        }
    }

    pub fn list_embedding_models() -> Vec<(String, usize, String)> {
        TextEmbedding::list_supported_models().into_iter().map(|m| (m.model_code, m.dim, m.description)).collect()
    }

    /// A fixed set of model sessions. A few sessions with a few threads each use a CPU far better
    /// than one session with every core for the small batches memory workloads produce.
    pub(crate) struct Pool<T> {
        items: Mutex<Vec<T>>,
        ready: std::sync::Condvar,
        pub(crate) size: usize,
    }

    impl<T> Pool<T> {
        pub(crate) fn new(items: Vec<T>) -> Pool<T> {
            let size = items.len();
            Pool { items: Mutex::new(items), ready: std::sync::Condvar::new(), size }
        }

        pub(crate) fn with<R>(&self, f: impl FnOnce(&mut T) -> R) -> anyhow::Result<R> {
            let mut item = {
                let mut g = self.items.lock().map_err(|_| anyhow::anyhow!("model pool poisoned"))?;
                loop {
                    if let Some(it) = g.pop() {
                        break it;
                    }
                    g = self.ready.wait(g).map_err(|_| anyhow::anyhow!("model pool poisoned"))?;
                }
            };
            let r = f(&mut item);
            self.items.lock().map_err(|_| anyhow::anyhow!("model pool poisoned"))?.push(item);
            self.ready.notify_one();
            Ok(r)
        }
    }

    /// Sessions and threads per session for this machine (or the configured values).
    pub(crate) fn pool_shape(sessions: usize, threads: usize) -> (usize, usize) {
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
        let s = if sessions > 0 { sessions } else { (cores / 2).clamp(1, 4) };
        let t = if threads > 0 { threads } else { (cores / s).max(1) };
        (s, t)
    }

    pub struct LocalEmbedder {
        id: String,
        dim: usize,
        batch: usize,
        max_len: usize,
        pool: Arc<Pool<TextEmbedding>>,
    }

    /// Plain CPU execution without the growing memory arena. The default provider set on macOS can
    /// route through CoreML, which recompiles for every new input shape (very slow, many GB of RAM).
    pub(crate) fn cpu_provider() -> Vec<fastembed::ExecutionProviderDispatch> {
        vec![ort::ep::CPU::default().with_arena_allocator(false).build()]
    }

    /// Approximate tokens per padded batch. Batches are padded to their longest text, so texts are
    /// sorted by length and grouped until this budget is reached; memory stays flat (~100s of MB).
    const BATCH_TOKEN_BUDGET: usize = 8192;

    pub(crate) fn plan_batches(texts: &[String], max_batch: usize, max_len: usize) -> Vec<Vec<usize>> {
        let mut order: Vec<usize> = (0..texts.len()).collect();
        order.sort_by_key(|&i| std::cmp::Reverse(texts[i].len()));
        let mut batches = vec![];
        let mut cur: Vec<usize> = vec![];
        let mut cur_max = 0usize;
        for i in order {
            let toks = (texts[i].len() / 4 + 2).min(max_len).max(1);
            let new_max = cur_max.max(toks);
            if !cur.is_empty() && (cur.len() >= max_batch || new_max * (cur.len() + 1) > BATCH_TOKEN_BUDGET) {
                batches.push(std::mem::take(&mut cur));
                cur_max = 0;
            }
            cur_max = cur_max.max(toks);
            cur.push(i);
        }
        if !cur.is_empty() {
            batches.push(cur);
        }
        batches
    }

    impl LocalEmbedder {
        pub fn new(cfg: &EmbeddingConfig, show_progress: bool) -> anyhow::Result<LocalEmbedder> {
            let (model, dim, code) = resolve_embedding(&cfg.model)?;
            let (sessions, threads) = pool_shape(cfg.sessions, cfg.threads);
            let mut items = Vec::with_capacity(sessions);
            for i in 0..sessions {
                let opts = TextInitOptions::new(model.clone())
                    .with_max_length(cfg.max_length)
                    .with_cache_dir(model_cache_dir(&cfg.cache_dir))
                    .with_execution_providers(cpu_provider())
                    .with_intra_threads(threads)
                    .with_show_download_progress(show_progress && i == 0);
                items.push(TextEmbedding::try_new(opts).with_context(|| format!("loading local embedding model {code}"))?);
            }
            Ok(LocalEmbedder { id: format!("local:{code}"), dim, batch: cfg.batch_size.max(1), max_len: cfg.max_length, pool: Arc::new(Pool::new(items)) })
        }
    }

    #[async_trait]
    impl Embedder for LocalEmbedder {
        fn id(&self) -> &str {
            &self.id
        }
        fn dim(&self) -> usize {
            self.dim
        }
        async fn embed(&self, texts: &[String], _kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>> {
            if texts.is_empty() {
                return Ok(vec![]);
            }
            let pool = self.pool.clone();
            let texts = texts.to_vec();
            let batches = plan_batches(&texts, self.batch, self.max_len);
            tokio::task::spawn_blocking(move || {
                // Spread the batches of one call over the pool; each worker holds one session at a time.
                let next = std::sync::atomic::AtomicUsize::new(0);
                let workers = pool.size.min(batches.len()).max(1);
                let results: Vec<anyhow::Result<Vec<(usize, Vec<f32>)>>> = std::thread::scope(|s| {
                    let handles: Vec<_> = (0..workers)
                        .map(|_| {
                            s.spawn(|| -> anyhow::Result<Vec<(usize, Vec<f32>)>> {
                                let mut done = vec![];
                                loop {
                                    let j = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                                    let Some(b) = batches.get(j) else { break };
                                    let chunk: Vec<&str> = b.iter().map(|&i| texts[i].as_str()).collect();
                                    let vecs = pool.with(|m| m.embed(&chunk, Some(chunk.len())))?.map_err(|e| anyhow::anyhow!("embedding failed: {e}"))?;
                                    done.extend(b.iter().copied().zip(vecs));
                                }
                                Ok(done)
                            })
                        })
                        .collect();
                    handles.into_iter().map(|h| h.join().unwrap_or_else(|_| Err(anyhow::anyhow!("embedding thread panicked")))).collect()
                });
                let mut out: Vec<Vec<f32>> = vec![vec![]; texts.len()];
                for r in results {
                    for (i, v) in r? {
                        out[i] = v;
                    }
                }
                Ok(out)
            })
            .await?
        }
    }

    pub struct LocalReranker {
        id: String,
        max_length: usize,
        model: Arc<Mutex<TextRerank>>,
    }

    impl LocalReranker {
        pub fn new(cfg: &RerankConfig, cache_dir: &Option<std::path::PathBuf>, show_progress: bool) -> anyhow::Result<LocalReranker> {
            let want = cfg.model.to_ascii_lowercase();
            let models = TextRerank::list_supported_models();
            let pick = models
                .iter()
                .find(|m| m.model_code.to_ascii_lowercase().ends_with(&format!("/{want}")))
                .or_else(|| models.iter().find(|m| m.model_code.to_ascii_lowercase().contains(&want)))
                .ok_or_else(|| anyhow::anyhow!("unknown reranker '{}'. Available: {}", cfg.model, models.iter().map(|m| m.model_code.clone()).collect::<Vec<_>>().join(", ")))?;
            let model: RerankerModel = pick.model.clone();
            let opts = RerankInitOptions::new(model)
                .with_max_length(cfg.max_length)
                .with_cache_dir(model_cache_dir(cache_dir))
                .with_execution_providers(cpu_provider())
                .with_intra_threads(std::env::var("MEMHOUSE_RERANK_THREADS").ok().and_then(|v| v.parse().ok()).unwrap_or_else(|| pool_shape(0, 0).1.max(2)))
                .with_show_download_progress(show_progress);
            let rr = TextRerank::try_new(opts).with_context(|| format!("loading reranker {}", pick.model_code))?;
            Ok(LocalReranker { id: format!("local:{}", pick.model_code), max_length: cfg.max_length, model: Arc::new(Mutex::new(rr)) })
        }
    }

    #[async_trait]
    impl Reranker for LocalReranker {
        fn id(&self) -> &str {
            &self.id
        }
        async fn rerank(&self, query: &str, docs: &[String]) -> anyhow::Result<Vec<f32>> {
            let model = self.model.clone();
            let q = query.to_string();
            let d = docs.to_vec();
            let n = d.len();
            let max_len = self.max_length;
            tokio::task::spawn_blocking(move || {
                let mut m = model.lock().map_err(|_| anyhow::anyhow!("reranker lock poisoned"))?;
                // Same length-sorted token-budget batching as the embedder: padding a batch to its
                // longest pair is what makes cross-encoders slow on mixed-length memories.
                let mut scores = vec![f32::MIN; n];
                for batch in plan_batches(&d, 8, max_len) {
                    let refs: Vec<&str> = batch.iter().map(|&i| d[i].as_str()).collect();
                    let res = m.rerank(q.as_str(), refs, false, Some(batch.len())).map_err(|e| anyhow::anyhow!("rerank failed: {e}"))?;
                    for r in res {
                        scores[batch[r.index]] = r.score;
                    }
                }
                Ok(scores)
            })
            .await?
        }
    }
}

fn api_key(env: &Option<String>) -> Option<String> {
    env.as_ref().and_then(|k| std::env::var(k).ok()).filter(|k| !k.is_empty())
}

/// Embeddings over the OpenAI `/embeddings` API shape.
pub struct OpenAiEmbedder {
    id: String,
    dim: usize,
    url: String,
    model: String,
    key: Option<String>,
    batch: usize,
    http: reqwest::Client,
}

impl OpenAiEmbedder {
    pub fn new(cfg: &EmbeddingConfig) -> anyhow::Result<OpenAiEmbedder> {
        let base = cfg.base_url.clone().unwrap_or_else(|| "https://api.openai.com/v1".into());
        Ok(OpenAiEmbedder {
            id: format!("openai:{}@{}", cfg.model, base),
            dim: cfg.dim,
            url: format!("{}/embeddings", base.trim_end_matches('/')),
            model: cfg.model.clone(),
            key: api_key(&cfg.api_key_env),
            batch: cfg.batch_size.max(1),
            http: reqwest::Client::builder().timeout(std::time::Duration::from_secs(120)).build()?,
        })
    }
}

#[async_trait]
impl Embedder for OpenAiEmbedder {
    fn id(&self) -> &str {
        &self.id
    }
    fn dim(&self) -> usize {
        self.dim
    }
    async fn embed(&self, texts: &[String], _kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>> {
        let mut out = Vec::with_capacity(texts.len());
        for chunk in texts.chunks(self.batch) {
            let mut req = self.http.post(&self.url).json(&json!({ "model": self.model, "input": chunk }));
            if let Some(k) = &self.key {
                req = req.bearer_auth(k);
            }
            let resp = req.send().await.with_context(|| format!("calling {}", self.url))?;
            let status = resp.status();
            let body: serde_json::Value = resp.json().await?;
            if !status.is_success() {
                anyhow::bail!("embedding endpoint returned {status}: {body}");
            }
            let mut data: Vec<(usize, Vec<f32>)> = body["data"]
                .as_array()
                .ok_or_else(|| anyhow::anyhow!("embedding response has no data: {body}"))?
                .iter()
                .enumerate()
                .map(|(i, d)| {
                    let idx = d["index"].as_u64().map(|x| x as usize).unwrap_or(i);
                    let v = d["embedding"].as_array().map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect()).unwrap_or_default();
                    (idx, v)
                })
                .collect();
            data.sort_by_key(|(i, _)| *i);
            for (_, v) in data {
                if v.len() != self.dim {
                    anyhow::bail!("model {} returned {} dimensions, config says {} (embedding.dim)", self.model, v.len(), self.dim);
                }
                out.push(v);
            }
        }
        Ok(out)
    }
}

pub fn build_embedder(cfg: &Config, show_progress: bool) -> anyhow::Result<Arc<dyn Embedder>> {
    match cfg.embedding.provider.as_str() {
        #[cfg(feature = "local")]
        "local" => Ok(Arc::new(local::LocalEmbedder::new(&cfg.embedding, show_progress)?)),
        "openai" | "ollama" | "openai-compatible" => Ok(Arc::new(OpenAiEmbedder::new(&cfg.embedding)?)),
        other => anyhow::bail!("unknown embedding provider '{other}' (use local or openai)"),
    }
}

pub fn build_reranker(cfg: &Config, show_progress: bool) -> anyhow::Result<Option<Arc<dyn Reranker>>> {
    if !cfg.rerank.enabled {
        return Ok(None);
    }
    #[cfg(feature = "local")]
    {
        Ok(Some(Arc::new(local::LocalReranker::new(&cfg.rerank, &cfg.embedding.cache_dir, show_progress)?)))
    }
    #[cfg(not(feature = "local"))]
    {
        let _ = show_progress;
        anyhow::bail!("reranking needs the `local` feature")
    }
}

pub use memhouse_core::types::LlmUsage;

pub struct Completion {
    pub text: String,
    pub usage: LlmUsage,
}

/// Minimal chat client (OpenAI-compatible chat completions or Anthropic messages).
#[derive(Clone)]
pub struct Llm {
    cfg: LlmConfig,
    key: Option<String>,
    http: reqwest::Client,
    /// USD per million (prompt, completion) tokens, used when the provider reports no cost.
    price: Option<(f64, f64)>,
}

impl Llm {
    pub fn new(cfg: &LlmConfig) -> anyhow::Result<Llm> {
        Ok(Llm { cfg: cfg.clone(), key: api_key(&cfg.api_key_env), http: reqwest::Client::builder().timeout(std::time::Duration::from_secs(300)).build()?, price: None })
    }

    pub fn with_price(mut self, price: Option<(f64, f64)>) -> Llm {
        self.price = price;
        self
    }

    pub fn id(&self) -> String {
        format!("{}:{}", self.cfg.provider, self.cfg.model)
    }

    pub async fn complete(&self, system: &str, user: &str) -> anyhow::Result<String> {
        Ok(self.complete_with_usage(system, user).await?.text)
    }

    /// Like `complete`, plus token counts, cost and wall time. Tokens and cost cover every
    /// attempt that returned a response.
    pub async fn complete_with_usage(&self, system: &str, user: &str) -> anyhow::Result<Completion> {
        let start = std::time::Instant::now();
        let mut attempt = 0;
        loop {
            attempt += 1;
            match self.complete_once(system, user).await {
                Ok(mut c) => {
                    c.usage.ms = start.elapsed().as_secs_f64() * 1000.0;
                    c.usage.attempts = attempt;
                    return Ok(c);
                }
                Err(e) if attempt < 5 => {
                    tracing::warn!("llm call failed (attempt {attempt}): {e:#}");
                    tokio::time::sleep(std::time::Duration::from_millis(500 * 2u64.pow(attempt))).await;
                }
                Err(e) => return Err(e),
            }
        }
    }

    async fn complete_once(&self, system: &str, user: &str) -> anyhow::Result<Completion> {
        let base = self.cfg.base_url.trim_end_matches('/');
        let (url, body) = if self.cfg.provider == "anthropic" {
            (
                format!("{base}/messages"),
                json!({
                    "model": self.cfg.model, "max_tokens": self.cfg.max_tokens, "temperature": self.cfg.temperature,
                    "system": system, "messages": [{"role": "user", "content": user}]
                }),
            )
        } else {
            (
                format!("{base}/chat/completions"),
                json!({
                    "model": self.cfg.model, "max_tokens": self.cfg.max_tokens, "temperature": self.cfg.temperature,
                    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]
                }),
            )
        };
        let mut body = body;
        if let (Some(extra), Some(obj)) = (self.cfg.extra.as_ref().and_then(|e| e.as_object()), body.as_object_mut()) {
            for (k, v) in extra {
                obj.insert(k.clone(), v.clone());
            }
        }
        if base.contains("openrouter.ai") {
            // Ask OpenRouter to report the exact charged cost in `usage.cost`.
            body["usage"] = json!({"include": true});
        }
        let mut req = self.http.post(&url).json(&body);
        if let Some(k) = &self.key {
            req = if self.cfg.provider == "anthropic" { req.header("x-api-key", k).header("anthropic-version", "2023-06-01") } else { req.bearer_auth(k) };
        }
        let resp = req.send().await.with_context(|| format!("calling {url}"))?;
        let status = resp.status();
        let v: serde_json::Value = resp.json().await?;
        if !status.is_success() {
            anyhow::bail!("{url} returned {status}: {v}");
        }
        let text = if self.cfg.provider == "anthropic" {
            v["content"].as_array().map(|a| a.iter().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("")).unwrap_or_default()
        } else {
            v["choices"][0]["message"]["content"].as_str().unwrap_or_default().to_string()
        };
        let u = &v["usage"];
        let tok = |a: &str, b: &str| u[a].as_u64().or_else(|| u[b].as_u64()).unwrap_or(0);
        let (prompt_tokens, completion_tokens) = (tok("prompt_tokens", "input_tokens"), tok("completion_tokens", "output_tokens"));
        let reported = u["cost"].as_f64();
        let cost_usd = reported.or_else(|| self.price.map(|(pi, po)| (prompt_tokens as f64 * pi + completion_tokens as f64 * po) / 1e6));
        Ok(Completion { text, usage: LlmUsage { prompt_tokens, completion_tokens, cost_usd, cost_reported: reported.is_some(), ms: 0.0, attempts: 1 } })
    }
}

#[async_trait]
impl ChatModel for Llm {
    /// Provider, model and endpoint host: the endpoint is part of the extraction-cache key, so
    /// answers from a local mock or another provider never stand in for the real model.
    fn id(&self) -> String {
        let host = self.cfg.base_url.split("://").nth(1).unwrap_or(&self.cfg.base_url).split('/').next().unwrap_or("");
        format!("{}@{host}", Llm::id(self))
    }
    async fn chat(&self, system: &str, user: &str) -> anyhow::Result<(String, LlmUsage)> {
        let c = self.complete_with_usage(system, user).await?;
        Ok((c.text, c.usage))
    }
}

/// The enrichment LLM from config, priced from `price` when the provider reports no cost.
pub fn enrich_chat(cfg: &Config, price: Option<(f64, f64)>) -> anyhow::Result<Option<Arc<dyn ChatModel>>> {
    if !cfg.enrich.enabled {
        return Ok(None);
    }
    Ok(Some(Arc::new(Llm::new(&cfg.enrich.llm)?.with_price(price))))
}

#[cfg(all(test, feature = "local"))]
mod tests {
    use super::local::plan_batches;

    #[test]
    fn batches_respect_token_budget_and_cover_all() {
        let texts: Vec<String> = (0..100).map(|i| "x".repeat(40 * (i % 50) + 4)).collect();
        let b = plan_batches(&texts, 32, 512);
        let mut seen: Vec<usize> = b.iter().flatten().copied().collect();
        seen.sort();
        assert_eq!(seen, (0..100).collect::<Vec<_>>());
        for batch in &b {
            let max = batch.iter().map(|&i| (texts[i].len() / 4 + 2).min(512)).max().unwrap();
            assert!(batch.len() == 1 || max * batch.len() <= 8192);
            assert!(batch.len() <= 32);
        }
    }
}
