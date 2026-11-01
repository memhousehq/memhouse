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
}

impl Spend {
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
    let keep = |v: Vec<ExtractedFact>| v.into_iter().filter(|f| f.text.trim().chars().count() >= 8).collect::<Vec<_>>();
    let start = text.find('{').ok_or_else(|| anyhow::anyhow!("no JSON object in extractor output"))?;
    if let Some(end) = text.rfind('}') {
        if let Ok(e) = serde_json::from_str::<Extracted>(&text[start..=end]) {
            return Ok(keep(e.facts));
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
    Ok(keep(facts))
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

impl Engine {
    /// Start `n` enrichment workers on this runtime. They poll the queue until `stop` is set.
    pub fn spawn_enrichment(&self, n: usize, stop: Arc<AtomicBool>, spend: Arc<Spend>) -> Vec<tokio::task::JoinHandle<()>> {
        (0..n)
            .map(|w| {
                let e = self.clone();
                let stop = stop.clone();
                let spend = spend.clone();
                tokio::spawn(async move {
                    while !stop.load(Ordering::Relaxed) {
                        match e.enrich_once(&spend).await {
                            Ok(true) => {}
                            Ok(false) => tokio::time::sleep(Duration::from_millis(150)).await,
                            Err(err) => {
                                tracing::warn!("enrichment worker {w}: {err:#}");
                                tokio::time::sleep(Duration::from_secs(1)).await;
                            }
                        }
                    }
                })
            })
            .collect()
    }

    /// Claim and process one job. Returns false when the queue is empty.
    pub async fn enrich_once(&self, spend: &Spend) -> anyhow::Result<bool> {
        let Some(job) = self.store.enrich_claim(1, 300).await?.pop() else { return Ok(false) };
        match self.enrich_job(&job, spend).await {
            Ok((key, outcome)) => self.store.enrich_finish(job.id, key.as_deref(), &outcome).await?,
            Err(e) => {
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
            return Ok((None, outcome));
        }
        let (text, user_chars) = render(&rounds, cfg.assistant_chars);
        if user_chars < cfg.min_user_chars {
            outcome.skipped = true;
            return Ok((None, outcome));
        }
        let session_time = rounds.iter().find_map(|r| r.occurred_at);
        let date_line = session_time.map(|t| t.format("%Y-%m-%d (%A)").to_string()).unwrap_or_else(|| "unknown".into());
        let prompt = format!("{INSTRUCTIONS}\n\nSession date: {date_line}\n\nConversation:\n{text}");
        let key = cache_key(&model, &prompt);
        let answer = match self.store.llm_cache_get(&key).await? {
            Some(a) => {
                outcome.cached = true;
                a
            }
            None => {
                if cfg.max_cost_usd > 0.0 && spend.usd() >= cfg.max_cost_usd {
                    anyhow::bail!("enrichment spend ${:.4} reached max_cost_usd {}", spend.usd(), cfg.max_cost_usd);
                }
                let (a, usage) = chat.chat(SYSTEM, &prompt).await?;
                spend.add(usage.cost_usd.unwrap_or(0.0));
                outcome.usage = usage;
                // Cache only answers that parse, so a malformed one is retried next time.
                parse(&a)?;
                self.store.llm_cache_put(&key, &model, &a).await?;
                a
            }
        };
        let facts = parse(&answer)?;
        outcome.facts = self.store_facts(job, &rounds, session_time, facts, &model).await?;
        Ok((Some(key), outcome))
    }

    async fn store_facts(&self, job: &EnrichJob, rounds: &[Memory], session_time: Option<DateTime<Utc>>, facts: Vec<ExtractedFact>, model: &str) -> anyhow::Result<usize> {
        let now = Utc::now();
        let mut recs: Vec<NewMemory> = vec![];
        let mut seen = std::collections::HashSet::new();
        for f in facts {
            let Ok(gated) = self.screen(f.text.trim()) else { continue };
            let hash = content_hash(&format!("fact\u{1f}{}\u{1f}{}", job.session_id, gated.content));
            if !seen.insert(hash.clone()) {
                continue;
            }
            // Cited rounds (1-based); none or out of range means the whole session.
            let mut src: Vec<&Memory> = f
                .rounds
                .iter()
                .filter_map(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())))
                .filter_map(|i| rounds.get((i as usize).checked_sub(1)?))
                .collect();
            if src.is_empty() {
                src = rounds.iter().collect();
            }
            let refs: Vec<String> = src.iter().filter_map(|r| r.turn_ref.clone()).collect();
            let when = f.date.as_deref().and_then(parse_date).or(session_time);
            let status = if gated.quarantine() { MemoryStatus::Quarantined } else { MemoryStatus::Committed };
            let mut metadata = serde_json::json!({
                "derived": true,
                "extractor": model,
                "prompt_version": PROMPT_VERSION,
                "source_ids": src.iter().map(|r| r.id.to_string()).collect::<Vec<_>>(),
                "observed_at": session_time,
            });
            if !gated.redactions.is_empty() {
                metadata["redactions"] = serde_json::json!(gated.redactions);
            }
            if !gated.injection.is_empty() {
                metadata["quarantine_reasons"] = serde_json::json!(gated.injection);
            }
            recs.push(NewMemory {
                memory: Memory {
                    id: Uuid::now_v7(),
                    tenant: job.tenant.clone(),
                    subject: job.subject.clone(),
                    kind: kind_of(f.kind.as_deref()),
                    status,
                    content: gated.content,
                    session_id: Some(job.session_id.clone()),
                    turn_ref: Some(refs.join(",")).filter(|r| !r.is_empty()),
                    occurred_at: when,
                    valid_from: when.unwrap_or(now),
                    valid_to: None,
                    supersedes: None,
                    labels: vec![],
                    tags: vec![],
                    source: format!("enrich:{model}"),
                    confidence: 0.9,
                    metadata,
                    created_at: now,
                },
                embedding: None,
                content_hash: hash,
                alt: None,
            });
        }
        let existing = self.store.existing_hashes(&job.tenant, &job.subject, &recs.iter().map(|r| r.content_hash.clone()).collect::<Vec<_>>()).await?;
        recs.retain(|r| !existing.contains(&r.content_hash));
        if recs.is_empty() {
            return Ok(0);
        }
        let vecs = self.embed_passages(&recs.iter().map(|r| r.memory.content.clone()).collect::<Vec<_>>()).await?;
        for (r, v) in recs.iter_mut().zip(vecs) {
            r.embedding = Some(v);
        }
        self.store.insert(&recs).await?;
        self.store
            .audit(
                "enrich",
                "memory.enrich",
                &job.tenant,
                Some(&job.subject),
                None,
                serde_json::json!({ "session": job.session_id, "job": job.id, "facts": recs.len(), "model": model }),
            )
            .await?;
        Ok(recs.len())
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
