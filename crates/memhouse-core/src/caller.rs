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
        Ok(d)
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
        let m = self.engine.store.get(self.tenant(), id).await?.ok_or_else(missing)?;
        let req = AccessRequest::new(op).record(&m);
        let d = self.engine.authorizer.authorize(&self.who, &req).await;
        if !d.allowed {
            self.denied(&req, &d).await;
            // Missing permission is no secret; subject, label, kind and scope rules are.
            return Err(if d.rule == "permission" { error::forbidden(d.reasons.join("; ")) } else { missing() });
        }
        if !d.visible(&m) {
            return Err(missing());
        }
        Ok((m, d))
    }

    fn entry(&self, d: &Decision) -> Entry {
        match (d.propose_only, self.engine.cfg.access.admission) {
            (false, _) => Entry::Commit,
            (true, Admission::Auto) => Entry::ProposeAdmit,
            (true, Admission::Review) => Entry::Propose,
        }
    }

    pub async fn remember(&self, mut req: RememberRequest) -> anyhow::Result<RememberResult> {
        let subject = self.engine.subject(&req.subject);
        let mut a = AccessRequest::new(Operation::Remember).subject(&subject).tenant(&req.tenant);
        a.kinds = vec![req.kind.unwrap_or(MemoryKind::Semantic)];
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
        self.engine.remember_with(req, self.entry(&d)).await
    }

    pub async fn revise(&self, mut req: ReviseRequest) -> anyhow::Result<RememberResult> {
        let (old, _) = self.visible(Operation::Revise, req.id).await?;
        let mut a = AccessRequest::new(Operation::Revise).record(&old).tenant(&req.tenant);
        a.kinds = vec![req.kind.unwrap_or(old.kind)];
        a.labels = req.labels.clone().unwrap_or(old.labels.clone());
        if let Some(s) = &req.scope {
            a.scope = Some(s.clone());
        }
        a.user = req.user.clone();
        let d = self.decide(&a).await?;
        req.tenant = Some(d.tenant.clone());
        req.actor = Some(self.who.id().into());
        req.user = self.who.user.clone();
        self.engine.revise_with(req, self.entry(&d)).await
    }

    pub async fn ingest(&self, mut req: IngestRequest) -> anyhow::Result<IngestResult> {
        let subject = self.engine.subject(&req.subject);
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
        self.engine.ingest_with(req, if d.propose_only { Entry::Propose } else { Entry::Commit }).await
    }

    pub async fn recall(&self, mut req: RecallRequest) -> anyhow::Result<RecallResult> {
        let subject = self.engine.subject(&req.subject);
        let mut a = AccessRequest::new(Operation::Recall).subject(&subject).tenant(&req.tenant);
        a.kinds = req.kinds.clone().unwrap_or_default();
        a.scope = req.scope.clone();
        let d = self.decide(&a).await?;
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
        let d = self.decide(&a).await?;
        let kinds = kinds.or_else(|| Some(d.kinds.clone()).filter(|k| !k.is_empty()));
        let page = Page { kinds, include_inactive, limit, denied_labels: d.denied_labels.clone(), scope: d.scope.clone() };
        self.engine.list_page_with(Some(d.tenant), subject, page, cursor).await
    }

    /// The pre-v1 list: offset paging; without a subject, over every subject (only for a caller
    /// whose subjects are `*`).
    pub async fn list_offset(&self, subject: Option<String>, kinds: Option<Vec<MemoryKind>>, include_inactive: bool, limit: usize, offset: usize) -> anyhow::Result<Vec<Memory>> {
        let mut a = AccessRequest::new(Operation::List);
        a.subject = Some(subject.clone().unwrap_or_else(|| "*".into()));
        a.kinds = kinds.clone().unwrap_or_default();
        let d = self.decide(&a).await?;
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
                    Ok((m, _)) => a = a.record(&m),
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
        self.engine.store.audit(self.who.id(), "memory.relabel", self.tenant(), Some(&m.subject), Some(m.id), json!({ "from": m.labels, "to": labels })).await?;
        self.engine.store.get(self.tenant(), m.id).await?.ok_or_else(|| error::not_found(format!("memory {} not found", m.id)))
    }

    pub async fn review(&self, req: ReviewRequest) -> anyhow::Result<ReviewResult> {
        let (m, _) = self.visible(Operation::Review, req.id).await?;
        self.decide(&AccessRequest::new(Operation::Review).record(&m)).await?;
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
