// SPDX-License-Identifier: Apache-2.0
//! The authorizer kit: what every authorizer must do whatever its rules are. It must fail
//! closed (PR-5): what it cannot decide, it denies.

use crate::{unless, Report};
use memhouse_core::access::{AccessRequest, Authorizer, Decision, Operation};
use memhouse_core::identity::{perm, Identity, Principal, PrincipalKind, Via};
use memhouse_core::types::{ForgetScope, Scope};

const TENANT: &str = "kit-tenant";

fn identity(kind: PrincipalKind, id: &str, scopes: &[&str]) -> Identity {
    let mut p = Principal::new(id, TENANT, kind, "conformance");
    p.subjects = vec!["kit:*".into()];
    Identity {
        principal: p,
        user: Some("user:kit-ana".into()),
        scopes: scopes.iter().map(|s| s.to_string()).collect(),
        key_id: Some("kit-key".into()),
        expires_at: None,
        via: Via::Key,
    }
}

fn request(op: Operation) -> AccessRequest {
    AccessRequest::new(op).subject("kit:case-1")
}

fn says(d: &Decision) -> String {
    format!("allowed: {}, rule {:?}, tenant {:?}", d.allowed, d.rule, d.tenant)
}

/// The authorizer contract. The kit builds its own principals in the tenant `kit-tenant`,
/// allowed the subjects `kit:*`; an authorizer that needs stored relationships must allow
/// those for the agent `agent:kit` and the user `user:kit-ana` before it is run.
pub async fn run_authorizer_kit(a: &dyn Authorizer) -> Report {
    let mut r = Report::new("authorizer", a.name());
    let agent = identity(PrincipalKind::Agent, "agent:kit", &[perm::READ, perm::WRITE, perm::FORGET]);
    let ops = [Operation::Recall, Operation::Get, Operation::List, Operation::Remember, Operation::Revise, Operation::Ingest, Operation::Forget(ForgetScope::Record)];

    let read = a.authorize(&agent, &request(Operation::Recall)).await;
    r.check("allows_what_it_grants", "an agent with read permission, in its tenant and subjects, may recall", unless(read.allowed, || says(&read)));

    let d = a.authorize(&agent, &AccessRequest { op: None, ..request(Operation::Recall) }).await;
    r.check("no_operation_is_denied", "a request that names no operation is denied", unless(!d.allowed, || says(&d)));

    let nothing = identity(PrincipalKind::Agent, "agent:kit", &[]);
    let mut leaked = vec![];
    for op in ops {
        if a.authorize(&nothing, &request(op)).await.allowed {
            leaked.push(op.name().to_string());
        }
    }
    r.check(
        "no_permission_no_access",
        "a credential that carries no permission is denied every memory operation",
        unless(leaked.is_empty(), || format!("allowed: {}", leaked.join(", "))),
    );

    let read_only = identity(PrincipalKind::Agent, "agent:kit", &[perm::READ]);
    let mut wrote = vec![];
    for op in ops.iter().filter(|o| o.is_write() || matches!(o, Operation::Forget(_))) {
        if a.authorize(&read_only, &request(*op)).await.allowed {
            wrote.push(op.name().to_string());
        }
    }
    r.check("read_permission_does_not_write", "a read-only credential may not write or forget", unless(wrote.is_empty(), || format!("allowed: {}", wrote.join(", "))));

    let other = Some("another-tenant".to_string());
    let mut crossed = vec![];
    for op in ops {
        let d = a.authorize(&agent, &request(op).tenant(&other)).await;
        if d.allowed || d.tenant != TENANT {
            crossed.push(format!("{} ({})", op.name(), says(&d)));
        }
    }
    r.check(
        "another_tenant_is_denied",
        "a request that names another tenant is denied, and a decision's tenant is always the principal's own",
        unless(crossed.is_empty(), || crossed.join("; ")),
    );
    r.check("decision_names_the_principals_tenant", "an allowed decision runs in the principal's tenant", unless(read.tenant == TENANT, || says(&read)));

    let d = a.authorize(&agent, &AccessRequest::new(Operation::Recall).subject("payroll:everyone")).await;
    r.check("outside_subjects_is_denied", "a subject outside the principal's subjects is denied", unless(!d.allowed, || says(&d)));

    let mut limited = identity(PrincipalKind::Agent, "agent:kit", &[perm::READ, perm::WRITE]);
    limited.principal.denied_labels = vec!["kit-secret".into()];
    let d = a.authorize(&limited, &request(Operation::Recall)).await;
    r.check(
        "denied_labels_reach_the_decision",
        "labels a principal may never read are in the decision's denied labels (or the read is denied)",
        unless(!d.allowed || d.denied_labels.iter().any(|l| l == "kit-secret"), || format!("allowed with denied labels {:?}", d.denied_labels)),
    );
    let d = a.authorize(&limited, &AccessRequest { labels: vec!["kit-secret".into()], ..request(Operation::Remember) }).await;
    r.check("denied_label_is_not_written", "a write that carries a label the principal is denied is refused", unless(!d.allowed, || says(&d)));

    // A caller cannot widen its own scope by naming someone else's in the request.
    let asked = Scope { user: Some("user:kit-someone-else".into()), agent: Some("agent:kit-someone-else".into()), ..Default::default() };
    let d = a.authorize(&agent, &AccessRequest { scope: Some(asked), ..request(Operation::Recall) }).await;
    let widened = d.allowed && (d.scope.user.as_deref() == Some("user:kit-someone-else") || d.scope.agent.as_deref() == Some("agent:kit-someone-else"));
    r.check(
        "scope_is_not_widened_by_the_request",
        "a request that names another user's or agent's scope is denied, or is answered within the caller's own scope",
        unless(!widened, || format!("allowed with scope user {:?}, agent {:?}", d.scope.user, d.scope.agent)),
    );

    let (one, two) = (a.authorize(&agent, &request(Operation::Remember)).await, a.authorize(&agent, &request(Operation::Remember)).await);
    r.check(
        "deterministic",
        "the same identity and request get the same decision",
        unless(one.allowed == two.allowed && one.rule == two.rule && one.propose_only == two.propose_only, || format!("{} then {}", says(&one), says(&two))),
    );

    let denied = a.authorize(&nothing, &request(Operation::Recall)).await;
    r.check(
        "denials_say_why",
        "a denial names the rule that decided and gives a reason",
        unless(denied.allowed || (!denied.rule.trim().is_empty() && !denied.reasons.is_empty()), || format!("rule {:?}, {} reasons", denied.rule, denied.reasons.len())),
    );
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use memhouse_core::access::ScopeAuthorizer;
    use memhouse_core::config::Config;

    /// An authorizer that allows everything, in whatever tenant the request names.
    struct Open;

    #[async_trait::async_trait]
    impl Authorizer for Open {
        fn name(&self) -> &str {
            "broken:open"
        }
        async fn authorize(&self, who: &Identity, req: &AccessRequest) -> Decision {
            Decision {
                allowed: true,
                rule: "allow".into(),
                reasons: vec![],
                tenant: req.tenant.clone().unwrap_or_else(|| who.principal.tenant.clone()),
                denied_labels: vec![],
                scope: req.scope.clone().unwrap_or_default(),
                kinds: vec![],
                propose_only: false,
                shared_agents: vec![],
            }
        }
    }

    #[tokio::test]
    async fn the_default_authorizer_passes_and_an_open_one_fails_closed_checks() {
        run_authorizer_kit(&ScopeAuthorizer::new(&Config::default())).await.assert_passed();
        let broken = run_authorizer_kit(&Open).await;
        let failed: Vec<&str> = broken.failures().iter().map(|c| c.name.as_str()).collect();
        for must in ["no_operation_is_denied", "no_permission_no_access", "another_tenant_is_denied", "outside_subjects_is_denied", "scope_is_not_widened_by_the_request"] {
            assert!(failed.contains(&must), "{must} passed for an authorizer that allows everything: {failed:?}");
        }
    }
}
