// SPDX-License-Identifier: Apache-2.0
//! The authorization seam (GOV-02, GOV-08, ACC-04): every operation a caller makes is decided by
//! an [`Authorizer`] before the engine does anything. The decision says why, and carries the
//! constraints the engine injects: the tenant, the scope filter and the denied labels go into the
//! statement itself, so a caller can't widen them.
//!
//! [`ScopeAuthorizer`] decides from the principal's role, its key's permissions and its
//! attributes. Relationship-based decisions (ReBAC, ADR 0005) replace it in G27 behind the same
//! trait.

use crate::config::Config;
use crate::identity::{perm, Identity, PrincipalKind};
use crate::types::{ForgetScope, Memory, MemoryKind, Scope};
use schemars::JsonSchema;
use serde::Serialize;

/// A scope value no record has: the filter for "only records that don't set this field".
pub const NOBODY: &str = "\u{1}none";

/// What a caller wants to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Recall,
    Get,
    List,
    Remember,
    Revise,
    Ingest,
    Forget(ForgetScope),
    Relabel,
    Review,
    IssueToken,
    Stats,
    Subjects,
    EnrichStatus,
    Audit,
    Whoami,
}

impl Operation {
    pub fn name(&self) -> String {
        match self {
            Operation::Forget(s) => format!("forget.{}", s.as_str()),
            o => serde_json::to_value(o).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default(),
        }
    }

    pub fn is_write(&self) -> bool {
        matches!(self, Operation::Remember | Operation::Revise | Operation::Ingest | Operation::Relabel)
    }

    pub fn is_read(&self) -> bool {
        matches!(self, Operation::Recall | Operation::Get | Operation::List)
    }
}

/// The facts an authorizer decides on. Fields the caller supplied (`tenant`, `user`, `scope`) are
/// checked against the verified identity, never trusted.
#[derive(Debug, Clone, Default)]
pub struct AccessRequest {
    pub op: Option<Operation>,
    pub tenant: Option<String>,
    pub subject: Option<String>,
    pub kinds: Vec<MemoryKind>,
    pub labels: Vec<String>,
    pub scope: Option<Scope>,
    pub user: Option<String>,
    /// The user, agent or source a `forget` names.
    pub target: Option<String>,
}

impl AccessRequest {
    pub fn new(op: Operation) -> AccessRequest {
        AccessRequest { op: Some(op), ..Default::default() }
    }

    pub fn subject(mut self, s: &str) -> Self {
        self.subject = Some(s.to_string());
        self
    }

    pub fn tenant(mut self, t: &Option<String>) -> Self {
        self.tenant = t.clone();
        self
    }

    /// The facts of an existing record (for get, revise, forget, relabel, review).
    pub fn record(mut self, m: &Memory) -> Self {
        self.subject = Some(m.subject.clone());
        self.kinds = vec![m.kind];
        self.labels = m.labels.clone();
        self.scope = Some(m.scope.clone()).filter(|s| !s.is_empty());
        self
    }
}

/// An authorization decision and the constraints that come with it.
#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct Decision {
    pub allowed: bool,
    /// The rule that decided, e.g. `permission`, `tenant`, `subject`, `label`.
    pub rule: String,
    /// Why, for the caller and the audit log (identifiers only, never content).
    pub reasons: Vec<String>,
    /// The tenant the operation runs in: always the principal's.
    pub tenant: String,
    /// Labels the operation must not read or write (filtered inside the recall statement).
    pub denied_labels: Vec<String>,
    /// The scope every read is filtered by: the request's scope merged with the caller's own.
    pub scope: Scope,
    /// Kinds the caller may use; empty is all.
    pub kinds: Vec<MemoryKind>,
    /// Writes enter as `candidate` and the engine admits them (GOV-08).
    pub propose_only: bool,
}

impl Decision {
    /// Whether a record is visible under this decision's read constraints.
    pub fn visible(&self, m: &Memory) -> bool {
        let field = |want: &Option<String>, have: &Option<String>| want.is_none() || have.is_none() || want == have;
        m.tenant == self.tenant
            && !m.labels.iter().any(|l| self.denied_labels.contains(l))
            && (self.kinds.is_empty() || self.kinds.contains(&m.kind))
            && field(&self.scope.org, &m.scope.org)
            && field(&self.scope.team, &m.scope.team)
            && field(&self.scope.agent, &m.scope.agent)
            && field(&self.scope.user, &m.scope.user)
            && field(&self.scope.session, &m.scope.session)
    }
}

/// Decides every operation. Implementations must fail closed: anything they can't decide is
/// denied (PR-5).
#[async_trait::async_trait]
pub trait Authorizer: Send + Sync {
    fn name(&self) -> &str;
    async fn authorize(&self, who: &Identity, req: &AccessRequest) -> Decision;
}

/// Role and scope rules (G06): permissions from the key, tenant from the principal, subjects by
/// pattern, kinds and labels by role and principal, scope fields injected from the identity.
pub struct ScopeAuthorizer {
    tenant_labels: Vec<String>,
    role_labels: [(PrincipalKind, Vec<String>); 3],
}

impl ScopeAuthorizer {
    pub fn new(cfg: &Config) -> ScopeAuthorizer {
        let r = &cfg.access.denied_labels;
        ScopeAuthorizer {
            tenant_labels: cfg.governance.denied_labels.clone(),
            role_labels: [(PrincipalKind::Agent, r.agent.clone()), (PrincipalKind::User, r.user.clone()), (PrincipalKind::Admin, r.admin.clone())],
        }
    }

    /// The permission an operation needs from this caller.
    pub fn permission(who: &Identity, req: &AccessRequest) -> Option<&'static str> {
        let own = |v: &Option<String>| v.is_some() && *v == req.target;
        Some(match req.op? {
            Operation::Recall | Operation::Get | Operation::List => perm::READ,
            Operation::Remember | Operation::Revise | Operation::Ingest => perm::WRITE,
            Operation::Forget(ForgetScope::Record) => perm::FORGET,
            Operation::Forget(ForgetScope::User) if own(&who.user) => perm::FORGET,
            Operation::Forget(ForgetScope::Agent) if who.principal.kind == PrincipalKind::Agent && own(&Some(who.principal.id.clone())) => perm::FORGET,
            Operation::Forget(_) => perm::ERASE,
            Operation::Relabel => perm::LABEL,
            Operation::Review => perm::REVIEW,
            Operation::IssueToken => perm::TOKEN,
            Operation::Stats | Operation::Subjects | Operation::EnrichStatus => perm::OPS,
            Operation::Audit => perm::AUDIT,
            Operation::Whoami => return None,
        })
    }
}

#[async_trait::async_trait]
impl Authorizer for ScopeAuthorizer {
    fn name(&self) -> &str {
        "scope"
    }

    async fn authorize(&self, who: &Identity, req: &AccessRequest) -> Decision {
        let p = &who.principal;
        let admin = who.is_admin();
        let mut denied: Vec<String> = self.tenant_labels.clone();
        for (k, labels) in &self.role_labels {
            if *k == p.kind {
                denied.extend(labels.iter().cloned());
            }
        }
        denied.extend(p.denied_labels.iter().cloned());
        denied.sort();
        denied.dedup();
        // The caller's own scope: its org, team, agent and user. A caller without one of them
        // sees only records that don't set it (`NOBODY` matches no record); admins see all.
        let mine = |v: Option<String>| if admin { None } else { Some(v.unwrap_or_else(|| NOBODY.to_string())) };
        let own = Scope {
            org: mine(p.org.clone()),
            team: mine(p.team.clone()),
            agent: mine((p.kind == PrincipalKind::Agent).then(|| p.id.clone())),
            user: mine(who.user.clone()),
            session: None,
        };
        let mut d = Decision {
            allowed: true,
            rule: "allow".into(),
            reasons: vec![],
            tenant: p.tenant.clone(),
            denied_labels: denied.clone(),
            scope: own.clone(),
            kinds: p.kinds.clone(),
            propose_only: p.kind == PrincipalKind::Agent && !p.can_commit,
        };
        let deny = |mut d: Decision, rule: &str, why: String| {
            d.allowed = false;
            d.rule = rule.into();
            d.reasons.push(why);
            d
        };
        let Some(op) = req.op else { return deny(d, "operation", "no operation named".into()) };
        if let Some(need) = Self::permission(who, req) {
            if !who.has(need) {
                return deny(d, "permission", format!("{} needs {need}, which this credential doesn't carry", op.name()));
            }
        }
        if let Some(t) = &req.tenant {
            if *t != p.tenant {
                return deny(d, "tenant", format!("tenant {t} is not this principal's ({})", p.tenant));
            }
        }
        if let Some(s) = &req.subject {
            if !p.may_use_subject(s) {
                return deny(d, "subject", format!("subject {s} is outside this principal's subjects"));
            }
        }
        if !p.kinds.is_empty() {
            if let Some(k) = req.kinds.iter().find(|k| !p.kinds.contains(k)) {
                return deny(d, "kind", format!("kind {k} is not allowed for this principal"));
            }
        }
        if let Some(l) = req.labels.iter().find(|l| denied.contains(l)) {
            return deny(d, "label", format!("label {l} is denied to this principal"));
        }
        if let Some(u) = &req.user {
            if !admin && Some(u) != who.user.as_ref() {
                return deny(d, "user", format!("user {u} is not the verified user"));
            }
        }
        if let Some(s) = &req.scope {
            // A caller may narrow its scope, never point it at someone else's.
            let pairs =
                [("org", &s.org, &own.org), ("team", &s.team, &own.team), ("agent", &s.agent, &own.agent), ("user", &s.user, &own.user), ("session", &s.session, &own.session)];
            for (name, asked, mine) in pairs {
                match (asked, mine) {
                    (Some(a), Some(m)) if m == NOBODY => return deny(d, "scope", format!("scope.{name} {a} needs this caller to have a verified {name}")),
                    (Some(a), Some(m)) if a != m => return deny(d, "scope", format!("scope.{name} {a} is not this caller's ({m})")),
                    _ => {}
                }
            }
            if op.is_read() {
                d.scope = Scope {
                    org: s.org.clone().or(own.org),
                    team: s.team.clone().or(own.team),
                    agent: s.agent.clone().or(own.agent),
                    user: s.user.clone().or(own.user),
                    session: s.session.clone().or(own.session),
                };
            }
        }
        d.reasons.push(format!("{} may {} with {}", p.id, op.name(), Self::permission(who, req).unwrap_or("any credential")));
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::{Principal, Via};

    fn who(kind: PrincipalKind, scopes: &[&str]) -> Identity {
        let id = format!("{}:x", kind.as_str());
        let mut p = Principal::new(&id, "t1", kind, "test");
        p.subjects = vec!["customer:*".into()];
        let user = (kind == PrincipalKind::User).then(|| id.clone());
        Identity { principal: p, user, scopes: scopes.iter().map(|s| s.to_string()).collect(), key_id: None, expires_at: None, via: Via::Key }
    }

    async fn decide(w: &Identity, r: AccessRequest) -> Decision {
        let mut cfg = Config::default();
        cfg.governance.denied_labels = vec!["secret-plan".into()];
        cfg.access.denied_labels.agent = vec!["hr".into()];
        ScopeAuthorizer::new(&cfg).authorize(w, &r).await
    }

    #[tokio::test]
    async fn rules() {
        let agent = who(PrincipalKind::Agent, &[perm::READ, perm::WRITE]);
        let ok = decide(&agent, AccessRequest::new(Operation::Recall).subject("customer:1")).await;
        assert!(ok.allowed && ok.propose_only && ok.scope.agent.as_deref() == Some("agent:x"));
        assert_eq!(ok.denied_labels, vec!["hr", "secret-plan"]);
        let none = who(PrincipalKind::Agent, &[]);
        let d = decide(&none, AccessRequest::new(Operation::Recall).subject("customer:1")).await;
        assert!(!d.allowed && d.rule == "permission");
        let d = decide(&agent, AccessRequest::new(Operation::Recall).subject("user:ana")).await;
        assert!(!d.allowed && d.rule == "subject");
        let d = decide(&agent, AccessRequest::new(Operation::Recall).subject("customer:1").tenant(&Some("t2".into()))).await;
        assert!(!d.allowed && d.rule == "tenant");
        let mut r = AccessRequest::new(Operation::Remember).subject("customer:1");
        r.labels = vec!["hr".into()];
        assert_eq!(decide(&agent, r).await.rule, "label");
        let mut r = AccessRequest::new(Operation::Recall).subject("customer:1");
        r.scope = Some(Scope { agent: Some("agent:other".into()), ..Default::default() });
        assert_eq!(decide(&agent, r).await.rule, "scope");
        let mut r = AccessRequest::new(Operation::Remember).subject("customer:1");
        r.user = Some("user:ana".into());
        assert_eq!(decide(&agent, r).await.rule, "user");
        // Forgetting by user: one's own needs memory:forget, anyone else's memory:erase.
        let user = who(PrincipalKind::User, &[perm::FORGET]);
        let mut r = AccessRequest::new(Operation::Forget(ForgetScope::User));
        r.target = Some("user:x".into());
        assert!(decide(&user, r.clone()).await.allowed);
        r.target = Some("user:y".into());
        assert_eq!(decide(&user, r).await.rule, "permission");
        let admin = who(PrincipalKind::Admin, &perm::ALL);
        let mut r = AccessRequest::new(Operation::Recall).subject("customer:9");
        r.scope = Some(Scope { user: Some("user:ana".into()), ..Default::default() });
        let d = decide(&admin, r).await;
        assert!(d.allowed && !d.propose_only && d.scope.user.as_deref() == Some("user:ana"));
    }
}
