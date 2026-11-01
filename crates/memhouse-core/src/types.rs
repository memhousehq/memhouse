// SPDX-License-Identifier: Apache-2.0
//! Public data types shared by the engine, the store adapters, the API and the benchmark.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Kinds of memory (requirements MEM-01..MEM-06).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    /// Short-lived task context for one session; expires (MEM-01).
    Working,
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
    pub const ALL: [MemoryKind; 7] =
        [MemoryKind::Working, MemoryKind::Episodic, MemoryKind::Semantic, MemoryKind::Preference, MemoryKind::Procedural, MemoryKind::Commitment, MemoryKind::Document];

    pub fn as_str(&self) -> &'static str {
        match self {
            MemoryKind::Working => "working",
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

/// Lifecycle of a record (CORE-02). Only `committed` records are recalled.
///
/// ```text
/// candidate ──► committed ──► superseded
///     │  │          │  └────► expired
///     │  └► rejected │
///     └──► quarantined ◄┘ ──► rejected   (quarantined ──► committed on release)
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryStatus {
    /// Proposed, waiting for its gate (asynchronous admission, G10).
    Candidate,
    Committed,
    /// Replaced by a newer version (`superseded_by`).
    Superseded,
    /// Held back by the gate (for example an injected instruction).
    Quarantined,
    /// Refused by the gate or a reviewer.
    Rejected,
    /// Past `expires_at` (working memory, commitments).
    Expired,
}

impl MemoryStatus {
    pub const ALL: [MemoryStatus; 6] =
        [MemoryStatus::Candidate, MemoryStatus::Committed, MemoryStatus::Superseded, MemoryStatus::Quarantined, MemoryStatus::Rejected, MemoryStatus::Expired];

    pub fn as_str(&self) -> &'static str {
        match self {
            MemoryStatus::Candidate => "candidate",
            MemoryStatus::Committed => "committed",
            MemoryStatus::Superseded => "superseded",
            MemoryStatus::Quarantined => "quarantined",
            MemoryStatus::Rejected => "rejected",
            MemoryStatus::Expired => "expired",
        }
    }

    pub fn parse(s: &str) -> Option<MemoryStatus> {
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }

    /// No record leaves these states.
    pub fn is_terminal(&self) -> bool {
        matches!(self, MemoryStatus::Superseded | MemoryStatus::Rejected | MemoryStatus::Expired)
    }

    /// The transitions of the state machine above.
    pub fn can_become(&self, to: MemoryStatus) -> bool {
        use MemoryStatus::*;
        matches!((self, to), (Candidate, Committed | Rejected | Quarantined | Expired) | (Committed, Superseded | Quarantined | Expired) | (Quarantined, Committed | Rejected))
    }

    /// States a record may be in to move to `to`.
    pub fn sources_of(to: MemoryStatus) -> Vec<MemoryStatus> {
        Self::ALL.into_iter().filter(|s| s.can_become(to)).collect()
    }
}

/// Narrower visibility inside a subject (MEM-04). All empty means the whole subject; resolution
/// order (user over team over org) is applied by recall from G11.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scope {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub org: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

impl Scope {
    pub fn is_empty(&self) -> bool {
        *self == Scope::default()
    }
}

/// Who and what admitted a record (GOV-03), and which model derived it (TR-MS-02). The source
/// turn is the record's `session_id` and `turn_ref`; its confidence is `confidence`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provenance {
    /// The writing agent (principal).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// The user the agent acted for, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// The compiled policy that admitted the record (`mh_policy`; `legacy-v1` before schema v2).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_version: Option<String>,
    /// The client's idempotency key for the request that wrote it (CORE-06).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_key: Option<String>,
    /// For derived records: the model that extracted it, and its prompt and configuration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extractor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extractor_config: Option<String>,
}

impl Provenance {
    pub fn is_empty(&self) -> bool {
        *self == Provenance::default()
    }
}

/// The queryable form of a structured record (HYB-02), under the same id as its text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Structured {
    pub record_type: String,
    /// A JSON object of attributes, queried exactly, never by similarity.
    pub attrs: serde_json::Value,
}

/// A file a memory is about (TR-TPL-02): stale when the file's content hash changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CodeRef {
    pub path: String,
    pub blob_hash: String,
}

/// A reference from one subject to another (ACC-06), stored with the subject that holds it.
/// Following it also needs a relationship with the linked subject (enforced from G27).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Link {
    pub tenant: String,
    pub subject: String,
    pub linked_subject: String,
    pub link_type: String,
    /// The record that justifies the link, if any; deleting it deletes the link.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_id: Option<Uuid>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
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
    /// After this the record is no longer recalled (working memory, MEM-01).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Scope::is_empty")]
    pub scope: Scope,
    #[serde(default, skip_serializing_if = "Provenance::is_empty")]
    pub provenance: Provenance,
}

/// A record ready to be inserted (embedding already computed).
#[derive(Debug, Clone)]
pub struct NewMemory {
    pub memory: Memory,
    pub embedding: Option<Vec<f32>>,
    pub content_hash: String,
    /// Second vector (embedding-cache key, vector) for the round's user text alone.
    pub alt: Option<(String, Vec<f32>)>,
    pub structured: Option<Structured>,
    pub code_refs: Vec<CodeRef>,
}

impl NewMemory {
    pub fn new(memory: Memory, content_hash: String) -> NewMemory {
        NewMemory { memory, embedding: None, content_hash, alt: None, structured: None, code_refs: vec![] }
    }
}

/// What a database's vectors were made with. Vectors are only comparable within one identity, so
/// a store refuses another one until `memhouse reembed` has moved every record (TR-MS-04).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EmbeddingIdentity {
    pub embedder: String,
    pub dim: usize,
    /// Prefix added to passages before embedding (part of the text the model saw).
    pub passage_prefix: String,
}

impl EmbeddingIdentity {
    /// Short hash of the whole identity, stamped on every vector (TR-MS-02, INT-07).
    pub fn config_hash(&self) -> String {
        crate::engine::content_hash(&serde_json::to_string(self).expect("identity serializes"))[..16].to_string()
    }
}

impl std::fmt::Display for EmbeddingIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({} dims", self.embedder, self.dim)?;
        if !self.passage_prefix.is_empty() {
            write!(f, ", passage prefix {:?}", self.passage_prefix)?;
        }
        write!(f, ")")
    }
}

/// A record still to be re-embedded.
#[derive(Debug, Clone)]
pub struct ReembedRow {
    pub id: Uuid,
    pub content: String,
    /// Cache key of the record's second (user-only) vector, when it has one.
    pub alt_hash: Option<String>,
}

/// A record's vectors under the new identity.
#[derive(Debug, Clone)]
pub struct ReembedVectors {
    pub id: Uuid,
    pub embedding: Vec<f32>,
    pub alt: Option<(String, Vec<f32>)>,
}

/// A record of an export file on its way into a store, with its vectors.
#[derive(Debug, Clone)]
pub struct ImportRow {
    pub record: crate::format::RecordLine,
    pub embedding: Option<Vec<f32>>,
    pub alt: Option<(String, Vec<f32>)>,
}

/// Size of a re-embedding before it starts.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ReembedEstimate {
    pub records: u64,
    pub second_vectors: u64,
    pub characters: u64,
    /// Records already done by an interrupted run to the same target.
    pub done: u64,
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
    /// Sensitivity labels (ACC-04); recall can exclude them.
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub scope: Option<Scope>,
    /// The user the calling agent acts for (provenance).
    #[serde(default)]
    pub user: Option<String>,
    /// Idempotency key: a repeat with the same key and request returns the first result (CORE-06).
    #[serde(default)]
    pub request_key: Option<String>,
    /// Working memory and other short-lived records; working memory defaults to `memory.working_ttl_secs`.
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub structured: Option<Structured>,
    #[serde(default)]
    pub code_refs: Vec<CodeRef>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RememberResult {
    pub id: Uuid,
    pub status: MemoryStatus,
    /// True when an equivalent memory already existed and nothing new was written.
    pub deduplicated: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub redactions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
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
    #[serde(default)]
    pub scope: Option<Scope>,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub request_key: Option<String>,
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
    /// Override query analysis (time windows and sub-queries) on/off.
    #[serde(default)]
    pub analyze: Option<bool>,
    /// "Now" for reading relative time in the query ("two weeks ago"). Defaults to `as_of`, then
    /// the current time. Unlike `as_of` it filters nothing.
    #[serde(default)]
    pub reference_time: Option<DateTime<Utc>>,
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
    /// Time spent embedding the query, in the SQL statement, and reranking.
    #[serde(default)]
    pub embed_ms: f64,
    #[serde(default)]
    pub search_ms: f64,
    #[serde(default)]
    pub rerank_ms: f64,
    pub candidates: usize,
    pub reranked: bool,
    /// How the query was read: time windows and sub-queries that got their own retrieval probe.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<crate::query::QueryPlan>,
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
    /// Only memories whose event time falls in one of these `[start, end)` windows (empty = any time).
    pub windows: Vec<(DateTime<Utc>, DateTime<Utc>)>,
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

/// Tokens, cost and wall time of one logical LLM call (retries included).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LlmUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    /// USD: as reported by the provider (OpenRouter), else from the configured price.
    pub cost_usd: Option<f64>,
    /// True when `cost_usd` came from the provider rather than a price table.
    #[serde(default)]
    pub cost_reported: bool,
    /// Wall time including retries and backoff.
    pub ms: f64,
    pub attempts: u32,
}

/// A queued enrichment job: one ingested session of one subject.
#[derive(Debug, Clone)]
pub struct EnrichJob {
    pub id: i64,
    pub tenant: String,
    pub subject: String,
    pub session_id: String,
    pub round_ids: Vec<Uuid>,
    pub attempts: i32,
}

/// What a finished job did, kept on the job row for cost and lag accounting.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnrichOutcome {
    pub facts: usize,
    /// Answer served from the extraction cache (no LLM call, no cost).
    pub cached: bool,
    /// Skipped without an LLM call (too little user text).
    pub skipped: bool,
    pub usage: LlmUsage,
    pub model: String,
    /// Milliseconds from enqueue to facts committed.
    #[serde(default)]
    pub lag_ms: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnrichStatus {
    pub pending: i64,
    pub running: i64,
    pub done: i64,
    pub failed: i64,
}
