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
    /// The organisation's own terms and classifications: agents propose, an administrator
    /// approves (MEM-03).
    Taxonomic,
}

impl MemoryKind {
    pub const ALL: [MemoryKind; 8] = [
        MemoryKind::Working,
        MemoryKind::Episodic,
        MemoryKind::Semantic,
        MemoryKind::Preference,
        MemoryKind::Procedural,
        MemoryKind::Commitment,
        MemoryKind::Document,
        MemoryKind::Taxonomic,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            MemoryKind::Working => "working",
            MemoryKind::Episodic => "episodic",
            MemoryKind::Semantic => "semantic",
            MemoryKind::Preference => "preference",
            MemoryKind::Procedural => "procedural",
            MemoryKind::Commitment => "commitment",
            MemoryKind::Document => "document",
            MemoryKind::Taxonomic => "taxonomic",
        }
    }

    /// Whether a record of this kind may be promoted to `to` (MEM-05). Promotion moves towards
    /// durable memory: never into working memory, never to the same kind (that is `revise`), and
    /// only working memory becomes episodic. Commitments and documents are sources, not targets.
    pub fn promotable_to(&self, to: MemoryKind) -> bool {
        use MemoryKind::*;
        match to {
            _ if *self == to => false,
            Working | Commitment | Document => false,
            Episodic => *self == Working,
            Semantic | Preference | Procedural | Taxonomic => true,
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

/// What a statement asserts, as the write gate reads it (QUAL-02). Plans and speculation stay
/// candidates until confirmed or expired (PR-7); a correction supersedes what it corrects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Statement {
    /// Something true now ("Acme's renewal date is 1 March").
    Fact,
    /// Something that happened ("The user adopted a cat in March").
    Event,
    /// A change to, or fix of, something stored before ("Actually, she moved to Porto").
    Correction,
    /// An intention not yet carried out ("The user plans to visit Japan in May").
    Plan,
    /// A guess, rumour or hypothetical ("He might switch vendors").
    Speculation,
    /// A like, dislike or way of working.
    Preference,
    /// How something should be done ("Run the tests before every commit").
    Instruction,
}

impl Statement {
    pub const ALL: [Statement; 7] =
        [Statement::Fact, Statement::Event, Statement::Correction, Statement::Plan, Statement::Speculation, Statement::Preference, Statement::Instruction];

    pub fn as_str(&self) -> &'static str {
        match self {
            Statement::Fact => "fact",
            Statement::Event => "event",
            Statement::Correction => "correction",
            Statement::Plan => "plan",
            Statement::Speculation => "speculation",
            Statement::Preference => "preference",
            Statement::Instruction => "instruction",
        }
    }

    pub fn parse(s: &str) -> Option<Statement> {
        let s = s.trim().to_ascii_lowercase();
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }

    /// Held as a candidate instead of committed (QUAL-02, PR-7).
    pub fn held(&self) -> bool {
        matches!(self, Statement::Plan | Statement::Speculation)
    }
}

/// The representation intake routes a record to (HYB-01).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Route {
    /// Conversation or longer prose: text with keyword and vector search.
    Narrative,
    /// One self-contained statement: text search plus correction and duplicate checks.
    Fact,
    /// A record with attributes (an order, an address): also a row in the structured table,
    /// answered by exact query (HYB-02).
    Structured,
    /// A statement relating people or organisations; stored as a fact until the graph (G35).
    Relationship,
    /// Source code or a change to it; stored as text with the `code` tag until code-aware
    /// memory (G19).
    Code,
}

impl Route {
    pub fn as_str(&self) -> &'static str {
        match self {
            Route::Narrative => "narrative",
            Route::Fact => "fact",
            Route::Structured => "structured",
            Route::Relationship => "relationship",
            Route::Code => "code",
        }
    }
}

/// The intake queue's backlog (TR-IN-06): the lag metric.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct IntakeStatus {
    pub pending: i64,
    pub running: i64,
    /// Finished and not yet pruned.
    pub done: i64,
    /// Poison proposals moved aside after `intake.max_attempts` (TR-IN-07).
    pub dead: i64,
    /// Age of the oldest unfinished proposal, in seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_pending_secs: Option<f64>,
}

/// Narrower visibility inside a subject (MEM-04). All empty means the whole subject (the tenant
/// level). Levels inherit broadest to narrowest: tenant, org, team, agent, user, session; a
/// preference set at a narrower level overrides the same preference at a broader one.
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

    /// The narrowest level the scope names; `tenant` when it names none.
    pub fn level(&self) -> ScopeLevel {
        ScopeLevel::NARROWEST_FIRST.into_iter().find(|l| self.get(*l).is_some()).unwrap_or(ScopeLevel::Tenant)
    }

    /// The value at a level (`tenant` has none here: the tenant is the record's own field).
    pub fn get(&self, level: ScopeLevel) -> Option<&String> {
        match level {
            ScopeLevel::Tenant => None,
            ScopeLevel::Org => self.org.as_ref(),
            ScopeLevel::Team => self.team.as_ref(),
            ScopeLevel::Agent => self.agent.as_ref(),
            ScopeLevel::User => self.user.as_ref(),
            ScopeLevel::Session => self.session.as_ref(),
        }
    }

    /// Scope inheritance (MEM-04), the one rule every read applies: a reader in this scope sees a
    /// record whose scope names, at every level, either nothing (the record belongs to a broader
    /// level) or the reader's own value. So a session sees its own records and those of its user,
    /// agent, team, org and tenant. `shared` holds the agents whose memory was granted to the
    /// reader (INT-06), as `agent`, or `agent` for one kind.
    ///
    /// The session level has one exception, kept for API v1: a reader that names no session
    /// (its session is [`crate::access::NOBODY`]) still sees session-scoped records, as it did
    /// before 1.5, except working memory, which is session-local (MEM-01). A reader that names
    /// a session never sees another session's records.
    pub fn sees(&self, record: &Scope, kind: MemoryKind, shared: &[String]) -> bool {
        let field = |mine: &Option<String>, theirs: &Option<String>| mine.is_none() || theirs.is_none() || mine == theirs;
        let session = field(&self.session, &record.session) || (self.session.as_deref() == Some(crate::access::NOBODY) && kind != MemoryKind::Working);
        let agent =
            field(&self.agent, &record.agent) || record.agent.as_ref().is_some_and(|a| shared.contains(&shared_key(a, None)) || shared.contains(&shared_key(a, Some(kind))));
        field(&self.org, &record.org) && field(&self.team, &record.team) && agent && field(&self.user, &record.user) && session
    }
}

/// The key a grant puts in a read's `shared` list: the granting agent, for every kind (`*`) or one.
pub fn shared_key(agent: &str, kind: Option<MemoryKind>) -> String {
    format!("{agent}\u{1f}{}", kind.map(|k| k.as_str()).unwrap_or("*"))
}

/// The levels of a scope, broadest first (MEM-04). Each level inherits from those before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ScopeLevel {
    Tenant,
    Org,
    Team,
    Agent,
    User,
    Session,
}

impl ScopeLevel {
    pub const NARROWEST_FIRST: [ScopeLevel; 6] = [ScopeLevel::Session, ScopeLevel::User, ScopeLevel::Agent, ScopeLevel::Team, ScopeLevel::Org, ScopeLevel::Tenant];

    pub fn as_str(&self) -> &'static str {
        match self {
            ScopeLevel::Tenant => "tenant",
            ScopeLevel::Org => "org",
            ScopeLevel::Team => "team",
            ScopeLevel::Agent => "agent",
            ScopeLevel::User => "user",
            ScopeLevel::Session => "session",
        }
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
    /// Wait for the write gate before answering (at most `intake.wait_timeout_ms`): the result
    /// then carries the record's final state. By default `remember` answers as soon as the
    /// redacted write is durably queued, with `status: candidate` (CORE-02).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait: bool,
}

/// What a write did. The id is returned at once; `status` says the record's state, which can
/// also be read later with `GET /v1/memories/{id}` (CORE-02).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RememberResult {
    /// The record's id. For a deduplicated write, the id of the memory already stored.
    pub id: Uuid,
    /// `candidate` while the write waits for the gate (the default answer); with `wait`, the
    /// gate's decision: `committed`, `candidate` (a plan or speculation held until confirmed, or a
    /// proposal waiting for review), `quarantined` or `rejected`. Clients must not assume a write
    /// is committed: read `GET /v1/memories/{id}` for its state.
    pub status: MemoryStatus,
    /// True when an equivalent memory already existed and nothing new was written.
    pub deduplicated: bool,
    /// Kinds of sensitive data redacted from the text (`card`, `secret`, ...).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub redactions: Vec<String>,
    /// The record this write superseded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded: Option<Uuid>,
    /// Why the write was deduplicated, held, quarantined or rejected.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// What the gate read the statement as (QUAL-02), once it has run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub statement: Option<Statement>,
    /// The representation the record was routed to (HYB-01), once the gate has run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub route: Option<Route>,
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
    /// Wait for the write gate, as for `remember`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait: bool,
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
    /// Sensitivity labels for every round.
    #[serde(default)]
    pub labels: Vec<String>,
    /// Wait until the rounds are stored, as for `remember`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, JsonSchema)]
pub struct IngestResult {
    /// Rounds stored; while `queued`, the rounds accepted into the intake queue.
    pub stored: usize,
    /// Rounds stored as quarantined (never recalled).
    pub quarantined: usize,
    /// Rounds already stored, skipped.
    pub deduplicated: usize,
    /// Ids of the rounds stored (or queued).
    pub ids: Vec<Uuid>,
    /// True while the rounds are still in the intake queue (the request did not set `wait`):
    /// their ids resolve to `candidate` until the pipeline has stored them.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub queued: bool,
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
    /// with the same value or none (scope inheritance, MEM-04). `scope.session` names the session
    /// the recall runs in: its working memory comes first, and records of other sessions are never
    /// returned.
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
    /// A hard cap, in approximate tokens (4 bytes each), on the content of the returned
    /// memories and on the rendered block (PERF-06). A memory that does not fit is left out.
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
    /// The form of the text block: `plain` (the default), `markdown` or `xml`. Naming one also
    /// asks for the block, like `render`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub render_format: Option<RenderFormat>,
    #[serde(default)]
    pub actor: Option<String>,
    /// Also return candidates (plans and speculation the gate holds, proposals waiting for
    /// review), each labelled by its `status` (PR-7). Default recall never returns them.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub include_candidates: bool,
    /// An exact query over structured records (HYB-02): records of this type whose attributes
    /// contain these values are returned first, matched exactly, never by similarity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exact: Option<ExactQuery>,
}

/// An exact structured-record query inside a recall (HYB-02, HYB-03).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExactQuery {
    /// Only records of this type (`order`, `address`, ...); any type when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record_type: Option<String>,
    /// A JSON object the record's attributes must contain (`{"order_id": "A-1001"}`).
    #[serde(default = "empty_object")]
    pub attrs: serde_json::Value,
}

fn empty_object() -> serde_json::Value {
    serde_json::json!({})
}

/// The form of a recall's rendered text block (INT-04).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RenderFormat {
    /// One line per memory: `- [id] (kind, date #tags) text`.
    #[default]
    Plain,
    /// A Markdown list under a heading.
    Markdown,
    /// One `<memory>` element per memory inside `<memories>`, with the text escaped.
    Xml,
}

impl RenderFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            RenderFormat::Plain => "plain",
            RenderFormat::Markdown => "markdown",
            RenderFormat::Xml => "xml",
        }
    }

    pub fn parse(s: &str) -> Option<RenderFormat> {
        [RenderFormat::Plain, RenderFormat::Markdown, RenderFormat::Xml].into_iter().find(|f| f.as_str() == s)
    }
}

/// What a hit's final score was combined from (HYB-05), each before its policy weight.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RankFeatures {
    /// Keyword and vector ranks fused, or the reranker's score.
    pub relevance: f32,
    /// 1 for a memory of now, halving towards 0 with age (`1 / (1 + age / half_life)`).
    pub recency: f32,
    /// The record's confidence, 0 to 1.
    pub confidence: f32,
    /// 1 for a confirmed record valid now, 0.5 for a candidate, 0 for one no longer valid.
    pub validity: f32,
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
    /// Found by an exact structured-record match (HYB-02), not by similarity.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub exact: bool,
    /// From the working memory of the recall's session (MEM-01): listed first, newest first, not
    /// ranked against the query.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub working: bool,
    /// The record's vector, kept inside the engine for near-duplicate removal; never returned.
    #[serde(skip)]
    #[schemars(skip)]
    pub embedding: Option<Vec<f32>>,
    /// The score's features, kept for the recall explanation.
    #[serde(skip)]
    #[schemars(skip)]
    pub features: Option<RankFeatures>,
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
    /// Id of this recall's explanation (`GET /v1/recalls/{id}/explanation`, GOV-04).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recall_id: Option<Uuid>,
    /// Set when retrieval failed or ran out of time: `hits` is then empty, not a real answer
    /// (PERF-07). The value says why; callers should go on without memory, not retry in a loop.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub degraded: Option<String>,
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
    /// Candidates too (PR-7: only when the caller asks).
    pub include_candidates: bool,
    /// Agents whose agent-scoped records the reader was granted (INT-06): `shared_key` values.
    pub shared_agents: Vec<String>,
    /// Also return each hit's vector (`Hit::embedding`), for near-duplicate removal (ECON-03).
    pub with_vectors: bool,
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
    /// Records with any of these labels are left out (inside the statement).
    #[serde(default)]
    pub denied_labels: Vec<String>,
    /// Only records visible in this scope (see `RecallRequest::scope`).
    #[serde(default)]
    pub scope: Scope,
    /// Agents whose agent-scoped records the reader was granted (INT-06): `shared_key` values.
    #[serde(default)]
    pub shared_agents: Vec<String>,
    /// Only records scoped to exactly this session (a session's working memory).
    #[serde(default)]
    pub session: Option<String>,
    /// Only records with at least one of these tags.
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    /// Only records valid and unexpired at this time.
    #[serde(default)]
    pub live_at: Option<DateTime<Utc>>,
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
    /// Age of the oldest pending job, in seconds (queue lag).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_pending_secs: Option<f64>,
}

/// Commit or reject a candidate (`POST /v1/review`, GOV-08, GOV-11).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ReviewRequest {
    pub id: Uuid,
    pub action: ReviewAction,
    /// Why, for the audit log (a rejection's reason).
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReviewAction {
    Commit,
    Reject,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ReviewResult {
    pub id: Uuid,
    /// `committed`, or `rejected` (also when a revision's predecessor is no longer current).
    pub status: MemoryStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded: Option<Uuid>,
}

/// Replace a record's sensitivity labels (`POST /v1/labels`, ACC-04). No new version and no
/// re-embedding.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RelabelRequest {
    pub id: Uuid,
    /// The complete new set of labels.
    pub labels: Vec<String>,
}

/// Ask for a short-lived agent token (`POST /v1/tokens`, GOV-13).
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct TokenRequest {
    /// The agent principal the token acts as. Required when a user or an admin asks; an agent
    /// gets a token for itself.
    #[serde(default)]
    pub agent: Option<String>,
    /// The user the token acts for. A user's token always acts for that user; an admin or an
    /// agent trusted to act for users (`act_as`) may name one.
    #[serde(default)]
    pub user: Option<String>,
    /// At most `access.token_ttl_secs` (default and maximum 900 unless configured, never above 3600).
    #[serde(default)]
    pub ttl_secs: Option<u64>,
    /// Narrower permissions than the caller's; defaults to all the caller may pass on.
    #[serde(default)]
    pub scopes: Option<Vec<String>>,
}

/// Who the API sees (`GET /v1/whoami`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct WhoAmI {
    pub principal: String,
    /// `agent`, `user` or `admin`.
    pub kind: String,
    pub tenant: String,
    /// The verified user the calls act for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    pub scopes: Vec<String>,
    pub subjects: Vec<String>,
    pub denied_labels: Vec<String>,
    /// Writes enter as candidates (GOV-08).
    pub propose_only: bool,
    /// The caller's own scope (MEM-04): its org, team, agent and user. Reads return records of
    /// these and of broader levels. Empty for an admin, who reads every scope.
    #[serde(default, skip_serializing_if = "Scope::is_empty")]
    pub scope: Scope,
    /// `key`, `token`, `bootstrap` or `operator`.
    pub via: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
}

/// Why a record that matched a recall's query is not among its results (GOV-04).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ExclusionReason {
    /// Not recallable in its state: quarantined, candidate, rejected, expired, or superseded.
    Status,
    /// Scoped to another user, agent, team or org than the caller.
    Access,
    /// Carries a label denied to the caller.
    Label,
    /// Not valid at the recall's time: before `valid_from`, after `valid_to` or `expires_at`, or
    /// happened after `as_of`.
    Validity,
    /// Outside the request's own filters: kinds, tags or time window.
    Filter,
    /// A preference overridden by the same preference at a narrower scope (MEM-04).
    Overridden,
    /// A near-duplicate of a better-ranked memory in the same recall (ECON-03).
    Duplicate,
    /// Cut by the token budget.
    Budget,
    /// Ranked below the `k` returned.
    Rank,
}

impl ExclusionReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            ExclusionReason::Status => "status",
            ExclusionReason::Access => "access",
            ExclusionReason::Label => "label",
            ExclusionReason::Validity => "validity",
            ExclusionReason::Filter => "filter",
            ExclusionReason::Overridden => "overridden",
            ExclusionReason::Duplicate => "duplicate",
            ExclusionReason::Budget => "budget",
            ExclusionReason::Rank => "rank",
        }
    }
}

/// A record a recall returned, with its ranking signals.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ReturnedRecord {
    pub id: Uuid,
    /// 1 is the most relevant.
    pub rank: usize,
    pub score: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyword_rank: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vector_rank: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub similarity: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rerank_score: Option<f32>,
    /// Approximate tokens of its content.
    pub tokens: usize,
    /// What the score was combined from, each before its policy weight (HYB-05).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub features: Option<RankFeatures>,
}

/// A record left out of a recall, and why.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ExcludedRecord {
    pub id: Uuid,
    pub reason: ExclusionReason,
    /// Identifiers and values only, never content (e.g. `label hr`, `valid_to 2026-10-01T00:00:00Z`).
    pub detail: String,
}

/// Time spent per stage of a recall.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct RecallStages {
    pub embed_ms: f64,
    pub search_ms: f64,
    pub rerank_ms: f64,
    pub total_ms: f64,
    /// Database round trips on the synchronous path (PERF-02).
    pub statements: usize,
    /// Probes run in that statement: the query, plus a time window or sub-queries it mentions.
    pub probes: usize,
    /// Time the recall spent on its own instrumentation: metrics and this record (the row itself is
    /// written off the request path).
    pub instrument_ms: f64,
}

/// What a recall was asked, how it was authorized and what it returned, kept for its explanation.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RecallRecord {
    pub recall_id: Uuid,
    pub at: DateTime<Utc>,
    pub tenant: String,
    pub subject: String,
    /// The principal that recalled.
    pub principal: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    pub policy_version: String,
    /// The authorizer that decided (`scope`; `rebac` from G27).
    pub authorizer: String,
    pub query: String,
    pub k: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<MemoryKind>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// The scope filter applied (the caller's own, merged with the request's).
    #[serde(default, skip_serializing_if = "Scope::is_empty")]
    pub scope: Scope,
    /// Agents whose memory the caller was granted when it recalled (INT-06).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shared_agents: Vec<String>,
    pub denied_labels: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<DateTime<Utc>>,
    /// The time validity was checked at.
    pub valid_at: DateTime<Utc>,
    pub mode: RetrievalMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_budget: Option<usize>,
    pub reranked: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub windows: Vec<crate::query::TimeWindow>,
    pub returned: Vec<ReturnedRecord>,
    /// Records the recall itself cut (budget, rank); the explanation adds the rest.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cut: Vec<ExcludedRecord>,
    pub stages: RecallStages,
}

/// A recall's explanation (`GET /v1/recalls/{id}/explanation`, GOV-04): what it returned and why,
/// and the records that matched the query but were left out, each with its reason. Exclusions for
/// access, labels and state are recomputed from the store when the explanation is read
/// (`replayed_at`); budget and rank cuts are as recorded.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RecallExplanation {
    pub recall: RecallRecord,
    /// Most relevant first, by reason order (status, access, label, validity, filter, budget, rank).
    pub excluded: Vec<ExcludedRecord>,
    /// Excluded records this viewer may not know about, counted by reason (ids are shown only to
    /// principals with `audit:read`).
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub hidden: std::collections::BTreeMap<String, u64>,
    pub replayed_at: DateTime<Utc>,
}

/// Promote memories to another type (`POST /v1/promote`, MEM-05): a new record of `kind` in the
/// same subject, through that type's own gate, linked to its sources (`metadata.promoted_from`)
/// and audited (`memory.promote`). The sources stay as they are.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct PromoteRequest {
    #[serde(default)]
    pub tenant: Option<String>,
    /// The records promoted: 1 to 50 committed records of one subject.
    pub sources: Vec<Uuid>,
    /// The type of the new record: `semantic`, `preference`, `procedural` or `taxonomic`, or
    /// `episodic` for working memory.
    pub kind: MemoryKind,
    /// The promoted memory's text. Required for several sources; for one it defaults to the
    /// source's text.
    #[serde(default)]
    pub content: Option<String>,
    /// Why, for the audit log.
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    /// Labels added to the sources' own, which the new record always keeps.
    #[serde(default)]
    pub labels: Vec<String>,
    /// The new record's scope. Defaults to the sources' common scope without its session, so
    /// promoting out of a session's working memory makes the memory visible to the session's user.
    #[serde(default)]
    pub scope: Option<Scope>,
    #[serde(default)]
    pub structured: Option<Structured>,
    #[serde(default)]
    pub valid_to: Option<DateTime<Utc>>,
    #[serde(default)]
    pub actor: Option<String>,
    #[serde(default)]
    pub user: Option<String>,
    /// Idempotency key, as for `remember`.
    #[serde(default)]
    pub request_key: Option<String>,
    /// Wait for the write gate, as for `remember`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub wait: bool,
}

impl Default for PromoteRequest {
    /// For struct-update syntax in Rust callers; on the wire `kind` is required.
    fn default() -> Self {
        PromoteRequest {
            tenant: None,
            sources: vec![],
            kind: MemoryKind::Semantic,
            content: None,
            reason: None,
            tags: vec![],
            labels: vec![],
            scope: None,
            structured: None,
            valid_to: None,
            actor: None,
            user: None,
            request_key: None,
            wait: false,
        }
    }
}

/// One agent's agent-scoped memory made readable to another agent (INT-06). Without a grant an
/// agent never reads records scoped to another agent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Grant {
    pub id: Uuid,
    pub tenant: String,
    /// The agent whose memory is shared.
    pub grantor: String,
    /// The agent that may read it.
    pub grantee: String,
    /// Subjects the grant covers: an exact name, a prefix ending in `*`, or `*` for all.
    pub subjects: String,
    /// Kinds the grant covers; empty is all.
    #[serde(default)]
    pub kinds: Vec<MemoryKind>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<DateTime<Utc>>,
}

impl Grant {
    pub fn active(&self, now: DateTime<Utc>) -> bool {
        self.revoked_at.is_none() && self.expires_at.is_none_or(|t| t > now)
    }

    pub fn covers(&self, subject: &str) -> bool {
        match self.subjects.strip_suffix('*') {
            Some(prefix) => subject.starts_with(prefix),
            None => self.subjects == subject,
        }
    }
}

/// Create a grant (`POST /v1/grants`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrantRequest {
    pub grantor: String,
    pub grantee: String,
    /// Defaults to `*`.
    #[serde(default)]
    pub subjects: Option<String>,
    #[serde(default)]
    pub kinds: Vec<MemoryKind>,
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
}

/// A preference as it applies to a reader (`GET /v1/subjects/{subject}/preferences`, MEM-04):
/// for each key, the one set at the narrowest scope the reader is in.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EffectivePreference {
    /// The preference's key (`structured.attrs.key` of a `preference` record); absent for a
    /// preference written as text only, which overrides nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// The scope level it is set at.
    pub level: ScopeLevel,
    pub memory: Memory,
    /// The same preference at broader levels, which this one overrides.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub overrides: Vec<Uuid>,
}
