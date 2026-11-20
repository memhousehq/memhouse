// SPDX-License-Identifier: Apache-2.0
//! Asynchronous enrichment: a small LLM reads each stored session and writes back short,
//! dated, self-contained facts (events, preferences, plans, changes). Ingest only queues a
//! job, so writes stay fast and recall keeps working on the raw rounds while jobs run; facts
//! become searchable as each job lands.
//!
//! Facts are ordinary memories: they pass the write gate (redaction, injection quarantine),
//! carry the session and message refs of the rounds they came from, and are deleted with
//! those rounds. Extraction answers are cached by content, so a repeated session costs nothing.

use crate::engine::{content_hash, Engine};
use crate::types::*;
use chrono::{DateTime, NaiveDate, Utc};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tracing::Instrument;
use uuid::Uuid;

/// Bump when the prompt or output format changes: it is part of the cache key.
pub const PROMPT_VERSION: &str = "facts-v1";

const SYSTEM: &str = "You extract long-term memories from a conversation so an assistant can answer questions about it months later. Output JSON only.";

const INSTRUCTIONS: &str = r#"Extract every durable piece of information about the user (or, in a group chat, about each named person): facts about their life, events they took part in, things they bought, did, planned, owned, liked or disliked, people they mentioned, numbers, names, places, and anything they changed or updated.

Rules:
- One fact per item, self-contained and specific: keep names, titles, brands, amounts and counts. Write "the user" for the user, real names for named people.
- Resolve relative time ("yesterday", "last week", "two months ago") to an absolute date using the session date, and put that date in "date" (YYYY-MM-DD, or YYYY-MM if only the month is known). Use the session date for things that happened at the time of the conversation.
- Include preferences and opinions as facts ("the user prefers ..."), and plans with their target dates.
- Include what the assistant recommended or provided only when the user asked for something specific about themselves.
- Skip generic knowledge, small talk and assistant boilerplate. If nothing is worth remembering, return {"facts": []}.
- "rounds" lists the round numbers the fact comes from.

Output format:
{"facts": [{"text": "...", "kind": "event|fact|preference|plan", "date": "YYYY-MM-DD or null", "rounds": [1]}]}"#;

/// Added for a server with more than one language (G36): facts stay in the language they were
/// stated in, so the statement gate and the keyword search read them with the right pack.
const ANY_LANGUAGE: &str = "\n\nThe conversation may be in any language. Write each fact's \"text\" in the language it was stated in (in that language, write the equivalent of \"the user\"); keep the JSON keys and the \"kind\" values in English.";

#[derive(Debug, serde::Deserialize)]
struct Extracted {
    #[serde(default)]
    facts: Vec<ExtractedFact>,
}

#[derive(Debug, serde::Deserialize)]
struct ExtractedFact {
    text: String,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    date: Option<String>,
    #[serde(default)]
    rounds: Vec<serde_json::Value>,
}

/// Process-wide enrichment spend, so `max_cost_usd` holds across workers.
#[derive(Default)]
pub struct Spend {
    micro_usd: AtomicU64,
    /// Per tenant: the jobs extracted, and those the large model read (ECON-04's cap).
    tiers: std::sync::Mutex<std::collections::HashMap<String, TenantTiers>>,
    unpriced: AtomicBool,
}

#[derive(Default)]
struct TenantTiers {
    sessions: std::collections::HashSet<String>,
    large: std::collections::HashSet<String>,
}

impl Spend {
    /// Count one extracted session of `tenant`: once per session (its subject and session
    /// id), however many jobs the session has and however often one is retried.
    fn session(&self, tenant: &str, session: &str) {
        let mut t = self.tiers.lock().expect("tiers");
        t.entry(tenant.to_string()).or_default().sessions.insert(session.to_string());
    }

    /// Take one large-model extraction from the tenant's share (`large_max_share` of its
    /// extracted sessions in this process), if it has one left. A session that already holds
    /// one keeps it on a retry.
    fn take_large(&self, tenant: &str, session: &str, max_share: f32) -> bool {
        let mut t = self.tiers.lock().expect("tiers");
        let e = t.entry(tenant.to_string()).or_default();
        if e.large.contains(session) {
            return true;
        }
        let ok = (e.large.len() + 1) as f64 <= max_share.clamp(0.0, 1.0) as f64 * e.sessions.len() as f64;
        if ok {
            e.large.insert(session.to_string());
        }
        ok
    }

    /// Sessions extracted for `tenant` in this process, and those of them the large model read.
    pub fn tiers(&self, tenant: &str) -> (u64, u64) {
        self.tiers.lock().expect("tiers").get(tenant).map(|e| (e.sessions.len() as u64, e.large.len() as u64)).unwrap_or_default()
    }

    /// A model call came back with tokens and no cost: the spend is no longer known. True the
    /// first time.
    fn mark_unpriced(&self) -> bool {
        !self.unpriced.swap(true, Ordering::Relaxed)
    }

    /// Whether some call's cost is unknown, so `max_cost_usd` cannot be enforced exactly.
    pub fn unpriced(&self) -> bool {
        self.unpriced.load(Ordering::Relaxed)
    }

    pub fn add(&self, usd: f64) -> f64 {
        let add = (usd * 1e6).round() as u64;
        (self.micro_usd.fetch_add(add, Ordering::Relaxed) + add) as f64 / 1e6
    }
    pub fn usd(&self) -> f64 {
        self.micro_usd.load(Ordering::Relaxed) as f64 / 1e6
    }
}

/// Render a session for the extractor: rounds numbered from 1, user text in full, assistant
/// replies cut to `assistant_chars`. Returns the text and the total user characters.
fn render(rounds: &[Memory], assistant_chars: usize) -> (String, usize) {
    let mut out = String::new();
    let mut user_chars = 0;
    for (i, r) in rounds.iter().enumerate() {
        out.push_str(&format!("[round {}]\n", i + 1));
        let (user, assistant) = match r.content.find("\nassistant:") {
            Some(p) => (&r.content[..p], Some(&r.content[p + 1..])),
            None => (r.content.as_str(), None),
        };
        user_chars += user.chars().count();
        out.push_str(user.trim());
        out.push('\n');
        if let Some(a) = assistant {
            let cut: String = a.chars().take(assistant_chars).collect();
            out.push_str(cut.trim());
            if a.chars().count() > assistant_chars {
                out.push_str(" …");
            }
            out.push('\n');
        }
    }
    (out, user_chars)
}

/// Parse the model's answer: the JSON object in the text. A truncated answer (the model hit its
/// token limit) still yields every complete fact object before the cut.
fn parse(text: &str) -> anyhow::Result<Vec<ExtractedFact>> {
    parse_answer(text).map(|(f, _)| f)
}

/// The facts of an answer, and whether the answer was complete (false: cut at the token limit,
/// only the facts before the cut were recovered).
fn parse_answer(text: &str) -> anyhow::Result<(Vec<ExtractedFact>, bool)> {
    let keep = |v: Vec<ExtractedFact>| v.into_iter().filter(|f| f.text.trim().chars().count() >= 8).collect::<Vec<_>>();
    let start = text.find('{').ok_or_else(|| anyhow::anyhow!("no JSON object in extractor output"))?;
    if let Some(end) = text.rfind('}') {
        if let Ok(e) = serde_json::from_str::<Extracted>(&text[start..=end]) {
            return Ok((keep(e.facts), true));
        }
    }
    let list = text[start..].find('[').map(|i| start + i + 1).ok_or_else(|| anyhow::anyhow!("no fact list in extractor output"))?;
    let mut facts = vec![];
    let (mut depth, mut in_str, mut esc, mut obj_start) = (0usize, false, false, None);
    for (i, c) in text[list..].char_indices() {
        if in_str {
            match (esc, c) {
                (true, _) => esc = false,
                (false, '\\') => esc = true,
                (false, '"') => in_str = false,
                _ => {}
            }
            continue;
        }
        match c {
            '"' => in_str = true,
            '{' => {
                if depth == 0 {
                    obj_start = Some(list + i);
                }
                depth += 1;
            }
            '}' if depth > 0 => {
                depth -= 1;
                if let (0, Some(s0)) = (depth, obj_start.take()) {
                    if let Ok(f) = serde_json::from_str::<ExtractedFact>(&text[s0..=list + i]) {
                        facts.push(f);
                    }
                }
            }
            ']' if depth == 0 => break,
            _ => {}
        }
    }
    if facts.is_empty() {
        anyhow::bail!("could not parse extractor output");
    }
    Ok((keep(facts), false))
}

/// The rounds a fact cites (1-based), as indexes into the session; empty when it cites none or
/// only rounds that do not exist.
fn cited(f: &ExtractedFact, n: usize) -> Vec<usize> {
    f.rounds.iter().filter_map(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))).filter_map(|i| (i as usize).checked_sub(1)).filter(|i| *i < n).collect()
}

fn content_words(s: &str) -> std::collections::HashSet<String> {
    // Five letters stand for the word, so "moving" in the fact meets "moved" in the round.
    s.split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.chars().count() >= 4 && !w.chars().any(|c| c.is_ascii_digit()))
        .map(|w| w.to_lowercase().chars().take(5).collect::<String>())
        .filter(|w| w != "user" && w != "users")
        .collect()
}

/// Confidence of one extracted fact, 0.3 to 0.95 (the "confidence score on extracted facts" of
/// ECON-04): the part of its content words found in the rounds it cites. A fact that cites no
/// round is compared with the whole session and loses a tenth. Deterministic and free: it says
/// how well the fact is grounded in what was said, not whether the model felt sure. Numbers
/// and dates are left out, since the extractor rewrites them ("last week" becomes a date).
pub fn fact_confidence(fact: &str, cited_rounds: &str, cites: bool) -> f32 {
    let words = content_words(fact);
    if words.is_empty() {
        return 0.3;
    }
    let source = content_words(cited_rounds);
    let found = words.iter().filter(|w| source.contains(*w)).count() as f32 / words.len() as f32;
    let c = 0.3 + 0.65 * found;
    if cites {
        c
    } else {
        (c - 0.1).max(0.3)
    }
}

/// Confidence of a session's extraction: the mean of its facts'. An answer cut at the token
/// limit is capped at 0.5 (facts are missing), and an answer with no facts for a session with
/// plenty of user text scores 0.4 (the model may have given up).
fn session_confidence(facts: &[f32], complete: bool, user_chars: usize) -> f32 {
    if facts.is_empty() {
        return if user_chars >= 400 { 0.4 } else { 0.9 };
    }
    let mean = facts.iter().sum::<f32>() / facts.len() as f32;
    if complete {
        mean
    } else {
        mean.min(0.5)
    }
}

/// Each fact with its confidence against the rounds it cites.
fn with_confidence(facts: Vec<ExtractedFact>, rounds: &[Memory]) -> Vec<(ExtractedFact, f32)> {
    facts
        .into_iter()
        .map(|f| {
            let idx = cited(&f, rounds.len());
            let source: String = if idx.is_empty() {
                rounds.iter().map(|r| r.content.as_str()).collect::<Vec<_>>().join("\n")
            } else {
                idx.iter().map(|i| rounds[*i].content.as_str()).collect::<Vec<_>>().join("\n")
            };
            let c = fact_confidence(&f.text, &source, !idx.is_empty());
            (f, c)
        })
        .collect()
}

/// Extraction-cache key: model, prompt version and the full prompt (so the same session,
/// shown the same way, is never paid for twice).
pub fn cache_key(model: &str, prompt: &str) -> String {
    content_hash(&format!("{PROMPT_VERSION}\u{1f}{model}\u{1f}{prompt}"))
}

fn parse_date(d: &str) -> Option<DateTime<Utc>> {
    let d = d.trim();
    let day = NaiveDate::parse_from_str(d, "%Y-%m-%d").ok().or_else(|| NaiveDate::parse_from_str(&format!("{d}-01"), "%Y-%m-%d").ok())?;
    Some(day.and_hms_opt(12, 0, 0)?.and_utc())
}

fn kind_of(k: Option<&str>) -> MemoryKind {
    match k.unwrap_or("fact") {
        "preference" => MemoryKind::Preference,
        "plan" => MemoryKind::Commitment,
        _ => MemoryKind::Semantic,
    }
}

/// Enrichment as a job of the [`crate::intake::JobRunner`]: one session per run.
pub struct EnrichWorker {
    pub engine: Engine,
    pub spend: Arc<Spend>,
}

#[async_trait::async_trait]
impl crate::intake::Job for EnrichWorker {
    fn name(&self) -> &'static str {
        "enrichment"
    }
    async fn run_once(&self) -> anyhow::Result<bool> {
        self.engine.enrich_once(&self.spend).await
    }
}

impl Engine {
    /// Start `n` enrichment workers on this runtime. They poll the queue until `stop` is set.
    pub fn spawn_enrichment(&self, n: usize, stop: Arc<AtomicBool>, spend: Arc<Spend>) -> Vec<tokio::task::JoinHandle<()>> {
        use crate::intake::JobRunner;
        crate::intake::LocalRunner::new(stop).spawn(Arc::new(EnrichWorker { engine: self.clone(), spend }), n)
    }

    /// Claim and process one job. Returns false when the queue is empty.
    pub async fn enrich_once(&self, spend: &Spend) -> anyhow::Result<bool> {
        let Some(job) = self.store.enrich_claim(1, 300).await?.pop() else { return Ok(false) };
        self.enrich_claimed(job, spend).await
    }

    /// Claim and process one job of this subject only (a replay, a test: nothing of another
    /// subject or tenant is touched). Returns false when the subject has none to claim.
    pub async fn enrich_once_for(&self, tenant: &str, subject: &str, spend: &Spend) -> anyhow::Result<bool> {
        let Some(job) = self.store.enrich_claim_for(tenant, subject, 1, 300).await?.pop() else { return Ok(false) };
        self.enrich_claimed(job, spend).await
    }

    async fn enrich_claimed(&self, job: EnrichJob, spend: &Spend) -> anyhow::Result<bool> {
        let span = tracing::info_span!("memhouse.enrich", memhouse.enrich_job = job.id, memhouse.subject = %job.subject, memhouse.facts = tracing::field::Empty, otel.status_code = tracing::field::Empty);
        match self.enrich_job(&job, spend).instrument(span.clone()).await {
            Ok((key, outcome)) => {
                span.record("memhouse.facts", outcome.facts);
                crate::metrics::inc("memhouse_operations_total", &[("op", "enrich"), ("outcome", "ok")], 1.0);
                self.store.enrich_finish(job.id, key.as_deref(), &outcome).await?
            }
            Err(e) => {
                span.record("otel.status_code", "ERROR");
                crate::metrics::inc("memhouse_operations_total", &[("op", "enrich"), ("outcome", "error")], 1.0);
                tracing::warn!("enrichment job {} failed (attempt {}): {e:#}", job.id, job.attempts);
                self.store.enrich_fail(job.id, &format!("{e:#}"), self.cfg.enrich.max_attempts).await?;
            }
        }
        Ok(true)
    }

    async fn enrich_job(&self, job: &EnrichJob, spend: &Spend) -> anyhow::Result<(Option<String>, EnrichOutcome)> {
        let chat = self.chat.as_ref().ok_or_else(|| anyhow::anyhow!("enrichment is enabled but no LLM is configured"))?;
        let cfg = &self.cfg.enrich;
        let model = chat.id();
        let mut rounds = self.store.get_many(&job.tenant, &job.round_ids).await?;
        rounds.retain(|m| m.status == MemoryStatus::Committed);
        rounds.sort_by_key(|m| (m.occurred_at, m.metadata["round"].as_i64(), m.id));
        let mut outcome = EnrichOutcome { model: model.clone(), ..Default::default() };
        if rounds.is_empty() {
            outcome.skipped = true;
            outcome.tier = "rules".into();
            return Ok((None, outcome));
        }
        let (text, user_chars) = render(&rounds, cfg.assistant_chars);
        if user_chars < cfg.min_user_chars {
            // The rules tier: nothing in the session is worth a model call.
            outcome.skipped = true;
            outcome.tier = "rules".into();
            outcome.rounds = rounds.len();
            crate::metrics::inc("memhouse_enrich_tier_total", &[("tier", "rules")], 1.0);
            return Ok((None, outcome));
        }
        let session_time = rounds.iter().find_map(|r| r.occurred_at);
        let date_line = session_time.map(|t| t.format("%Y-%m-%d (%A)").to_string()).unwrap_or_else(|| "unknown".into());
        // With one language the prompt is unchanged, so what was extracted before stays cached.
        let any_language = if self.languages.packs().len() > 1 { ANY_LANGUAGE } else { "" };
        let prompt = format!("{INSTRUCTIONS}{any_language}\n\nSession date: {date_line}\n\nConversation:\n{text}");
        outcome.rounds = rounds.len();
        outcome.tier = "small".into();
        let (key, answer) = self.extract(chat, &prompt, job, spend, &mut outcome, false).await?;
        let (facts, complete) = parse_answer(&answer)?;
        let mut facts = with_confidence(facts, &rounds);
        let confidence = session_confidence(&facts.iter().map(|(_, c)| *c).collect::<Vec<_>>(), complete, user_chars);
        outcome.confidence = Some(confidence);
        let session = format!("{}\u{1f}{}", job.subject, job.session_id);
        spend.session(&job.tenant, &session);
        let mut extractor = model.clone();
        // The last tier (ECON-04, TR-MS-05): an unsure extraction is done again by the large
        // model, while the tenant is within its share. If that fails, the small model's facts
        // stand: escalation never loses a session.
        if let Some(large) = self.chat_large.as_ref().filter(|_| cfg.escalate && confidence < cfg.escalate_below) {
            if spend.take_large(&job.tenant, &session, cfg.large_max_share) {
                let mut again = EnrichOutcome { model: large.id(), ..Default::default() };
                match self.extract(large, &prompt, job, spend, &mut again, true).await.and_then(|(_, a)| parse_answer(&a)) {
                    Ok((better, _)) => {
                        facts = with_confidence(better, &rounds);
                        extractor = large.id();
                        outcome.tier = "large".into();
                        outcome.model = large.id();
                    }
                    Err(e) => tracing::warn!("enrichment job {}: the large model failed ({e:#}); keeping the small model's facts", job.id),
                }
                outcome.cached &= again.cached;
                outcome.calls += again.calls;
                outcome.usage.prompt_tokens += again.usage.prompt_tokens;
                outcome.usage.completion_tokens += again.usage.completion_tokens;
                outcome.usage.cost_usd = match (outcome.usage.cost_usd, again.usage.cost_usd) {
                    (None, None) => None,
                    (a, b) => Some(a.unwrap_or(0.0) + b.unwrap_or(0.0)),
                };
            } else {
                outcome.capped = true;
                crate::metrics::inc("memhouse_enrich_tier_capped_total", &[], 1.0);
            }
        }
        crate::metrics::inc("memhouse_enrich_tier_total", &[("tier", &outcome.tier)], 1.0);
        outcome.facts = self.store_facts(job, &rounds, session_time, facts, &extractor).await?;
        Ok((Some(key), outcome))
    }

    /// One extraction by `chat`: from the cache when this prompt was answered before, else a
    /// model call within `max_cost_usd`. Returns the cache key and the answer; tokens, cost and
    /// the call are added to `outcome`.
    async fn extract(
        &self,
        chat: &Arc<dyn crate::traits::ChatModel>,
        prompt: &str,
        job: &EnrichJob,
        spend: &Spend,
        outcome: &mut EnrichOutcome,
        large: bool,
    ) -> anyhow::Result<(String, String)> {
        let cfg = &self.cfg.enrich;
        let model = chat.id();
        let key = cache_key(&model, prompt);
        if let Some(a) = self.store.llm_cache_get(&key).await? {
            outcome.cached = true;
            return Ok((key, a));
        }
        outcome.cached = false;
        if cfg.max_cost_usd > 0.0 && spend.usd() >= cfg.max_cost_usd {
            anyhow::bail!("enrichment spend ${:.4} reached max_cost_usd {}", spend.usd(), cfg.max_cost_usd);
        }
        // A cap that cannot be checked is not a cap: once a call has come back without a cost,
        // the optional tier stops (the small model's facts stand), and the operator is told.
        if large && cfg.max_cost_usd > 0.0 && spend.unpriced() {
            anyhow::bail!("max_cost_usd is set but a model call reported no cost: the large model is not called until the provider reports costs or a price is configured");
        }
        // An LLM call in the GenAI conventions, so LLM-observability tools show it (TR-OPS-06).
        let span = tracing::info_span!(
            "gen_ai.chat",
            gen_ai.operation.name = "chat",
            gen_ai.system = "openai",
            gen_ai.request.model = %model,
            gen_ai.usage.input_tokens = tracing::field::Empty,
            gen_ai.usage.output_tokens = tracing::field::Empty,
            memhouse.cost_usd = tracing::field::Empty,
            memhouse.enrich_job = job.id,
        );
        let (a, usage) = chat.chat(SYSTEM, prompt).instrument(span.clone()).await?;
        span.record("gen_ai.usage.input_tokens", usage.prompt_tokens);
        span.record("gen_ai.usage.output_tokens", usage.completion_tokens);
        span.record("memhouse.cost_usd", usage.cost_usd.unwrap_or(0.0));
        crate::metrics::inc("memhouse_enrich_cost_usd_total", &[], usage.cost_usd.unwrap_or(0.0));
        crate::metrics::inc("memhouse_enrich_tokens_total", &[("type", "prompt")], usage.prompt_tokens as f64);
        crate::metrics::inc("memhouse_enrich_tokens_total", &[("type", "completion")], usage.completion_tokens as f64);
        spend.add(usage.cost_usd.unwrap_or(0.0));
        if usage.cost_usd.is_none() && usage.prompt_tokens + usage.completion_tokens > 0 && cfg.max_cost_usd > 0.0 && spend.mark_unpriced() {
            tracing::warn!("enrichment: {model} reported tokens but no cost, so max_cost_usd cannot count its calls; the large model will not be called");
        }
        outcome.usage = usage;
        outcome.calls += 1;
        // Cache only answers that parse, so a malformed one is retried next time.
        parse(&a)?;
        self.store.llm_cache_put(&key, &model, &a).await?;
        Ok((key, a))
    }

    /// The extracted facts through stages 4 to 7 of the write pipeline: the gate (injection
    /// check, statement classifier: plans held, corrections superseding the facts they correct),
    /// routing, embedding, and one insert with their audit events.
    async fn store_facts(&self, job: &EnrichJob, rounds: &[Memory], session_time: Option<DateTime<Utc>>, facts: Vec<(ExtractedFact, f32)>, model: &str) -> anyhow::Result<usize> {
        use crate::intake::{Entry, IntakeWrite, Item};
        let now = Utc::now();
        let policy = self.policy_for(&job.tenant).await?;
        let mut items: Vec<Item> = vec![];
        let mut seen = std::collections::HashSet::new();
        for (f, confidence) in facts {
            // Facts go through the same stages as any write, under the tenant's policy now.
            let kind = kind_of(f.kind.as_deref());
            if !policy.allows(kind) {
                continue;
            }
            let Ok((content, redactions)) = self.redact(&policy, f.text.trim()).await else { continue };
            let hash = content_hash(&format!("fact\u{1f}{}\u{1f}{}", job.session_id, content));
            if !seen.insert(hash.clone()) {
                continue;
            }
            // Cited rounds (1-based); none or out of range means the whole session.
            let mut src: Vec<&Memory> = cited(&f, rounds.len()).into_iter().map(|i| &rounds[i]).collect();
            if src.is_empty() {
                src = rounds.iter().collect();
            }
            let refs: Vec<String> = src.iter().filter_map(|r| r.turn_ref.clone()).collect();
            let when = f.date.as_deref().and_then(parse_date).or(session_time);
            let mut metadata = serde_json::json!({
                "derived": true,
                "extractor": model,
                "prompt_version": PROMPT_VERSION,
                "source_ids": src.iter().map(|r| r.id.to_string()).collect::<Vec<_>>(),
                "observed_at": session_time,
            });
            if !redactions.is_empty() {
                metadata["redactions"] = serde_json::json!(redactions);
            }
            let mem = Memory {
                id: Uuid::now_v7(),
                tenant: job.tenant.clone(),
                subject: job.subject.clone(),
                kind,
                status: MemoryStatus::Candidate,
                content,
                session_id: Some(job.session_id.clone()),
                turn_ref: Some(refs.join(",")).filter(|r| !r.is_empty()),
                occurred_at: when,
                valid_from: when.unwrap_or(now),
                valid_to: None,
                supersedes: None,
                labels: vec![],
                tags: vec![],
                source: format!("enrich:{model}"),
                confidence,
                metadata,
                created_at: now,
                expires_at: None,
                scope: src.first().map(|r| r.scope.clone()).unwrap_or_default(),
                provenance: Provenance {
                    agent: Some("enrich".into()),
                    user: src.first().and_then(|r| r.provenance.user.clone()),
                    policy_version: Some(policy.version.clone()),
                    request_key: None,
                    extractor: Some(model.to_string()),
                    extractor_config: Some(PROMPT_VERSION.to_string()),
                },
                language: None,
            };
            let mut it = Item::new(NewMemory::new(mem, hash), None, redactions);
            it.derived = true;
            it.hint = match f.kind.as_deref() {
                Some("plan") => Some(Statement::Plan),
                Some("event") => Some(Statement::Event),
                Some("preference") => Some(Statement::Preference),
                _ => None,
            };
            items.push(it);
        }
        let existing = self.store.existing_hashes(&job.tenant, &job.subject, &items.iter().map(|i| i.rec.content_hash.clone()).collect::<Vec<_>>()).await?;
        items.retain(|i| !existing.contains(&i.rec.content_hash));
        if items.is_empty() {
            return Ok(0);
        }
        self.gate_stage(&policy, Entry::Commit, &mut items).await?;
        self.route_stage(&mut items);
        self.embed_stage(&mut items).await?;
        let (supersede, confirm) = self.resolve_stage(&policy, &job.tenant, &job.subject, Entry::Commit, &mut items).await?;
        let count = |s: MemoryStatus| items.iter().filter(|i| i.rec.memory.status == s).count();
        let (held, rejected, quarantined) = (count(MemoryStatus::Candidate), count(MemoryStatus::Rejected), count(MemoryStatus::Quarantined));
        // One event for the batch; each change to another record (a supersession, a confirmed
        // plan) also gets its own.
        let mut audit: Vec<_> = self.record_audit(&items, &job.subject).into_iter().filter(|a| a.action == "memory.supersede" || a.action == "memory.admit").collect();
        audit.insert(
            0,
            crate::intake::AuditEntry {
                actor: "enrich".into(),
                action: "memory.enrich".into(),
                subject: Some(job.subject.clone()),
                memory_id: None,
                detail: serde_json::json!({ "session": job.session_id, "job": job.id, "facts": items.len(), "held": held, "rejected": rejected, "quarantined": quarantined, "superseded": supersede.len(), "confirmed": confirm.len(), "model": model }),
            },
        );
        let n = items.len();
        let signals = crate::intake::signals_of(&items);
        let w = IntakeWrite {
            proposal: None,
            tenant: job.tenant.clone(),
            records: items.into_iter().map(|i| i.rec).collect(),
            supersede,
            confirm,
            signals,
            audit,
            ..Default::default()
        };
        self.store.apply_intake(&w).await?;
        Ok(n)
    }

    /// Wait until the subject has no pending or running jobs (benchmarks; tests).
    pub async fn enrich_wait(&self, tenant: Option<String>, subject: &str, timeout: Duration) -> anyhow::Result<EnrichStatus> {
        let tenant = tenant.unwrap_or_else(|| self.cfg.memory.tenant.clone());
        let start = std::time::Instant::now();
        loop {
            let st = self.store.enrich_status(&tenant, Some(subject)).await?;
            if st.pending + st.running == 0 || start.elapsed() > timeout {
                return Ok(st);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fact_is_as_sure_as_it_is_grounded_in_its_rounds() {
        let round = "user: I moved to Porto last week and I adopted a cat named Miso.";
        let grounded = fact_confidence("The user adopted a cat named Miso on 2023-05-02.", round, true);
        let invented = fact_confidence("The user enjoys skiing in Austria every winter.", round, true);
        assert!(grounded > 0.9 && invented < 0.5, "{grounded} {invented}");
        // The same fact without a cited round is a tenth less sure; numbers alone say nothing.
        assert!((grounded - fact_confidence("The user adopted a cat named Miso on 2023-05-02.", round, false) - 0.1).abs() < 1e-6);
        assert_eq!(fact_confidence("2023 05 02", round, true), 0.3);
        // A session: the mean; capped when the answer was cut; low when nothing came of a long one.
        assert!((session_confidence(&[0.9, 0.5], true, 900) - 0.7).abs() < 1e-6);
        assert_eq!(session_confidence(&[0.9, 0.9], false, 900), 0.5);
        assert_eq!(session_confidence(&[], true, 900), 0.4);
        assert_eq!(session_confidence(&[], true, 80), 0.9);
        // The cut is seen by the parser.
        assert!(!parse_answer("{\"facts\": [{\"text\": \"The user sold a bike\", \"rounds\": [1]}, {\"text\": \"The user mo").unwrap().1);
        assert!(parse_answer("{\"facts\": [{\"text\": \"The user sold a bike\", \"rounds\": [7]}]}").unwrap().1);
    }

    #[test]
    fn the_large_tier_keeps_to_the_tenants_share() {
        let s = Spend::default();
        for session in ["s1", "s2", "s3"] {
            s.session("a", session);
        }
        assert!(!s.take_large("a", "s3", 0.3));
        // A retry, or another job of the same session, is the same session: it makes no room.
        for _ in 0..5 {
            s.session("a", "s3");
        }
        assert!(!s.take_large("a", "s3", 0.3));
        s.session("a", "s4");
        assert!(s.take_large("a", "s4", 0.3));
        // The session that holds the slot keeps it on a retry; another one gets none.
        assert!(s.take_large("a", "s4", 0.3));
        assert!(!s.take_large("a", "s2", 0.3));
        assert_eq!((s.tiers("a"), s.tiers("b")), ((4, 1), (0, 0)));
    }

    #[test]
    fn salvages_truncated_output() {
        let f = parse("{\"facts\": [{\"text\": \"The user sold a bike {red}\", \"rounds\": [1]}, {\"text\": \"The user moved to Lis").unwrap();
        assert_eq!(f.len(), 1);
        assert!(parse("nothing here").is_err());
    }

    #[test]
    fn parses_fenced_json_and_dates() {
        let f = parse(
            "```json\n{\"facts\": [{\"text\": \"The user bought an air fryer\", \"kind\": \"event\", \"date\": \"2023-03-15\", \"rounds\": [2, \"3\"]}, {\"text\": \"ok\"}]}\n```",
        )
        .unwrap();
        assert_eq!(f.len(), 1);
        assert_eq!(parse_date("2023-03-15").unwrap().format("%F").to_string(), "2023-03-15");
        assert_eq!(parse_date("2023-03").unwrap().format("%F").to_string(), "2023-03-01");
        assert!(parse_date("null").is_none());
    }
}
