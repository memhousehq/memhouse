// SPDX-License-Identifier: Apache-2.0
//! Public data types shared by the engine, the store adapters, the API and the benchmark.

use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Kinds of memory (requirements MEM-01..MEM-06).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Structured {
    pub record_type: String,
    /// A JSON object of attributes, queried exactly, never by similarity.
    pub attrs: serde_json::Value,
}

/// A file a memory is about (TR-TPL-02): stale when the file's content hash changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CodeRef {
    pub path: String,
    pub blob_hash: String,
}

/// A reference from one subject to another (ACC-06), stored with the subject that holds it.
/// Following it also needs a relationship with the linked subject (enforced from G27).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
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
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Memory {
    pub id: Uuid,
    pub tenant: String,
    /// Whose memory it is.
    pub subject: String,
    pub kind: MemoryKind,
    /// Lifecycle state; only `committed` records are recalled.
    pub status: MemoryStatus,
    /// The text, after redaction.
    pub content: String,
    /// The conversation it came from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The messages it came from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_ref: Option<String>,
    /// When the remembered thing happened (event time), if known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_at: Option<DateTime<Utc>>,
    /// When the memory became true.
    pub valid_from: DateTime<Utc>,
    /// When it stopped being true; set when it is superseded.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub valid_to: Option<DateTime<Utc>>,
    /// The previous version, which this record replaced.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supersedes: Option<Uuid>,
    /// Sensitivity labels.
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    /// Source label: the writer by default, `enrich:<model>` for extracted facts.
    pub source: String,
    /// 0 to 1.
    pub confidence: f32,
    /// Free-form JSON object.
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
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Message {
    /// `user`, `assistant`, or a participant's name in a multi-party conversation.
    pub role: String,
    pub content: String,
    /// When the message was sent; defaults to the request's `session_time`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<DateTime<Utc>>,
    /// Caller's own reference for the message (for provenance and evaluation).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

/// Propose one memory (`remember`, CORE-01).
#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct RememberRequest {
    /// The tenant; defaults to the configured one.
    #[serde(default)]
    pub tenant: Option<String>,
    /// Whose memory it is, e.g. `user:alice`, `customer:42`, `repo:api`. Defaults to the configured subject.
    #[serde(default)]
    pub subject: Option<String>,
    /// The memory, written so it stands alone (who, what, when), ideally one fact.
    pub content: String,
    /// Defaults to `semantic`.
    #[serde(default)]
    pub kind: Option<MemoryKind>,
    /// Free tags, usable as recall filters.
    #[serde(default)]
    pub tags: Vec<String>,
    /// When the remembered thing happened; defaults to now.
    #[serde(default)]
    pub occurred_at: Option<DateTime<Utc>>,
    /// When it stops being true (a due date, an expiry).
    #[serde(default)]
    pub valid_to: Option<DateTime<Utc>>,
    /// Replace an existing memory with this one; prefer `revise`.
    #[serde(default)]
    pub supersedes: Option<Uuid>,
    /// Source label; defaults to the actor.
    #[serde(default)]
    pub source: Option<String>,
    /// Free-form JSON object, stored as given.
    #[serde(default)]
    pub metadata: Option<serde_json::Value>,
    /// Who makes the change, for the audit log; defaults to the `x-memhouse-actor` header. From
    /// API keys per principal (G06) the authenticated principal is used instead.
    #[serde(default)]
    pub actor: Option<String>,
    /// Sensitivity labels (ACC-04); `governance.denied_labels` keeps them out of recall.
    #[serde(default)]
    pub labels: Vec<String>,
    /// Narrower visibility inside the subject (MEM-04).
    #[serde(default)]
    pub scope: Option<Scope>,
    /// The user the calling agent acts for (provenance).
    #[serde(default)]
    pub user: Option<String>,
    /// Idempotency key (or the `Idempotency-Key` header): a repeat with the same key and request
    /// returns the first result; the same key with another request is a conflict (CORE-06).
    #[serde(default)]
    pub request_key: Option<String>,
    /// When it stops being recalled; `working` memory defaults to now + `memory.working_ttl_secs`.
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
    /// The queryable form of the record (an order, a ticket), under the same id.
    #[serde(default)]
    pub structured: Option<Structured>,
    /// Files the memory is about, for staleness checks.
    #[serde(default)]
    pub code_refs: Vec<CodeRef>,
}

/// What a write did. The id is returned at once; `status` says the record's state, which can
/// also be read later with `GET /v1/memories/{id}` (CORE-02).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RememberResult {
    /// The record's id. For a deduplicated write, the id of the memory already stored.
    pub id: Uuid,
    /// `committed` or `quarantined` today; `candidate` once admission is asynchronous (G10).
    /// Clients must not assume a write is committed.
    pub status: MemoryStatus,
    /// True when an equivalent memory already existed and nothing new was written.
    pub deduplicated: bool,
    /// Kinds of sensitive data redacted from the text (`card`, `secret`, ...).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub redactions: Vec<String>,
    /// The record this write superseded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded: Option<Uuid>,
    /// Why the write was deduplicated or quarantined.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// Correct a memory (`revise`, CORE-04): a new version that supersedes the current one. Fields
/// left out are taken from the current version (kind, tags, labels, scope, metadata, validity,
/// structured form, code references).
#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct ReviseRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    /// The memory to revise; it must be the current (`committed`) version.
    pub id: Uuid,
    /// The corrected memory.
    pub content: String,
    #[serde(default)]
    pub kind: Option<MemoryKind>,
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    #[serde(default)]
    pub labels: Option<Vec<String>>,
    #[serde(default)]
    pub occurred_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub valid_to: Option<DateTime<Utc>>,
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub metadata: Option<serde_json::Value>,
    #[serde(default)]
    pub scope: Option<Scope>,
    #[serde(default)]
    pub structured: Option<Structured>,
    #[serde(default)]
    pub code_refs: Option<Vec<CodeRef>>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub actor: Option<String>,
    #[serde(default)]
    pub user: Option<String>,
    /// Idempotency key, as for `remember`.
    #[serde(default)]
    pub request_key: Option<String>,
}

/// Delete memories (`forget`, CORE-05). Name exactly one of `id`, `subject`, `user`, `agent`,
/// `source` or `all`. Deletion is permanent and includes every derived representation.
#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct ForgetRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    /// One record (and the facts derived from it).
    #[serde(default)]
    pub id: Option<Uuid>,
    /// Everything held about a subject (right to erasure).
    #[serde(default)]
    pub subject: Option<String>,
    /// Records the user wrote through an agent or that are scoped to the user, in any subject.
    #[serde(default)]
    pub user: Option<String>,
    /// Records written by the agent or scoped to it, in any subject.
    #[serde(default)]
    pub agent: Option<String>,
    /// Records with this source label, in any subject.
    #[serde(default)]
    pub source: Option<String>,
    /// The whole tenant. Needs `confirm` set to the tenant's name.
    #[serde(default)]
    pub all: bool,
    /// The tenant's name, when `all` is set.
    #[serde(default)]
    pub confirm: Option<String>,
    /// Count what would be deleted, delete nothing.
    #[serde(default)]
    pub dry_run: bool,
    #[serde(default)]
    pub actor: Option<String>,
    /// Idempotency key: a repeat returns the first result instead of `not_found`.
    #[serde(default)]
    pub request_key: Option<String>,
}

/// What a `forget` matched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ForgetScope {
    Record,
    Subject,
    User,
    Agent,
    Source,
    Tenant,
}

impl ForgetScope {
    pub fn as_str(&self) -> &'static str {
        match self {
            ForgetScope::Record => "record",
            ForgetScope::Subject => "subject",
            ForgetScope::User => "user",
            ForgetScope::Agent => "agent",
            ForgetScope::Source => "source",
            ForgetScope::Tenant => "tenant",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ForgetResult {
    pub scope: ForgetScope,
    /// The id, subject, user, agent, source or tenant named.
    pub value: String,
    /// Records deleted (or, with `dry_run`, that would be). Facts derived from them are deleted
    /// too and are not counted unless they match themselves.
    pub deleted: u64,
    #[serde(default)]
    pub dry_run: bool,
}

/// One page of a list. Pass `next_cursor` back as `cursor` for the next page; it is absent on the
/// last page. Cursors are opaque.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct MemoryPage {
    pub items: Vec<Memory>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// Store a conversation as episodic memory, one record per user/assistant round.
#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct IngestRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    #[serde(default)]
    pub subject: Option<String>,
    /// Groups the rounds; also the unit of background enrichment. Defaults to a new id.
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
    /// Idempotency key, as for `remember`.
    #[serde(default)]
    pub request_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct IngestResult {
    /// Rounds stored.
    pub stored: usize,
    /// Rounds stored as quarantined (never recalled).
    pub quarantined: usize,
    /// Rounds already stored, skipped.
    pub deduplicated: usize,
    /// Ids of the rounds stored.
    pub ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RetrievalMode {
    #[default]
    Hybrid,
    Dense,
    Keyword,
}

/// Retrieve memories for a context (`recall`, CORE-03).
#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct RecallRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    /// Whose memory to search. Recall never crosses subjects.
    #[serde(default)]
    pub subject: Option<String>,
    /// What you need to know, in natural language.
    pub query: String,
    /// Number of memories to return (default `memory.default_k`, at most 200).
    #[serde(default)]
    pub k: Option<usize>,
    /// Only these kinds.
    #[serde(default)]
    pub kinds: Option<Vec<MemoryKind>>,
    /// Only memories with at least one of these tags.
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    /// Only memories visible in this scope: each scope field the request sets matches records
    /// with the same value or none. Unset fields don't filter.
    #[serde(default)]
    pub scope: Option<Scope>,
    /// Recall what was true at this time (validity and event-time filter).
    #[serde(default)]
    pub as_of: Option<DateTime<Utc>>,
    #[serde(default)]
    pub mode: Option<RetrievalMode>,
    /// Override the configured reranker on/off.
    #[serde(default)]
    pub rerank: Option<bool>,
    /// Approximate token budget for the returned memories.
    #[serde(default)]
    pub token_budget: Option<usize>,
    /// Override query analysis (time windows and sub-queries) on/off.
    #[serde(default)]
    pub analyze: Option<bool>,
    /// "Now" for reading relative time in the query ("two weeks ago"). Defaults to `as_of`, then
    /// the current time. Unlike `as_of` it filters nothing.
    #[serde(default)]
    pub reference_time: Option<DateTime<Utc>>,
    /// Also return the memories as a text block ready for a prompt (`rendered`, INT-04).
    #[serde(default)]
    pub render: bool,
    #[serde(default)]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Hit {
    pub memory: Memory,
    /// Fused score; compare it only within one response.
    pub score: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keyword_rank: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vector_rank: Option<i32>,
    /// Cosine similarity of the best vector.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub similarity: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rerank_score: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RecallResult {
    /// Ranked memories, most relevant first, each with its id and provenance.
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
    /// The hits as a model-neutral text block, when the request set `render`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rendered: Option<String>,
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
    /// Only records visible in this scope (see `RecallRequest::scope`).
    pub scope: Scope,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListQuery {
    pub tenant: String,
    pub subject: Option<String>,
    pub kinds: Option<Vec<MemoryKind>>,
    pub include_inactive: bool,
    pub limit: usize,
    pub offset: usize,
    /// Keyset paging: only records ordered after this (created_at, id), newest first.
    #[serde(default)]
    pub before: Option<(DateTime<Utc>, Uuid)>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
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

#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
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

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct EnrichStatus {
    pub pending: i64,
    pub running: i64,
    pub done: i64,
    pub failed: i64,
}
