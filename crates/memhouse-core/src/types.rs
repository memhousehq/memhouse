//! Public data types shared by the engine, the store adapters, the API and the benchmark.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Kinds of memory (requirements MEM-01..MEM-06).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    /// Raw conversation history: a user/assistant round.
    Episodic,
    /// Durable facts about the subject.
    Semantic,
    /// Likes, dislikes, ways of working.
    Preference,
    /// How-to knowledge, conventions, procedures.
    Procedural,
    /// Promises, follow-ups, open items with a due date.
    Commitment,
    /// Reference documents or snippets.
    Document,
}

impl MemoryKind {
    pub const ALL: [MemoryKind; 6] = [
        MemoryKind::Episodic,
        MemoryKind::Semantic,
        MemoryKind::Preference,
        MemoryKind::Procedural,
        MemoryKind::Commitment,
        MemoryKind::Document,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            MemoryKind::Episodic => "episodic",
            MemoryKind::Semantic => "semantic",
            MemoryKind::Preference => "preference",
            MemoryKind::Procedural => "procedural",
            MemoryKind::Commitment => "commitment",
            MemoryKind::Document => "document",
        }
    }

    pub fn parse(s: &str) -> Option<MemoryKind> {
        Self::ALL.into_iter().find(|k| k.as_str() == s.trim().to_ascii_lowercase())
    }
}

impl std::fmt::Display for MemoryKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryStatus {
    Committed,
    Superseded,
    Quarantined,
}

impl MemoryStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            MemoryStatus::Committed => "committed",
            MemoryStatus::Superseded => "superseded",
            MemoryStatus::Quarantined => "quarantined",
        }
    }
    pub fn parse(s: &str) -> MemoryStatus {
        match s {
            "superseded" => MemoryStatus::Superseded,
            "quarantined" => MemoryStatus::Quarantined,
            _ => MemoryStatus::Committed,
        }
    }
}

/// A stored memory record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Memory {
    pub id: Uuid,
    pub tenant: String,
    pub subject: String,
    pub kind: MemoryKind,
    pub status: MemoryStatus,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_ref: Option<String>,
    /// When the remembered thing happened (event time), if known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_at: Option<DateTime<Utc>>,
    pub valid_from: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub valid_to: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supersedes: Option<Uuid>,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub source: String,
    pub confidence: f32,
    #[serde(default)]
    pub metadata: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

/// A record ready to be inserted (embedding already computed).
#[derive(Debug, Clone)]
pub struct NewMemory {
    pub memory: Memory,
    pub embedding: Option<Vec<f32>>,
    pub content_hash: String,
}

/// One message of a conversation handed to `ingest`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<DateTime<Utc>>,
    /// Caller's own reference for the message (for provenance and evaluation).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RememberRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    #[serde(default)]
    pub subject: Option<String>,
    pub content: String,
    #[serde(default)]
    pub kind: Option<MemoryKind>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub occurred_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub valid_to: Option<DateTime<Utc>>,
    /// Replace an existing memory with this one (supersession, CORE-03).
    #[serde(default)]
    pub supersedes: Option<Uuid>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub metadata: Option<serde_json::Value>,
    #[serde(default)]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RememberResult {
    pub id: Uuid,
    pub status: MemoryStatus,
    /// True when an equivalent memory already existed and nothing new was written.
    pub deduplicated: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub redactions: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub superseded: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct IngestRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    #[serde(default)]
    pub subject: Option<String>,
    #[serde(default)]
    pub session_id: Option<String>,
    /// Session start time; used for messages without their own timestamp.
    #[serde(default)]
    pub session_time: Option<DateTime<Utc>>,
    pub messages: Vec<Message>,
    /// Store every message as its own record instead of grouping user/assistant rounds
    /// (use for multi-party conversations without a "user" role).
    #[serde(default)]
    pub per_message: bool,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct IngestResult {
    pub stored: usize,
    pub quarantined: usize,
    pub deduplicated: usize,
    pub ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum RetrievalMode {
    #[default]
    Hybrid,
    Dense,
    Keyword,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RecallRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    #[serde(default)]
    pub subject: Option<String>,
    pub query: String,
    #[serde(default)]
    pub k: Option<usize>,
    #[serde(default)]
    pub kinds: Option<Vec<MemoryKind>>,
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    /// Recall the state of memory as of this time (validity and event-time filter).
    #[serde(default)]
    pub as_of: Option<DateTime<Utc>>,
    #[serde(default)]
    pub mode: Option<RetrievalMode>,
    /// Override the configured reranker on/off.
    #[serde(default)]
    pub rerank: Option<bool>,
    /// Approximate token budget for the returned context.
    #[serde(default)]
    pub token_budget: Option<usize>,
    #[serde(default)]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Hit {
    pub memory: Memory,
    pub score: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keyword_rank: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vector_rank: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub similarity: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rerank_score: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecallResult {
    pub hits: Vec<Hit>,
    pub took_ms: f64,
    pub candidates: usize,
    pub reranked: bool,
}

/// Parameters passed from the engine to a store's single-statement hybrid search.
#[derive(Debug, Clone)]
pub struct SearchQuery {
    pub tenant: String,
    pub subject: String,
    pub text: String,
    pub embedding: Option<Vec<f32>>,
    pub kinds: Option<Vec<MemoryKind>>,
    pub tags: Option<Vec<String>>,
    pub denied_labels: Vec<String>,
    pub as_of: Option<DateTime<Utc>>,
    /// Validity is always checked at this time (the `as_of` time, or now).
    pub valid_at: DateTime<Utc>,
    pub mode: RetrievalMode,
    /// Candidates per retriever.
    pub per_retriever: usize,
    /// Fused results to return.
    pub limit: usize,
    pub rrf_k: f32,
    pub keyword_weight: f32,
    pub vector_weight: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListQuery {
    pub tenant: String,
    pub subject: Option<String>,
    pub kinds: Option<Vec<MemoryKind>>,
    pub include_inactive: bool,
    pub limit: usize,
    pub offset: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEvent {
    pub id: i64,
    pub at: DateTime<Utc>,
    pub actor: String,
    pub action: String,
    pub tenant: String,
    pub subject: Option<String>,
    pub memory_id: Option<Uuid>,
    pub detail: serde_json::Value,
    pub prev_hash: String,
    pub hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Stats {
    pub memories: i64,
    pub committed: i64,
    pub quarantined: i64,
    pub superseded: i64,
    pub subjects: i64,
    pub audit_events: i64,
    pub by_kind: Vec<(String, i64)>,
}
