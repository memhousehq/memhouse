// SPDX-License-Identifier: Apache-2.0
//! Sharing across agents (INT-06). A record scoped to an agent (`scope.agent`) is read by that
//! agent only. A grant makes one agent's agent-scoped memory readable to another, for the
//! subjects and kinds it names, until it expires or is revoked. Grants give read access only:
//! revising, forgetting and promoting stay with the owner.
//!
//! Grants are read from the store through a short cache ([`REFRESH`]): a grant or a revocation
//! made through this process applies at once, through another within that time.

use crate::engine::Engine;
use crate::error;
use crate::identity::PrincipalKind;
use crate::types::*;
use chrono::Utc;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use uuid::Uuid;

/// How long an engine trusts the grants it read.
pub const REFRESH: Duration = Duration::from_secs(2);

/// The grants given to one agent, and when they were read.
type Given = (Vec<Grant>, Instant);

/// The grants given to each agent an engine has served: (tenant, grantee) to its grants.
#[derive(Default)]
pub struct GrantCache {
    entries: Mutex<HashMap<(String, String), Given>>,
}

impl GrantCache {
    fn fresh(&self, tenant: &str, grantee: &str) -> Option<Vec<Grant>> {
        let m = self.entries.lock().ok()?;
        m.get(&(tenant.to_string(), grantee.to_string())).filter(|(_, at)| at.elapsed() < REFRESH).map(|(g, _)| g.clone())
    }

    fn put(&self, tenant: &str, grantee: &str, grants: Vec<Grant>) {
        if let Ok(mut m) = self.entries.lock() {
            m.insert((tenant.to_string(), grantee.to_string()), (grants, Instant::now()));
        }
    }

    pub fn clear(&self) {
        if let Ok(mut m) = self.entries.lock() {
            m.clear();
        }
    }
}

/// The `shared` list of a read: one key per granting agent, for all kinds or for each kind named.
pub fn shared_keys(grants: &[Grant], subject: &str, now: chrono::DateTime<Utc>) -> Vec<String> {
    let mut keys: Vec<String> = vec![];
    for g in grants.iter().filter(|g| g.active(now) && g.covers(subject)) {
        if g.kinds.is_empty() {
            keys.push(shared_key(&g.grantor, None));
        } else {
            keys.extend(g.kinds.iter().map(|k| shared_key(&g.grantor, Some(*k))));
        }
    }
    keys.sort();
    keys.dedup();
    keys
}

impl Engine {
    /// The agents whose agent-scoped memory `grantee` may read in `subject`, as `shared_key`s.
    pub(crate) async fn shared_agents(&self, tenant: &str, grantee: &str, subject: &str) -> anyhow::Result<Vec<String>> {
        let grants = match self.grants.fresh(tenant, grantee) {
            Some(g) => g,
            None => {
                let g = self.store.grants(tenant, Some(grantee)).await?;
                self.grants.put(tenant, grantee, g.clone());
                g
            }
        };
        Ok(shared_keys(&grants, subject, Utc::now()))
    }

    async fn agent_of(&self, tenant: &str, id: &str, role: &str) -> anyhow::Result<()> {
        match self.store.principal_get(id).await? {
            Some(p) if p.kind == PrincipalKind::Agent && p.tenant == tenant && p.disabled_at.is_none() => Ok(()),
            _ => Err(error::invalid(format!("the {role} {id:?} is not an active agent of this tenant"))),
        }
    }

    /// Share `grantor`'s agent-scoped memory with `grantee` (audited as `grant.create`).
    pub async fn grant_create(&self, tenant: &str, req: &GrantRequest, by: &str) -> anyhow::Result<Grant> {
        if req.grantor == req.grantee {
            return Err(error::invalid("an agent needs no grant to its own memory"));
        }
        self.agent_of(tenant, &req.grantor, "grantor").await?;
        self.agent_of(tenant, &req.grantee, "grantee").await?;
        let subjects = req.subjects.clone().unwrap_or_else(|| "*".into());
        if subjects.trim().is_empty() || subjects.len() > 200 || subjects[..subjects.len() - 1].contains('*') {
            return Err(error::invalid("subjects is an exact subject, a prefix ending in '*', or '*'"));
        }
        if req.expires_at.is_some_and(|t| t <= Utc::now()) {
            return Err(error::invalid("expires_at is in the past"));
        }
        let mut kinds = req.kinds.clone();
        kinds.sort_by_key(|k| k.as_str());
        kinds.dedup();
        let g = Grant {
            id: Uuid::now_v7(),
            tenant: tenant.to_string(),
            grantor: req.grantor.clone(),
            grantee: req.grantee.clone(),
            subjects,
            kinds,
            created_by: by.to_string(),
            created_at: Utc::now(),
            expires_at: req.expires_at,
            revoked_at: None,
        };
        self.store.grant_put(&g).await?;
        self.grants.clear();
        let detail = json!({ "grant": g.id, "grantor": g.grantor, "grantee": g.grantee, "subjects": g.subjects, "kinds": g.kinds, "expires_at": g.expires_at });
        self.store.audit(by, "grant.create", tenant, None, None, detail).await?;
        Ok(g)
    }

    /// Every grant of a tenant, newest first, revoked and expired ones included.
    pub async fn grant_list(&self, tenant: &str) -> anyhow::Result<Vec<Grant>> {
        self.store.grants(tenant, None).await
    }

    /// Revoke a grant now (audited as `grant.revoke`).
    pub async fn grant_revoke(&self, tenant: &str, id: Uuid, by: &str) -> anyhow::Result<()> {
        if !self.store.grant_revoke(tenant, id).await? {
            return Err(error::not_found(format!("no active grant {id}")));
        }
        self.grants.clear();
        self.store.audit(by, "grant.revoke", tenant, None, None, json!({ "grant": id })).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grant(subjects: &str, kinds: Vec<MemoryKind>) -> Grant {
        Grant {
            id: Uuid::now_v7(),
            tenant: "t".into(),
            grantor: "agent:a".into(),
            grantee: "agent:b".into(),
            subjects: subjects.into(),
            kinds,
            created_by: "admin".into(),
            created_at: Utc::now(),
            expires_at: None,
            revoked_at: None,
        }
    }

    /// INT-06: a record of another agent is seen only through a grant that is active and covers
    /// the subject and the kind.
    #[test]
    fn grants_decide_agent_visibility() {
        let now = Utc::now();
        let reader = Scope { agent: Some("agent:b".into()), ..Default::default() };
        let theirs = Scope { agent: Some("agent:a".into()), ..Default::default() };
        let sees = |grants: &[Grant], subject: &str, kind| reader.sees(&theirs, kind, &shared_keys(grants, subject, now));
        assert!(!sees(&[], "customer:1", MemoryKind::Semantic));
        assert!(sees(&[grant("*", vec![])], "customer:1", MemoryKind::Semantic));
        assert!(sees(&[grant("customer:*", vec![])], "customer:1", MemoryKind::Working));
        assert!(!sees(&[grant("customer:*", vec![])], "user:ana", MemoryKind::Semantic));
        let semantic_only = [grant("*", vec![MemoryKind::Semantic])];
        assert!(sees(&semantic_only, "customer:1", MemoryKind::Semantic) && !sees(&semantic_only, "customer:1", MemoryKind::Working));
        let mut revoked = grant("*", vec![]);
        revoked.revoked_at = Some(now);
        let mut expired = grant("*", vec![]);
        expired.expires_at = Some(now - chrono::Duration::seconds(1));
        assert!(!sees(&[revoked, expired], "customer:1", MemoryKind::Semantic));
        // A grant from A says nothing about a third agent, and unscoped records need none.
        let other = Scope { agent: Some("agent:c".into()), ..Default::default() };
        assert!(!reader.sees(&other, MemoryKind::Semantic, &shared_keys(&[grant("*", vec![])], "customer:1", now)));
        assert!(reader.sees(&Scope::default(), MemoryKind::Semantic, &[]));
    }
}
