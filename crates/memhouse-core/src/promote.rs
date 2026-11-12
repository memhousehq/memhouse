// SPDX-License-Identifier: Apache-2.0
//! Promotion between memory types (MEM-05): a note in working memory becomes a fact, a run of
//! events becomes a procedure. A promotion writes a new record of the target type in the same
//! subject. It goes through the write pipeline like any write, so the target type's own gate
//! applies (a promoted procedure from an agent still waits for confirmation). The new record
//! keeps the ids and kinds of its sources (`metadata.promoted_from`), the union of their labels
//! and the earliest of their event times; the sources stay as they are. The pipeline writes a
//! `memory.promote` audit event with the insert, in the same transaction.

use crate::engine::Engine;
use crate::error;
use crate::intake::{Entry, Op};
use crate::policy::CompiledPolicy;
use crate::types::*;
use serde_json::json;

/// Sources per promotion.
pub const MAX_SOURCES: usize = 50;

impl Engine {
    /// Promote as the operator (CLI, tests); callers go through [`crate::caller::Caller::promote`].
    pub async fn promote(&self, req: PromoteRequest) -> anyhow::Result<RememberResult> {
        self.promote_with(req, Entry::Commit).await
    }

    pub(crate) async fn promote_with(&self, req: PromoteRequest, entry: Entry) -> anyhow::Result<RememberResult> {
        let policy = crate::engine::retryable(self.policy_for(&self.tenant(&req.tenant)).await)?;
        let span = Self::write_span("memhouse.promote", &policy, &req.actor, &None);
        crate::engine::retryable(self.traced("promote", span, self.promote_untraced(req, entry, &policy)).await)
    }

    /// The source records of a promotion, in the order named: all there, of one subject,
    /// committed, and of kinds that may become `to`.
    pub(crate) async fn promotion_sources(&self, tenant: &str, ids: &[uuid::Uuid], to: MemoryKind) -> anyhow::Result<Vec<Memory>> {
        if ids.is_empty() || ids.len() > MAX_SOURCES {
            return Err(error::invalid(format!("a promotion names 1 to {MAX_SOURCES} source records")));
        }
        let mut seen = std::collections::HashSet::new();
        if !ids.iter().all(|i| seen.insert(*i)) {
            return Err(error::invalid("a source record is named twice"));
        }
        for id in ids {
            // A source still in the intake queue is settled first, so it is promoted as stored.
            self.settle_record(tenant, *id).await?;
        }
        let mut stored = self.store.get_many(tenant, ids).await?;
        let mut sources = Vec::with_capacity(ids.len());
        for id in ids {
            let i = stored.iter().position(|m| m.id == *id).ok_or_else(|| error::not_found(format!("memory {id} not found")))?;
            sources.push(stored.swap_remove(i));
        }
        let subject = sources[0].subject.clone();
        for m in &sources {
            if m.subject != subject {
                return Err(error::invalid("the sources belong to different subjects; a promotion stays inside one subject"));
            }
            if m.status != MemoryStatus::Committed {
                return Err(error::conflict(format!("memory {} is {}; only committed records are promoted", m.id, m.status.as_str())));
            }
            // Past its expiry a note is no longer recalled, whether or not retention has marked
            // it yet: it is not given a durable copy either.
            if m.expires_at.is_some_and(|t| t <= chrono::Utc::now()) {
                return Err(error::conflict(format!("memory {} has expired; only live records are promoted", m.id)));
            }
            if !m.kind.promotable_to(to) {
                return Err(error::invalid(format!("{} memory can't be promoted to {to}", m.kind)));
            }
        }
        Ok(sources)
    }

    /// The scope a promoted record takes when the request names none: the sources' common scope
    /// without its session.
    pub(crate) fn promotion_scope(sources: &[Memory]) -> anyhow::Result<Scope> {
        let mut scope = sources[0].scope.clone();
        scope.session = None;
        let same = sources.iter().all(|m| Scope { session: None, ..m.scope.clone() } == scope);
        if !same {
            return Err(error::invalid("the sources have different scopes; name the scope of the promoted memory"));
        }
        Ok(scope)
    }

    async fn promote_untraced(&self, req: PromoteRequest, entry: Entry, policy: &CompiledPolicy) -> anyhow::Result<RememberResult> {
        let tenant = self.tenant(&req.tenant);
        let actor = req.actor.clone().unwrap_or_else(|| "api".into());
        if let Some(done) = self.replay::<RememberResult>(&tenant, &req.request_key, &req).await? {
            return Ok(done);
        }
        let kind = req.kind;
        let sources = self.promotion_sources(&tenant, &req.sources, kind).await?;
        let subject = sources[0].subject.clone();
        let content = match req.content.as_deref().map(str::trim).filter(|c| !c.is_empty()) {
            Some(c) => c.to_string(),
            None if sources.len() == 1 => sources[0].content.clone(),
            None => return Err(error::invalid("a promotion of several records needs the content of the promoted memory")),
        };
        let scope = match &req.scope {
            Some(s) => s.clone(),
            None => Self::promotion_scope(&sources)?,
        };
        let mut labels: Vec<String> = sources.iter().flat_map(|m| m.labels.iter().cloned()).chain(req.labels.iter().cloned()).collect();
        labels.sort();
        labels.dedup();
        let structured = match (&req.structured, sources.as_slice()) {
            (Some(s), _) => Some(s.clone()),
            // The single source's structured form carries over with its own text only: new
            // text describes something the old attributes may not (give `structured` with it).
            (None, [one]) if content == one.content => self.store.representations(&tenant, one.id).await?.0,
            _ => None,
        };
        let mut metadata = json!({
            "promoted_from": sources.iter().map(|m| m.id.to_string()).collect::<Vec<_>>(),
            "promoted_from_kinds": sources.iter().map(|m| m.kind.as_str()).collect::<Vec<_>>(),
        });
        if let Some(r) = req.reason.as_deref().map(str::trim).filter(|r| !r.is_empty()) {
            metadata["promotion_reason"] = json!(r.chars().take(500).collect::<String>());
        }
        let write = RememberRequest {
            tenant: Some(tenant.clone()),
            subject: Some(subject.clone()),
            content,
            kind: Some(kind),
            tags: req.tags.clone(),
            occurred_at: sources.iter().filter_map(|m| m.occurred_at).min(),
            valid_to: req.valid_to,
            supersedes: None,
            source: None,
            metadata: Some(metadata),
            actor: Some(actor.clone()),
            labels,
            scope: Some(scope),
            user: req.user.clone(),
            request_key: req.request_key.clone(),
            expires_at: None,
            structured,
            code_refs: vec![],
            wait: req.wait,
        };
        let result = self.remember_once(&write, &tenant, &subject, &actor, (entry, Op::Promote), policy).await?;
        self.accepted_key(&tenant, &subject, "promote", &req.request_key, &req, &result).await;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// MEM-05: promotion only moves towards durable memory.
    #[test]
    fn promotion_directions() {
        use MemoryKind::*;
        assert!(Working.promotable_to(Episodic) && Working.promotable_to(Semantic) && Working.promotable_to(Preference));
        assert!(Episodic.promotable_to(Semantic) && Episodic.promotable_to(Procedural) && Semantic.promotable_to(Taxonomic));
        assert!(Commitment.promotable_to(Semantic) && Document.promotable_to(Procedural));
        for k in MemoryKind::ALL {
            assert!(!k.promotable_to(k) && !k.promotable_to(Working) && !k.promotable_to(Commitment) && !k.promotable_to(Document));
        }
        assert!(!Semantic.promotable_to(Episodic) && !Preference.promotable_to(Episodic));
    }
}
