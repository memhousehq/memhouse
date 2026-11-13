// SPDX-License-Identifier: Apache-2.0
//! Governance checks for identity and authorization (roadmap G06), over HTTP against a real server
//! on a scratch database: every call is authenticated, every route is authorized, agents only
//! propose, labels are filtered inside the recall statement, and authorization is fast.

use crate::api_checks::{Api, KEY};
use crate::governance::{check, stub_engine, Check, Scratch};
use memhouse_core::access::{AccessRequest, Operation};
use memhouse_core::config::Admission;
use memhouse_core::identity::{self, perm, Authenticator, Principal, PrincipalKind};
use memhouse_core::types::*;
use memhouse_core::Engine;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

type Outcome = (bool, String, String);

fn verdict(problems: Vec<String>, value: String, ok: &str) -> Outcome {
    (problems.is_empty(), value, if problems.is_empty() { ok.to_string() } else { problems.into_iter().take(6).collect::<Vec<_>>().join("; ") })
}

const CHECKS: [(&str, &str, &str); 5] = [
    ("authentication", "GOV-01 / GOV-13 / TR-LT-07", "Missing, forged, expired and revoked keys and tokens are refused and audited; tokens carry a verified user"),
    ("route_authorization", "GOV-02 / TR-CORE-05", "Every REST route and MCP tool goes through the authorizer: a key without permissions is refused everywhere"),
    ("propose_only", "GOV-08", "An agent's writes are proposals the engine or a reviewer commits; its direct commit is refused and audited"),
    (
        "label_filter",
        "TR-RQ-03 / ACC-04 / GOV-02",
        "Denied labels are filtered inside the recall statement, before ranking; caller-supplied tenant, user and scope can't widen access",
    ),
    ("authz_latency", "GOV-14", "Authentication plus authorization adds at most 10 ms at p95"),
];

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    match run_all(engine).await {
        Ok(results) => CHECKS.iter().zip(results).map(|((id, req, title), (passed, value, detail))| check(id, req, title, passed, value, "all", detail)).collect(),
        Err(e) => CHECKS.iter().map(|(id, req, title)| check(id, req, title, false, "error".into(), "all", format!("{e:#}"))).collect(),
    }
}

/// The principals and keys of the scenario.
struct Keys(BTreeMap<&'static str, String>);

impl Keys {
    fn bearer(&self, name: &str) -> String {
        format!("Bearer {}", self.0[name])
    }
}

async fn principal(e: &Engine, id: &str, kind: PrincipalKind, f: impl FnOnce(&mut Principal)) -> anyhow::Result<()> {
    let mut p = Principal::new(id, "default", kind, "bench");
    f(&mut p);
    e.store.principal_put(&p).await
}

async fn key(e: &Engine, principal: &str, scopes: Option<Vec<String>>, expires: Option<chrono::DateTime<chrono::Utc>>) -> anyhow::Result<(String, String)> {
    let p = e.store.principal_get(principal).await?.expect("seeded");
    let (k, full) = identity::new_key(principal, scopes.unwrap_or_else(|| p.kind.permissions()), expires, "bench");
    e.store.api_key_put(&k).await?;
    Ok((k.id, full))
}

async fn serve(e: Engine) -> anyhow::Result<(String, tokio::task::JoinHandle<anyhow::Result<()>>)> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}", listener.local_addr()?);
    Ok((url, tokio::spawn(memhouse_server::serve_listener(listener, e))))
}

async fn run_all(base: &Engine) -> anyhow::Result<Vec<Outcome>> {
    let scratch = Scratch::create(base, "idn1").await?;
    let result = async {
        let e = stub_engine(base, &scratch.url, "stub:a", 16, "", true).await?;
        let mut cfg = (*e.cfg).clone();
        cfg.server.api_keys = vec![KEY.into()];
        cfg.governance.audit_reads = false;
        cfg.governance.denied_labels = vec![];
        cfg.access.denied_labels.agent = vec!["hr".into()];
        let e = e.reconfigure(cfg.clone());
        // Revocations must show at once in these checks; production caches for 5 s.
        let e = e.clone().with_authenticator(Authenticator::new(e.store.clone(), e.cfg.clone()).with_cache_ttl(Duration::ZERO));
        let mut review_cfg = cfg.clone();
        review_cfg.access.admission = Admission::Review;
        let reviewed = e.clone().reconfigure(review_cfg);
        let reviewed = reviewed.clone().with_authenticator(Authenticator::new(reviewed.store.clone(), reviewed.cfg.clone()).with_cache_ttl(Duration::ZERO));

        principal(&e, "agent:a", PrincipalKind::Agent, |p| p.subjects = vec!["customer:*".into()]).await?;
        principal(&e, "agent:trusted", PrincipalKind::Agent, |p| p.can_commit = true).await?;
        principal(&e, "agent:svc", PrincipalKind::Agent, |p| p.act_as = true).await?;
        principal(&e, "agent:gone", PrincipalKind::Agent, |_| {}).await?;
        principal(&e, "user:ana", PrincipalKind::User, |_| {}).await?;
        principal(&e, "user:bob", PrincipalKind::User, |_| {}).await?;
        principal(&e, "admin:rev", PrincipalKind::Admin, |_| {}).await?;
        let mut keys = BTreeMap::new();
        for (name, who, scopes, expires) in [
            ("a", "agent:a", None, None),
            ("a-none", "agent:a", Some(vec![]), None),
            ("a-expired", "agent:a", None, Some(chrono::Utc::now() - chrono::Duration::minutes(1))),
            ("a-revoked", "agent:a", None, None),
            ("trusted", "agent:trusted", None, None),
            ("svc", "agent:svc", None, None),
            ("gone", "agent:gone", None, None),
            ("ana", "user:ana", None, None),
            ("bob", "user:bob", None, None),
            ("rev", "admin:rev", None, None),
        ] {
            let (id, full) = key(&e, who, scopes, expires).await?;
            if name == "a-revoked" {
                e.store.api_key_end(&id, None).await?;
            }
            keys.insert(name, full);
        }
        let mut gone = e.store.principal_get("agent:gone").await?.expect("seeded");
        gone.disabled_at = Some(chrono::Utc::now());
        e.store.principal_put(&gone).await?;
        let keys = Keys(keys);

        let (url, server) = serve(e.clone()).await?;
        let (review_url, review_server) = serve(reviewed.clone()).await?;
        let pool = sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(&scratch.url).await?;
        let mut api = Api::new(url);
        let mut review_api = Api::new(review_url);
        let out = vec![
            authentication(&mut api, &keys, &pool).await?,
            routes(&mut api, &keys, &pool).await?,
            propose_only(&mut api, &mut review_api, &keys, &pool).await?,
            labels(&mut api, &keys, &e).await?,
            latency(&e, &keys).await?,
        ];
        server.abort();
        review_server.abort();
        pool.close().await;
        anyhow::Ok(out)
    }
    .await;
    scratch.drop().await?;
    result
}

async fn count(pool: &sqlx::PgPool, action: &str) -> anyhow::Result<i64> {
    Ok(sqlx::query_scalar("SELECT count(*) FROM mh_audit WHERE action = $1").bind(action).fetch_one(pool).await?)
}

/// A refused credential: why, the Authorization header, extra headers.
type Case = (&'static str, String, Vec<(&'static str, String)>);

/// GOV-01, GOV-13: every credential that isn't valid is refused with an audit entry and no data.
async fn authentication(api: &mut Api, keys: &Keys, pool: &sqlx::PgPool) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let ok = api.call("GET", "/v1/whoami", "/v1/whoami", None, &[("authorization", &keys.bearer("a"))]).await?;
    if ok.body["principal"] != "agent:a" || ok.body["via"] != "key" || ok.body["user"].is_string() {
        problems.push(format!("valid agent key: {}", ok.body));
    }
    // A user delegates to an agent: the token's user is verified.
    let t = api.call("POST", "/v1/tokens", "/v1/tokens", Some(json!({"agent": "agent:a", "ttl_secs": 2})), &[("authorization", &keys.bearer("ana"))]).await?;
    let token = t.body["token"].as_str().unwrap_or_default().to_string();
    let w = api.call("GET", "/v1/whoami", "/v1/whoami", None, &[("authorization", &format!("Bearer {token}"))]).await?;
    if w.body["principal"] != "agent:a" || w.body["user"] != "user:ana" || w.body["via"] != "token" {
        problems.push(format!("user-issued token: {}", w.body));
    }
    if w.body["scopes"].as_array().is_some_and(|s| s.iter().any(|x| x == perm::TOKEN || x == perm::LABEL)) {
        problems.push(format!("token carries more than the agent's role: {}", w.body["scopes"]));
    }
    let svc = api.call("GET", "/v1/whoami", "/v1/whoami", None, &[("authorization", &keys.bearer("svc")), ("x-memhouse-user", "user:carol")]).await?;
    if svc.body["user"] != "user:carol" {
        problems.push(format!("act_as agent stating its user: {}", svc.body));
    }
    let mut forged = token.clone();
    if let Some(dot) = forged.rfind('.') {
        forged.replace_range(dot + 1..dot + 3, if &forged[dot + 1..dot + 3] == "AA" { "BB" } else { "AA" });
    }
    let mut tampered_body = token.clone();
    tampered_body.replace_range(5..7, if &token[5..7] == "ey" { "ab" } else { "ey" });
    let before = count(pool, "auth.failed").await?;
    let mut cases: Vec<Case> = vec![
        ("no credential", String::new(), vec![]),
        ("garbage", "Bearer hello".into(), vec![]),
        ("wrong secret", format!("Bearer {}{}", &keys.0["a"][..keys.0["a"].len() - 1], if keys.0["a"].ends_with('x') { 'y' } else { 'x' }), vec![]),
        ("expired key", keys.bearer("a-expired"), vec![]),
        ("revoked key", keys.bearer("a-revoked"), vec![]),
        ("disabled principal", keys.bearer("gone"), vec![]),
        ("forged token signature", format!("Bearer {forged}"), vec![]),
        ("tampered token claims", format!("Bearer {tampered_body}"), vec![]),
        ("agent stating a user without act_as", keys.bearer("a"), vec![("x-memhouse-user", "user:ana".into())]),
        ("user key stating another user", keys.bearer("ana"), vec![("x-memhouse-user", "user:bob".into())]),
    ];
    tokio::time::sleep(Duration::from_millis(2100)).await;
    cases.push(("expired token", format!("Bearer {token}"), vec![]));
    for (why, auth, extra) in &cases {
        let mut h: Vec<(&str, &str)> = vec![("authorization", auth.as_str())];
        h.extend(extra.iter().map(|(k, v)| (*k, v.as_str())));
        let r = api.call("POST", "/v1/recall", "/v1/recall", Some(json!({"subject": "customer:1", "query": "anything"})), &h).await?;
        if r.status != 401 || r.body["code"] != "unauthorized" || r.body.get("hits").is_some() {
            problems.push(format!("{why}: {} {}", r.status, r.body));
        }
    }
    let audited = count(pool, "auth.failed").await? - before;
    if audited != cases.len() as i64 {
        problems.push(format!("{audited} auth.failed events for {} refused calls", cases.len()));
    }
    // Revoking the issuing key revokes its tokens.
    let t = api.call("POST", "/v1/tokens", "/v1/tokens", Some(json!({})), &[("authorization", &keys.bearer("trusted"))]).await?;
    let tok = format!("Bearer {}", t.body["token"].as_str().unwrap_or_default());
    let before = api.call("GET", "/v1/whoami", "/v1/whoami", None, &[("authorization", &tok)]).await?.status;
    let key_id = keys.0["trusted"].split('_').nth(1).unwrap_or_default().to_string();
    sqlx::query("UPDATE mh_api_key SET revoked_at = now() WHERE id = $1").bind(&key_id).execute(pool).await?;
    let after = api.call("GET", "/v1/whoami", "/v1/whoami", None, &[("authorization", &tok)]).await?.status;
    sqlx::query("UPDATE mh_api_key SET revoked_at = NULL WHERE id = $1").bind(&key_id).execute(pool).await?;
    if before != 200 || after != 401 {
        problems.push(format!("token of a revoked key: {before} before, {after} after"));
    }
    Ok(verdict(problems, format!("{} bad credentials refused, {audited} audited", cases.len()), "every bad credential refused with an audit entry; tokens carry a verified user"))
}

/// Done-when of G06: a key without permissions reaches the authorizer on every route and tool.
async fn routes(api: &mut Api, keys: &Keys, pool: &sqlx::PgPool) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let id = uuid::Uuid::now_v7().to_string();
    let body = |path: &str| -> Option<Value> {
        Some(match path {
            "/v1/remember" | "/v1/memories" => json!({"subject": "customer:1", "content": "x"}),
            "/v1/recall" => json!({"subject": "customer:1", "query": "x"}),
            "/v1/revise" => json!({"id": id, "content": "x"}),
            "/v1/forget" => json!({"id": id}),
            "/v1/ingest" => json!({"subject": "customer:1", "messages": [{"role": "user", "content": "x"}]}),
            "/v1/labels" => json!({"id": id, "labels": []}),
            "/v1/review" => json!({"id": id, "action": "commit"}),
            "/v1/tokens" => json!({}),
            "/v1/memories/{id}" => json!({"content": "x"}),
            "/v1/policies" | "/v1/policies/validate" => json!({"spec": {"name": "x", "scope": {"tenant": "default"}}}),
            "/v1/policies/diff" => json!({"to": "default"}),
            "/v1/policies/rollback" => json!({}),
            "/v1/promote" => json!({"sources": [id], "kind": "semantic"}),
            "/v1/grants" => json!({"grantor": "agent:a", "grantee": "agent:trusted"}),
            _ => return None,
        })
    };
    let spec = api.spec.clone();
    let none = keys.bearer("a-none");
    let mut calls = 0;
    let before = count(pool, "access.denied").await?;
    for (path, methods) in spec["paths"].as_object().into_iter().flatten() {
        for (method, op) in methods.as_object().into_iter().flatten() {
            if op.get("security") == Some(&json!([])) || path == "/v1/whoami" {
                continue;
            }
            let concrete = path.replace("{id}", &id).replace("{subject}", "customer:1").replace("{version}", "1");
            let b = if method == "get" || method == "delete" { None } else { body(path) };
            let r = api.call(&method.to_uppercase(), path, &concrete, b, &[("authorization", none.as_str())]).await?;
            calls += 1;
            if r.status != 403 || r.body["code"] != "forbidden" {
                problems.push(format!("{} {path}: {} {}", method.to_uppercase(), r.status, r.body["code"]));
            }
        }
    }
    let tools = api.mcp_as("tools/list", json!({}), &[("authorization", none.as_str())]).await?;
    let mut tool_calls = 0;
    for t in tools["tools"].as_array().into_iter().flatten() {
        let name = t["name"].as_str().unwrap_or("");
        let args = match name {
            "recall" => json!({"query": "x"}),
            "remember" => json!({"content": "x"}),
            "revise" => json!({"id": id, "content": "x"}),
            "forget" => json!({"id": id}),
            "ingest" => json!({"messages": [{"role": "user", "content": "x"}]}),
            _ => json!({}),
        };
        let r = api.mcp_as("tools/call", json!({"name": name, "arguments": args}), &[("authorization", none.as_str())]).await?;
        tool_calls += 1;
        if r["isError"] != true || !r["content"][0]["text"].as_str().unwrap_or("").contains("forbidden") {
            problems.push(format!("MCP {name}: {}", r["content"][0]["text"]));
        }
    }
    let audited = count(pool, "access.denied").await? - before;
    if audited < (calls + tool_calls) as i64 {
        problems.push(format!("{audited} access.denied events for {} refused calls", calls + tool_calls));
    }
    // The same routes answer for a key that has the permissions (the refusals came from the
    // authorizer, not from a broken route).
    let r = api.call("POST", "/v1/recall", "/v1/recall", body("/v1/recall"), &[("authorization", &keys.bearer("a"))]).await?;
    if r.status != 200 {
        problems.push(format!("recall with permissions: {}", r.status));
    }
    Ok(verdict(
        problems,
        format!("{calls} routes, {tool_calls} MCP tools refused; {audited} audited"),
        "every route and tool refused a key without permissions, each with an access.denied event",
    ))
}

/// GOV-08: agents propose; the engine (auto) or a reviewer (review) commits.
async fn propose_only(api: &mut Api, review: &mut Api, keys: &Keys, pool: &sqlx::PgPool) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let actions = |id: String| {
        let pool = pool.clone();
        async move { sqlx::query_as::<_, (String, String)>("SELECT action, actor FROM mh_audit WHERE memory_id = $1::uuid ORDER BY id").bind(id).fetch_all(&pool).await }
    };
    let a = keys.bearer("a");
    let r =
        api.call("POST", "/v1/remember", "/v1/remember", Some(json!({"subject": "customer:p1", "content": "Initech renews in March"})), &[("authorization", a.as_str())]).await?;
    let id = r.body["id"].as_str().unwrap_or_default().to_string();
    let trail = actions(id.clone()).await?;
    let want = vec![("memory.propose".to_string(), "agent:a".to_string()), ("memory.admit".to_string(), "engine".to_string())];
    if r.body["status"] != "committed" || trail != want {
        problems.push(format!("auto admission: status {}, audit {trail:?}", r.body["status"]));
    }
    // Review mode: the proposal waits, the agent can't commit it, a reviewer can.
    let r = review
        .call("POST", "/v1/remember", "/v1/remember", Some(json!({"subject": "customer:p1", "content": "Initech's champion is Raj"})), &[("authorization", a.as_str())])
        .await?;
    let cand = r.body["id"].as_str().unwrap_or_default().to_string();
    if r.body["status"] != "candidate" {
        problems.push(format!("review mode: status {}", r.body["status"]));
    }
    let hits = review.call("POST", "/v1/recall", "/v1/recall", Some(json!({"subject": "customer:p1", "query": "Initech champion"})), &[("authorization", a.as_str())]).await?;
    if hits.body["hits"].as_array().is_some_and(|h| h.iter().any(|x| x["memory"]["id"] == cand.as_str())) {
        problems.push("a candidate was recalled".into());
    }
    let denied_before = count(pool, "access.denied").await?;
    let direct = review.call("POST", "/v1/review", "/v1/review", Some(json!({"id": cand, "action": "commit"})), &[("authorization", a.as_str())]).await?;
    if direct.status != 403 || count(pool, "access.denied").await? != denied_before + 1 {
        problems.push(format!("agent committing its own proposal: {}", direct.status));
    }
    let rev = keys.bearer("rev");
    let ok = review.call("POST", "/v1/review", "/v1/review", Some(json!({"id": cand, "action": "commit"})), &[("authorization", rev.as_str())]).await?;
    let trail = actions(cand.clone()).await?;
    if ok.body["status"] != "committed" || trail.last() != Some(&("memory.admit".to_string(), "admin:rev".to_string())) {
        problems.push(format!("reviewer commit: {} {trail:?}", ok.body));
    }
    // A revision proposed for review leaves the current version current until committed.
    let r = review.call("POST", "/v1/revise", "/v1/revise", Some(json!({"id": cand, "content": "Initech's champion is Raj Patel"})), &[("authorization", a.as_str())]).await?;
    let rv = r.body["id"].as_str().unwrap_or_default().to_string();
    let cur = review.call("GET", "/v1/memories/{id}", &format!("/v1/memories/{cand}"), None, &[("authorization", rev.as_str())]).await?;
    if r.body["status"] != "candidate" || cur.body["status"] != "committed" {
        problems.push(format!("proposed revision: {} / current {}", r.body["status"], cur.body["status"]));
    }
    let rej = review.call("POST", "/v1/review", "/v1/review", Some(json!({"id": rv, "action": "reject", "reason": "unverified"})), &[("authorization", rev.as_str())]).await?;
    if rej.body["status"] != "rejected" {
        problems.push(format!("reviewer reject: {}", rej.body));
    }
    // The explicit grant, and users, commit directly.
    for (k, who) in [("trusted", "agent:trusted"), ("ana", "user:ana")] {
        let r = api
            .call(
                "POST",
                "/v1/remember",
                "/v1/remember",
                Some(json!({"subject": "customer:p1", "content": format!("Note written by {who}")})),
                &[("authorization", keys.bearer(k).as_str())],
            )
            .await?;
        let trail = actions(r.body["id"].as_str().unwrap_or_default().to_string()).await?;
        if r.body["status"] != "committed" || trail != vec![("memory.write".to_string(), who.to_string())] {
            problems.push(format!("{who}: status {}, audit {trail:?}", r.body["status"]));
        }
    }
    let prov: Option<String> = sqlx::query_scalar("SELECT prov_agent FROM mh_memory WHERE id = $1::uuid").bind(&id).fetch_optional(pool).await?.flatten();
    if prov.as_deref() != Some("agent:a") {
        problems.push(format!("provenance.agent of the proposal is {prov:?}"));
    }
    Ok(verdict(
        problems,
        "auto and review admission".into(),
        "agent writes are proposals: admitted by the engine, or held for a reviewer; the agent's own commit is refused and audited",
    ))
}

/// TR-RQ-03, ACC-04, GOV-02: denied labels inside the statement; caller-supplied filters can't
/// widen access.
async fn labels(api: &mut Api, keys: &Keys, e: &Engine) -> anyhow::Result<Outcome> {
    let mut problems = vec![];
    let subj = "customer:lbl";
    // As the operator: 12 HR records that match the query best, 3 ordinary ones.
    // Distinct words, so none is a near-duplicate of another.
    const NAMES: [&str; 15] = ["alder", "birch", "cedar", "dogwood", "elm", "fir", "ginkgo", "hazel", "ironwood", "juniper", "larch", "maple", "oakley", "pine", "rowan"];
    for n in &NAMES[..12] {
        e.remember(RememberRequest {
            subject: Some(subj.into()),
            content: format!("Payroll grievance from {n}: salary dispute escalated"),
            labels: vec!["hr".into()],
            wait: true,
            ..Default::default()
        })
        .await?;
    }
    for n in &NAMES[12..] {
        e.remember(RememberRequest { subject: Some(subj.into()), content: format!("Payroll vendor {n} invoices monthly"), wait: true, ..Default::default() }).await?;
    }
    let a = keys.bearer("a");
    let r =
        api.call("POST", "/v1/recall", "/v1/recall", Some(json!({"subject": subj, "query": "payroll salary grievance dispute", "k": 3})), &[("authorization", a.as_str())]).await?;
    let hits = r.body["hits"].as_array().cloned().unwrap_or_default();
    if hits.len() != 3 || hits.iter().any(|h| h["memory"]["labels"].as_array().is_some_and(|l| !l.is_empty())) {
        problems.push(format!("agent recall k=3: {} hits, labels {:?}", hits.len(), hits.iter().map(|h| h["memory"]["labels"].clone()).collect::<Vec<_>>()));
    }
    let ana = keys.bearer("ana");
    let r = api
        .call("POST", "/v1/recall", "/v1/recall", Some(json!({"subject": subj, "query": "payroll salary grievance dispute", "k": 3})), &[("authorization", ana.as_str())])
        .await?;
    if r.body["hits"].as_array().is_none_or(|h| h.iter().filter(|x| x["memory"]["labels"] == json!(["hr"])).count() != 3) {
        problems.push("a user (no hr denial) didn't get the best-matching hr records".into());
    }
    // The filter is part of the statement: the scan of mh_memory carries it, before any sort.
    let q = SearchQuery {
        tenant: "default".into(),
        subject: subj.into(),
        text: "payroll".into(),
        embedding: Some(e.embedder.embed(&["payroll".to_string()], memhouse_core::EmbedKind::Query).await?.remove(0)),
        kinds: None,
        tags: None,
        denied_labels: vec!["hr".into()],
        as_of: None,
        valid_at: chrono::Utc::now(),
        mode: RetrievalMode::Hybrid,
        per_retriever: 100,
        limit: 3,
        rrf_k: 60.0,
        keyword_weight: 1.0,
        vector_weight: 1.0,
        windows: vec![],
        scope: Scope::default(),
        include_candidates: false,
        shared_agents: vec![],
    };
    let plan = e.store.search_plan(&q).await?.unwrap_or_default();
    if !scan_filters_labels(&plan) {
        problems.push("no mh_memory scan in the recall plan filters on labels".into());
    }
    // Get and list hide what recall hides; writing a denied label is refused.
    let hr_id: String =
        e.list(None, Some(subj.into()), None, 1, 0, false).await?.into_iter().find(|m| m.labels.contains(&"hr".to_string())).map(|m| m.id.to_string()).unwrap_or_default();
    let g = api.call("GET", "/v1/memories/{id}", &format!("/v1/memories/{hr_id}"), None, &[("authorization", a.as_str())]).await?;
    let l = api.call("GET", "/v1/subjects/{subject}/memories", &format!("/v1/subjects/{subj}/memories?limit=100"), None, &[("authorization", a.as_str())]).await?;
    let w = api.call("POST", "/v1/remember", "/v1/remember", Some(json!({"subject": subj, "content": "x", "labels": ["hr"]})), &[("authorization", a.as_str())]).await?;
    if g.status != 404 || l.body["items"].as_array().map(|i| i.len()) != Some(3) || w.status != 403 {
        problems.push(format!("agent: get {} list {} write {}", g.status, l.body["items"].as_array().map(|i| i.len()).unwrap_or(0), w.status));
    }
    // Relabelling doesn't re-embed and takes effect at once.
    let plain: String = l.body["items"][0]["id"].as_str().unwrap_or_default().to_string();
    let vec_before: Option<String> = sqlx::query_scalar("SELECT embedding::text FROM mh_memory WHERE id = $1::uuid").bind(&plain).fetch_optional(&pool_of(e)).await?;
    let rl = api.call("POST", "/v1/labels", "/v1/labels", Some(json!({"id": plain, "labels": ["hr"]})), &[("authorization", ana.as_str())]).await?;
    let vec_after: Option<String> = sqlx::query_scalar("SELECT embedding::text FROM mh_memory WHERE id = $1::uuid").bind(&plain).fetch_optional(&pool_of(e)).await?;
    let g = api.call("GET", "/v1/memories/{id}", &format!("/v1/memories/{plain}"), None, &[("authorization", a.as_str())]).await?;
    if rl.status != 200 || vec_before != vec_after || g.status != 404 {
        problems.push(format!("relabel: {} (vector unchanged: {}), agent then gets {}", rl.status, vec_before == vec_after, g.status));
    }
    // GOV-02: filters supplied by the caller are checked, never trusted.
    e.remember(RememberRequest {
        subject: Some(subj.into()),
        content: "Ana's private note on payroll".into(),
        scope: Some(Scope { user: Some("user:ana".into()), ..Default::default() }),
        wait: true,
        ..Default::default()
    })
    .await?;
    e.remember(RememberRequest {
        subject: Some(subj.into()),
        content: "Bob's private note on payroll".into(),
        scope: Some(Scope { user: Some("user:bob".into()), ..Default::default() }),
        wait: true,
        ..Default::default()
    })
    .await?;
    let tamper = [
        ("tenant", json!({"subject": subj, "query": "payroll", "tenant": "other"}), a.clone()),
        ("scope.user of another user", json!({"subject": subj, "query": "payroll", "scope": {"user": "user:bob"}}), ana.clone()),
        ("scope.user without a verified user", json!({"subject": subj, "query": "payroll", "scope": {"user": "user:ana"}}), a.clone()),
        ("subject outside the agent's", json!({"subject": "user:ana", "query": "payroll"}), a.clone()),
    ];
    for (why, body, who) in tamper {
        let r = api.call("POST", "/v1/recall", "/v1/recall", Some(body), &[("authorization", who.as_str())]).await?;
        if r.status != 403 {
            problems.push(format!("recall with {why}: {}", r.status));
        }
    }
    let w = api.call("POST", "/v1/remember", "/v1/remember", Some(json!({"subject": subj, "content": "x", "user": "user:bob"})), &[("authorization", ana.as_str())]).await?;
    if w.status != 403 {
        problems.push(format!("ana writing as bob: {}", w.status));
    }
    let r = api.call("POST", "/v1/recall", "/v1/recall", Some(json!({"subject": subj, "query": "private note payroll", "k": 20})), &[("authorization", ana.as_str())]).await?;
    let texts: Vec<String> = r.body["hits"].as_array().into_iter().flatten().filter_map(|h| h["memory"]["content"].as_str().map(String::from)).collect();
    if !texts.iter().any(|t| t.starts_with("Ana's")) || texts.iter().any(|t| t.starts_with("Bob's")) {
        problems.push(format!("ana's recall: own private note {}, bob's {}", texts.iter().any(|t| t.starts_with("Ana's")), texts.iter().any(|t| t.starts_with("Bob's"))));
    }
    let r = api.call("POST", "/v1/recall", "/v1/recall", Some(json!({"subject": subj, "query": "private note payroll", "k": 20})), &[("authorization", a.as_str())]).await?;
    if r.body["hits"].as_array().into_iter().flatten().any(|h| h["memory"]["content"].as_str().unwrap_or("").contains("private note")) {
        problems.push("an agent without a verified user recalled user-scoped notes".into());
    }
    Ok(verdict(problems, "12 hr + 3 plain records, k=3".into(), "denied labels filtered in the scan before ranking (k still full); tampered tenant, user and scope refused"))
}

fn pool_of(e: &Engine) -> sqlx::PgPool {
    sqlx::postgres::PgPoolOptions::new().max_connections(1).connect_lazy(&e.cfg.database.url).expect("database url")
}

/// The plan has a scan of `mh_memory` whose filter (or index condition) mentions labels.
fn scan_filters_labels(plan: &Value) -> bool {
    match plan {
        Value::Object(o) => {
            let on_memory = o.get("Relation Name").and_then(Value::as_str) == Some("mh_memory");
            let filtered = ["Filter", "Recheck Cond", "Index Cond"].iter().any(|k| o.get(*k).and_then(Value::as_str).is_some_and(|f| f.contains("labels")));
            (on_memory && filtered) || o.values().any(scan_filters_labels)
        }
        Value::Array(a) => a.iter().any(scan_filters_labels),
        _ => false,
    }
}

/// GOV-14: authenticate + authorize, cold (no cache, a store lookup) and warm (cached).
async fn latency(e: &Engine, keys: &Keys) -> anyhow::Result<Outcome> {
    let cold = Authenticator::new(e.store.clone(), e.cfg.clone()).with_cache_ttl(Duration::ZERO);
    let warm = Authenticator::new(e.store.clone(), e.cfg.clone());
    let mut req = AccessRequest::new(Operation::Recall).subject("customer:1");
    req.kinds = vec![MemoryKind::Semantic];
    let mut cold_ms = vec![];
    let mut warm_ms = vec![];
    for (auth, out) in [(&cold, &mut cold_ms), (&warm, &mut warm_ms)] {
        for _ in 0..200 {
            let t = Instant::now();
            let who = auth.authenticate(&keys.0["a"], None).await.map_err(|f| anyhow::anyhow!("{f}"))?;
            let d = e.authorizer.authorize(&who, &req).await;
            anyhow::ensure!(d.allowed, "{:?}", d.reasons);
            out.push(t.elapsed().as_secs_f64() * 1000.0);
        }
    }
    let p95 = |v: &mut Vec<f64>| {
        v.sort_by(|a, b| a.total_cmp(b));
        v[(v.len() * 95 / 100).min(v.len() - 1)]
    };
    let (c, w) = (p95(&mut cold_ms), p95(&mut warm_ms));
    Ok((c <= 10.0, format!("p95 {c:.2} ms uncached, {w:.3} ms cached"), "≤ 10 ms".into()))
}
