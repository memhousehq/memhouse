// SPDX-License-Identifier: Apache-2.0
//! A verified caller's view of the engine: the only way transports reach it (security baseline
//! rule 1). Every method asks the [`Authorizer`](crate::access::Authorizer) first, then runs the
//! operation with the decision's constraints injected: the principal's tenant, its verified user
//! and agent, its scope filter and its denied labels. Values the caller supplied for those are
//! checked, never trusted (GOV-02). A denial is audited (`access.denied`) and fails closed.

use crate::access::{AccessRequest, Decision, Operation};
use crate::config::Admission;
use crate::engine::{Engine, Entry, Page};
use crate::error;
use crate::identity::{perm, Identity, PrincipalKind, TokenResponse, Via};
use crate::policy::{Approver, Partition, TypeGate};
use crate::policy::{
    CompiledPolicy, PolicyDiff, PolicyDiffRequest, PolicySpec, PolicySpecRecord, PolicySpecRequest, PolicyStatus, PolicyTarget, PolicyValidation, RollbackRequest,
};
use crate::types::*;
use serde_json::json;
use uuid::Uuid;

pub struct Caller {
    pub engine: Engine,
    pub who: Identity,
}

impl Caller {
    fn tenant(&self) -> &str {
        &self.who.principal.tenant
    }

    /// Ask the authorizer; audit and refuse a denial.
    #[tracing::instrument(name = "memhouse.authorize", skip_all, fields(memhouse.principal = %self.who.id(), memhouse.op = tracing::field::Empty, memhouse.rule = tracing::field::Empty, memhouse.allowed = tracing::field::Empty))]
    pub async fn decide(&self, req: &AccessRequest) -> anyhow::Result<Decision> {
        let d = self.engine.authorizer.authorize(&self.who, req).await;
        let span = tracing::Span::current();
        span.record("memhouse.op", req.op.map(|o| o.name()).unwrap_or_default().as_str());
        span.record("memhouse.rule", d.rule.as_str());
        span.record("memhouse.allowed", d.allowed);
        if !d.allowed {
            self.denied(req, &d).await;
            return Err(error::forbidden(d.reasons.join("; ")));
        }
        self.with_policy(req, d).await
    }

    /// The tenant's policy narrows a decision further (G08): labels it denies are neither written
    /// nor read.
    async fn with_policy(&self, req: &AccessRequest, mut d: Decision) -> anyhow::Result<Decision> {
        let policy = self.engine.policy_for(&d.tenant).await?;
        if let Some(l) = req.labels.iter().find(|l| policy.policy.recall.denied_labels.contains(l)) {
            d.allowed = false;
            d.rule = "policy".into();
            d.reasons.push(format!("label {l} is denied by policy {}", policy.version));
            tracing::Span::current().record("memhouse.rule", "policy");
            tracing::Span::current().record("memhouse.allowed", false);
            self.denied(req, &d).await;
            return Err(error::forbidden(d.reasons.join("; ")));
        }
        d.denied_labels = crate::engine::with_policy_labels(&d.denied_labels, &policy);
        Ok(d)
    }

    /// The tenant's policies (G08).
    pub async fn policy_status(&self) -> anyhow::Result<PolicyStatus> {
        self.decide(&AccessRequest::new(Operation::PolicyRead)).await?;
        self.engine.policy_status(self.tenant()).await
    }

    pub async fn policy_validate(&self, spec: &PolicySpec) -> anyhow::Result<PolicyValidation> {
        self.decide(&AccessRequest::new(Operation::PolicyRead)).await?;
        Ok(PolicyValidation::of(self.engine.policy_validate(self.tenant(), spec)))
    }

    pub async fn policy_diff(&self, req: &PolicyDiffRequest) -> anyhow::Result<PolicyDiff> {
        self.decide(&AccessRequest::new(Operation::PolicyRead)).await?;
        self.engine.policy_diff(self.tenant(), req).await
    }

    /// Propose a spec; the caller is recorded as proposer.
    pub async fn policy_propose(&self, req: &PolicySpecRequest) -> anyhow::Result<PolicySpecRecord> {
        self.decide(&AccessRequest::new(Operation::PolicyPropose)).await?;
        self.engine.policy_propose(self.tenant(), &req.spec, self.who.id(), req.note.as_deref()).await
    }

    /// Approve a proposed version; the caller is the named approver.
    pub async fn policy_approve(&self, version: u32) -> anyhow::Result<CompiledPolicy> {
        self.decide(&AccessRequest::new(Operation::PolicyApprove)).await?;
        self.engine.policy_approve(self.tenant(), version, self.who.id()).await
    }

    pub async fn policy_rollback(&self, req: &RollbackRequest) -> anyhow::Result<CompiledPolicy> {
        self.decide(&AccessRequest::new(Operation::PolicyApprove)).await?;
        let to = req.to.as_deref().map(PolicyTarget::parse).transpose()?;
        self.engine.policy_rollback(self.tenant(), to, self.who.id()).await
    }

    async fn denied(&self, req: &AccessRequest, d: &Decision) {
        crate::metrics::inc("memhouse_refused_total", &[("kind", "access"), ("reason", d.rule.as_str())], 1.0);
        let detail = json!({ "op": req.op.map(|o| o.name()), "rule": d.rule, "reasons": d.reasons, "key": self.who.key_id, "authorizer": self.engine.authorizer.name() });
        if let Err(e) = self.engine.store.audit(self.who.id(), "access.denied", self.tenant(), req.subject.as_deref(), None, detail).await {
            tracing::error!("audit of a denial failed: {e:#}");
        }
    }

    /// A record the caller may see, or `not_found` (a hidden record is never confirmed to exist).
    async fn visible(&self, op: Operation, id: Uuid) -> anyhow::Result<(Memory, Decision)> {
        let missing = || error::not_found(format!("memory {id} not found"));
        // Permission first, so a credential that may not do this learns nothing about the id.
        self.decide(&AccessRequest::new(op)).await?;
        // A write still in the intake queue reads as a candidate (CORE-02).
        let m = self.engine.get_record(self.tenant(), id).await?.ok_or_else(missing)?;
        let mut req = AccessRequest::new(op).record(&m);
        req.own_partition = self.own(&m);
        // A record of another agent that was shared with this one (INT-06) is read as shared,
        // not as a claim to that agent's scope. Reads only: a grant gives nothing else.
        let shared =
            if op.is_read() && self.who.principal.kind == PrincipalKind::Agent { self.engine.shared_agents(self.tenant(), self.who.id(), &m.subject).await? } else { vec![] };
        if let Some(agent) = m.scope.agent.as_deref().filter(|a| shared.contains(&shared_key(a, None)) || shared.contains(&shared_key(a, Some(m.kind)))) {
            if let Some(s) = req.scope.as_mut().filter(|s| s.agent.as_deref() == Some(agent)) {
                s.agent = None;
            }
        }
        let d = self.engine.authorizer.authorize(&self.who, &req).await;
        if !d.allowed {
            self.denied(&req, &d).await;
            // Missing permission is no secret; subject, label, kind and scope rules are.
            return Err(if d.rule == "permission" { error::forbidden(d.reasons.join("; ")) } else { missing() });
        }
        let mut d = self.with_policy(&AccessRequest::new(op), d).await?;
        d.shared_agents = shared;
        if !d.visible(&m) {
            return Err(missing());
        }
        Ok((m, d))
    }

    /// A record in the caller's own partition that the caller wrote (ACC-10): the id a write
    /// returned stays readable, revisable and forgettable by its author.
    fn own(&self, m: &Memory) -> bool {
        self.who.user.as_ref().is_some_and(|u| *u == m.subject && m.provenance.user.as_ref() == Some(u))
    }

    /// Reads by an agent also return what other agents shared with it (INT-06).
    async fn with_grants(&self, d: &mut Decision, subject: &str) -> anyhow::Result<()> {
        if self.who.principal.kind == PrincipalKind::Agent {
            d.shared_agents = self.engine.shared_agents(&d.tenant, self.who.id(), subject).await?;
        }
        Ok(())
    }

    /// How a write of a kind enters (MEM-01): the type's gate decides who commits, and the
    /// tenant's policy whether ordinary proposals wait for review.
    async fn entry(&self, d: &Decision, kind: MemoryKind) -> anyhow::Result<Entry> {
        let policy = self.engine.policy_for(&d.tenant).await?;
        let rules = policy.of(kind);
        let proposed = match policy.policy.write_gate.admission {
            Admission::Auto => Entry::ProposeAdmit,
            Admission::Review => Entry::Propose,
        };
        Ok(match rules.gate {
            // Committed as written or on a verified source: nothing for a reviewer to judge.
            TypeGate::None | TypeGate::Source => {
                if d.propose_only {
                    Entry::ProposeAdmit
                } else {
                    Entry::Commit
                }
            }
            TypeGate::Full | TypeGate::Explicit => {
                if d.propose_only {
                    proposed
                } else {
                    Entry::Commit
                }
            }
            // A proposal waits for explicit confirmation, whatever the admission setting (MEM-02).
            TypeGate::Confirmation => {
                if d.propose_only {
                    Entry::Propose
                } else {
                    Entry::Commit
                }
            }
            // Only the type's approver commits; everyone else proposes (MEM-03).
            TypeGate::Approval => {
                if self.approves(rules.access.approver) {
                    Entry::Commit
                } else {
                    Entry::Propose
                }
            }
        })
    }

    fn approves(&self, approver: Approver) -> bool {
        self.who.has(perm::REVIEW) && (approver == Approver::Reviewer || self.who.is_admin())
    }

    /// An agent's writes of a type that is private to its agent are scoped to it (INT-06).
    fn agent_private(&self, policy: &CompiledPolicy, kind: MemoryKind, scope: &mut Option<Scope>) {
        if policy.of(kind).access.agent_private && self.who.principal.kind == PrincipalKind::Agent {
            let s = scope.get_or_insert_with(Scope::default);
            if s.agent.is_none() {
                s.agent = Some(self.who.id().to_string());
            }
        }
    }

    pub async fn remember(&self, mut req: RememberRequest) -> anyhow::Result<RememberResult> {
        let kind = req.kind.unwrap_or(MemoryKind::Semantic);
        let policy = self.engine.policy_for(self.tenant()).await?;
        let mut subject = self.engine.subject(&req.subject);
        let mut a = AccessRequest::new(Operation::Remember);
        // ACC-10: a type kept in its author's partition is stored with the verified user it is
        // written for, whatever subject the request named; the author is on the record either way.
        if policy.of(kind).access.partition == Partition::Author && req.supersedes.is_none() {
            if let Some(u) = &self.who.user {
                subject = u.clone();
                a.own_partition = true;
            }
        }
        self.agent_private(&policy, kind, &mut req.scope);
        let mut a = a.subject(&subject).tenant(&req.tenant);
        a.kinds = vec![kind];
        a.labels = req.labels.clone();
        a.scope = req.scope.clone();
        a.user = req.user.clone();
        let d = self.decide(&a).await?;
        if let Some(old) = req.supersedes {
            let (m, _) = self.visible(Operation::Revise, old).await?;
            if m.subject != subject {
                return Err(error::invalid("supersedes names a memory of another subject"));
            }
        }
        req.tenant = Some(d.tenant.clone());
        req.subject = Some(subject);
        req.actor = Some(self.who.id().into());
        req.user = self.who.user.clone();
        self.engine.remember_with(req, self.entry(&d, kind).await?).await
    }

    /// Promote records to another type (MEM-05): the caller must see every source and may write
    /// the target type, with the sources' labels, at the target scope.
    pub async fn promote(&self, mut req: PromoteRequest) -> anyhow::Result<RememberResult> {
        let kind = req.kind;
        if req.sources.is_empty() || req.sources.len() > crate::promote::MAX_SOURCES {
            return Err(error::invalid(format!("a promotion names 1 to {} source records", crate::promote::MAX_SOURCES)));
        }
        let mut sources = Vec::with_capacity(req.sources.len());
        for id in &req.sources {
            sources.push(self.visible(Operation::Promote, *id).await?.0);
        }
        let policy = self.engine.policy_for(self.tenant()).await?;
        // ACC-10: a type kept in its author's partition is not promoted into another subject's.
        if policy.of(kind).access.partition == Partition::Author {
            if let Some(u) = self.who.user.as_ref().filter(|u| **u != sources[0].subject) {
                return Err(error::invalid(format!("{kind} memory is kept in its author's partition ({u}); a promotion stays in its sources' subject, so write it with remember")));
            }
        }
        let mut scope = match req.scope.take() {
            Some(s) => Some(s),
            None => Some(Engine::promotion_scope(&sources)?).filter(|s| !s.is_empty()),
        };
        self.agent_private(&policy, kind, &mut scope);
        let mut a = AccessRequest::new(Operation::Promote).subject(&sources[0].subject).tenant(&req.tenant);
        a.kinds = vec![kind];
        a.labels = sources.iter().flat_map(|m| m.labels.iter().cloned()).chain(req.labels.iter().cloned()).collect();
        a.scope = scope.clone();
        a.user = req.user.clone();
        let d = self.decide(&a).await?;
        req.tenant = Some(d.tenant.clone());
        req.scope = Some(scope.unwrap_or_default());
        req.actor = Some(self.who.id().into());
        req.user = self.who.user.clone();
        self.engine.promote_with(req, self.entry(&d, kind).await?).await
    }

    /// The preferences of a subject as they apply to the caller (MEM-04): per key, the one at the
    /// narrowest scope the caller is in. `session` adds that session's own preferences.
    pub async fn preferences(&self, subject: &str, key: Option<&str>, session: Option<String>) -> anyhow::Result<Vec<EffectivePreference>> {
        let mut a = AccessRequest::new(Operation::Recall).subject(subject);
        a.kinds = vec![MemoryKind::Preference];
        a.scope = session.map(|s| Scope { session: Some(s), ..Default::default() });
        let mut d = self.decide(&a).await?;
        self.with_grants(&mut d, subject).await?;
        let reader = crate::preference::Reader { scope: &d.scope, denied_labels: &d.denied_labels, shared_agents: &d.shared_agents };
        self.engine.effective_preferences(&d.tenant, subject, key, &reader).await
    }

    /// Share one agent's agent-scoped memory with another (INT-06).
    pub async fn grant_create(&self, req: &GrantRequest) -> anyhow::Result<Grant> {
        self.decide(&AccessRequest::new(Operation::GrantManage)).await?;
        self.engine.grant_create(self.tenant(), req, self.who.id()).await
    }

    pub async fn grants(&self) -> anyhow::Result<Vec<Grant>> {
        self.decide(&AccessRequest::new(Operation::GrantManage)).await?;
        self.engine.grant_list(self.tenant()).await
    }

    pub async fn grant_revoke(&self, id: Uuid) -> anyhow::Result<()> {
        self.decide(&AccessRequest::new(Operation::GrantManage)).await?;
        self.engine.grant_revoke(self.tenant(), id, self.who.id()).await
    }

    pub async fn revise(&self, mut req: ReviseRequest) -> anyhow::Result<RememberResult> {
        let (old, _) = self.visible(Operation::Revise, req.id).await?;
        let kind = req.kind.unwrap_or(old.kind);
        // A scope given with the revision is completed like a new write's: an agent's revision of
        // an agent-private type stays the agent's. Without one the old scope is inherited.
        if req.scope.is_some() {
            let policy = self.engine.policy_for(self.tenant()).await?;
            self.agent_private(&policy, kind, &mut req.scope);
        }
        let mut a = AccessRequest::new(Operation::Revise).record(&old).tenant(&req.tenant);
        a.own_partition = self.own(&old);
        a.kinds = vec![kind];
        a.labels = req.labels.clone().unwrap_or(old.labels.clone());
        if let Some(s) = &req.scope {
            a.scope = Some(s.clone());
        }
        a.user = req.user.clone();
        let d = self.decide(&a).await?;
        req.tenant = Some(d.tenant.clone());
        req.actor = Some(self.who.id().into());
        req.user = self.who.user.clone();
        self.engine.revise_with(req, self.entry(&d, kind).await?).await
    }

    pub async fn ingest(&self, mut req: IngestRequest) -> anyhow::Result<IngestResult> {
        let subject = self.engine.subject(&req.subject);
        let policy = self.engine.policy_for(self.tenant()).await?;
        self.agent_private(&policy, MemoryKind::Episodic, &mut req.scope);
        let mut a = AccessRequest::new(Operation::Ingest).subject(&subject).tenant(&req.tenant);
        a.kinds = vec![MemoryKind::Episodic];
        a.labels = req.labels.clone();
        a.scope = req.scope.clone();
        a.user = req.user.clone();
        let d = self.decide(&a).await?;
        req.tenant = Some(d.tenant.clone());
        req.subject = Some(subject);
        req.actor = Some(self.who.id().into());
        req.user = self.who.user.clone();
        // The episodic gate decides, like any type's: under its own gate (`source`) rounds are
        // admitted by the engine; a tenant that raised it to confirmation or approval gets review.
        let entry = self.entry(&d, MemoryKind::Episodic).await?;
        self.engine.ingest_with(req, entry).await
    }

    pub async fn recall(&self, mut req: RecallRequest) -> anyhow::Result<RecallResult> {
        let subject = self.engine.subject(&req.subject);
        let mut a = AccessRequest::new(Operation::Recall).subject(&subject).tenant(&req.tenant);
        a.kinds = req.kinds.clone().unwrap_or_default();
        a.scope = req.scope.clone();
        let mut d = self.decide(&a).await?;
        self.with_grants(&mut d, &subject).await?;
        req.tenant = Some(d.tenant.clone());
        req.subject = Some(subject);
        req.scope = Some(d.scope.clone()).filter(|s| !s.is_empty());
        if req.kinds.is_none() && !d.kinds.is_empty() {
            req.kinds = Some(d.kinds.clone());
        }
        req.actor = Some(self.who.id().into());
        let ctx = crate::engine::RecallContext {
            principal: self.who.id().into(),
            user: self.who.user.clone(),
            denied_labels: d.denied_labels,
            authorizer: self.engine.authorizer.name().into(),
            shared_agents: d.shared_agents,
        };
        self.engine.recall_with(req, ctx).await
    }

    /// A recall's explanation (GOV-04), for the principal that recalled or an auditor. Others get
    /// `not_found`; exclusions for state, access and labels are listed by id only to auditors.
    pub async fn explain(&self, id: Uuid) -> anyhow::Result<RecallExplanation> {
        self.decide(&AccessRequest::new(Operation::Explain)).await?;
        let auditor = self.who.has(perm::AUDIT);
        let missing = || error::not_found(format!("recall {id} not found"));
        let record = self.engine.recall_record(self.tenant(), id).await?.ok_or_else(missing)?;
        if record.principal != self.who.id() && !auditor {
            return Err(missing());
        }
        self.engine.explain(record, auditor).await
    }

    pub async fn get(&self, id: Uuid) -> anyhow::Result<Memory> {
        Ok(self.visible(Operation::Get, id).await?.0)
    }

    pub async fn list(&self, subject: String, kinds: Option<Vec<MemoryKind>>, include_inactive: bool, limit: usize, cursor: Option<&str>) -> anyhow::Result<MemoryPage> {
        let mut a = AccessRequest::new(Operation::List).subject(&subject);
        a.kinds = kinds.clone().unwrap_or_default();
        let mut d = self.decide(&a).await?;
        self.with_grants(&mut d, &subject).await?;
        let kinds = kinds.or_else(|| Some(d.kinds.clone()).filter(|k| !k.is_empty()));
        let page = Page { kinds, include_inactive, limit, denied_labels: d.denied_labels.clone(), scope: d.scope.clone(), shared_agents: d.shared_agents.clone() };
        self.engine.list_page_with(Some(d.tenant), subject, page, cursor).await
    }

    /// The pre-v1 list: offset paging; without a subject, over every subject (only for a caller
    /// whose subjects are `*`).
    pub async fn list_offset(&self, subject: Option<String>, kinds: Option<Vec<MemoryKind>>, include_inactive: bool, limit: usize, offset: usize) -> anyhow::Result<Vec<Memory>> {
        let mut a = AccessRequest::new(Operation::List);
        a.subject = Some(subject.clone().unwrap_or_else(|| "*".into()));
        a.kinds = kinds.clone().unwrap_or_default();
        let mut d = self.decide(&a).await?;
        if let Some(s) = &subject {
            self.with_grants(&mut d, s).await?;
        }
        let q = ListQuery {
            tenant: d.tenant.clone(),
            subject,
            kinds: kinds.or_else(|| Some(d.kinds.clone()).filter(|k| !k.is_empty())),
            include_inactive,
            limit: limit.clamp(1, 1000),
            offset,
            before: None,
            denied_labels: d.denied_labels.clone(),
            scope: d.scope.clone(),
            shared_agents: d.shared_agents.clone(),
            session: None,
        };
        self.engine.store.list(&q).await
    }

    pub async fn forget(&self, mut req: ForgetRequest) -> anyhow::Result<ForgetResult> {
        let named: Vec<(ForgetScope, Option<String>)> = [
            req.id.map(|i| (ForgetScope::Record, Some(i.to_string()))),
            req.subject.clone().map(|s| (ForgetScope::Subject, Some(s))),
            req.user.clone().map(|u| (ForgetScope::User, Some(u))),
            req.agent.clone().map(|a| (ForgetScope::Agent, Some(a))),
            req.source.clone().map(|s| (ForgetScope::Source, Some(s))),
            req.all.then_some((ForgetScope::Tenant, None)),
        ]
        .into_iter()
        .flatten()
        .collect();
        let [(scope, target)] = named.as_slice() else {
            return Err(error::invalid("forget needs exactly one of id, subject, user, agent, source or all"));
        };
        let mut a = AccessRequest::new(Operation::Forget(*scope)).tenant(&req.tenant);
        a.target = target.clone();
        match scope {
            ForgetScope::Record => {
                let id = req.id.expect("named");
                match self.visible(Operation::Forget(ForgetScope::Record), id).await {
                    Ok((m, _)) => {
                        a.own_partition = self.own(&m);
                        a = a.record(&m);
                    }
                    // A keyed retry of a forget that succeeded finds the record gone: the engine
                    // answers it from the stored response (or with `not_found`).
                    Err(e) if req.request_key.is_some() && error::code_of(&e) == error::ErrorCode::NotFound => {}
                    Err(e) => return Err(e),
                }
            }
            ForgetScope::Subject => a.subject = target.clone(),
            _ => {}
        }
        let d = self.decide(&a).await?;
        req.tenant = Some(d.tenant);
        req.actor = Some(self.who.id().into());
        self.engine.forget_by(req).await
    }

    pub async fn relabel(&self, req: RelabelRequest) -> anyhow::Result<Memory> {
        let (m, _) = self.visible(Operation::Relabel, req.id).await?;
        let mut a = AccessRequest::new(Operation::Relabel).record(&m);
        a.labels = m.labels.iter().chain(&req.labels).cloned().collect();
        self.decide(&a).await?;
        let mut labels = req.labels.clone();
        labels.sort();
        labels.dedup();
        if labels.iter().any(|l| l.trim().is_empty() || l.len() > 80) {
            return Err(error::invalid("labels must be 1 to 80 characters"));
        }
        self.engine.store.set_labels(self.tenant(), m.id, &labels).await?;
        self.engine.working.drop_record(m.id);
        self.engine.store.audit(self.who.id(), "memory.relabel", self.tenant(), Some(&m.subject), Some(m.id), json!({ "from": m.labels, "to": labels })).await?;
        self.engine.store.get(self.tenant(), m.id).await?.ok_or_else(|| error::not_found(format!("memory {} not found", m.id)))
    }

    pub async fn review(&self, req: ReviewRequest) -> anyhow::Result<ReviewResult> {
        let (m, _) = self.visible(Operation::Review, req.id).await?;
        let a = AccessRequest::new(Operation::Review).record(&m);
        let mut d = self.decide(&a).await?;
        // The type says who settles its candidates: taxonomic terms are an administrator's (MEM-03).
        let approver = self.engine.policy_for(&d.tenant).await?.of(m.kind).access.approver;
        if !self.approves(approver) {
            d.allowed = false;
            d.rule = "approver".into();
            d.reasons = vec![format!("{} memory is approved by an administrator", m.kind)];
            self.denied(&a, &d).await;
            return Err(error::forbidden(d.reasons.join("; ")));
        }
        let (status, superseded) = match req.action {
            ReviewAction::Commit => self.engine.admit(self.tenant(), m.id, self.who.id()).await?,
            ReviewAction::Reject => (self.engine.reject(self.tenant(), m.id, self.who.id(), req.reason.as_deref().unwrap_or("rejected by a reviewer")).await?, None),
        };
        Ok(ReviewResult { id: m.id, status, superseded })
    }

    /// Issue a short-lived agent token (GOV-13). The token's user is verified: the calling user
    /// itself, or one named by an admin or by an agent trusted to act for users.
    pub async fn issue_token(&self, req: TokenRequest) -> anyhow::Result<TokenResponse> {
        self.decide(&AccessRequest::new(Operation::IssueToken)).await?;
        let p = &self.who.principal;
        let agent = match (p.kind, &req.agent) {
            (PrincipalKind::Agent, None) => p.clone(),
            (PrincipalKind::Agent, Some(a)) if *a == p.id => p.clone(),
            (PrincipalKind::Agent, Some(a)) => return Err(error::forbidden(format!("an agent can only get tokens for itself, not {a}"))),
            (_, None) => return Err(error::invalid("name the agent the token is for")),
            (_, Some(a)) => match self.engine.store.principal_get(a).await? {
                Some(ag) if ag.kind == PrincipalKind::Agent && ag.tenant == p.tenant && ag.disabled_at.is_none() => ag,
                _ => return Err(error::not_found(format!("no active agent {a} in this tenant"))),
            },
        };
        let user = match (p.kind, &req.user) {
            (PrincipalKind::User, Some(u)) if Some(u) != self.who.user.as_ref() => return Err(error::forbidden("a user's token acts for that user only")),
            (PrincipalKind::User, _) => self.who.user.clone(),
            (PrincipalKind::Admin, u) => u.clone().or(self.who.user.clone()),
            (PrincipalKind::Agent, Some(u)) if p.act_as || self.who.user.as_ref() == Some(u) => Some(u.clone()),
            (PrincipalKind::Agent, Some(_)) => return Err(error::forbidden("this agent may not state which user it acts for (act_as)")),
            (PrincipalKind::Agent, None) => self.who.user.clone(),
        };
        // A token carries at most what both the caller and the agent's role allow, and can't
        // issue further tokens.
        let passable: Vec<String> = self.who.scopes.iter().filter(|s| agent.kind.permissions().contains(s) && s.as_str() != perm::TOKEN).cloned().collect();
        let scopes = match req.scopes {
            None => passable,
            Some(asked) => {
                if let Some(s) = asked.iter().find(|s| !passable.contains(s)) {
                    return Err(error::forbidden(format!("permission {s} can't be passed to this token")));
                }
                asked
            }
        };
        let issuing = self.who.key_id.clone().ok_or_else(|| error::forbidden("this credential can't issue tokens"))?;
        let ttl = req.ttl_secs.unwrap_or(self.engine.cfg.access.token_ttl_secs);
        let t = self.engine.auth.sign(&agent, user, scopes, &issuing, ttl).await?;
        self.engine
            .store
            .audit(
                self.who.id(),
                "token.issue",
                self.tenant(),
                None,
                None,
                json!({ "agent": t.agent, "user": t.user, "scopes": t.scopes, "expires_at": t.expires_at, "key": issuing }),
            )
            .await?;
        Ok(t)
    }

    pub async fn whoami(&self) -> anyhow::Result<WhoAmI> {
        let d = self.decide(&AccessRequest::new(Operation::Whoami)).await?;
        let p = &self.who.principal;
        let via = match self.who.via {
            Via::Key => "key",
            Via::Token => "token",
            Via::Bootstrap => "bootstrap",
            Via::Operator => "operator",
        };
        Ok(WhoAmI {
            principal: p.id.clone(),
            kind: p.kind.as_str().into(),
            tenant: p.tenant.clone(),
            user: self.who.user.clone(),
            scopes: self.who.scopes.clone(),
            subjects: p.subjects.clone(),
            denied_labels: d.denied_labels,
            propose_only: d.propose_only,
            scope: {
                let own = |v: &Option<String>| v.clone().filter(|x| x != crate::access::NOBODY);
                Scope { org: own(&d.scope.org), team: own(&d.scope.team), agent: own(&d.scope.agent), user: own(&d.scope.user), session: None }
            },
            via: via.into(),
            expires_at: self.who.expires_at,
        })
    }

    pub async fn stats(&self) -> anyhow::Result<Stats> {
        self.decide(&AccessRequest::new(Operation::Stats)).await?;
        self.engine.store.stats(self.tenant()).await
    }

    pub async fn subjects(&self) -> anyhow::Result<Vec<(String, i64)>> {
        self.decide(&AccessRequest::new(Operation::Subjects)).await?;
        let all = self.engine.store.subjects(self.tenant(), 500).await?;
        Ok(all.into_iter().filter(|(s, _)| self.who.principal.may_use_subject(s)).collect())
    }

    pub async fn audit_log(&self, limit: usize) -> anyhow::Result<Vec<AuditEvent>> {
        self.decide(&AccessRequest::new(Operation::Audit)).await?;
        self.engine.store.audit_log(self.tenant(), limit).await
    }

    pub async fn enrich_status(&self) -> anyhow::Result<EnrichStatus> {
        self.decide(&AccessRequest::new(Operation::EnrichStatus)).await?;
        self.engine.store.enrich_status(self.tenant(), None).await
    }
}
