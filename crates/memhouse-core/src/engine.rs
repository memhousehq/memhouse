// SPDX-License-Identifier: Apache-2.0
//! The memory engine: one implementation of write gate, routing, ranking, redaction and audit,
//! shared by every transport (REST, MCP, CLI, benchmark).

use crate::config::Config;
use crate::gate;
use crate::query;
use crate::traits::{ChatModel, EmbedKind, Embedder, Reranker, Store};
use crate::types::*;
use chrono::Utc;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;
use uuid::Uuid;

#[derive(Clone)]
pub struct Engine {
    pub store: Arc<dyn Store>,
    pub embedder: Arc<dyn Embedder>,
    pub reranker: Option<Arc<dyn Reranker>>,
    /// LLM for background enrichment (only workers use it; ingest just queues jobs).
    pub chat: Option<Arc<dyn ChatModel>>,
    pub cfg: Arc<Config>,
}

pub fn content_hash(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// Rough token estimate (4 characters per token) used for context packing.
pub fn approx_tokens(s: &str) -> usize {
    s.len().div_ceil(4)
}

fn truncate_chars(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

impl Engine {
    pub fn new(store: Arc<dyn Store>, embedder: Arc<dyn Embedder>, reranker: Option<Arc<dyn Reranker>>, cfg: Config) -> Engine {
        Engine { store, embedder, reranker, chat: None, cfg: Arc::new(cfg) }
    }

    pub fn with_chat(mut self, chat: Option<Arc<dyn ChatModel>>) -> Engine {
        self.chat = chat;
        self
    }

    fn tenant(&self, t: &Option<String>) -> String {
        t.clone().unwrap_or_else(|| self.cfg.memory.tenant.clone())
    }

    fn subject(&self, s: &Option<String>) -> String {
        s.clone().filter(|s| !s.trim().is_empty()).unwrap_or_else(|| self.cfg.memory.default_subject.clone())
    }

    /// Embed passages through the content-addressed cache, so re-ingesting the same text is free.
    pub async fn embed_passages(&self, texts: &[String]) -> anyhow::Result<Vec<Vec<f32>>> {
        let model = self.embedder.id().to_string();
        let prefix = self.cfg.embedding.passage_prefix.clone().unwrap_or_default();
        let inputs: Vec<String> = texts.iter().map(|t| format!("{prefix}{t}")).collect();
        let hashes: Vec<String> = inputs.iter().map(|t| content_hash(t)).collect();
        let mut unique: Vec<String> = hashes.clone();
        unique.sort();
        unique.dedup();
        let cached: HashMap<String, Vec<f32>> = self.store.embed_cache_get(&model, &unique).await?.into_iter().collect();
        let mut missing_idx = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for (i, h) in hashes.iter().enumerate() {
            if !cached.contains_key(h) && seen.insert(h.clone()) {
                missing_idx.push(i);
            }
        }
        let mut fresh: HashMap<String, Vec<f32>> = HashMap::new();
        if !missing_idx.is_empty() {
            let batch = self.cfg.embedding.batch_size.max(1) * 4;
            for chunk in missing_idx.chunks(batch) {
                let to_embed: Vec<String> = chunk.iter().map(|&i| texts[i].clone()).collect();
                let vecs = self.embedder.embed(&to_embed, EmbedKind::Passage).await?;
                let items: Vec<(String, Vec<f32>)> = chunk.iter().zip(vecs).map(|(&i, v)| (hashes[i].clone(), v)).collect();
                self.store.embed_cache_put(&model, &items).await?;
                fresh.extend(items);
            }
        }
        Ok(hashes.iter().map(|h| cached.get(h).or_else(|| fresh.get(h)).cloned().unwrap_or_default()).collect())
    }

    async fn embed_queries(&self, qs: &[String]) -> anyhow::Result<Vec<Vec<f32>>> {
        let prefix = self.cfg.embedding.query_prefix.clone().unwrap_or_default();
        let texts: Vec<String> = qs.iter().map(|q| format!("{prefix}{q}")).collect();
        let v = self.embedder.embed(&texts, EmbedKind::Query).await?;
        anyhow::ensure!(v.len() == qs.len(), "embedder returned {} vectors for {} queries", v.len(), qs.len());
        Ok(v)
    }

    pub(crate) fn screen(&self, content: &str) -> anyhow::Result<gate::GateOutcome> {
        let g = &self.cfg.governance;
        if content.trim().is_empty() {
            anyhow::bail!("content is empty");
        }
        if content.chars().count() > g.max_content_chars {
            anyhow::bail!("content is {} characters; the limit is {} (governance.max_content_chars)", content.chars().count(), g.max_content_chars);
        }
        Ok(gate::screen(content, &g.redact, g.quarantine_injection))
    }

    /// Store one explicit memory (a fact, preference, procedure, commitment...).
    pub async fn remember(&self, req: RememberRequest) -> anyhow::Result<RememberResult> {
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        let kind = req.kind.unwrap_or(MemoryKind::Semantic);
        let gated = self.screen(&req.content)?;
        let hash = content_hash(&format!("{}\u{1f}{}", kind.as_str(), gated.content));

        if req.supersedes.is_none() {
            if let Some(existing) = self.store.find_by_hash(&tenant, &subject, &hash).await? {
                return Ok(RememberResult {
                    id: existing,
                    status: MemoryStatus::Committed,
                    deduplicated: true,
                    redactions: gated.redactions,
                    superseded: None,
                    note: Some("identical memory already stored".into()),
                });
            }
        }

        let embedding = self.embed_passages(std::slice::from_ref(&gated.content)).await?.pop();
        let status = if gated.quarantine() { MemoryStatus::Quarantined } else { MemoryStatus::Committed };

        if req.supersedes.is_none() && status == MemoryStatus::Committed {
            if let Some(emb) = &embedding {
                if let Some((id, sim)) = self.store.nearest(&tenant, &subject, kind, emb).await? {
                    if sim >= self.cfg.memory.dedup_threshold {
                        return Ok(RememberResult {
                            id,
                            status: MemoryStatus::Committed,
                            deduplicated: true,
                            redactions: gated.redactions,
                            superseded: None,
                            note: Some(format!("near-duplicate of an existing memory (similarity {sim:.3})")),
                        });
                    }
                }
            }
        }

        let now = Utc::now();
        let id = Uuid::now_v7();
        let mut metadata = req.metadata.clone().unwrap_or(serde_json::json!({}));
        if !gated.injection.is_empty() {
            metadata["quarantine_reasons"] = serde_json::json!(gated.injection);
        }
        let mem = Memory {
            id,
            tenant: tenant.clone(),
            subject: subject.clone(),
            kind,
            status,
            content: gated.content.clone(),
            session_id: None,
            turn_ref: None,
            occurred_at: req.occurred_at.or(Some(now)),
            valid_from: now,
            valid_to: req.valid_to,
            supersedes: req.supersedes,
            labels: vec![],
            tags: req.tags.clone(),
            source: req.source.clone().unwrap_or_else(|| actor.clone()),
            confidence: 1.0,
            metadata,
            created_at: now,
        };
        self.store.insert(&[NewMemory { memory: mem, embedding, content_hash: hash, alt: None }]).await?;
        let mut superseded = None;
        if let Some(old) = req.supersedes {
            if status == MemoryStatus::Committed && self.store.set_superseded(&tenant, old, id).await? {
                superseded = Some(old);
            }
        }
        self.store
            .audit(
                &actor,
                if superseded.is_some() { "memory.supersede" } else { "memory.write" },
                &tenant,
                Some(&subject),
                Some(id),
                serde_json::json!({
                    "kind": kind.as_str(),
                    "status": status.as_str(),
                    "redactions": gated.redactions,
                    "supersedes": superseded,
                    "embedder": self.embedder.id(),
                }),
            )
            .await?;
        Ok(RememberResult {
            id,
            status,
            deduplicated: false,
            redactions: gated.redactions,
            superseded,
            note: if status == MemoryStatus::Quarantined { Some(format!("quarantined: looks like an instruction to the agent ({})", gated.injection.join(", "))) } else { None },
        })
    }

    /// Store a conversation as episodic memory, one record per user/assistant round.
    pub async fn ingest(&self, req: IngestRequest) -> anyhow::Result<IngestResult> {
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        let session = req.session_id.clone().unwrap_or_else(|| Uuid::now_v7().to_string());
        let rounds = if req.per_message {
            req.messages
                .iter()
                .enumerate()
                .map(|(i, m)| Round {
                    text: format!("{}: {}", m.role, m.content.trim()),
                    focus: None,
                    timestamp: m.timestamp,
                    refs: vec![m.id.clone().unwrap_or_else(|| i.to_string())],
                })
                .collect()
        } else {
            build_rounds(&req.messages, self.cfg.memory.assistant_chars)
        };
        let now = Utc::now();
        let mut out = IngestResult::default();
        let mut recs: Vec<NewMemory> = Vec::with_capacity(rounds.len());
        let mut texts = Vec::with_capacity(rounds.len());
        // (record index, gated user text) for rounds that get a second, user-only vector.
        let mut focus: Vec<(usize, String)> = vec![];
        let gated_rounds: Vec<(usize, gate::GateOutcome, String)> = rounds
            .iter()
            .enumerate()
            .filter_map(|(i, r)| self.screen(truncate_chars(&r.text, self.cfg.governance.max_content_chars)).ok().map(|g| (i, g)))
            .map(|(i, g)| {
                let h = content_hash(&format!("episodic\u{1f}{session}\u{1f}{i}\u{1f}{}", g.content));
                (i, g, h)
            })
            .collect();
        let existing = self.store.existing_hashes(&tenant, &subject, &gated_rounds.iter().map(|(_, _, h)| h.clone()).collect::<Vec<_>>()).await?;
        for (i, gated, hash) in gated_rounds {
            let r = &rounds[i];
            if existing.contains(&hash) {
                out.deduplicated += 1;
                continue;
            }
            let status = if gated.quarantine() { MemoryStatus::Quarantined } else { MemoryStatus::Committed };
            if status == MemoryStatus::Quarantined {
                out.quarantined += 1;
            }
            let ts = r.timestamp.or(req.session_time);
            let mut metadata = serde_json::json!({ "round": i, "message_refs": r.refs });
            if !gated.injection.is_empty() {
                metadata["quarantine_reasons"] = serde_json::json!(gated.injection);
            }
            if !gated.redactions.is_empty() {
                metadata["redactions"] = serde_json::json!(gated.redactions);
            }
            let id = Uuid::now_v7();
            if let Some(f) = r.focus.as_deref().and_then(|f| self.screen(f).ok()) {
                focus.push((recs.len(), f.content));
            }
            texts.push(gated.content.clone());
            recs.push(NewMemory {
                memory: Memory {
                    id,
                    tenant: tenant.clone(),
                    subject: subject.clone(),
                    kind: MemoryKind::Episodic,
                    status,
                    content: gated.content,
                    session_id: Some(session.clone()),
                    turn_ref: Some(r.refs.join(",")),
                    occurred_at: ts,
                    valid_from: ts.unwrap_or(now),
                    valid_to: None,
                    supersedes: None,
                    labels: vec![],
                    tags: vec![],
                    source: req.source.clone().unwrap_or_else(|| actor.clone()),
                    confidence: 1.0,
                    metadata,
                    created_at: now,
                },
                embedding: None,
                content_hash: hash,
                alt: None,
            });
        }
        if recs.is_empty() {
            return Ok(out);
        }
        let n = texts.len();
        texts.extend(focus.iter().map(|(_, f)| f.clone()));
        let mut vecs = self.embed_passages(&texts).await?;
        let focus_vecs = vecs.split_off(n);
        for (rec, v) in recs.iter_mut().zip(vecs) {
            rec.embedding = Some(v);
        }
        let prefix = self.cfg.embedding.passage_prefix.clone().unwrap_or_default();
        for ((i, f), v) in focus.into_iter().zip(focus_vecs) {
            recs[i].alt = Some((content_hash(&format!("{prefix}{f}")), v));
        }
        self.store.insert(&recs).await?;
        out.ids = recs.iter().map(|r| r.memory.id).collect();
        out.stored = recs.len() - out.quarantined;
        if self.cfg.enrich.enabled && out.stored > 0 {
            let committed: Vec<Uuid> = recs.iter().filter(|r| r.memory.status == MemoryStatus::Committed).map(|r| r.memory.id).collect();
            self.store.enrich_enqueue(&tenant, &subject, &session, &committed).await?;
        }
        self.store
            .audit(&actor, "memory.ingest", &tenant, Some(&subject), None, serde_json::json!({ "session": session, "records": recs.len(), "quarantined": out.quarantined }))
            .await?;
        Ok(out)
    }

    /// Hybrid recall: keyword (BM25) + exact per-subject vector search fused by RRF in one SQL
    /// statement per probe. Query analysis adds a time-window probe for dated questions; probes
    /// are fused by weighted RRF, then optional cross-encoder reranking, recency weighting and
    /// token-budget packing.
    pub async fn recall(&self, req: RecallRequest) -> anyhow::Result<RecallResult> {
        let start = Instant::now();
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let k = req.k.unwrap_or(self.cfg.memory.default_k).clamp(1, 200);
        let mode = req.mode.unwrap_or_default();
        let use_rerank = req.rerank.unwrap_or(self.cfg.rerank.enabled) && self.reranker.is_some();
        let now = req.reference_time.or(req.as_of).unwrap_or_else(Utc::now);
        let plan = if req.analyze.unwrap_or(self.cfg.memory.query_analysis) {
            let mut p = query::analyze(&req.query, now);
            // A probe with no weight is not run at all.
            if self.cfg.memory.window_weight <= 0.0 {
                p.windows.clear();
            }
            if self.cfg.memory.subquery_weight <= 0.0 {
                p.subqueries.clear();
            }
            Some(p).filter(|p| !p.windows.is_empty() || !p.subqueries.is_empty())
        } else {
            None
        };
        let subqueries: &[String] = plan.as_ref().map(|p| p.subqueries.as_slice()).unwrap_or(&[]);
        let mut embeddings = if mode == RetrievalMode::Keyword {
            vec![None; 1 + subqueries.len()]
        } else {
            let texts: Vec<String> = std::iter::once(&req.query).chain(subqueries).cloned().collect();
            self.embed_queries(&texts).await?.into_iter().map(Some).collect()
        };
        let embed_ms = start.elapsed().as_secs_f64() * 1000.0;
        let fused_limit = if use_rerank { self.cfg.rerank.candidates.max(k) } else { k };
        let rerank_n = self.cfg.rerank.candidates.max(1);
        let q = SearchQuery {
            tenant: tenant.clone(),
            subject: subject.clone(),
            text: req.query.clone(),
            embedding: embeddings[0].take(),
            kinds: req.kinds.clone(),
            tags: req.tags.clone(),
            denied_labels: self.cfg.governance.denied_labels.clone(),
            as_of: req.as_of,
            valid_at: req.as_of.unwrap_or_else(Utc::now),
            mode,
            per_retriever: self.cfg.memory.candidates.max(fused_limit),
            limit: fused_limit,
            rrf_k: self.cfg.memory.rrf_k,
            keyword_weight: self.cfg.memory.keyword_weight,
            vector_weight: self.cfg.memory.vector_weight,
            windows: vec![],
        };
        // Extra probes: the same query inside the time windows it mentions, and one per sub-query.
        let mut probes: Vec<(SearchQuery, f32)> = vec![];
        if let Some(p) = &plan {
            if !p.windows.is_empty() {
                let mut w = q.clone();
                w.windows = p.windows.iter().map(|w| (w.start, w.end)).collect();
                probes.push((w, self.cfg.memory.window_weight));
            }
            for (sq, emb) in p.subqueries.iter().zip(embeddings.into_iter().skip(1)) {
                let mut s = q.clone();
                s.text = sq.clone();
                s.embedding = emb;
                probes.push((s, self.cfg.memory.subquery_weight));
            }
        }
        let t_search = Instant::now();
        let mut hits = if probes.is_empty() {
            self.store.search(&q).await?
        } else {
            let main = self.store.search(&q);
            let rest = futures::future::try_join_all(probes.iter().map(|(p, _)| self.store.search(p)));
            let (main, rest) = futures::future::try_join(main, rest).await?;
            let (top, top_w) = (self.cfg.memory.window_top, self.cfg.memory.window_top_weight);
            let bonus = (top > 0 && top_w > 0.0 && plan.as_ref().is_some_and(|p| !p.windows.is_empty())).then(|| (rest[0].iter().take(top).cloned().collect::<Vec<Hit>>(), top_w));
            let lists: Vec<(Vec<Hit>, f32)> = std::iter::once((main, 1.0)).chain(rest.into_iter().zip(probes.iter().map(|(_, w)| *w))).chain(bonus).collect();
            fuse(lists, self.cfg.memory.rrf_k, fused_limit)
        };
        let search_ms = t_search.elapsed().as_secs_f64() * 1000.0;
        let t_rerank = Instant::now();
        let candidates = hits.len();

        if use_rerank && hits.len() > 1 {
            // Re-score only the head of the fused list; the tail keeps its fused order below it.
            let rr = self.reranker.as_ref().unwrap();
            let n = hits.len().min(rerank_n);
            let docs: Vec<String> = hits[..n].iter().map(|h| h.memory.content.clone()).collect();
            let scores = rr.rerank(&req.query, &docs).await?;
            // Blend the cross-encoder with the fused rank so a good keyword/vector agreement still counts.
            for (i, (h, s)) in hits[..n].iter_mut().zip(scores).enumerate() {
                let fused_prior = 1.0 - i as f32 / n as f32;
                h.rerank_score = Some(s);
                h.score = 2.0 + sigmoid(s) + self.cfg.rerank.fused_weight * fused_prior;
            }
            hits[..n].sort_by(|a, b| b.score.total_cmp(&a.score));
        }

        let rw = self.cfg.memory.recency_weight;
        if rw > 0.0 {
            let now = req.as_of.unwrap_or_else(Utc::now);
            let hl = self.cfg.memory.recency_half_life_days.max(1.0);
            for h in hits.iter_mut() {
                let t = h.memory.occurred_at.unwrap_or(h.memory.created_at);
                let age = (now - t).num_seconds().max(0) as f32 / 86_400.0;
                h.score += rw / (1.0 + age / hl);
            }
            hits.sort_by(|a, b| b.score.total_cmp(&a.score));
        }

        hits.truncate(k);
        if let Some(budget) = req.token_budget {
            let mut used = 0;
            hits.retain(|h| {
                let t = approx_tokens(&h.memory.content);
                if used + t <= budget || used == 0 {
                    used += t;
                    true
                } else {
                    false
                }
            });
        }
        if self.cfg.governance.audit_reads {
            self.store
                .audit(
                    req.actor.as_deref().unwrap_or("api"),
                    "memory.recall",
                    &tenant,
                    Some(&subject),
                    None,
                    serde_json::json!({ "returned": hits.iter().map(|h| h.memory.id).collect::<Vec<_>>() }),
                )
                .await?;
        }
        Ok(RecallResult {
            hits,
            took_ms: start.elapsed().as_secs_f64() * 1000.0,
            embed_ms,
            search_ms,
            rerank_ms: if use_rerank { t_rerank.elapsed().as_secs_f64() * 1000.0 } else { 0.0 },
            candidates,
            reranked: use_rerank,
            plan,
        })
    }

    /// Replace a memory with new content; the old version stays for audit but is no longer recalled.
    pub async fn update(&self, tenant: Option<String>, id: Uuid, content: String, actor: Option<String>) -> anyhow::Result<RememberResult> {
        let t = self.tenant(&tenant);
        let old = self.store.get(&t, id).await?.ok_or_else(|| anyhow::anyhow!("memory {id} not found"))?;
        self.remember(RememberRequest {
            tenant: Some(t),
            subject: Some(old.subject),
            content,
            kind: Some(old.kind),
            tags: old.tags,
            supersedes: Some(id),
            actor,
            ..Default::default()
        })
        .await
    }

    pub async fn forget(&self, tenant: Option<String>, id: Uuid, actor: Option<String>) -> anyhow::Result<bool> {
        let t = self.tenant(&tenant);
        let actor = actor.unwrap_or_else(|| "api".into());
        let mem = self.store.get(&t, id).await?;
        let ok = self.store.delete(&t, id, &actor).await?;
        if ok {
            self.store.audit(&actor, "memory.delete", &t, mem.as_ref().map(|m| m.subject.as_str()), Some(id), serde_json::json!({})).await?;
        }
        Ok(ok)
    }

    pub async fn forget_subject(&self, tenant: Option<String>, subject: &str, actor: Option<String>) -> anyhow::Result<u64> {
        let t = self.tenant(&tenant);
        let actor = actor.unwrap_or_else(|| "api".into());
        let n = self.store.delete_subject(&t, subject, &actor, true).await?;
        self.store.audit(&actor, "subject.erase", &t, Some(subject), None, serde_json::json!({ "records": n })).await?;
        Ok(n)
    }

    /// Drop a subject's records but keep the content-addressed embedding cache. For benchmarks and
    /// tests over public data that re-ingest the same text; not an erasure (use `forget_subject`).
    pub async fn reset_subject(&self, tenant: Option<String>, subject: &str, actor: Option<String>) -> anyhow::Result<u64> {
        let t = self.tenant(&tenant);
        let actor = actor.unwrap_or_else(|| "api".into());
        let n = self.store.delete_subject(&t, subject, &actor, false).await?;
        self.store.audit(&actor, "subject.reset", &t, Some(subject), None, serde_json::json!({ "records": n })).await?;
        Ok(n)
    }

    pub async fn list(
        &self,
        tenant: Option<String>,
        subject: Option<String>,
        kinds: Option<Vec<MemoryKind>>,
        limit: usize,
        offset: usize,
        include_inactive: bool,
    ) -> anyhow::Result<Vec<Memory>> {
        self.store.list(&ListQuery { tenant: self.tenant(&tenant), subject, kinds, include_inactive, limit: limit.clamp(1, 1000), offset }).await
    }

    /// Apply retention rules (episodic purge). Returns records removed.
    pub async fn apply_retention(&self) -> anyhow::Result<u64> {
        let days = self.cfg.governance.episodic_retention_days;
        if days == 0 {
            return Ok(0);
        }
        let n = self.store.purge_episodic_older_than(&self.cfg.memory.tenant, days).await?;
        if n > 0 {
            self.store.audit("system", "retention.purge", &self.cfg.memory.tenant, None, None, serde_json::json!({ "records": n, "days": days })).await?;
        }
        Ok(n)
    }
}

fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

/// A user/assistant exchange indexed as one episodic record.
#[derive(Debug, Clone)]
pub struct Round {
    pub text: String,
    /// The user's own words, when the round also holds replies (embedded as a second vector).
    pub focus: Option<String>,
    pub timestamp: Option<chrono::DateTime<Utc>>,
    /// Caller references (or positions) of the messages it contains.
    pub refs: Vec<String>,
}

/// Group messages into rounds: each user message plus the replies that follow it.
/// Assistant text is trimmed so long answers don't drown the user's own words in the embedding.
pub fn build_rounds(messages: &[Message], assistant_chars: usize) -> Vec<Round> {
    let mut rounds: Vec<Round> = Vec::new();
    let mut cur: Option<Round> = None;
    for (i, m) in messages.iter().enumerate() {
        let role = m.role.to_ascii_lowercase();
        let r = m.id.clone().unwrap_or_else(|| i.to_string());
        let is_user = role == "user" || role == "human" || role == "customer";
        if is_user || cur.is_none() {
            if let Some(c) = cur.take() {
                rounds.push(c);
            }
            cur = Some(Round { text: String::new(), focus: None, timestamp: m.timestamp, refs: vec![] });
        }
        let c = cur.as_mut().unwrap();
        if is_user && c.text.is_empty() && m.content.trim().chars().count() >= 20 {
            c.focus = Some(m.content.trim().to_string());
        }
        let body = if is_user { m.content.as_str() } else { truncate_chars(&m.content, assistant_chars) };
        if !c.text.is_empty() {
            c.text.push('\n');
        }
        c.text.push_str(&format!("{}: {}", m.role, body.trim()));
        c.refs.push(r);
        if c.timestamp.is_none() {
            c.timestamp = m.timestamp;
        }
    }
    if let Some(c) = cur {
        rounds.push(c);
    }
    // A round that is only the user's message needs no second vector.
    for r in rounds.iter_mut() {
        if r.refs.len() < 2 {
            r.focus = None;
        }
    }
    rounds
}

/// Weighted reciprocal rank fusion of several probes' ranked lists. The first list's hit data
/// (keyword/vector ranks, similarity) is kept for a memory found by several probes.
fn fuse(lists: Vec<(Vec<Hit>, f32)>, rrf_k: f32, limit: usize) -> Vec<Hit> {
    let mut by_id: HashMap<Uuid, Hit> = HashMap::new();
    let mut score: HashMap<Uuid, f32> = HashMap::new();
    for (hits, w) in lists {
        for (rank, h) in hits.into_iter().enumerate() {
            *score.entry(h.memory.id).or_default() += w / (rrf_k + 1.0 + rank as f32);
            by_id.entry(h.memory.id).or_insert(h);
        }
    }
    let mut out: Vec<Hit> = by_id
        .into_values()
        .map(|mut h| {
            h.score = score[&h.memory.id];
            h
        })
        .collect();
    out.sort_by(|a, b| b.score.total_cmp(&a.score).then_with(|| a.memory.id.cmp(&b.memory.id)));
    out.truncate(limit);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(role: &str, c: &str) -> Message {
        Message { role: role.into(), content: c.into(), timestamp: None, id: None }
    }

    #[test]
    fn rounds_group_user_and_replies() {
        let r = build_rounds(&[msg("user", "hi"), msg("assistant", "hello"), msg("user", "I moved to Lisbon"), msg("assistant", "nice"), msg("assistant", "anything else?")], 100);
        assert_eq!(r.len(), 2);
        assert_eq!(r[1].refs, vec!["2", "3", "4"]);
        assert!(r[1].text.starts_with("user: I moved to Lisbon"));
    }

    #[test]
    fn leading_assistant_message_gets_own_round() {
        let r = build_rounds(&[msg("assistant", "Welcome!"), msg("user", "thanks")], 100);
        assert_eq!(r.len(), 2);
    }
}
