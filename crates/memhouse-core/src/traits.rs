// SPDX-License-Identifier: Apache-2.0
//! Adapter interfaces (TR-CORE-02). The engine only talks to these.

use crate::types::*;
use async_trait::async_trait;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmbedKind {
    Query,
    Passage,
}

#[async_trait]
pub trait Embedder: Send + Sync {
    /// Stable identifier (provider + model), stored with every record.
    fn id(&self) -> &str;
    fn dim(&self) -> usize;
    async fn embed(&self, texts: &[String], kind: EmbedKind) -> anyhow::Result<Vec<Vec<f32>>>;
}

#[async_trait]
pub trait Reranker: Send + Sync {
    fn id(&self) -> &str;
    /// One relevance score per document, same order as `docs`.
    async fn rerank(&self, query: &str, docs: &[String]) -> anyhow::Result<Vec<f32>>;
}

/// A chat model used by background enrichment.
#[async_trait]
pub trait ChatModel: Send + Sync {
    fn id(&self) -> String;
    async fn chat(&self, system: &str, user: &str) -> anyhow::Result<(String, LlmUsage)>;
}

#[async_trait]
pub trait Store: Send + Sync {
    async fn migrate(&self, dim: usize, embedder_id: &str) -> anyhow::Result<()>;
    async fn insert(&self, records: &[NewMemory]) -> anyhow::Result<()>;
    /// One hybrid statement per subject: keyword + vector candidates fused by RRF.
    async fn search(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>>;
    /// The query plan of `search` for these parameters (stores with a planner), so tests can check
    /// that recall never scans outside the subject (TR-RQ-01).
    async fn search_plan(&self, _q: &SearchQuery) -> anyhow::Result<Option<serde_json::Value>> {
        Ok(None)
    }
    async fn get(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<Memory>>;
    async fn list(&self, q: &ListQuery) -> anyhow::Result<Vec<Memory>>;
    /// Records of the subject whose content hash matches (exact dedup).
    async fn find_by_hash(&self, tenant: &str, subject: &str, hash: &str) -> anyhow::Result<Option<Uuid>>;
    /// Which of these content hashes the subject already has (batch dedup for ingest).
    async fn existing_hashes(&self, tenant: &str, subject: &str, hashes: &[String]) -> anyhow::Result<std::collections::HashSet<String>>;
    /// Most similar committed record of the same kind (near-dup check).
    async fn nearest(&self, tenant: &str, subject: &str, kind: MemoryKind, embedding: &[f32]) -> anyhow::Result<Option<(Uuid, f32)>>;
    async fn set_superseded(&self, tenant: &str, id: Uuid, by: Uuid) -> anyhow::Result<bool>;
    async fn set_status(&self, tenant: &str, id: Uuid, status: MemoryStatus) -> anyhow::Result<bool>;
    /// Hard delete of one record and every derived representation; records the deletion in the ledger.
    async fn delete(&self, tenant: &str, id: Uuid, actor: &str) -> anyhow::Result<bool>;
    /// Erase everything held about a subject. Returns the number of records removed.
    /// `purge_cache` also removes the subject's cached vectors (always true for erasure requests).
    async fn delete_subject(&self, tenant: &str, subject: &str, actor: &str, purge_cache: bool) -> anyhow::Result<u64>;
    /// Retention: delete episodic rounds written more than `days` ago, with the same cascade as
    /// `delete` (cached vectors, derived facts, enrichment jobs, cached extractions, ledger rows).
    /// Returns rounds plus derived facts removed.
    async fn purge_episodic_older_than(&self, tenant: &str, days: u32) -> anyhow::Result<u64>;
    async fn embed_cache_get(&self, model: &str, hashes: &[String]) -> anyhow::Result<Vec<(String, Vec<f32>)>>;
    async fn embed_cache_put(&self, model: &str, items: &[(String, Vec<f32>)]) -> anyhow::Result<()>;
    async fn audit(&self, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<Uuid>, detail: serde_json::Value) -> anyhow::Result<()>;
    async fn audit_log(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<AuditEvent>>;
    /// Recompute the hash chain. Returns (events checked, first broken event id).
    async fn audit_verify(&self) -> anyhow::Result<(u64, Option<i64>)>;
    async fn stats(&self, tenant: &str) -> anyhow::Result<Stats>;
    async fn subjects(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<(String, i64)>>;
    /// Records by id, in any order (missing ids are skipped).
    async fn get_many(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<Memory>>;

    // Enrichment queue (one row per ingested session), claimed with SKIP LOCKED.
    async fn enrich_enqueue(&self, tenant: &str, subject: &str, session_id: &str, round_ids: &[Uuid]) -> anyhow::Result<i64>;
    /// Claim up to `limit` pending jobs (or running ones whose lease expired).
    async fn enrich_claim(&self, limit: usize, lease_secs: i64) -> anyhow::Result<Vec<EnrichJob>>;
    async fn enrich_finish(&self, id: i64, cache_key: Option<&str>, outcome: &EnrichOutcome) -> anyhow::Result<()>;
    /// Retry later, or mark failed after `max_attempts`.
    async fn enrich_fail(&self, id: i64, error: &str, max_attempts: i32) -> anyhow::Result<()>;
    async fn enrich_status(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<EnrichStatus>;
    /// Outcomes of finished jobs (for cost and lag reports).
    async fn enrich_outcomes(&self, tenant: &str, subject: &str) -> anyhow::Result<Vec<EnrichOutcome>>;
    /// Content-addressed cache of extraction answers (purged with the subject on erasure).
    async fn llm_cache_get(&self, key: &str) -> anyhow::Result<Option<String>>;
    async fn llm_cache_put(&self, key: &str, model: &str, text: &str) -> anyhow::Result<()>;

    // Schema v2: the rest of a logical record, links, policies and request keys.
    /// Full records for an export, in id order after `after` (TR-CORE-03).
    async fn export_records(&self, tenant: &str, subject: Option<&str>, after: Option<Uuid>, limit: usize) -> anyhow::Result<Vec<crate::format::RecordLine>>;
    async fn export_links(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<Vec<Link>>;
    async fn export_policies(&self) -> anyhow::Result<Vec<crate::format::PolicyLine>>;
    /// Insert records exactly as given (ids, states, timestamps, provenance); ids already present
    /// are skipped. Returns how many were inserted.
    async fn import_records(&self, rows: &[ImportRow]) -> anyhow::Result<u64>;
    /// Record a compiled policy version (first write wins).
    async fn policy_put(&self, policy: &crate::format::PolicyLine) -> anyhow::Result<()>;
    /// Add a link between two subjects (an existing one is left as it is).
    async fn link_put(&self, link: &Link) -> anyhow::Result<()>;
    async fn links(&self, tenant: &str, subject: &str) -> anyhow::Result<Vec<Link>>;
    /// The stored (request hash, response) for an idempotency key (CORE-06).
    async fn request_get(&self, tenant: &str, key: &str) -> anyhow::Result<Option<(String, serde_json::Value)>>;
    async fn request_put(&self, tenant: &str, key: &str, subject: &str, operation: &str, request_hash: &str, response: &serde_json::Value) -> anyhow::Result<()>;
    /// Move records past `expires_at` to `expired` (working memory). Returns how many.
    async fn expire_due(&self, tenant: &str) -> anyhow::Result<u64>;
    /// Structured records of a subject by type, matched exactly on attributes (HYB-02).
    async fn structured_query(&self, tenant: &str, subject: &str, record_type: &str, attrs: &serde_json::Value) -> anyhow::Result<Vec<(Uuid, serde_json::Value)>>;
    /// Code references of a subject (a repository) whose stored hash differs from the given one.
    async fn stale_code_refs(&self, tenant: &str, subject: &str, path: &str, blob_hash: &str) -> anyhow::Result<Vec<Uuid>>;

    // Re-embedding to another model in place (see `reembed`). Stores that can't do it say so.
    /// The identity the stored vectors were made with, and the target of an unfinished re-embedding.
    async fn embedding_identity(&self) -> anyhow::Result<(Option<EmbeddingIdentity>, Option<EmbeddingIdentity>)> {
        anyhow::bail!("this store can't re-embed in place; export, then import into a new database")
    }
    /// How much there is to re-embed (no changes made).
    async fn reembed_estimate(&self) -> anyhow::Result<ReembedEstimate> {
        anyhow::bail!("this store can't re-embed in place")
    }
    /// Prepare space for vectors of `target` next to the current ones, and record the target.
    async fn reembed_begin(&self, _target: &EmbeddingIdentity) -> anyhow::Result<()> {
        anyhow::bail!("this store can't re-embed in place")
    }
    /// Records with a vector but none yet for the target, in id order after `after`.
    async fn reembed_pending(&self, _after: Option<Uuid>, _limit: usize) -> anyhow::Result<Vec<ReembedRow>> {
        anyhow::bail!("this store can't re-embed in place")
    }
    async fn reembed_write(&self, _target: &EmbeddingIdentity, _rows: &[ReembedVectors]) -> anyhow::Result<()> {
        anyhow::bail!("this store can't re-embed in place")
    }
    /// Switch to the target atomically if nothing is pending (writers are blocked meanwhile, readers
    /// are not). Returns the number still pending when it couldn't switch.
    async fn reembed_cutover(&self, _target: &EmbeddingIdentity) -> anyhow::Result<Option<u64>> {
        anyhow::bail!("this store can't re-embed in place")
    }
    /// Drop the target's vectors and forget the target; the current vectors are untouched.
    async fn reembed_abort(&self) -> anyhow::Result<bool> {
        anyhow::bail!("this store can't re-embed in place")
    }
}
