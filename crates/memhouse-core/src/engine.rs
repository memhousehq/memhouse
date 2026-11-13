// SPDX-License-Identifier: Apache-2.0
//! The memory engine: one implementation of write gate, routing, ranking, redaction and audit,
//! shared by every transport (REST, MCP, CLI, benchmark).

use crate::config::Config;
use crate::error;
use crate::gate;
use crate::metrics;
use crate::policy::CompiledPolicy;
use crate::query;
use crate::traits::{ChatModel, EmbedKind, Embedder, Reranker, Store};
use crate::types::*;
use chrono::Utc;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;
use tracing::Instrument;
use uuid::Uuid;

#[derive(Clone)]
pub struct Engine {
    pub store: Arc<dyn Store>,
    /// Verifies credentials (keys, tokens) and issues tokens.
    pub auth: Arc<crate::identity::Authenticator>,
    /// Decides every operation a `Caller` makes.
    pub authorizer: Arc<dyn crate::access::Authorizer>,
    pub embedder: Arc<dyn Embedder>,
    pub reranker: Option<Arc<dyn Reranker>>,
    /// LLM for background enrichment (only workers use it; ingest just queues jobs).
    pub chat: Option<Arc<dyn ChatModel>>,
    pub cfg: Arc<Config>,
    /// The compiled policy of each tenant (G08): read through `policy_for`.
    pub policies: Arc<crate::policy::PolicyCache>,
    /// Where policy specs and their activations live (the `PolicySource` seam).
    pub policy_source: Arc<dyn crate::policy::PolicySource>,
    /// One tenant run under a fixed policy whatever is active: the scratch tenant of an
    /// evaluation replay (QUAL-05).
    pub(crate) policy_pin: Option<Arc<(String, Arc<CompiledPolicy>)>>,
    /// Record an explanation for every recall (GOV-04). Off only to measure what it costs.
    pub explain_recalls: bool,
    /// The latest recall records, so an explanation can be read before its row is written.
    recent: Arc<std::sync::Mutex<std::collections::VecDeque<RecallRecord>>>,
    /// Where writes wait between intake and the gate (the `IntakeQueue` seam, G10).
    pub intake: Arc<dyn crate::traits::IntakeQueue>,
    /// The write gate's statement classifier (QUAL-02).
    pub classifier: Arc<dyn crate::traits::Classifier>,
    /// Redacts personal data and secrets (stage 2 of the pipeline).
    pub pii: Arc<dyn crate::traits::PiiDetector>,
    /// Finish each write's pipeline in the request's own task right after answering (on by
    /// default; tests turn it off to leave proposals to workers).
    pub inline_intake: bool,
    /// The working memory of active sessions (PERF-05); see [`crate::working`].
    pub working: Arc<crate::working::WorkingCache>,
    /// Grants between agents, as last read from the store (INT-06); see [`crate::sharing`].
    pub(crate) grants: Arc<crate::sharing::GrantCache>,
}

/// Who recalls, and the read constraints of their authorization decision.
pub(crate) struct RecallContext {
    pub principal: String,
    pub user: Option<String>,
    pub denied_labels: Vec<String>,
    pub authorizer: String,
    /// Agents whose agent-scoped memory the caller was granted (`shared_key` values).
    pub shared_agents: Vec<String>,
}

/// The deduplication key of a single write: its kind and text, and its scope when it has one, so
/// the same words noted in two scopes are two records (MEM-04).
fn write_hash(base: String, scope: &Scope) -> String {
    if scope.is_empty() {
        content_hash(&base)
    } else {
        content_hash(&format!("{base}\u{1f}scope\u{1f}{}", serde_json::to_string(scope).unwrap_or_default()))
    }
}

pub fn content_hash(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// Hash of a request without its key and caller, for idempotency checks.
fn request_hash(request: &impl serde::Serialize) -> String {
    let mut v = serde_json::to_value(request).unwrap_or_default();
    if let Some(o) = v.as_object_mut() {
        o.remove("request_key");
        o.remove("actor");
        // Waiting changes when the answer comes, not what is written.
        o.remove("wait");
    }
    content_hash(&v.to_string())
}

pub(crate) use crate::intake::Entry;
use crate::intake::{Op, PendingRecord, Proposal};

/// What a list may return.
pub(crate) struct Page {
    pub kinds: Option<Vec<MemoryKind>>,
    pub include_inactive: bool,
    pub limit: usize,
    pub denied_labels: Vec<String>,
    pub scope: Scope,
    pub shared_agents: Vec<String>,
}

fn encode_cursor(at: chrono::DateTime<Utc>, id: Uuid) -> String {
    hex::encode(format!("{}.{id}", at.timestamp_micros()))
}

fn decode_cursor(c: &str) -> anyhow::Result<(chrono::DateTime<Utc>, Uuid)> {
    let bad = || error::invalid("cursor is not one this API returned");
    let text = String::from_utf8(hex::decode(c).map_err(|_| bad())?).map_err(|_| bad())?;
    let (micros, id) = text.split_once('.').ok_or_else(bad)?;
    let at = chrono::DateTime::from_timestamp_micros(micros.parse().map_err(|_| bad())?).ok_or_else(bad)?;
    Ok((at, Uuid::parse_str(id).map_err(|_| bad())?))
}

/// Recall hits as the plain model-neutral text block (INT-04); [`crate::pack::render`] has the
/// other forms. MCP returns it as the tool's text content.
pub fn render(subject: &str, hits: &[Hit]) -> String {
    crate::pack::render(subject, hits, RenderFormat::Plain)
}

pub use crate::pack::approx_tokens;

fn truncate_chars(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

impl Engine {
    pub fn new(store: Arc<dyn Store>, embedder: Arc<dyn Embedder>, reranker: Option<Arc<dyn Reranker>>, cfg: Config) -> Engine {
        let authorizer = Arc::new(crate::access::ScopeAuthorizer::new(&cfg));
        let cfg = Arc::new(cfg);
        let auth = Arc::new(crate::identity::Authenticator::new(store.clone(), cfg.clone()));
        let policy_source = Arc::new(crate::policy::StorePolicies(store.clone()));
        let intake = store.intake_queue().unwrap_or_else(|| Arc::new(crate::intake::NoQueue));
        let working = Arc::new(crate::working::WorkingCache::new(cfg.memory.working_cache_secs, cfg.memory.working_cache_sessions, cfg.memory.working_cache_items));
        Engine {
            store,
            auth,
            authorizer,
            embedder,
            reranker,
            chat: None,
            cfg,
            policies: Default::default(),
            policy_source,
            policy_pin: None,
            explain_recalls: true,
            recent: Default::default(),
            intake,
            classifier: Arc::new(crate::classify::RuleClassifier),
            pii: Arc::new(gate::RulePii),
            inline_intake: true,
            working,
            grants: Default::default(),
        }
    }

    /// Replace the statement classifier (a small model, `intake.classifier = "llm"`).
    pub fn with_classifier(mut self, c: Arc<dyn crate::traits::Classifier>) -> Engine {
        self.classifier = c;
        self
    }

    /// Replace the intake queue (tests; the durable log in G31).
    pub fn with_intake(mut self, q: Arc<dyn crate::traits::IntakeQueue>) -> Engine {
        self.intake = q;
        self
    }

    /// Run `tenant` under `policy` whatever policy is active for it (an evaluation's scratch tenant).
    pub(crate) fn with_policy_pin(mut self, tenant: &str, policy: Arc<CompiledPolicy>) -> Engine {
        self.policy_pin = Some(Arc::new((tenant.to_string(), policy)));
        self
    }

    /// Leave every proposal to the workers instead of finishing it in the request's task.
    pub fn with_inline_intake(mut self, on: bool) -> Engine {
        self.inline_intake = on;
        self
    }

    fn provenance(policy: &CompiledPolicy, actor: &str, user: &Option<String>, request_key: &Option<String>) -> Provenance {
        Provenance {
            agent: Some(actor.to_string()),
            user: user.clone(),
            policy_version: Some(policy.version.clone()),
            request_key: request_key.clone(),
            extractor: None,
            extractor_config: None,
        }
    }

    /// Idempotency (CORE-06): the stored response for a repeated key, or an error when the key
    /// was used for a different request. `None` means go ahead.
    pub(crate) async fn replay<T: serde::de::DeserializeOwned>(&self, tenant: &str, key: &Option<String>, request: &impl serde::Serialize) -> anyhow::Result<Option<T>> {
        let Some(key) = key else { return Ok(None) };
        if key.is_empty() || key.len() > 255 || key.chars().any(char::is_control) {
            return Err(error::invalid("request_key must be 1 to 255 characters without control characters"));
        }
        let Some((hash, response)) = self.store.request_get(tenant, key).await? else { return Ok(None) };
        if hash != request_hash(request) {
            return Err(error::conflict(format!("request key '{key}' was already used for a different request")));
        }
        Ok(Some(serde_json::from_value(response)?))
    }

    async fn remember_key(
        &self,
        tenant: &str,
        subject: &str,
        op: &str,
        key: &Option<String>,
        request: &impl serde::Serialize,
        response: &impl serde::Serialize,
    ) -> anyhow::Result<()> {
        if let Some(key) = key {
            self.store.request_put(tenant, key, subject, op, &request_hash(request), &serde_json::to_value(response)?).await?;
        }
        Ok(())
    }

    /// The key of a write that is already queued. Failing to record it does not undo the write,
    /// so it is not an error (which would read as "not accepted"): a retry may then queue the
    /// same content again, and the gate rejects that copy as a near-duplicate of the first.
    pub(crate) async fn accepted_key(&self, tenant: &str, subject: &str, op: &str, key: &Option<String>, request: &impl serde::Serialize, response: &impl serde::Serialize) {
        if let Err(e) = self.remember_key(tenant, subject, op, key, request, response).await {
            metrics::inc("memhouse_request_key_failures_total", &[("op", op)], 1.0);
            tracing::warn!("the {op} was queued but its request key could not be recorded: {e:#}");
        }
    }

    /// Link `subject` to another subject (ACC-06), held in `subject`'s own partition.
    pub async fn link(&self, tenant: Option<String>, subject: &str, linked_subject: &str, link_type: &str, memory_id: Option<Uuid>, actor: &str) -> anyhow::Result<Link> {
        let tenant = self.tenant(&tenant);
        anyhow::ensure!(subject != linked_subject, "a link joins two different subjects");
        let link = Link {
            tenant: tenant.clone(),
            subject: subject.into(),
            linked_subject: linked_subject.into(),
            link_type: link_type.into(),
            memory_id,
            created_by: actor.into(),
            created_at: Utc::now(),
        };
        self.store.link_put(&link).await?;
        self.store.audit(actor, "subject.link", &tenant, Some(subject), memory_id, serde_json::json!({ "linked_subject": linked_subject, "link_type": link_type })).await?;
        Ok(link)
    }

    /// The same engine under another configuration (policy, authenticator and authorizer rebuilt).
    pub fn reconfigure(self, cfg: Config) -> Engine {
        let (chat, intake, pii, inline) = (self.chat.clone(), self.intake.clone(), self.pii.clone(), self.inline_intake);
        // A classifier built for another `intake.classifier` setting is not kept: the rules
        // stand in until the caller sets the new one with `with_classifier`.
        let classifier: Arc<dyn crate::traits::Classifier> = if cfg.intake.classifier == self.cfg.intake.classifier {
            self.classifier.clone()
        } else {
            // The model classifier is built from the configuration by the server
            // (`memhouse_models::classifier_chat`); core can't build it, so say so.
            if cfg.intake.classifier != crate::config::ClassifierKind::default() {
                tracing::warn!("intake.classifier changed in reconfigure: the rules classify until with_classifier sets the model classifier");
            }
            Arc::new(crate::classify::RuleClassifier)
        };
        let mut e = Engine::new(self.store, self.embedder, self.reranker, cfg).with_chat(chat).with_classifier(classifier).with_intake(intake).with_inline_intake(inline);
        e.pii = pii;
        e
    }

    /// The span of a write: who, which subject, under which policy; the record ids and outcome
    /// are recorded on it as they become known (QUAL-07).
    pub(crate) fn write_span(name: &'static str, policy: &CompiledPolicy, actor: &Option<String>, subject: &Option<String>) -> tracing::Span {
        let principal = actor.clone().unwrap_or_else(|| "api".into());
        let subject = subject.clone().unwrap_or_default();
        let version = &policy.version;
        match name {
            "memhouse.remember" => {
                tracing::info_span!("memhouse.remember", memhouse.principal = %principal, memhouse.subject = %subject, memhouse.policy_version = %version, memhouse.record_ids = tracing::field::Empty, memhouse.status = tracing::field::Empty, otel.status_code = tracing::field::Empty)
            }
            "memhouse.revise" => {
                tracing::info_span!("memhouse.revise", memhouse.principal = %principal, memhouse.policy_version = %version, memhouse.record_ids = tracing::field::Empty, memhouse.status = tracing::field::Empty, otel.status_code = tracing::field::Empty)
            }
            "memhouse.promote" => {
                tracing::info_span!("memhouse.promote", memhouse.principal = %principal, memhouse.policy_version = %version, memhouse.record_ids = tracing::field::Empty, memhouse.status = tracing::field::Empty, otel.status_code = tracing::field::Empty)
            }
            "memhouse.ingest" => {
                tracing::info_span!("memhouse.ingest", memhouse.principal = %principal, memhouse.subject = %subject, memhouse.policy_version = %version, memhouse.record_ids = tracing::field::Empty, memhouse.status = tracing::field::Empty, otel.status_code = tracing::field::Empty)
            }
            _ => {
                tracing::info_span!("memhouse.forget", memhouse.principal = %principal, memhouse.subject = %subject, memhouse.policy_version = %version, memhouse.record_ids = tracing::field::Empty, memhouse.status = tracing::field::Empty, otel.status_code = tracing::field::Empty)
            }
        }
    }

    /// Run an operation in its span and count it, with its outcome, in the metrics.
    pub(crate) async fn traced<T>(&self, op: &'static str, span: tracing::Span, fut: impl std::future::Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
        let start = Instant::now();
        let r = fut.instrument(span.clone()).await;
        let outcome = match &r {
            Ok(_) => "ok",
            Err(e) => {
                span.record("otel.status_code", "ERROR");
                error::code_of(e).as_str()
            }
        };
        metrics::inc("memhouse_operations_total", &[("op", op), ("outcome", outcome)], 1.0);
        metrics::observe("memhouse_operation_duration_seconds", &[("op", op)], start.elapsed().as_secs_f64());
        r
    }

    fn keep_recent(&self, r: RecallRecord) {
        if let Ok(mut q) = self.recent.lock() {
            if q.len() >= 256 {
                q.pop_front();
            }
            q.push_back(r);
        }
    }

    /// A recall's record: from memory if it was recent, else from the store.
    pub async fn recall_record(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<RecallRecord>> {
        let recent = self.recent.lock().ok().and_then(|q| q.iter().find(|r| r.recall_id == id && r.tenant == tenant).cloned());
        match recent {
            Some(r) => Ok(Some(r)),
            None => self.store.recall_get(tenant, id).await,
        }
    }

    /// Replace the authorizer (ReBAC in G27; tests).
    pub fn with_authorizer(mut self, a: Arc<dyn crate::access::Authorizer>) -> Engine {
        self.authorizer = a;
        self
    }

    /// Replace the authenticator (tests shorten its cache).
    pub fn with_authenticator(mut self, a: crate::identity::Authenticator) -> Engine {
        self.auth = Arc::new(a);
        self
    }

    /// Act as a verified caller: every operation is authorized first.
    pub fn caller(&self, who: crate::identity::Identity) -> crate::caller::Caller {
        crate::caller::Caller { engine: self.clone(), who }
    }

    pub fn with_chat(mut self, chat: Option<Arc<dyn ChatModel>>) -> Engine {
        self.chat = chat;
        self
    }

    pub(crate) fn tenant(&self, t: &Option<String>) -> String {
        t.clone().unwrap_or_else(|| self.cfg.memory.tenant.clone())
    }

    pub(crate) fn subject(&self, s: &Option<String>) -> String {
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

    /// Store one explicit memory (a fact, preference, procedure, commitment...).
    pub async fn remember(&self, req: RememberRequest) -> anyhow::Result<RememberResult> {
        self.remember_with(req, Entry::Commit).await
    }

    pub(crate) async fn remember_with(&self, req: RememberRequest, entry: Entry) -> anyhow::Result<RememberResult> {
        let policy = retryable(self.policy_for(&self.tenant(&req.tenant)).await)?;
        let span = Self::write_span("memhouse.remember", &policy, &req.actor, &req.subject);
        retryable(self.traced("remember", span, self.remember_untraced(req, entry, &policy)).await)
    }

    async fn remember_untraced(&self, req: RememberRequest, entry: Entry, policy: &CompiledPolicy) -> anyhow::Result<RememberResult> {
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        if let Some(done) = self.replay::<RememberResult>(&tenant, &req.request_key, &req).await? {
            return Ok(done);
        }
        let result = self.remember_once(&req, &tenant, &subject, &actor, (entry, Op::Remember), policy).await?;
        self.accepted_key(&tenant, &subject, "remember", &req.request_key, &req, &result).await;
        Ok(result)
    }

    /// Stages 2 and 3 of a single write (stage 1, authorization, is the caller's): validate,
    /// redact, deduplicate exactly, queue durably, answer `candidate`. With `wait`, also run the
    /// rest of the pipeline and answer with the gate's decision.
    pub(crate) async fn remember_once(
        &self,
        req: &RememberRequest,
        tenant: &str,
        subject: &str,
        actor: &str,
        how: (Entry, Op),
        policy: &CompiledPolicy,
    ) -> anyhow::Result<RememberResult> {
        let (entry, op) = how;
        let (tenant, subject, actor) = (tenant.to_string(), subject.to_string(), actor.to_string());
        let kind = req.kind.unwrap_or(MemoryKind::Semantic);
        if !policy.allows(kind) {
            return Err(policy.kind_refused(kind));
        }
        let type_policy = policy.of(kind);
        let scope = req.scope.clone().unwrap_or_default();
        if ScopeLevel::NARROWEST_FIRST.iter().any(|l| scope.get(*l).is_some_and(|v| v.trim().is_empty() || v.len() > 200 || v.chars().any(char::is_control))) {
            return Err(error::invalid("a scope value is 1 to 200 characters without control characters"));
        }
        if let Some(st) = &req.structured {
            if st.record_type.trim().is_empty() || !st.attrs.is_object() {
                return Err(error::invalid("structured needs a record_type and an attrs object"));
            }
        }
        // The pipeline adds its own keys to the metadata, so it must be an object.
        if req.metadata.as_ref().is_some_and(|m| !m.is_object()) {
            return Err(error::invalid("metadata must be a JSON object"));
        }
        // Routing input (HYB-01): a JSON record written as content is a structured record.
        let (content, structured) = match (&req.structured, crate::classify::structured_from_content(&req.content)) {
            (None, Some((st, text))) => (text, Some(st)),
            _ => (req.content.clone(), req.structured.clone()),
        };
        let (content, mut redactions) = self.redact(policy, &content).await?;
        let structured = match structured {
            Some(st) => Some(Structured { attrs: self.redact_attrs(policy, &st.attrs, &mut redactions).await?, record_type: st.record_type }),
            None => None,
        };
        // Metadata is stored with the record, so it is redacted like the content: nothing a
        // detector finds reaches the queue (TR-IN-02).
        let mut metadata = match &req.metadata {
            Some(m) => self.redact_attrs(policy, m, &mut redactions).await?,
            None => serde_json::json!({}),
        };
        // Provenance of a promotion is written by `promote` only, never taken from a caller.
        if op != Op::Promote {
            if let Some(o) = metadata.as_object_mut() {
                for k in ["promoted_from", "promoted_from_kinds", "promotion_reason"] {
                    o.remove(k);
                }
            }
        }
        // Structured records with the same text but other attributes are different records.
        let hash = match &structured {
            None => write_hash(format!("{}\u{1f}{}", kind.as_str(), content), &scope),
            Some(st) => write_hash(format!("{}\u{1f}{}\u{1f}{}\u{1f}{}", kind.as_str(), content, st.record_type, st.attrs), &scope),
        };
        // A signal must reach the gate every time it is seen: the repeat is what commits it.
        let signal = type_policy.gate.holds_signals() && metadata.get("signal").and_then(|v| v.as_bool()) == Some(true);

        if req.supersedes.is_none() && !signal {
            if let Some(existing) = self.store.find_by_hash(&tenant, &subject, &hash).await? {
                let stored = self.store.get(&tenant, existing).await?;
                let status = stored.as_ref().map(|m| m.status).unwrap_or(MemoryStatus::Committed);
                metrics::inc("memhouse_writes_total", &[("status", "deduplicated")], 1.0);
                // A promotion that lands on an identical record still happened (MEM-05): its
                // sources, kinds and labels join a record that is itself a promotion, and it is
                // audited either way. A record someone wrote independently is left as it is.
                let mut note = "identical memory already stored".to_string();
                if op == Op::Promote {
                    let sources = crate::intake::promoted_from_in(&metadata);
                    let kinds: Vec<String> = metadata["promoted_from_kinds"].as_array().into_iter().flatten().filter_map(|k| k.as_str().map(String::from)).collect();
                    let audit = crate::intake::AuditEntry {
                        actor: actor.clone(),
                        action: "memory.promote".into(),
                        subject: Some(subject.clone()),
                        memory_id: Some(existing),
                        detail: serde_json::json!({ "from": metadata["promoted_from"], "from_kinds": metadata["promoted_from_kinds"], "to": kind.as_str(), "status": status.as_str(), "deduplicated": true, "reason": metadata.get("promotion_reason") }),
                    };
                    if self.store.promotion_merge(&tenant, existing, &sources, &kinds, &req.labels, &audit).await? {
                        note = "identical promoted memory already stored; these sources were added to it".into();
                    } else {
                        self.store.audit(&audit.actor, &audit.action, &tenant, audit.subject.as_deref(), audit.memory_id, audit.detail.clone()).await?;
                        note = "identical memory already stored independently of these sources; it was left as it is".into();
                    }
                }
                return Ok(RememberResult { id: existing, status, deduplicated: true, redactions, superseded: None, note: Some(note), statement: None, route: None });
            }
        }

        let now = Utc::now();
        let id = Uuid::now_v7();
        let expires_at = req.expires_at.or_else(|| type_policy.ttl_secs.map(|t| now + chrono::Duration::seconds(t as i64)));
        // Working memory written in a session lives until the session's last write plus the TTL
        // (MEM-01), unless the write set its own expiry.
        let session = scope.session.clone().filter(|_| type_policy.ttl_secs.is_some());
        let follows_session = session.is_some() && req.expires_at.is_none();
        if follows_session {
            metadata["ttl"] = serde_json::json!("session");
        } else if let Some(o) = metadata.as_object_mut() {
            o.remove("ttl");
        }
        let source = req.source.clone().unwrap_or_else(|| actor.clone());
        let mem = Memory {
            id,
            tenant: tenant.clone(),
            subject: subject.clone(),
            kind,
            status: MemoryStatus::Candidate,
            content,
            session_id: None,
            turn_ref: None,
            occurred_at: req.occurred_at.or(Some(now)),
            valid_from: now,
            valid_to: req.valid_to,
            supersedes: req.supersedes,
            labels: req.labels.clone(),
            tags: req.tags.clone(),
            source: source.clone(),
            confidence: 1.0,
            metadata,
            created_at: now,
            expires_at,
            scope,
            provenance: Self::provenance(policy, &actor, &req.user, &req.request_key),
        };
        let proposal = Proposal {
            id,
            tenant: tenant.clone(),
            subject: subject.clone(),
            actor: actor.clone(),
            user: req.user.clone(),
            source,
            op,
            entry,
            records: vec![PendingRecord { memory: mem, content_hash: hash, redactions: redactions.clone(), focus: None, structured, code_refs: req.code_refs.clone() }],
            session_id: None,
            enqueued_at: now,
        };
        self.enqueue(&proposal).await?;
        let span = tracing::Span::current();
        span.record("memhouse.record_ids", id.to_string().as_str());
        // From here the write is accepted: a failure while waiting answers the candidate (the
        // workers finish it), never an error that would invite a duplicate retry.
        // A session reads its own scratchpad back at once, so its working memory always waits.
        if req.wait || session.is_some() {
            let waited = match self.settle(&tenant, &subject, id, std::time::Duration::from_millis(self.cfg.intake.wait_timeout_ms)).await {
                Ok(_) => self.result_of(&tenant, id, redactions.clone()).await,
                Err(e) => Err(e),
            };
            match waited {
                Ok(r) => {
                    if let Some(s) = &session {
                        self.session_wrote(&tenant, &subject, s, &r, follows_session.then_some(expires_at).flatten(), req.supersedes.is_some()).await;
                    }
                    span.record("memhouse.status", r.status.as_str());
                    return Ok(r);
                }
                Err(e) => tracing::warn!("write {id} is queued; waiting for its gate decision failed: {e:#}"),
            }
        } else {
            self.nudge(&tenant, &subject, id);
        }
        span.record("memhouse.status", "candidate");
        Ok(RememberResult { id, status: MemoryStatus::Candidate, deduplicated: false, redactions, superseded: None, note: None, statement: None, route: None })
    }

    /// Store a conversation as episodic memory, one record per user/assistant round.
    pub async fn ingest(&self, req: IngestRequest) -> anyhow::Result<IngestResult> {
        self.ingest_with(req, Entry::Commit).await
    }

    pub(crate) async fn ingest_with(&self, req: IngestRequest, entry: Entry) -> anyhow::Result<IngestResult> {
        let policy = retryable(self.policy_for(&self.tenant(&req.tenant)).await)?;
        let span = Self::write_span("memhouse.ingest", &policy, &req.actor, &req.subject);
        retryable(self.traced("ingest", span, self.ingest_untraced(req, entry, &policy)).await)
    }

    async fn ingest_untraced(&self, req: IngestRequest, entry: Entry, policy: &CompiledPolicy) -> anyhow::Result<IngestResult> {
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        if let Some(done) = self.replay::<IngestResult>(&tenant, &req.request_key, &req).await? {
            return Ok(done);
        }
        let result = self.ingest_once(&req, &tenant, &subject, &actor, entry, policy).await?;
        self.accepted_key(&tenant, &subject, "ingest", &req.request_key, &req, &result).await;
        Ok(result)
    }

    /// Stages 2 and 3 of a conversation: rounds built, redacted, deduplicated against the
    /// subject's stored rounds, queued as one proposal.
    async fn ingest_once(&self, req: &IngestRequest, tenant: &str, subject: &str, actor: &str, entry: Entry, policy: &CompiledPolicy) -> anyhow::Result<IngestResult> {
        let (tenant, subject, actor) = (tenant.to_string(), subject.to_string(), actor.to_string());
        if !policy.allows(MemoryKind::Episodic) {
            return Err(policy.kind_refused(MemoryKind::Episodic));
        }
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
        let mut gated_rounds: Vec<(usize, String, Vec<String>, String)> = vec![];
        for (i, r) in rounds.iter().enumerate() {
            // An empty round is skipped; a detector that fails refuses the whole call, before
            // anything is queued, rather than dropping the round unredacted or unseen.
            let (text, redactions) = match self.redact(policy, truncate_chars(&r.text, policy.policy.write_gate.max_content_chars)).await {
                Ok(v) => v,
                Err(e) if error::code_of(&e) == error::ErrorCode::InvalidRequest => continue,
                Err(e) => return Err(e),
            };
            // Scoped rounds (an agent-private conversation) are their scope's own records: two
            // agents that ingest the same round each keep theirs.
            let h = write_hash(format!("episodic\u{1f}{session}\u{1f}{i}\u{1f}{text}"), req.scope.as_ref().unwrap_or(&Scope::default()));
            gated_rounds.push((i, text, redactions, h));
        }
        let existing = self.store.existing_hashes(&tenant, &subject, &gated_rounds.iter().map(|g| g.3.clone()).collect::<Vec<_>>()).await?;
        let source = req.source.clone().unwrap_or_else(|| actor.clone());
        let mut records: Vec<PendingRecord> = Vec::with_capacity(gated_rounds.len());
        for (i, text, redactions, hash) in gated_rounds {
            let r = &rounds[i];
            if existing.contains(&hash) {
                out.deduplicated += 1;
                continue;
            }
            let ts = r.timestamp.or(req.session_time);
            let mut metadata = serde_json::json!({ "round": i, "message_refs": r.refs });
            if !redactions.is_empty() {
                metadata["redactions"] = serde_json::json!(redactions);
            }
            let focus = match r.focus.as_deref() {
                Some(f) => match self.redact(policy, f).await {
                    Ok((t, _)) => Some(t),
                    Err(e) if error::code_of(&e) == error::ErrorCode::InvalidRequest => None,
                    Err(e) => return Err(e),
                },
                None => None,
            };
            records.push(PendingRecord {
                memory: Memory {
                    id: Uuid::now_v7(),
                    tenant: tenant.clone(),
                    subject: subject.clone(),
                    kind: MemoryKind::Episodic,
                    status: MemoryStatus::Candidate,
                    content: text,
                    session_id: Some(session.clone()),
                    turn_ref: Some(r.refs.join(",")),
                    occurred_at: ts,
                    valid_from: ts.unwrap_or(now),
                    valid_to: None,
                    supersedes: None,
                    labels: req.labels.clone(),
                    tags: vec![],
                    source: source.clone(),
                    confidence: 1.0,
                    metadata,
                    created_at: now,
                    expires_at: None,
                    scope: req.scope.clone().unwrap_or_default(),
                    provenance: Self::provenance(policy, &actor, &req.user, &req.request_key),
                },
                content_hash: hash,
                redactions,
                focus,
                structured: None,
                code_refs: vec![],
            });
        }
        if records.is_empty() {
            return Ok(out);
        }
        out.ids = records.iter().map(|r| r.memory.id).collect();
        let proposal = Proposal {
            id: out.ids[0],
            tenant: tenant.clone(),
            subject: subject.clone(),
            actor: actor.clone(),
            user: req.user.clone(),
            source,
            op: Op::Ingest,
            entry,
            records,
            session_id: Some(session.clone()),
            enqueued_at: now,
        };
        self.enqueue(&proposal).await?;
        let span = tracing::Span::current();
        span.record("memhouse.record_ids", out.ids.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",").as_str());
        // Accepted from here: a failure while waiting answers `queued`, not an error.
        let waited = if req.wait {
            match self.settle(&tenant, &subject, proposal.id, std::time::Duration::from_millis(self.cfg.intake.wait_timeout_ms)).await {
                Ok(_) => self.store.get_many(&tenant, &out.ids).await.map(Some),
                Err(e) => Err(e),
            }
        } else {
            self.nudge(&tenant, &subject, proposal.id);
            Ok(None)
        };
        match waited {
            Ok(Some(stored)) => {
                out.queued = stored.len() < out.ids.len();
                out.quarantined = stored.iter().filter(|m| m.status == MemoryStatus::Quarantined).count();
                out.stored = stored.len() - out.quarantined;
            }
            other => {
                if let Err(e) = other {
                    tracing::warn!("ingest {} is queued; waiting for the pipeline failed: {e:#}", proposal.id);
                }
                // While queued, `stored` counts the rounds accepted (the 1.x meaning of the field).
                out.queued = true;
                out.stored = out.ids.len();
            }
        }
        span.record("memhouse.status", format!("{} stored, {} quarantined{}", out.stored, out.quarantined, if out.queued { ", queued" } else { "" }).as_str());
        Ok(out)
    }

    /// Hybrid recall: keyword (BM25) + exact per-subject vector search fused by RRF in one SQL
    /// statement for all probes (PERF-02). Query analysis adds a time-window probe for dated questions; probes
    /// are fused by weighted RRF, then optional cross-encoder reranking, recency weighting and
    /// token-budget packing.
    pub async fn recall(&self, req: RecallRequest) -> anyhow::Result<RecallResult> {
        let ctx = RecallContext {
            principal: req.actor.clone().unwrap_or_else(|| "api".into()),
            user: None,
            denied_labels: self.cfg.governance.denied_labels.clone(),
            authorizer: "operator".into(),
            shared_agents: vec![],
        };
        self.recall_with(req, ctx).await
    }

    /// Recall with the labels a caller may not read filtered inside the statement (TR-RQ-03),
    /// traced (QUAL-07), measured, and recorded for its explanation (GOV-04).
    pub(crate) async fn recall_with(&self, req: RecallRequest, mut ctx: RecallContext) -> anyhow::Result<RecallResult> {
        let t0 = Instant::now();
        // PERF-07: retrieval that fails or overruns its budget answers empty and flagged.
        let budget = self.cfg.memory.recall_timeout_ms;
        let deadline = (budget > 0).then(|| tokio::time::Instant::now() + std::time::Duration::from_millis(budget));
        // Resolved before the span opens: a refresh read is not part of the recall's statement.
        let policy = match within(deadline, self.policy_for(&self.tenant(&req.tenant))).await {
            Ok(p) => p,
            Err(e) => return degraded(e, t0, "recall"),
        };
        ctx.denied_labels = with_policy_labels(&ctx.denied_labels, &policy);
        let recall_id = Uuid::now_v7();
        let span = tracing::info_span!(
            "memhouse.recall",
            memhouse.recall_id = %recall_id,
            memhouse.principal = %ctx.principal,
            memhouse.policy_version = %policy.version,
            memhouse.subject = tracing::field::Empty,
            memhouse.returned = tracing::field::Empty,
            memhouse.record_ids = tracing::field::Empty,
            db.statements = tracing::field::Empty,
            otel.status_code = tracing::field::Empty,
        );
        let start = Instant::now();
        let r = self.recall_inner(req, ctx, recall_id, &policy, deadline).instrument(span.clone()).await;
        let r = match r {
            Err(e) if degradable(&e) => {
                span.record("otel.status_code", "ERROR");
                degraded(e, t0, "recall")
            }
            r => r,
        };
        let outcome = match &r {
            Ok(_) => "ok",
            Err(e) => {
                span.record("otel.status_code", "ERROR");
                error::code_of(e).as_str()
            }
        };
        metrics::inc("memhouse_operations_total", &[("op", "recall"), ("outcome", outcome)], 1.0);
        metrics::observe("memhouse_operation_duration_seconds", &[("op", "recall")], start.elapsed().as_secs_f64());
        r
    }

    async fn recall_inner(
        &self,
        req: RecallRequest,
        ctx: RecallContext,
        recall_id: Uuid,
        policy: &CompiledPolicy,
        deadline: Option<tokio::time::Instant>,
    ) -> anyhow::Result<RecallResult> {
        let rank = &policy.policy.ranking;
        let denied_labels = ctx.denied_labels.clone();
        let start = Instant::now();
        let tenant = self.tenant(&req.tenant);
        let subject = self.subject(&req.subject);
        let k = req.k.unwrap_or(rank.default_k).clamp(1, 200);
        let mode = req.mode.unwrap_or_default();
        let use_rerank = req.rerank.unwrap_or(self.cfg.rerank.enabled) && self.reranker.is_some();
        let now = req.reference_time.or(req.as_of).unwrap_or_else(Utc::now);
        let scope = req.scope.clone().unwrap_or_default();
        // MEM-01: inside a session, the session's working memory comes first, from the session
        // cache. A recall of working memory alone is answered from it entirely (PERF-05).
        let session_first = scope.session.clone().filter(|s| {
            s != crate::access::NOBODY
                && policy.of(MemoryKind::Working).retrieval == crate::policy::Retrieval::SessionCache
                && req.as_of.is_none()
                && req.kinds.as_ref().is_none_or(|k| k.contains(&MemoryKind::Working))
        });
        let working_only = session_first.is_some() && req.kinds.as_deref() == Some(&[MemoryKind::Working]) && req.exact.is_none();
        let plan = if working_only {
            None
        } else if req.analyze.unwrap_or(rank.query_analysis) {
            let mut p = query::analyze(&req.query, now);
            // A probe with no weight is not run at all.
            if rank.window_weight <= 0.0 {
                p.windows.clear();
            }
            if rank.subquery_weight <= 0.0 {
                p.subqueries.clear();
            }
            // Identifiers in the question ("order A-1001") get an exact structured probe (HYB-03).
            p.exact = query::identifiers(&req.query);
            Some(p).filter(|p| !p.windows.is_empty() || !p.subqueries.is_empty() || !p.exact.is_empty())
        } else {
            None
        };
        let subqueries: &[String] = plan.as_ref().map(|p| p.subqueries.as_slice()).unwrap_or(&[]);
        // The session's working memory is read while the query is embedded, so a cache miss adds
        // no latency either.
        let embed = async {
            if mode == RetrievalMode::Keyword || working_only {
                Ok(vec![None; 1 + subqueries.len()])
            } else {
                let texts: Vec<String> = std::iter::once(&req.query).chain(subqueries).cloned().collect();
                let v = within(deadline, self.embed_queries(&texts).instrument(tracing::info_span!("recall.embed", texts = texts.len()))).await?;
                Ok::<_, anyhow::Error>(v.into_iter().map(Some).collect::<Vec<_>>())
            }
        };
        let load = async {
            match &session_first {
                Some(s) => {
                    // A recall of working memory alone that asks for more than the cache keeps
                    // per session reads the store, so no note is out of its reach.
                    let more = (working_only && k > self.working.max_items()).then_some(k);
                    within(deadline, self.session_working(&tenant, &subject, s, more).instrument(tracing::info_span!("recall.working"))).await.map(Some)
                }
                None => Ok(None),
            }
        };
        let (embeddings, working) = tokio::join!(embed, load);
        let (mut embeddings, working) = (embeddings?, working?);
        let embed_ms = start.elapsed().as_secs_f64() * 1000.0;
        let now_valid = req.as_of.unwrap_or_else(Utc::now);
        // The cache is per session, not per reader: every access rule is applied here.
        let (mut session_hits, session_statements) = match working {
            Some((items, loaded, full)) => {
                let visible = |m: &Memory| {
                    m.status == MemoryStatus::Committed
                        && !m.labels.iter().any(|l| denied_labels.contains(l))
                        && scope.sees(&m.scope, m.kind, &ctx.shared_agents)
                        && m.valid_from <= now_valid
                        && m.valid_to.is_none_or(|t| t > now_valid)
                        && req.tags.as_ref().is_none_or(|t| t.iter().any(|x| m.tags.contains(x)))
                };
                let mut mine: Vec<Memory> = items.into_iter().filter(visible).collect();
                let mut statements = usize::from(loaded);
                // What was read holds the session's newest notes, whoever wrote them and whether
                // or not they are still live. If it was cut at its limit and too few of them are
                // this reader's to give, older ones may lie beyond it: read the session with the
                // reader's scope, grants, labels, tags, validity and expiry in the statement.
                let want = if working_only { k } else { (k / 2).max(1) };
                if full && mine.len() < want {
                    if let Some(s) = &session_first {
                        let q = ListQuery {
                            tenant: tenant.clone(),
                            subject: Some(subject.clone()),
                            kinds: Some(vec![MemoryKind::Working]),
                            limit: want,
                            denied_labels: denied_labels.clone(),
                            scope: scope.clone(),
                            shared_agents: ctx.shared_agents.clone(),
                            session: Some(s.clone()),
                            tags: req.tags.clone(),
                            live_at: Some(now_valid),
                            ..Default::default()
                        };
                        // Every filter is in the statement, before its limit: however many
                        // newer notes don't count, the newest that do are the ones returned.
                        mine = within(deadline, self.store.list(&q)).await?.into_iter().filter(visible).collect();
                        statements += 1;
                    }
                }
                (mine, statements)
            }
            None => (vec![], 0),
        };
        let fused_limit = if use_rerank { self.cfg.rerank.candidates.max(k) } else { k };
        let rerank_n = self.cfg.rerank.candidates.max(1);
        // Near-duplicate removal (ECON-03) frees places; the candidates ranked just below the
        // ones a recall without it would consider are fetched in the same statement to fill them.
        let fetch_limit = if rank.dedup { fused_limit + k.clamp(5, 20) } else { fused_limit };
        let q = SearchQuery {
            tenant: tenant.clone(),
            subject: subject.clone(),
            text: req.query.clone(),
            embedding: embeddings[0].take(),
            kinds: req.kinds.clone(),
            tags: req.tags.clone(),
            denied_labels,
            as_of: req.as_of,
            valid_at: now_valid,
            mode,
            // Each retriever returns at least what is fetched, or the reserve would be empty
            // whenever `candidates` is no larger than k.
            per_retriever: rank.candidates.max(fetch_limit),
            limit: fetch_limit,
            rrf_k: rank.rrf_k,
            keyword_weight: rank.keyword_weight,
            vector_weight: rank.vector_weight,
            windows: vec![],
            scope: scope.clone(),
            include_candidates: req.include_candidates,
            shared_agents: ctx.shared_agents.clone(),
            with_vectors: rank.dedup,
        };
        // Extra probes: the same query inside the time windows it mentions, and one per sub-query.
        let mut probes: Vec<(SearchQuery, f32)> = vec![];
        if let Some(p) = &plan {
            if !p.windows.is_empty() {
                let mut w = q.clone();
                w.windows = p.windows.iter().map(|w| (w.start, w.end)).collect();
                // The reserve comes from the main probe alone.
                w.limit = fused_limit;
                probes.push((w, rank.window_weight));
            }
            for (sq, emb) in p.subqueries.iter().zip(embeddings.into_iter().skip(1)) {
                let mut s = q.clone();
                s.text = sq.clone();
                s.embedding = emb;
                s.limit = fused_limit;
                probes.push((s, rank.subquery_weight));
            }
        }
        let t_search = Instant::now();
        let n_probes = 1 + probes.len();
        let statements = if working_only { 0 } else { self.store.statements_per_recall(n_probes) };
        let all: Vec<SearchQuery> = std::iter::once(q.clone()).chain(probes.iter().map(|(p, _)| p.clone())).collect();
        let mut lists = if working_only {
            vec![vec![]]
        } else {
            within(deadline, self.store.search_many(&all).instrument(tracing::info_span!("recall.search", probes = n_probes, db.statements = statements))).await?
        };
        // The exact probe (HYB-02/03): structured records matched on the request's attributes or
        // on identifiers in the question, never by similarity.
        let exact_values: Vec<String> = plan.as_ref().map(|p| p.exact.clone()).unwrap_or_default();
        let mut exact_statements = 0;
        let exact_hits = if req.exact.is_some() || !exact_values.is_empty() {
            let (rt, attrs) = match &req.exact {
                Some(x) => (x.record_type.as_deref(), Some(&x.attrs).filter(|a| a.as_object().is_some_and(|o| !o.is_empty()))),
                None => (None, None),
            };
            let mut xq = q.clone();
            xq.limit = k;
            // Attributes asked for explicitly decide alone. A type alone narrows the identifiers
            // in the question: those matches first, then the type's other records.
            let (values, fallback) = match &req.exact {
                Some(_) if attrs.is_some() => (vec![], false),
                Some(_) => (exact_values, true),
                None => (exact_values, false),
            };
            let mut found = within(deadline, self.store.structured_lookup(&xq, rt, attrs, &values).instrument(tracing::info_span!("recall.exact"))).await?;
            if fallback && !values.is_empty() && found.len() < k {
                let more = within(deadline, self.store.structured_lookup(&xq, rt, None, &[]).instrument(tracing::info_span!("recall.exact"))).await?;
                let seen: std::collections::HashSet<Uuid> = found.iter().map(|h| h.memory.id).collect();
                found.extend(more.into_iter().filter(|h| !seen.contains(&h.memory.id)));
                found.truncate(k);
            }
            exact_statements += 1 + usize::from(fallback && !values.is_empty());
            found
        } else {
            vec![]
        };
        let mut statements = statements + exact_statements + session_statements;
        // Each probe's list as a recall without the reserve would see it; what lies below is
        // the main list's reserve, which only fills places freed by duplicates.
        let mut reserve: Vec<Hit> = vec![];
        for (i, l) in lists.iter_mut().enumerate() {
            if l.len() > fused_limit {
                let tail = l.split_off(fused_limit);
                if i == 0 {
                    reserve = tail;
                }
            }
        }
        let mut hits = if probes.is_empty() {
            lists.pop().unwrap_or_default()
        } else {
            let rest = lists.split_off(1);
            let main = lists.pop().unwrap_or_default();
            let (top, top_w) = (rank.window_top, rank.window_top_weight);
            let bonus = (top > 0 && top_w > 0.0 && plan.as_ref().is_some_and(|p| !p.windows.is_empty())).then(|| (rest[0].iter().take(top).cloned().collect::<Vec<Hit>>(), top_w));
            let lists: Vec<(Vec<Hit>, f32)> = std::iter::once((main, 1.0)).chain(rest.into_iter().zip(probes.iter().map(|(_, w)| *w))).chain(bonus).collect();
            fuse(lists, rank.rrf_k, fused_limit)
        };
        let search_ms = t_search.elapsed().as_secs_f64() * 1000.0;
        let t_rerank = Instant::now();
        let candidates = hits.len();

        if use_rerank && hits.len() > 1 {
            // Re-score only the head of the fused list; the tail keeps its fused order below it.
            let rr = self.reranker.as_ref().unwrap();
            let n = hits.len().min(rerank_n);
            let docs: Vec<String> = hits[..n].iter().map(|h| h.memory.content.clone()).collect();
            let scores = within(deadline, rr.rerank(&req.query, &docs).instrument(tracing::info_span!("recall.rerank", docs = n))).await?;
            // Blend the cross-encoder with the fused rank so a good keyword/vector agreement still counts.
            for (i, (h, s)) in hits[..n].iter_mut().zip(scores).enumerate() {
                let fused_prior = 1.0 - i as f32 / n as f32;
                h.rerank_score = Some(s);
                h.score = 2.0 + sigmoid(s) + self.cfg.rerank.fused_weight * fused_prior;
            }
            hits[..n].sort_by(|a, b| b.score.total_cmp(&a.score));
        }

        // HYB-05: the final score combines relevance, recency, confidence and validity with
        // the compiled policy's weights. Recency is measured from the recall's own time.
        let present = Utc::now();
        crate::pack::score(&mut hits, rank, req.as_of.unwrap_or(present), present);

        if !exact_hits.is_empty() {
            let top = hits.first().map(|h| h.score).unwrap_or(0.0);
            let ids: std::collections::HashSet<Uuid> = exact_hits.iter().map(|h| h.memory.id).collect();
            hits.retain(|h| !ids.contains(&h.memory.id));
            let n = exact_hits.len();
            let exact: Vec<Hit> = exact_hits
                .into_iter()
                .enumerate()
                .map(|(i, mut h)| {
                    h.exact = true;
                    h.score = top + 1.0 + (n - i) as f32;
                    h
                })
                .collect();
            hits.splice(0..0, exact);
        }
        // Scope-ordered lookup (MEM-04): a preference that is also set at a narrower scope the
        // reader is in gives way to that one. Only recalls that hit a keyed preference pay for it.
        let mut overridden: Vec<ExcludedRecord> = vec![];
        let keyed = |h: &Hit| h.memory.kind == MemoryKind::Preference && h.memory.status == MemoryStatus::Committed && h.memory.metadata.get("pref_key").is_some();
        if req.as_of.is_none() && policy.of(MemoryKind::Preference).retrieval == crate::policy::Retrieval::ScopeOrdered && hits.iter().any(keyed) {
            let reader = crate::preference::Reader { scope: &scope, denied_labels: &ctx.denied_labels, shared_agents: &ctx.shared_agents };
            let effective = within(deadline, self.effective_preferences(&tenant, &subject, None, &reader).instrument(tracing::info_span!("recall.preferences"))).await?;
            statements += 1;
            crate::preference::apply_overrides(&mut hits, &effective, req.tags.as_deref(), req.exact.is_some(), &mut overridden);
        }
        if !session_hits.is_empty() {
            // A mixed recall keeps at least half its places for ranked memories.
            session_hits.truncate(if working_only { k } else { (k / 2).max(1) });
            let ids: std::collections::HashSet<Uuid> = session_hits.iter().map(|m| m.id).collect();
            hits.retain(|h| !ids.contains(&h.memory.id));
            let top = hits.first().map(|h| h.score).unwrap_or(0.0);
            let n = session_hits.len();
            let first: Vec<Hit> = session_hits
                .drain(..)
                .enumerate()
                .map(|(i, memory)| Hit {
                    memory,
                    score: top + 1.0 + (n - i) as f32,
                    keyword_rank: None,
                    vector_rank: None,
                    similarity: None,
                    rerank_score: None,
                    exact: false,
                    working: true,
                    embedding: None,
                    features: None,
                })
                .collect();
            hits.splice(0..0, first);
        }
        // What the recall itself leaves out, for the explanation: near-duplicates, then below
        // k, then over the budget.
        let mut cut: Vec<ExcludedRecord> = vec![];
        if rank.dedup {
            let ids: std::collections::HashSet<Uuid> = hits.iter().map(|h| h.memory.id).collect();
            // A keyed preference is resolved by scope before it is returned (MEM-04); the
            // reserve was not, so it never fills a place with one.
            reserve.retain(|h| !ids.contains(&h.memory.id) && !keyed(h));
            crate::pack::score(&mut reserve, rank, req.as_of.unwrap_or(present), present);
            hits = crate::pack::dedup(hits, reserve, k, rank, &mut cut);
        }
        if hits.len() > k {
            cut.extend(hits.split_off(k).iter().enumerate().map(|(i, h)| ExcludedRecord {
                id: h.memory.id,
                reason: ExclusionReason::Rank,
                detail: format!("rank {} of {} candidates; k = {k}", k + i + 1, candidates),
            }));
        }
        cut.extend(overridden);
        // PERF-06: the token budget is a hard cap on the returned memories and on the block.
        let format = req.render_format.or(req.render.then_some(RenderFormat::Plain));
        let rendered = crate::pack::pack(&mut hits, req.token_budget, format, &subject, &mut cut);
        if policy.policy.recall.audit_reads {
            // Inside the recall's deadline too: an audit that can't be written in time degrades
            // the answer to empty rather than returning unaudited reads late.
            within(
                deadline,
                self.store.audit(
                    req.actor.as_deref().unwrap_or("api"),
                    "memory.recall",
                    &tenant,
                    Some(&subject),
                    None,
                    serde_json::json!({ "returned": hits.iter().map(|h| h.memory.id).collect::<Vec<_>>() }),
                ),
            )
            .await?;
        }
        let rerank_ms = if use_rerank { t_rerank.elapsed().as_secs_f64() * 1000.0 } else { 0.0 };
        let total_ms = start.elapsed().as_secs_f64() * 1000.0;
        let span = tracing::Span::current();
        span.record("memhouse.subject", subject.as_str());
        span.record("memhouse.returned", hits.len());
        span.record("memhouse.record_ids", hits.iter().map(|h| h.memory.id.to_string()).collect::<Vec<_>>().join(",").as_str());
        span.record("db.statements", statements);
        if self.explain_recalls {
            let t_instrument = Instant::now();
            for (stage, ms) in [("embed", embed_ms), ("search", search_ms), ("rerank", rerank_ms), ("total", total_ms)] {
                metrics::observe("memhouse_recall_stage_duration_seconds", &[("stage", stage)], ms / 1000.0);
            }
            metrics::observe("memhouse_recall_statements", &[], statements as f64);
            let record = RecallRecord {
                recall_id,
                at: Utc::now(),
                tenant: tenant.clone(),
                subject: subject.clone(),
                principal: ctx.principal,
                user: ctx.user,
                policy_version: policy.version.clone(),
                authorizer: ctx.authorizer,
                query: req.query.clone(),
                k,
                kinds: req.kinds.clone(),
                tags: req.tags.clone(),
                scope: scope.clone(),
                shared_agents: ctx.shared_agents,
                denied_labels: ctx.denied_labels,
                as_of: req.as_of,
                valid_at: req.as_of.unwrap_or(now_valid),
                mode,
                token_budget: req.token_budget,
                reranked: use_rerank,
                windows: plan.as_ref().map(|p| p.windows.clone()).unwrap_or_default(),
                returned: hits
                    .iter()
                    .enumerate()
                    .map(|(i, h)| ReturnedRecord {
                        id: h.memory.id,
                        rank: i + 1,
                        score: h.score,
                        keyword_rank: h.keyword_rank,
                        vector_rank: h.vector_rank,
                        similarity: h.similarity,
                        rerank_score: h.rerank_score,
                        tokens: approx_tokens(&h.memory.content),
                        features: h.features,
                    })
                    .collect(),
                cut,
                stages: RecallStages { embed_ms, search_ms, rerank_ms, total_ms, statements, probes: n_probes, instrument_ms: 0.0 },
            };
            let mut record = record;
            record.stages.instrument_ms = t_instrument.elapsed().as_secs_f64() * 1000.0;
            self.keep_recent(record.clone());
            // Written off the request path: the explanation is retrievable from memory meanwhile.
            let store = self.store.clone();
            tokio::spawn(async move {
                if let Err(e) = store.recall_put(&record).await {
                    tracing::warn!("recall explanation {} not stored: {e:#}", record.recall_id);
                }
            });
        }
        Ok(RecallResult {
            rendered,
            hits,
            took_ms: start.elapsed().as_secs_f64() * 1000.0,
            embed_ms,
            search_ms,
            rerank_ms,
            candidates,
            reranked: use_rerank,
            recall_id: self.explain_recalls.then_some(recall_id),
            plan,
            degraded: None,
        })
    }

    /// Replace a memory with new content; the old version stays for audit but is no longer recalled.
    pub async fn update(&self, tenant: Option<String>, id: Uuid, content: String, actor: Option<String>) -> anyhow::Result<RememberResult> {
        // The pre-v1 call answered with the stored revision: it waits for the gate.
        self.revise(ReviseRequest { tenant, id, content, actor, wait: true, ..Default::default() }).await
    }

    /// A new version of a memory that supersedes the current one (CORE-04). Fields the request
    /// leaves out are taken from the current version.
    pub async fn revise(&self, req: ReviseRequest) -> anyhow::Result<RememberResult> {
        self.revise_with(req, Entry::Commit).await
    }

    pub(crate) async fn revise_with(&self, req: ReviseRequest, entry: Entry) -> anyhow::Result<RememberResult> {
        let policy = retryable(self.policy_for(&self.tenant(&req.tenant)).await)?;
        let span = Self::write_span("memhouse.revise", &policy, &req.actor, &None);
        retryable(self.traced("revise", span, self.revise_untraced(req, entry, &policy)).await)
    }

    async fn revise_untraced(&self, req: ReviseRequest, entry: Entry, policy: &CompiledPolicy) -> anyhow::Result<RememberResult> {
        let tenant = self.tenant(&req.tenant);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        if let Some(done) = self.replay::<RememberResult>(&tenant, &req.request_key, &req).await? {
            return Ok(done);
        }
        // A version still in the intake queue is settled first, so it is revised as stored.
        self.settle_record(&tenant, req.id).await?;
        let old = self.store.get(&tenant, req.id).await?.ok_or_else(|| error::not_found(format!("memory {} not found", req.id)))?;
        if old.status != MemoryStatus::Committed {
            return Err(error::conflict(format!("memory {} is {}; only the current, committed version can be revised", req.id, old.status.as_str())));
        }
        let (structured, code_refs) = if req.structured.is_some() && req.code_refs.is_some() {
            (req.structured.clone(), req.code_refs.clone().unwrap_or_default())
        } else {
            let (s, c) = self.store.representations(&tenant, req.id).await?;
            (req.structured.clone().or(s), req.code_refs.clone().unwrap_or(c))
        };
        // New content that is itself a structured record replaces the old structured form.
        let structured = if req.structured.is_none() && crate::classify::structured_from_content(&req.content).is_some() { None } else { structured };
        let inherited_metadata = Some(old.metadata.clone()).filter(|m| m.as_object().is_some_and(|o| !o.is_empty()));
        let write = RememberRequest {
            tenant: Some(tenant.clone()),
            subject: Some(old.subject.clone()),
            content: req.content.clone(),
            kind: Some(req.kind.unwrap_or(old.kind)),
            tags: req.tags.clone().unwrap_or(old.tags),
            occurred_at: req.occurred_at,
            valid_to: req.valid_to.or(old.valid_to),
            supersedes: Some(req.id),
            source: req.source.clone(),
            metadata: req.metadata.clone().or(inherited_metadata),
            actor: Some(actor.clone()),
            labels: req.labels.clone().unwrap_or(old.labels),
            scope: Some(req.scope.clone().unwrap_or(old.scope)),
            user: req.user.clone(),
            request_key: req.request_key.clone(),
            // A note that follows its session keeps doing so: its expiry is the session's, set
            // again by the write, not an expiry the revision asked for.
            expires_at: req.expires_at.or(old.expires_at.filter(|_| old.metadata.get("ttl").and_then(|t| t.as_str()) != Some("session"))),
            structured,
            code_refs,
            wait: req.wait,
        };
        let result = self.remember_once(&write, &tenant, &old.subject, &actor, (entry, Op::Revise), policy).await?;
        self.accepted_key(&tenant, &old.subject, "revise", &req.request_key, &req, &result).await;
        Ok(result)
    }

    /// Commit a candidate (GOV-08): by the engine at once, or by a reviewer. A revision whose
    /// predecessor is no longer current is rejected instead, so history never forks.
    pub(crate) async fn admit(&self, tenant: &str, id: Uuid, by: &str) -> anyhow::Result<(MemoryStatus, Option<Uuid>)> {
        self.settle_record(tenant, id).await?;
        let m = self.store.get(tenant, id).await?.ok_or_else(|| error::not_found(format!("memory {id} not found")))?;
        if m.status != MemoryStatus::Candidate {
            return Err(error::conflict(format!("memory {id} is {}; only candidates are admitted", m.status.as_str())));
        }
        if let Some(old) = m.supersedes {
            if !self.store.set_superseded(tenant, old, id).await? {
                self.store.set_status(tenant, id, MemoryStatus::Rejected).await?;
                self.store.audit(by, "memory.reject", tenant, Some(&m.subject), Some(id), serde_json::json!({ "reason": "the version it revises is no longer current" })).await?;
                return Ok((MemoryStatus::Rejected, None));
            }
        }
        self.store.set_status(tenant, id, MemoryStatus::Committed).await?;
        if let Some(s) = &m.scope.session {
            self.working.drop_session(tenant, &m.subject, s);
        }
        self.store.audit(by, "memory.admit", tenant, Some(&m.subject), Some(id), serde_json::json!({ "supersedes": m.supersedes })).await?;
        Ok((MemoryStatus::Committed, m.supersedes))
    }

    /// Refuse a candidate.
    pub(crate) async fn reject(&self, tenant: &str, id: Uuid, by: &str, reason: &str) -> anyhow::Result<MemoryStatus> {
        self.settle_record(tenant, id).await?;
        let m = self.store.get(tenant, id).await?.ok_or_else(|| error::not_found(format!("memory {id} not found")))?;
        if !self.store.set_status(tenant, id, MemoryStatus::Rejected).await? {
            return Err(error::conflict(format!("memory {id} is {}; it can't be rejected", m.status.as_str())));
        }
        self.store.audit(by, "memory.reject", tenant, Some(&m.subject), Some(id), serde_json::json!({ "reason": reason })).await?;
        Ok(MemoryStatus::Rejected)
    }

    /// A record still in the intake queue: run its proposal through the pipeline first, so what
    /// follows (a review, a forget) acts on the stored record.
    pub(crate) async fn settle_record(&self, tenant: &str, id: Uuid) -> anyhow::Result<()> {
        if let Some(m) = self.intake.pending(tenant, id).await? {
            if m.status == MemoryStatus::Candidate {
                let proposal = self.intake.pending_proposal(tenant, id).await?.unwrap_or(id);
                self.settle(tenant, &m.subject, proposal, std::time::Duration::from_millis(self.cfg.intake.wait_timeout_ms)).await?;
            }
        }
        Ok(())
    }

    /// A record by id: stored, or still in the intake queue (then `candidate`, CORE-02).
    pub async fn get_record(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<Memory>> {
        if let Some(m) = self.store.get(tenant, id).await? {
            return Ok(Some(m));
        }
        match self.intake.pending(tenant, id).await? {
            Some(m) => Ok(Some(m)),
            // Its insert may have committed between the two reads.
            None => self.store.get(tenant, id).await,
        }
    }

    pub async fn forget(&self, tenant: Option<String>, id: Uuid, actor: Option<String>) -> anyhow::Result<bool> {
        let t = self.tenant(&tenant);
        let actor = actor.unwrap_or_else(|| "api".into());
        self.settle_record(&t, id).await?;
        let mem = self.get_record(&t, id).await?;
        // Whatever of it is still queued goes first (a proposal that could not be settled, or a
        // poison one whose records could not be stored): only this record leaves the proposal,
        // and it waits for an insert in progress, so the delete below sees what that wrote.
        let queued = self.intake.discard(&t, ForgetScope::Record, &id.to_string()).await? > 0;
        let ok = self.store.delete(&t, id, &actor).await? || queued;
        self.working.drop_record(id);
        if ok {
            self.store.audit(&actor, "memory.delete", &t, mem.as_ref().map(|m| m.subject.as_str()), Some(id), serde_json::json!({ "queued": queued })).await?;
        }
        Ok(ok)
    }

    /// `forget` by record, subject, user, agent, source or the whole tenant (CORE-05), with one
    /// audit event for the call.
    pub async fn forget_by(&self, req: ForgetRequest) -> anyhow::Result<ForgetResult> {
        let policy = self.policy_for(&self.tenant(&req.tenant)).await?;
        let span = Self::write_span("memhouse.forget", &policy, &req.actor, &req.subject);
        self.traced("forget", span, self.forget_untraced(req)).await
    }

    async fn forget_untraced(&self, req: ForgetRequest) -> anyhow::Result<ForgetResult> {
        let tenant = self.tenant(&req.tenant);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        let mut named: Vec<(ForgetScope, String)> = vec![];
        if let Some(id) = req.id {
            named.push((ForgetScope::Record, id.to_string()));
        }
        for (scope, v) in [(ForgetScope::Subject, &req.subject), (ForgetScope::User, &req.user), (ForgetScope::Agent, &req.agent), (ForgetScope::Source, &req.source)] {
            if let Some(v) = v {
                if v.trim().is_empty() {
                    return Err(error::invalid(format!("{} is empty", scope.as_str())));
                }
                named.push((scope, v.clone()));
            }
        }
        if req.all {
            named.push((ForgetScope::Tenant, tenant.clone()));
        }
        let [(scope, value)] = named.as_slice() else {
            return Err(error::invalid("forget needs exactly one of id, subject, user, agent, source or all"));
        };
        let (scope, value) = (*scope, value.clone());
        if scope == ForgetScope::Tenant && req.confirm.as_deref() != Some(tenant.as_str()) {
            return Err(error::invalid(format!("forgetting the whole tenant needs confirm set to the tenant's name ('{tenant}')")));
        }
        if let Some(done) = self.replay::<ForgetResult>(&tenant, &req.request_key, &req).await? {
            return Ok(done);
        }
        // The idempotency key is kept with the subject it is about, so erasing it removes the key.
        let mut key_subject = match scope {
            ForgetScope::Subject => value.clone(),
            _ => String::new(),
        };
        let deleted = match scope {
            ForgetScope::Record => {
                let id = req.id.expect("named");
                let mem = self.get_record(&tenant, id).await?.ok_or_else(|| error::not_found(format!("memory {id} not found")))?;
                key_subject = mem.subject;
                if !req.dry_run && !self.forget(Some(tenant.clone()), id, Some(actor.clone())).await? {
                    return Err(error::not_found(format!("memory {id} not found")));
                }
                1
            }
            _ if req.dry_run => self.store.forget_count(&tenant, scope, &value).await?,
            ForgetScope::Subject => self.forget_subject(Some(tenant.clone()), &value, Some(actor.clone())).await?,
            ForgetScope::Tenant => {
                let n = self.store.delete_tenant(&tenant, &actor).await?;
                self.working.clear();
                self.grants.clear();
                self.store.audit(&actor, "tenant.erase", &tenant, None, None, serde_json::json!({ "records": n })).await?;
                n
            }
            ForgetScope::User | ForgetScope::Agent | ForgetScope::Source => {
                // Queued writes that match go first, so none lands after the erasure.
                let queued = self.intake.discard(&tenant, scope, &value).await?;
                if queued > 0 {
                    self.store.audit(&actor, "intake.discard", &tenant, None, None, serde_json::json!({ "by": scope.as_str(), "value": value, "proposals": queued })).await?;
                }
                let before = self.store.forget_count(&tenant, scope, &value).await?;
                // Each record goes with its full cascade (derived facts, cached vectors, jobs,
                // ledger row). Facts derived from a match may match too and are then gone already.
                for _ in 0..=before / 500 + 10 {
                    let ids = self.store.forget_matches(&tenant, scope, &value, 500).await?;
                    if ids.is_empty() {
                        break;
                    }
                    for id in ids {
                        self.store.delete(&tenant, id, &actor).await?;
                    }
                }
                self.working.clear();
                if scope == ForgetScope::User {
                    // Explanations hold the user's queries.
                    self.store.recalls_delete(&tenant, Some(&value), None).await?;
                }
                let left = self.store.forget_count(&tenant, scope, &value).await?;
                anyhow::ensure!(left == 0, "forget by {}: {left} records still match", scope.as_str());
                self.store.audit(&actor, "memory.forget", &tenant, None, None, serde_json::json!({ "by": scope.as_str(), "value": value, "records": before })).await?;
                before
            }
        };
        let result = ForgetResult { scope, value, deleted, dry_run: req.dry_run };
        let span = tracing::Span::current();
        if scope == ForgetScope::Record {
            span.record("memhouse.record_ids", result.value.as_str());
        }
        span.record("memhouse.status", format!("{} {}: {} deleted", scope.as_str(), if req.dry_run { "dry run" } else { "forgotten" }, deleted).as_str());
        if !req.dry_run {
            self.remember_key(&tenant, &key_subject, "forget", &req.request_key, &req, &result).await?;
        }
        Ok(result)
    }

    pub async fn forget_subject(&self, tenant: Option<String>, subject: &str, actor: Option<String>) -> anyhow::Result<u64> {
        let t = self.tenant(&tenant);
        let actor = actor.unwrap_or_else(|| "api".into());
        let n = self.store.delete_subject(&t, subject, &actor, true).await?;
        self.working.drop_subject(&t, subject);
        self.store.audit(&actor, "subject.erase", &t, Some(subject), None, serde_json::json!({ "records": n })).await?;
        Ok(n)
    }

    /// Drop a subject's records but keep the content-addressed embedding cache. For benchmarks and
    /// tests over public data that re-ingest the same text; not an erasure (use `forget_subject`).
    pub async fn reset_subject(&self, tenant: Option<String>, subject: &str, actor: Option<String>) -> anyhow::Result<u64> {
        let t = self.tenant(&tenant);
        let actor = actor.unwrap_or_else(|| "api".into());
        let n = self.store.delete_subject(&t, subject, &actor, false).await?;
        self.working.drop_subject(&t, subject);
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
        let tenant = self.tenant(&tenant);
        let policy = self.policy_for(&tenant).await?;
        self.store
            .list(&ListQuery {
                tenant,
                subject,
                kinds,
                include_inactive,
                limit: limit.clamp(1, 1000),
                offset,
                before: None,
                denied_labels: with_policy_labels(&self.cfg.governance.denied_labels, &policy),
                scope: Scope::default(),
                shared_agents: vec![],
                session: None,
                tags: None,
                live_at: None,
            })
            .await
    }

    /// One page of a subject's memories, newest first, with keyset paging.
    pub async fn list_page(
        &self,
        tenant: Option<String>,
        subject: String,
        kinds: Option<Vec<MemoryKind>>,
        include_inactive: bool,
        limit: usize,
        cursor: Option<&str>,
    ) -> anyhow::Result<MemoryPage> {
        let page = Page { kinds, include_inactive, limit, denied_labels: self.cfg.governance.denied_labels.clone(), scope: Scope::default(), shared_agents: vec![] };
        self.list_page_with(tenant, subject, page, cursor).await
    }

    pub(crate) async fn list_page_with(&self, tenant: Option<String>, subject: String, page: Page, cursor: Option<&str>) -> anyhow::Result<MemoryPage> {
        let limit = page.limit.clamp(1, 1000);
        let before = cursor.map(decode_cursor).transpose()?;
        let tenant = self.tenant(&tenant);
        let policy = self.policy_for(&tenant).await?;
        let q = ListQuery {
            tenant,
            subject: Some(subject),
            kinds: page.kinds,
            include_inactive: page.include_inactive,
            limit: limit + 1,
            offset: 0,
            before,
            denied_labels: with_policy_labels(&page.denied_labels, &policy),
            scope: page.scope,
            shared_agents: page.shared_agents,
            session: None,
            tags: None,
            live_at: None,
        };
        let mut items = self.store.list(&q).await?;
        let next_cursor = if items.len() > limit {
            items.truncate(limit);
            items.last().map(|m| encode_cursor(m.created_at, m.id))
        } else {
            None
        };
        Ok(MemoryPage { items, next_cursor })
    }

    /// The committed working memory of a session, newest first, and whether it was read from the
    /// store (a cache miss: one statement) rather than the session cache.
    /// `more`: the caller wants up to this many, more than the cache keeps per session; they are
    /// read from the store and not cached.
    /// The third value says whether the read was cut at its limit, counted before expired notes
    /// are left out: the session may then have older notes that were not read.
    pub(crate) async fn session_working(&self, tenant: &str, subject: &str, session: &str, more: Option<usize>) -> anyhow::Result<(Vec<Memory>, bool, bool)> {
        let now = Utc::now();
        let generation = self.working.generation();
        if more.is_none() {
            if let Some((items, full)) = self.working.get(tenant, subject, session, now) {
                metrics::inc("memhouse_working_cache_total", &[("outcome", "hit")], 1.0);
                return Ok((items, false, full));
            }
            metrics::inc("memhouse_working_cache_total", &[("outcome", "miss")], 1.0);
        }
        let q = ListQuery {
            tenant: tenant.to_string(),
            subject: Some(subject.to_string()),
            kinds: Some(vec![MemoryKind::Working]),
            limit: more.unwrap_or(self.working.max_items()),
            session: Some(session.to_string()),
            ..Default::default()
        };
        let mut items = self.store.list(&q).await?;
        let full = items.len() >= q.limit;
        if more.is_none() {
            self.working.put(generation, tenant, subject, session, items.clone());
        }
        items.retain(|m| m.expires_at.is_none_or(|t| t > now));
        Ok((items, true, full))
    }

    /// After a session's working-memory write committed: the session's other working records
    /// take the new expiry (MEM-01: end of session plus the TTL), and the session cache shows the
    /// write at once. Failures here leave the write as it is and the cache to its next refresh.
    async fn session_wrote(&self, tenant: &str, subject: &str, session: &str, result: &RememberResult, extend_to: Option<chrono::DateTime<Utc>>, revision: bool) {
        if result.status != MemoryStatus::Committed || result.deduplicated {
            self.working.drop_session(tenant, subject, session);
            return;
        }
        if let Some(until) = extend_to {
            if let Err(e) = self.store.session_extend(tenant, subject, session, until).await {
                // The cache must not show an expiry the store doesn't have: read it again.
                tracing::warn!("working memory of session {session} was not extended: {e:#}");
                self.working.drop_session(tenant, subject, session);
                return;
            }
        }
        // A revision replaced a note the cache may hold: the session reads the store again.
        if revision {
            self.working.drop_session(tenant, subject, session);
            return;
        }
        let generation = self.working.generation();
        match self.store.get(tenant, result.id).await {
            Ok(Some(m)) => self.working.wrote(generation, &m, session, extend_to),
            _ => self.working.drop_session(tenant, subject, session),
        }
    }

    /// Apply each type's retention (MEM-01): expire what is past its `expires_at` (working
    /// memory, held candidates), then purge the types that have `retention_days`. Returns
    /// records purged, or expired when nothing was purged.
    pub async fn apply_retention(&self) -> anyhow::Result<u64> {
        let days = self.cfg.telemetry.explanation_retention_days;
        if days > 0 {
            self.store.recalls_delete(&self.cfg.memory.tenant, None, Some(days)).await?;
        }
        let expired = self.store.expire_due(&self.cfg.memory.tenant).await?;
        if expired > 0 {
            self.store.audit("system", "retention.expire", &self.cfg.memory.tenant, None, None, serde_json::json!({ "records": expired })).await?;
        }
        let policy = self.policy_for(&self.cfg.memory.tenant).await?;
        let mut purged = 0;
        for kind in MemoryKind::ALL {
            let days = policy.of(kind).retention_days;
            if days == 0 {
                continue;
            }
            let n = self.store.purge_older_than(&self.cfg.memory.tenant, kind, days).await?;
            if n > 0 {
                self.store
                    .audit("system", "retention.purge", &self.cfg.memory.tenant, None, None, serde_json::json!({ "records": n, "days": days, "kind": kind.as_str() }))
                    .await?;
            }
            purged += n;
        }
        if expired + purged > 0 {
            self.working.clear();
        }
        Ok(if purged > 0 { purged } else { expired })
    }
}

/// A write that failed inside MemHouse or the database before it was queued stored nothing:
/// the caller may retry it (PERF-07).
pub(crate) fn retryable<T>(r: anyhow::Result<T>) -> anyhow::Result<T> {
    r.map_err(|e| if error::code_of(&e) == error::ErrorCode::Internal { error::unavailable(format!("the write was not accepted, so nothing was stored; retry: {e:#}")) } else { e })
}

/// Await `fut` until `deadline` (if any); running out of time is a retryable failure.
async fn within<T>(deadline: Option<tokio::time::Instant>, fut: impl std::future::Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
    match deadline {
        None => fut.await,
        Some(d) => match tokio::time::timeout_at(d, fut).await {
            Ok(r) => r,
            Err(_) => Err(error::unavailable("retrieval took longer than memory.recall_timeout_ms")),
        },
    }
}

/// A failure recall answers with an empty, flagged result (PERF-07): one inside MemHouse or a
/// dependency. A refused or invalid request stays an error, so no data leaks either way.
fn degradable(e: &anyhow::Error) -> bool {
    matches!(error::code_of(e), error::ErrorCode::Internal | error::ErrorCode::Unavailable)
}

fn degraded(e: anyhow::Error, start: Instant, op: &str) -> anyhow::Result<RecallResult> {
    if !degradable(&e) {
        return Err(e);
    }
    let reason = format!("{e:#}");
    tracing::warn!("{op} degraded to an empty result: {reason}");
    metrics::inc("memhouse_recall_degraded_total", &[], 1.0);
    Ok(RecallResult {
        hits: vec![],
        took_ms: start.elapsed().as_secs_f64() * 1000.0,
        embed_ms: 0.0,
        search_ms: 0.0,
        rerank_ms: 0.0,
        candidates: 0,
        reranked: false,
        plan: None,
        rendered: None,
        recall_id: None,
        degraded: Some(reason),
    })
}

/// Labels a read may not return: the caller's, and those the tenant's policy denies.
pub(crate) fn with_policy_labels(denied: &[String], policy: &CompiledPolicy) -> Vec<String> {
    let mut all: Vec<String> = denied.iter().chain(&policy.policy.recall.denied_labels).cloned().collect();
    all.sort();
    all.dedup();
    all
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
