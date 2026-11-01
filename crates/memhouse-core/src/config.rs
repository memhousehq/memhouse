// SPDX-License-Identifier: Apache-2.0
//! Configuration: one TOML file (`~/.memhouse/config.toml` by default), every field
//! overridable by environment variables so agents and containers can configure it too.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub database: DatabaseConfig,
    pub embedding: EmbeddingConfig,
    pub rerank: RerankConfig,
    pub llm: Option<LlmConfig>,
    /// Asynchronous LLM enrichment: facts extracted from stored conversations.
    pub enrich: EnrichConfig,
    pub server: ServerConfig,
    pub memory: MemoryConfig,
    pub governance: GovernanceConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DatabaseConfig {
    pub url: String,
    pub max_connections: u32,
    /// Name of the Docker container managed by `memhouse up` (if any).
    pub container: Option<String>,
}

impl Default for DatabaseConfig {
    fn default() -> Self {
        DatabaseConfig { url: "postgres://memhouse:memhouse@127.0.0.1:54329/memhouse".into(), max_connections: 16, container: None }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct EmbeddingConfig {
    /// `local` (bundled ONNX model, offline) or `openai` (any OpenAI-compatible endpoint:
    /// OpenAI, Ollama, vLLM, LM Studio, Azure-compatible gateways).
    pub provider: String,
    pub model: String,
    /// Vector dimension. Fixed per database at `init` time (TR-MS-04).
    pub dim: usize,
    pub base_url: Option<String>,
    /// Name of the environment variable that holds the API key (never the key itself).
    pub api_key_env: Option<String>,
    /// API providers: send `dimensions = dim` with each request, for models that can shorten
    /// their vectors (OpenAI `text-embedding-3-*`). Changes the embedder identity.
    pub request_dimensions: bool,
    /// API providers: seconds before one request is abandoned.
    pub timeout_secs: u64,
    /// API providers: retries after a 429, a 5xx or a connection error, with backoff.
    pub max_retries: u32,
    /// Max tokens the local model reads per text.
    pub max_length: usize,
    pub batch_size: usize,
    /// Parallel local model sessions (0 = auto: half the cores, at most 4).
    pub sessions: usize,
    /// CPU threads per local model session (0 = auto: cores / sessions).
    pub threads: usize,
    pub cache_dir: Option<PathBuf>,
    /// Prefix added to queries (some models need one, e.g. "search_query: ").
    pub query_prefix: Option<String>,
    pub passage_prefix: Option<String>,
}

impl Default for EmbeddingConfig {
    fn default() -> Self {
        EmbeddingConfig {
            provider: "local".into(),
            model: "bge-small-en-v1.5".into(),
            dim: 384,
            base_url: None,
            api_key_env: None,
            request_dimensions: false,
            timeout_secs: 60,
            max_retries: 3,
            max_length: 512,
            batch_size: 1,
            sessions: 0,
            threads: 0,
            cache_dir: None,
            query_prefix: Some("Represent this sentence for searching relevant passages: ".into()),
            passage_prefix: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct RerankConfig {
    pub enabled: bool,
    /// `local` cross-encoder model name.
    pub model: String,
    /// How many fused candidates are re-scored.
    pub candidates: usize,
    pub max_length: usize,
    /// Weight of the fused (keyword + vector) rank blended with the cross-encoder score.
    pub fused_weight: f32,
}

impl Default for RerankConfig {
    fn default() -> Self {
        RerankConfig { enabled: false, model: "jina-reranker-v1-turbo-en".into(), candidates: 20, max_length: 256, fused_weight: 0.15 }
    }
}

/// Optional chat model, used by the benchmark (answer + judge) and by optional fact extraction.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct LlmConfig {
    /// `openai` (OpenAI-compatible chat completions) or `anthropic`.
    pub provider: String,
    pub base_url: String,
    pub model: String,
    pub api_key_env: Option<String>,
    pub max_tokens: u32,
    pub temperature: f32,
    /// Extra JSON merged into every request body (e.g. `{"reasoning": {"enabled": false}}`).
    pub extra: Option<serde_json::Value>,
}

impl Default for LlmConfig {
    fn default() -> Self {
        LlmConfig {
            provider: "openai".into(),
            base_url: "https://api.openai.com/v1".into(),
            model: "gpt-4o-mini".into(),
            api_key_env: Some("OPENAI_API_KEY".into()),
            max_tokens: 512,
            temperature: 0.0,
            extra: None,
        }
    }
}

/// Background fact extraction. Ingest stores rounds at once and queues a job per session;
/// workers call a small LLM, and the facts it returns go through the write gate like any
/// other memory. Recall never waits for it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct EnrichConfig {
    /// Queue a job for every ingested session.
    pub enabled: bool,
    /// Run workers in this process (`memhouse serve`, `memhouse bench`).
    pub workers: usize,
    pub llm: LlmConfig,
    /// Characters of each assistant reply shown to the extractor (user text is sent in full).
    pub assistant_chars: usize,
    /// Sessions whose user text is shorter than this are skipped without an LLM call.
    pub min_user_chars: usize,
    pub max_attempts: i32,
    /// Stop calling the LLM once this process has spent this much (USD); 0 = no limit.
    pub max_cost_usd: f64,
}

impl Default for EnrichConfig {
    fn default() -> Self {
        EnrichConfig {
            enabled: false,
            workers: 8,
            llm: LlmConfig {
                base_url: "https://openrouter.ai/api/v1".into(),
                model: "qwen/qwen3.7-flash".into(),
                max_tokens: 3000,
                extra: Some(serde_json::json!({ "reasoning": { "enabled": false } })),
                ..LlmConfig::default()
            },
            assistant_chars: 300,
            min_user_chars: 40,
            max_attempts: 4,
            max_cost_usd: 0.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ServerConfig {
    pub bind: String,
    /// API keys accepted by the REST and HTTP MCP endpoints. Generated by `memhouse init`.
    pub api_keys: Vec<String>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        ServerConfig { bind: "127.0.0.1:7077".into(), api_keys: vec![] }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryConfig {
    pub tenant: String,
    /// Subject used when a call does not name one (e.g. `user:me`, `repo:myproject`).
    pub default_subject: String,
    pub default_k: usize,
    /// Candidates fetched per retriever before fusion.
    pub candidates: usize,
    pub rrf_k: f32,
    pub keyword_weight: f32,
    pub vector_weight: f32,
    /// Cosine similarity above which a new explicit memory counts as a duplicate.
    pub dedup_threshold: f32,
    /// Recency bonus weight (0 disables). Applied as w / (1 + age_days / half_life_days).
    pub recency_weight: f32,
    pub recency_half_life_days: f32,
    /// Characters of assistant text kept when indexing an episodic round.
    pub assistant_chars: usize,
    /// Read time expressions ("two weeks ago", "in March") and comparisons ("A or B") from the
    /// query and run extra retrieval probes for them.
    pub query_analysis: bool,
    /// RRF weight of the probe restricted to the query's time windows.
    pub window_weight: f32,
    /// The top N hits of the time-window probe get an extra RRF weight of `window_top_weight`
    /// (0 = off). A few strongly promoted in-window hits find the dated memory without
    /// demoting everything outside the window.
    pub window_top: usize,
    pub window_top_weight: f32,
    /// RRF weight of each sub-query probe (0 = off: on LongMemEval they added noise).
    pub subquery_weight: f32,
    /// Active template (support, sales, success, coding, personal).
    pub template: Option<String>,
}

impl Default for MemoryConfig {
    fn default() -> Self {
        MemoryConfig {
            tenant: "default".into(),
            default_subject: "user:default".into(),
            default_k: 10,
            candidates: 100,
            rrf_k: 60.0,
            keyword_weight: 1.0,
            vector_weight: 1.0,
            dedup_threshold: 0.97,
            recency_weight: 0.0,
            recency_half_life_days: 90.0,
            assistant_chars: 1200,
            query_analysis: true,
            window_weight: 0.15,
            window_top: 3,
            window_top_weight: 1.0,
            subquery_weight: 0.0,
            template: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct GovernanceConfig {
    /// PII and secret categories redacted before anything is stored (GOV-05).
    /// Available: secret, card, ssn, iban, email, phone, ip.
    pub redact: Vec<String>,
    /// Quarantine content that looks like prompt injection instead of committing it (QUAL-02).
    pub quarantine_injection: bool,
    /// Sensitivity labels never returned by recall unless explicitly allowed.
    pub denied_labels: Vec<String>,
    /// Write an audit event for every recall, not only for writes and deletions.
    pub audit_reads: bool,
    /// Days after which episodic memory is purged (0 = keep).
    pub episodic_retention_days: u32,
    pub max_content_chars: usize,
}

impl Default for GovernanceConfig {
    fn default() -> Self {
        GovernanceConfig {
            redact: vec!["secret".into(), "card".into(), "ssn".into(), "iban".into()],
            quarantine_injection: true,
            denied_labels: vec![],
            audit_reads: false,
            episodic_retention_days: 0,
            max_content_chars: 20_000,
        }
    }
}

pub fn home_dir() -> PathBuf {
    if let Ok(h) = std::env::var("MEMHOUSE_HOME") {
        return PathBuf::from(h);
    }
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join(".memhouse")
}

pub fn default_config_path() -> PathBuf {
    if let Ok(p) = std::env::var("MEMHOUSE_CONFIG") {
        return PathBuf::from(p);
    }
    home_dir().join("config.toml")
}

impl Config {
    /// Load from `path` (or the default location). A missing file yields defaults.
    /// Environment variables override file values.
    pub fn load(path: Option<&Path>) -> anyhow::Result<Config> {
        let path = path.map(PathBuf::from).unwrap_or_else(default_config_path);
        let mut cfg = if path.exists() {
            let text = std::fs::read_to_string(&path)?;
            toml::from_str(&text).map_err(|e| anyhow::anyhow!("invalid config {}: {e}", path.display()))?
        } else {
            Config::default()
        };
        cfg.apply_env();
        Ok(cfg)
    }

    pub fn save(&self, path: Option<&Path>) -> anyhow::Result<PathBuf> {
        let path = path.map(PathBuf::from).unwrap_or_else(default_config_path);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(&path, toml::to_string_pretty(self)?)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(path)
    }

    fn apply_env(&mut self) {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        if let Some(v) = var("MEMHOUSE_DATABASE_URL").or_else(|| var("DATABASE_URL")) {
            self.database.url = v;
        }
        if let Some(v) = var("MEMHOUSE_SUBJECT") {
            self.memory.default_subject = v;
        }
        if let Some(v) = var("MEMHOUSE_TENANT") {
            self.memory.tenant = v;
        }
        if let Some(v) = var("MEMHOUSE_BIND") {
            self.server.bind = v;
        }
        if let Some(v) = var("MEMHOUSE_API_KEY") {
            if !self.server.api_keys.contains(&v) {
                self.server.api_keys.push(v);
            }
        }
        if let Some(v) = var("MEMHOUSE_EMBEDDING_PROVIDER") {
            self.embedding.provider = v;
        }
        if let Some(v) = var("MEMHOUSE_EMBEDDING_MODEL") {
            self.embedding.model = v;
        }
        if let Some(v) = var("MEMHOUSE_EMBEDDING_DIM").and_then(|v| v.parse().ok()) {
            self.embedding.dim = v;
        }
        if let Some(v) = var("MEMHOUSE_EMBEDDING_BASE_URL") {
            self.embedding.base_url = Some(v);
        }
        if let Some(v) = var("MEMHOUSE_EMBEDDING_API_KEY_ENV") {
            self.embedding.api_key_env = Some(v);
        }
        if let Some(v) = var("MEMHOUSE_RERANK").map(|v| v == "1" || v == "true") {
            self.rerank.enabled = v;
        }
        if let Some(v) = var("MEMHOUSE_ENRICH").map(|v| v == "1" || v == "true") {
            self.enrich.enabled = v;
        }
        if let Some(v) = var("MEMHOUSE_ENRICH_MODEL") {
            self.enrich.llm.model = v;
        }
    }
}
