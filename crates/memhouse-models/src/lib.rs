//! Model clients: embedders, rerankers and chat models (TR-MS-01, TR-LT-06).
//! `local` runs ONNX models in-process (offline after the first download);
//! `openai` talks to any OpenAI-compatible endpoint (OpenAI, Ollama, vLLM, LM Studio...).

use anyhow::Context;
use async_trait::async_trait;
use memhouse_core::config::{Config, EmbeddingConfig, LlmConfig, RerankConfig};
use memhouse_core::{EmbedKind, Embedder, Reranker};
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
        TextEmbedding::list_supported_models()
            .into_iter()
            .map(|m| (m.model_code, m.dim, m.description))
            .collect()
    }

    pub struct LocalEmbedder {
        id: String,
        dim: usize,
        batch: usize,
        model: Arc<Mutex<TextEmbedding>>,
    }

    impl LocalEmbedder {
        pub fn new(cfg: &EmbeddingConfig, show_progress: bool) -> anyhow::Result<LocalEmbedder> {
            let (model, dim, code) = resolve_embedding(&cfg.model)?;
            let opts = TextInitOptions::new(model)
                .with_max_length(cfg.max_length)
                .with_cache_dir(model_cache_dir(&cfg.cache_dir))
                .with_show_download_progress(show_progress);
            let te = TextEmbedding::try_new(opts).with_context(|| format!("loading local embedding model {code}"))?;
            Ok(LocalEmbedder { id: format!("local:{code}"), dim, batch: cfg.batch_size.max(1), model: Arc::new(Mutex::new(te)) })
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
            let model = self.model.clone();
            let texts = texts.to_vec();
            let batch = self.batch;
            tokio::task::spawn_blocking(move || {
                let mut m = model.lock().map_err(|_| anyhow::anyhow!("embedding model lock poisoned"))?;
                m.embed(&texts, Some(batch)).map_err(|e| anyhow::anyhow!("embedding failed: {e}"))
            })
            .await?
        }
    }

    pub struct LocalReranker {
        id: String,
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
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "unknown reranker '{}'. Available: {}",
                        cfg.model,
                        models.iter().map(|m| m.model_code.clone()).collect::<Vec<_>>().join(", ")
                    )
                })?;
            let model: RerankerModel = pick.model.clone();
            let opts = RerankInitOptions::new(model)
                .with_max_length(cfg.max_length)
                .with_cache_dir(model_cache_dir(cache_dir))
                .with_show_download_progress(show_progress);
            let rr = TextRerank::try_new(opts).with_context(|| format!("loading reranker {}", pick.model_code))?;
            Ok(LocalReranker { id: format!("local:{}", pick.model_code), model: Arc::new(Mutex::new(rr)) })
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
            tokio::task::spawn_blocking(move || {
                let mut m = model.lock().map_err(|_| anyhow::anyhow!("reranker lock poisoned"))?;
                let refs: Vec<&str> = d.iter().map(|s| s.as_str()).collect();
                let res = m.rerank(q.as_str(), refs, false, Some(16)).map_err(|e| anyhow::anyhow!("rerank failed: {e}"))?;
                let mut scores = vec![f32::MIN; n];
                for r in res {
                    scores[r.index] = r.score;
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

/// Minimal chat client (OpenAI-compatible chat completions or Anthropic messages).
#[derive(Clone)]
pub struct Llm {
    cfg: LlmConfig,
    key: Option<String>,
    http: reqwest::Client,
}

impl Llm {
    pub fn new(cfg: &LlmConfig) -> anyhow::Result<Llm> {
        Ok(Llm {
            cfg: cfg.clone(),
            key: api_key(&cfg.api_key_env),
            http: reqwest::Client::builder().timeout(std::time::Duration::from_secs(300)).build()?,
        })
    }

    pub fn id(&self) -> String {
        format!("{}:{}", self.cfg.provider, self.cfg.model)
    }

    pub async fn complete(&self, system: &str, user: &str) -> anyhow::Result<String> {
        let mut attempt = 0;
        loop {
            attempt += 1;
            match self.complete_once(system, user).await {
                Ok(s) => return Ok(s),
                Err(e) if attempt < 5 => {
                    tracing::warn!("llm call failed (attempt {attempt}): {e:#}");
                    tokio::time::sleep(std::time::Duration::from_millis(500 * 2u64.pow(attempt))).await;
                }
                Err(e) => return Err(e),
            }
        }
    }

    async fn complete_once(&self, system: &str, user: &str) -> anyhow::Result<String> {
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
        let mut req = self.http.post(&url).json(&body);
        if let Some(k) = &self.key {
            req = if self.cfg.provider == "anthropic" {
                req.header("x-api-key", k).header("anthropic-version", "2023-06-01")
            } else {
                req.bearer_auth(k)
            };
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
        Ok(text)
    }
}
