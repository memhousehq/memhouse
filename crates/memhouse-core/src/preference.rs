// SPDX-License-Identifier: Apache-2.0
//! Scope-ordered preferences (MEM-04). A preference has a key when it is written with the
//! structured form `{ record_type: "preference", attrs: { key, ... } }`. One scope holds one
//! value per key (a new one supersedes the old, in the write pipeline); across scopes the value
//! at the narrowest level the reader is in wins: session, then user, agent, team, org, tenant.
//! So a user's preference overrides the team's, which overrides the organisation's.

use crate::engine::Engine;
use crate::types::*;
use chrono::Utc;
use std::collections::{BTreeMap, HashMap, HashSet};
use uuid::Uuid;

/// Preferences read from the store per statement.
const PAGE: usize = 1000;

/// Who reads: the constraints of their authorization decision.
pub(crate) struct Reader<'a> {
    pub scope: &'a Scope,
    pub denied_labels: &'a [String],
    pub shared_agents: &'a [String],
}

/// The preferences that apply, from every preference the reader may see: per key the one at the
/// narrowest scope level (the newest, if a level somehow holds two), and each preference without
/// a key as it is. Narrowest level first, then newest first.
pub fn resolve(visible: Vec<Memory>, key: Option<&str>) -> Vec<EffectivePreference> {
    let key_of = |m: &Memory| m.metadata.get("pref_key").and_then(|k| k.as_str()).map(String::from);
    let mut keyed: BTreeMap<String, Vec<Memory>> = BTreeMap::new();
    let mut out: Vec<EffectivePreference> = vec![];
    for m in visible {
        match key_of(&m) {
            Some(k) if key.is_none_or(|want| want == k) => keyed.entry(k).or_default().push(m),
            None if key.is_none() => out.push(EffectivePreference { key: None, level: m.scope.level(), memory: m, overrides: vec![] }),
            _ => {}
        }
    }
    for (k, mut group) in keyed {
        group.sort_by_key(|m| std::cmp::Reverse((m.scope.level(), m.created_at, m.id)));
        let mut rest = group.into_iter();
        let winner = rest.next().expect("a group has a member");
        out.push(EffectivePreference { key: Some(k), level: winner.scope.level(), memory: winner, overrides: rest.map(|m| m.id).collect() });
    }
    out.sort_by_key(|e| std::cmp::Reverse((e.level, e.memory.created_at, e.memory.id)));
    out
}

/// In a recall's hits, a keyed preference that is overridden gives its place to the one that
/// applies (once), and is listed in `overridden` for the explanation. A winner outside the
/// recall's own tag filter takes no place: the overridden hit just goes.
pub(crate) fn apply_overrides(hits: &mut Vec<Hit>, effective: &[EffectivePreference], tags: Option<&[String]>, overridden: &mut Vec<ExcludedRecord>) {
    let winners: HashMap<&str, &EffectivePreference> = effective.iter().filter_map(|e| e.key.as_deref().map(|k| (k, e))).collect();
    let present: HashSet<Uuid> = hits.iter().map(|h| h.memory.id).collect();
    let mut placed: HashSet<Uuid> = HashSet::new();
    let mut out = Vec::with_capacity(hits.len());
    for mut h in hits.drain(..) {
        let key = (h.memory.kind == MemoryKind::Preference && h.memory.status == MemoryStatus::Committed)
            .then(|| h.memory.metadata.get("pref_key").and_then(|k| k.as_str()).map(String::from))
            .flatten();
        let Some(w) = key.as_deref().and_then(|k| winners.get(k)) else {
            out.push(h);
            continue;
        };
        if w.memory.id == h.memory.id {
            out.push(h);
            continue;
        }
        overridden.push(ExcludedRecord {
            id: h.memory.id,
            reason: ExclusionReason::Overridden,
            detail: format!("the same preference is set at the {} level ({})", w.level.as_str(), w.memory.id),
        });
        // The winner keeps its own place if it was found; otherwise it takes this one, once.
        let filtered_out = tags.is_some_and(|t| !t.iter().any(|x| w.memory.tags.contains(x)));
        if filtered_out || present.contains(&w.memory.id) || !placed.insert(w.memory.id) {
            continue;
        }
        h.memory = w.memory.clone();
        (h.keyword_rank, h.vector_rank, h.similarity, h.rerank_score, h.exact) = (None, None, None, None, false);
        out.push(h);
    }
    *hits = out;
}

impl Engine {
    /// The preferences of a subject as they apply to a reader, optionally one key only. One
    /// statement, inside the subject, under the reader's own filters.
    pub(crate) async fn effective_preferences(&self, tenant: &str, subject: &str, key: Option<&str>, reader: &Reader<'_>) -> anyhow::Result<Vec<EffectivePreference>> {
        let mut q = ListQuery {
            tenant: tenant.to_string(),
            subject: Some(subject.to_string()),
            kinds: Some(vec![MemoryKind::Preference]),
            limit: PAGE,
            denied_labels: reader.denied_labels.to_vec(),
            scope: reader.scope.clone(),
            shared_agents: reader.shared_agents.to_vec(),
            ..Default::default()
        };
        let now = Utc::now();
        // Every visible preference, page by page: an old one is still the value of its key.
        let mut visible: Vec<Memory> = vec![];
        loop {
            let page = self.store.list(&q).await?;
            let last = page.last().map(|m| (m.created_at, m.id));
            let full = page.len() == PAGE;
            visible.extend(page.into_iter().filter(|m| key.is_none_or(|k| m.metadata.get("pref_key").and_then(|v| v.as_str()) == Some(k))));
            match last {
                Some(l) if full => q.before = Some(l),
                _ => break,
            }
        }
        visible.retain(|m| m.valid_from <= now && m.valid_to.is_none_or(|t| t > now) && m.expires_at.is_none_or(|t| t > now));
        Ok(resolve(visible, key))
    }

    /// The preferences that apply in `scope` (operators, tests; callers go through
    /// [`crate::caller::Caller::preferences`]).
    pub async fn preferences(&self, tenant: Option<String>, subject: &str, key: Option<&str>, scope: &Scope) -> anyhow::Result<Vec<EffectivePreference>> {
        let tenant = self.tenant(&tenant);
        let policy = self.policy_for(&tenant).await?;
        let denied = crate::engine::with_policy_labels(&self.cfg.governance.denied_labels, &policy);
        self.effective_preferences(&tenant, subject, key, &Reader { scope, denied_labels: &denied, shared_agents: &[] }).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pref(key: Option<&str>, scope: Scope, text: &str, age_secs: i64) -> Memory {
        let at = Utc::now() - chrono::Duration::seconds(age_secs);
        Memory {
            id: Uuid::now_v7(),
            tenant: "t".into(),
            subject: "s".into(),
            kind: MemoryKind::Preference,
            status: MemoryStatus::Committed,
            content: text.into(),
            session_id: None,
            turn_ref: None,
            occurred_at: None,
            valid_from: at,
            valid_to: None,
            supersedes: None,
            labels: vec![],
            tags: vec![],
            source: "t".into(),
            confidence: 1.0,
            metadata: match key {
                Some(k) => serde_json::json!({ "pref_key": k }),
                None => serde_json::json!({}),
            },
            created_at: at,
            expires_at: None,
            scope,
            provenance: Provenance::default(),
        }
    }

    fn hit(m: &Memory, score: f32) -> Hit {
        Hit { memory: m.clone(), score, keyword_rank: Some(1), vector_rank: None, similarity: None, rerank_score: None, exact: false, working: false }
    }

    /// MEM-04: user over team over org, whatever order they were written in.
    #[test]
    fn narrowest_scope_wins() {
        let org = pref(Some("language"), Scope { org: Some("acme".into()), ..Default::default() }, "English", 1);
        let team = pref(Some("language"), Scope { org: Some("acme".into()), team: Some("support".into()), ..Default::default() }, "German", 30);
        let user = pref(Some("language"), Scope { user: Some("user:ana".into()), ..Default::default() }, "Portuguese", 60);
        let tone = pref(Some("tone"), Scope { org: Some("acme".into()), ..Default::default() }, "Formal", 5);
        let loose = pref(None, Scope::default(), "Likes short answers", 5);
        let all = resolve(vec![org.clone(), team.clone(), user.clone(), tone.clone(), loose.clone()], None);
        let language = all.iter().find(|e| e.key.as_deref() == Some("language")).unwrap();
        assert_eq!((language.memory.id, language.level), (user.id, ScopeLevel::User));
        assert_eq!(language.overrides.len(), 2);
        assert_eq!(all.len(), 3);
        // Without the user's own, the team's wins; a reader outside the team gets the org's.
        assert_eq!(resolve(vec![org.clone(), team.clone()], Some("language"))[0].memory.id, team.id);
        assert_eq!(resolve(vec![org.clone()], Some("language"))[0].memory.id, org.id);
        assert!(resolve(vec![org.clone(), loose], Some("tone")).is_empty());
        // In a recall the overridden hit gives its place to the winner, once.
        let mut hits = vec![hit(&org, 3.0), hit(&tone, 2.0), hit(&team, 1.0)];
        let mut cut = vec![];
        apply_overrides(&mut hits, &all, None, &mut cut);
        assert_eq!(hits.iter().map(|h| h.memory.id).collect::<Vec<_>>(), vec![user.id, tone.id]);
        assert!(cut.len() == 2 && cut.iter().all(|c| c.reason == ExclusionReason::Overridden));
        // A winner without the recall's tag takes no place; the overridden hit still goes.
        let mut hits = vec![hit(&org, 3.0), hit(&tone, 2.0)];
        let mut cut = vec![];
        apply_overrides(&mut hits, &all, Some(&["billing".to_string()]), &mut cut);
        assert_eq!(hits.iter().map(|h| h.memory.id).collect::<Vec<_>>(), vec![tone.id]);
        assert_eq!(cut.len(), 1);
    }
}
