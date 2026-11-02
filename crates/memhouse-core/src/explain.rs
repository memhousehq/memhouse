// SPDX-License-Identifier: Apache-2.0
//! Recall explanations (GOV-04). Every recall keeps a record: what was asked, under which
//! decision, what came back with its ranking signals, and what the recall itself cut (below `k`,
//! over the token budget). Reading the explanation replays the query against the subject without
//! any filter and gives every other matching record the reason it was left out: its state, access
//! (scope), a denied label, validity, the request's own filters, or its rank.

use crate::engine::Engine;
use crate::error;
use crate::types::*;
use chrono::Utc;
use std::collections::{BTreeMap, HashSet};

/// The reason a candidate is not among the results, if any; checks in the order of
/// [`ExclusionReason`] so the first rule that excludes it names it.
pub fn classify(m: &Memory, r: &RecallRecord) -> (ExclusionReason, String) {
    let recallable = m.status == MemoryStatus::Committed || (r.as_of.is_some() && m.status == MemoryStatus::Superseded);
    if !recallable {
        return (ExclusionReason::Status, format!("status {}", m.status.as_str()));
    }
    let fields = [
        ("org", &r.scope.org, &m.scope.org),
        ("team", &r.scope.team, &m.scope.team),
        ("agent", &r.scope.agent, &m.scope.agent),
        ("user", &r.scope.user, &m.scope.user),
        ("session", &r.scope.session, &m.scope.session),
    ];
    for (name, want, have) in fields {
        if let (Some(w), Some(h)) = (want, have) {
            if w != h {
                return (ExclusionReason::Access, format!("scope.{name} is not the caller's"));
            }
        }
    }
    if let Some(l) = m.labels.iter().find(|l| r.denied_labels.contains(l)) {
        return (ExclusionReason::Label, format!("label {l}"));
    }
    if m.valid_from > r.valid_at {
        return (ExclusionReason::Validity, format!("valid_from {} is after {}", m.valid_from.to_rfc3339(), r.valid_at.to_rfc3339()));
    }
    if let Some(t) = m.valid_to.filter(|t| *t <= r.valid_at) {
        return (ExclusionReason::Validity, format!("valid_to {} is not after {}", t.to_rfc3339(), r.valid_at.to_rfc3339()));
    }
    if let Some(t) = m.expires_at.filter(|t| *t <= r.valid_at) {
        return (ExclusionReason::Validity, format!("expired at {}", t.to_rfc3339()));
    }
    if let (Some(a), Some(o)) = (r.as_of, m.occurred_at) {
        if o > a {
            return (ExclusionReason::Validity, format!("occurred_at {} is after as_of", o.to_rfc3339()));
        }
    }
    if let Some(k) = r.kinds.as_ref().filter(|k| !k.contains(&m.kind)) {
        return (ExclusionReason::Filter, format!("kind {} is not among {}", m.kind, k.iter().map(|x| x.as_str()).collect::<Vec<_>>().join(",")));
    }
    if r.tags.as_ref().is_some_and(|t| !t.iter().any(|x| m.tags.contains(x))) {
        return (ExclusionReason::Filter, "no requested tag".into());
    }
    (ExclusionReason::Rank, "ranked below the results".into())
}

impl Engine {
    /// The explanation of a recall. `show_hidden` lists records excluded for state, access or
    /// labels by id (auditors); otherwise they are only counted.
    pub async fn explain(&self, record: RecallRecord, show_hidden: bool) -> anyhow::Result<RecallExplanation> {
        let embedding = if record.mode == RetrievalMode::Keyword { None } else { Some(self.embed_query(&record.query).await?) };
        let q = SearchQuery {
            tenant: record.tenant.clone(),
            subject: record.subject.clone(),
            text: record.query.clone(),
            embedding,
            kinds: None,
            tags: None,
            denied_labels: vec![],
            as_of: None,
            valid_at: record.valid_at,
            mode: record.mode,
            per_retriever: self.cfg.memory.candidates.max(record.k),
            limit: (record.k * 5).max(50),
            rrf_k: self.cfg.memory.rrf_k,
            keyword_weight: self.cfg.memory.keyword_weight,
            vector_weight: self.cfg.memory.vector_weight,
            windows: vec![],
            scope: Scope::default(),
        };
        let candidates = self.store.search_unfiltered(&q).await?;
        let returned: HashSet<_> = record.returned.iter().map(|r| r.id).collect();
        let mut excluded: Vec<ExcludedRecord> = vec![];
        let mut hidden: BTreeMap<String, u64> = BTreeMap::new();
        for c in candidates.into_iter().filter(|c| !returned.contains(&c.memory.id)) {
            let (reason, detail) = match record.cut.iter().find(|x| x.id == c.memory.id) {
                Some(x) => (x.reason, x.detail.clone()),
                None => classify(&c.memory, &record),
            };
            if !show_hidden && matches!(reason, ExclusionReason::Status | ExclusionReason::Access | ExclusionReason::Label) {
                *hidden.entry(reason.as_str().to_string()).or_default() += 1;
            } else {
                excluded.push(ExcludedRecord { id: c.memory.id, reason, detail });
            }
        }
        // Cut records the replay didn't reach (it looks at the top candidates only).
        for x in &record.cut {
            if !excluded.iter().any(|e| e.id == x.id) {
                excluded.push(x.clone());
            }
        }
        excluded.sort_by_key(|e| e.reason);
        let mut recall = record;
        recall.cut.clear();
        Ok(RecallExplanation { recall, excluded, hidden, replayed_at: Utc::now() })
    }

    async fn embed_query(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let prefix = self.cfg.embedding.query_prefix.clone().unwrap_or_default();
        let mut v = self.embedder.embed(&[format!("{prefix}{text}")], crate::traits::EmbedKind::Query).await?;
        v.pop().ok_or_else(|| error::invalid("the embedder returned no vector"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn record() -> RecallRecord {
        RecallRecord {
            recall_id: uuid::Uuid::nil(),
            at: Utc::now(),
            tenant: "t".into(),
            subject: "s".into(),
            principal: "agent:a".into(),
            user: None,
            policy_version: "p".into(),
            authorizer: "scope".into(),
            query: "q".into(),
            k: 3,
            kinds: Some(vec![MemoryKind::Semantic]),
            tags: None,
            scope: Scope { user: Some(crate::access::NOBODY.into()), ..Default::default() },
            denied_labels: vec!["hr".into()],
            as_of: None,
            valid_at: Utc::now(),
            mode: RetrievalMode::Hybrid,
            token_budget: None,
            reranked: false,
            windows: vec![],
            returned: vec![],
            cut: vec![],
            stages: RecallStages::default(),
        }
    }

    fn memory() -> Memory {
        Memory {
            id: uuid::Uuid::now_v7(),
            tenant: "t".into(),
            subject: "s".into(),
            kind: MemoryKind::Semantic,
            status: MemoryStatus::Committed,
            content: "x".into(),
            session_id: None,
            turn_ref: None,
            occurred_at: None,
            valid_from: Utc::now() - Duration::days(1),
            valid_to: None,
            supersedes: None,
            labels: vec![],
            tags: vec![],
            source: "t".into(),
            confidence: 1.0,
            metadata: serde_json::json!({}),
            created_at: Utc::now(),
            expires_at: None,
            scope: Scope::default(),
            provenance: Provenance::default(),
        }
    }

    #[test]
    fn reasons_in_order() {
        let r = record();
        let mut m = memory();
        assert_eq!(classify(&m, &r).0, ExclusionReason::Rank);
        m.kind = MemoryKind::Episodic;
        assert_eq!(classify(&m, &r).0, ExclusionReason::Filter);
        m.valid_to = Some(Utc::now() - Duration::hours(1));
        assert_eq!(classify(&m, &r).0, ExclusionReason::Validity);
        m.labels = vec!["hr".into()];
        assert_eq!(classify(&m, &r), (ExclusionReason::Label, "label hr".into()));
        m.scope.user = Some("user:bob".into());
        assert_eq!(classify(&m, &r).0, ExclusionReason::Access);
        m.status = MemoryStatus::Quarantined;
        assert_eq!(classify(&m, &r).0, ExclusionReason::Status);
    }
}
