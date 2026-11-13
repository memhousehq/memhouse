// SPDX-License-Identifier: Apache-2.0
//! `memhouse principal …` and `memhouse key …`: principals and their API keys (G06). The CLI holds
//! the database credentials, so it acts as the operator; every change is audited.

use clap::Subcommand;
use memhouse_core::identity::{self, perm, Principal, PrincipalKind};
use memhouse_core::types::MemoryKind;
use memhouse_core::Engine;
use serde_json::json;

#[derive(Subcommand)]
pub enum PrincipalCmd {
    /// Add (or update) an agent, user or admin
    Add {
        /// `agent:<name>`, `user:<name>` or `admin:<name>`
        id: String,
        /// Subjects it may use (exact, or a prefix ending in *); repeatable. Default: all
        #[arg(long = "subject")]
        subjects: Vec<String>,
        /// Memory kinds it may use; repeatable. Default: all
        #[arg(long = "kind")]
        kinds: Vec<String>,
        /// Labels it may never read or write; repeatable
        #[arg(long = "deny-label")]
        denied_labels: Vec<String>,
        #[arg(long)]
        org: Option<String>,
        #[arg(long)]
        team: Option<String>,
        /// Agents only: commit writes directly instead of proposing them (GOV-08)
        #[arg(long)]
        commit: bool,
        /// May state which user it acts for (a backend that authenticates its users)
        #[arg(long)]
        act_as: bool,
        #[arg(long)]
        name: Option<String>,
        /// Tenant (default: the configured one)
        #[arg(long)]
        tenant: Option<String>,
    },
    /// List principals
    List,
    /// Disable a principal: its keys and tokens stop working within 5 seconds
    Disable { id: String },
    /// Enable a disabled principal again
    Enable { id: String },
}

#[derive(Subcommand)]
pub enum KeyCmd {
    /// Create an API key for a principal (printed once)
    Create {
        principal: String,
        /// Comma-separated permissions (default: everything the principal's kind allows); "" for none
        #[arg(long)]
        scopes: Option<String>,
        /// Lifetime, e.g. 90d, 12h (default: no expiry)
        #[arg(long)]
        expires: Option<String>,
    },
    /// List keys (ids, permissions, state; never secrets)
    List { principal: Option<String> },
    /// Revoke a key now
    Revoke { id: String },
    /// Replace a key: a new key with the same permissions; the old one keeps working for --grace
    Rotate {
        id: String,
        #[arg(long, default_value = "24h")]
        grace: String,
    },
}

#[derive(Subcommand)]
pub enum GrantCmd {
    /// Let GRANTEE read GRANTOR's agent-scoped memory (INT-06)
    Add {
        /// The agent whose memory is shared
        grantor: String,
        /// The agent that may read it
        grantee: String,
        /// Subjects covered: an exact name, a prefix ending in *, or * (default)
        #[arg(long)]
        subjects: Option<String>,
        /// Kinds covered; repeatable. Default: all
        #[arg(long = "kind")]
        kinds: Vec<String>,
        /// Lifetime, e.g. 30d, 12h (default: until revoked)
        #[arg(long)]
        expires: Option<String>,
    },
    /// List grants, revoked and expired ones included
    List,
    /// Revoke a grant now
    Revoke { id: String },
}

pub async fn grant(eng: &Engine, cmd: GrantCmd) -> anyhow::Result<()> {
    let tenant = eng.cfg.memory.tenant.clone();
    match cmd {
        GrantCmd::Add { grantor, grantee, subjects, kinds, expires } => {
            let kinds = kinds.iter().map(|k| MemoryKind::parse(k).ok_or_else(|| anyhow::anyhow!("unknown kind '{k}'"))).collect::<anyhow::Result<_>>()?;
            let expires_at = expires.as_deref().map(duration).transpose()?.map(|d| chrono::Utc::now() + d);
            let g = eng.grant_create(&tenant, &memhouse_core::types::GrantRequest { grantor, grantee, subjects, kinds, expires_at }, "cli").await?;
            println!("{}", serde_json::to_string_pretty(&g)?);
        }
        GrantCmd::List => {
            let now = chrono::Utc::now();
            for g in eng.grant_list(&tenant).await? {
                let kinds = if g.kinds.is_empty() { "all kinds".to_string() } else { g.kinds.iter().map(|k| k.as_str()).collect::<Vec<_>>().join(",") };
                let state = match (g.revoked_at, g.active(now)) {
                    (Some(_), _) => "revoked",
                    (None, false) => "expired",
                    (None, true) => "active",
                };
                println!("{}  {} -> {}  subjects {}  {kinds}  {state}", g.id, g.grantor, g.grantee, g.subjects);
            }
        }
        GrantCmd::Revoke { id } => {
            eng.grant_revoke(&tenant, uuid::Uuid::parse_str(&id)?, "cli").await?;
            println!("revoked {id}");
        }
    }
    Ok(())
}

pub fn duration(s: &str) -> anyhow::Result<chrono::Duration> {
    let (n, unit) = s.split_at(s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len()));
    let n: i64 = n.parse().map_err(|_| anyhow::anyhow!("expected a duration like 90d, 12h or 30m, got '{s}'"))?;
    Ok(match unit {
        "d" => chrono::Duration::days(n),
        "h" => chrono::Duration::hours(n),
        "m" => chrono::Duration::minutes(n),
        "s" | "" => chrono::Duration::seconds(n),
        _ => anyhow::bail!("expected a duration like 90d, 12h or 30m, got '{s}'"),
    })
}

fn kind_of(id: &str) -> anyhow::Result<PrincipalKind> {
    let k = id.split(':').next().and_then(PrincipalKind::parse).ok_or_else(|| anyhow::anyhow!("principal ids start with agent:, user: or admin: ('{id}')"))?;
    Principal::check_id(id, k)?;
    Ok(k)
}

pub async fn principal(eng: &Engine, cmd: PrincipalCmd) -> anyhow::Result<()> {
    match cmd {
        PrincipalCmd::Add { id, subjects, kinds, denied_labels, org, team, commit, act_as, name, tenant } => {
            let kind = kind_of(&id)?;
            anyhow::ensure!(!commit || kind == PrincipalKind::Agent, "--commit is a grant for agents (users and admins always commit)");
            let tenant = tenant.unwrap_or_else(|| eng.cfg.memory.tenant.clone());
            let mut p = match eng.store.principal_get(&id).await? {
                Some(p) => {
                    anyhow::ensure!(p.tenant == tenant, "{id} exists in tenant {}", p.tenant);
                    p
                }
                None => Principal::new(&id, &tenant, kind, "cli"),
            };
            if !subjects.is_empty() {
                p.subjects = subjects;
            }
            p.kinds = kinds.iter().map(|k| MemoryKind::parse(k).ok_or_else(|| anyhow::anyhow!("unknown kind '{k}'"))).collect::<anyhow::Result<_>>()?;
            p.denied_labels = denied_labels;
            p.org = org;
            p.team = team;
            p.can_commit = commit;
            p.act_as = act_as;
            p.name = name.or(p.name);
            eng.store.principal_put(&p).await?;
            eng.store
                .audit(
                    "cli",
                    "principal.put",
                    &p.tenant,
                    None,
                    None,
                    json!({ "principal": p.id, "kind": kind.as_str(), "subjects": p.subjects, "can_commit": p.can_commit, "act_as": p.act_as, "denied_labels": p.denied_labels }),
                )
                .await?;
            println!(
                "{} ({}, tenant {}) subjects {}{}{}",
                p.id,
                kind.as_str(),
                p.tenant,
                p.subjects.join(","),
                if p.can_commit { ", may commit directly" } else { "" },
                if p.act_as { ", may act for users" } else { "" }
            );
            println!("Create a key with: memhouse key create {}", p.id);
        }
        PrincipalCmd::List => {
            for p in eng.store.principals(None).await? {
                let state = if p.disabled_at.is_some() { "disabled" } else { "active" };
                println!("{:<32} {:<6} {:<10} {:<9} subjects {}{}", p.id, p.kind.as_str(), p.tenant, state, p.subjects.join(","), if p.can_commit { " · commit" } else { "" });
            }
        }
        PrincipalCmd::Disable { id } => set_disabled(eng, &id, true).await?,
        PrincipalCmd::Enable { id } => set_disabled(eng, &id, false).await?,
    }
    Ok(())
}

async fn set_disabled(eng: &Engine, id: &str, disabled: bool) -> anyhow::Result<()> {
    let mut p = eng.store.principal_get(id).await?.ok_or_else(|| anyhow::anyhow!("no principal {id}"))?;
    p.disabled_at = disabled.then(chrono::Utc::now);
    eng.store.principal_put(&p).await?;
    eng.store.audit("cli", if disabled { "principal.disable" } else { "principal.enable" }, &p.tenant, None, None, json!({ "principal": id })).await?;
    println!("{id} {}", if disabled { "disabled" } else { "enabled" });
    Ok(())
}

/// Create a key and record it; returns the full key (shown once).
pub async fn create_key(
    eng: &Engine,
    principal: &str,
    scopes: Option<Vec<String>>,
    expires: Option<chrono::Duration>,
    created_by: &str,
) -> anyhow::Result<(identity::ApiKey, String)> {
    let p = eng.store.principal_get(principal).await?.ok_or_else(|| anyhow::anyhow!("no principal {principal}; add it with `memhouse principal add {principal}`"))?;
    let allowed = p.kind.permissions();
    let scopes = scopes.unwrap_or_else(|| allowed.clone());
    if let Some(s) = scopes.iter().find(|s| !allowed.contains(s)) {
        anyhow::bail!("a {} key can't carry {s} (allowed: {})", p.kind.as_str(), allowed.join(", "));
    }
    let (key, full) = identity::new_key(&p.id, scopes, expires.map(|d| chrono::Utc::now() + d), created_by);
    eng.store.api_key_put(&key).await?;
    eng.store.audit(created_by, "key.create", &p.tenant, None, None, json!({ "key": key.id, "principal": p.id, "scopes": key.scopes, "expires_at": key.expires_at })).await?;
    Ok((key, full))
}

pub async fn key(eng: &Engine, cmd: KeyCmd) -> anyhow::Result<()> {
    match cmd {
        KeyCmd::Create { principal, scopes, expires } => {
            let scopes = scopes.map(|s| s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect());
            let (k, full) = create_key(eng, &principal, scopes, expires.as_deref().map(duration).transpose()?, "cli").await?;
            eprintln!(
                "Key {} for {} ({}){}. Store it now: it is not shown again.",
                k.id,
                principal,
                if k.scopes.is_empty() { "no permissions".into() } else { k.scopes.join(", ") },
                k.expires_at.map(|e| format!(", expires {e}")).unwrap_or_default()
            );
            println!("{full}");
        }
        KeyCmd::List { principal } => {
            for k in eng.store.api_keys(principal.as_deref()).await? {
                let state = match (k.revoked_at, k.expires_at) {
                    (Some(_), _) => "revoked".to_string(),
                    (None, Some(e)) if e <= chrono::Utc::now() => "expired".into(),
                    (None, Some(e)) => format!("expires {}", e.format("%Y-%m-%d %H:%M")),
                    (None, None) => "active".into(),
                };
                println!("{}  {:<28} {:<22} {}", k.id, k.principal_id, state, k.scopes.join(","));
            }
        }
        KeyCmd::Revoke { id } => {
            let k = eng.store.api_key_get(&id).await?.ok_or_else(|| anyhow::anyhow!("no key {id}"))?;
            anyhow::ensure!(eng.store.api_key_end(&id, None).await?, "key {id} was already revoked");
            eng.store.audit("cli", "key.revoke", &tenant_of(eng, &k.principal_id).await?, None, None, json!({ "key": id, "principal": k.principal_id })).await?;
            println!("revoked {id} (its tokens stop working within 5 seconds)");
        }
        KeyCmd::Rotate { id, grace } => {
            let old = eng.store.api_key_get(&id).await?.ok_or_else(|| anyhow::anyhow!("no key {id}"))?;
            anyhow::ensure!(old.revoked_at.is_none(), "key {id} is revoked");
            let lifetime = old.expires_at.map(|e| e - old.created_at);
            let (k, full) = create_key(eng, &old.principal_id, Some(old.scopes.clone()), lifetime, "cli").await?;
            let until = chrono::Utc::now() + duration(&grace)?;
            eng.store.api_key_end(&id, Some(until)).await?;
            eng.store.audit("cli", "key.rotate", &tenant_of(eng, &old.principal_id).await?, None, None, json!({ "old": id, "new": k.id, "old_expires_at": until })).await?;
            eprintln!("Key {} replaces {id}, which keeps working until {until}. Store the new key now.", k.id);
            println!("{full}");
        }
    }
    Ok(())
}

async fn tenant_of(eng: &Engine, principal: &str) -> anyhow::Result<String> {
    Ok(eng.store.principal_get(principal).await?.map(|p| p.tenant).unwrap_or_else(|| eng.cfg.memory.tenant.clone()))
}

/// The key `memhouse connect` gives an agent: its own principal `agent:<name>` (created if
/// missing), propose-only, with a fresh key; earlier keys made by connect for it are revoked.
pub async fn agent_key(eng: &Engine, agent: &str) -> anyhow::Result<String> {
    let id = format!("agent:{agent}");
    if eng.store.principal_get(&id).await?.is_none() {
        let p = Principal::new(&id, &eng.cfg.memory.tenant, PrincipalKind::Agent, "memhouse connect");
        eng.store.principal_put(&p).await?;
        eng.store.audit("cli", "principal.put", &p.tenant, None, None, json!({ "principal": id, "kind": "agent" })).await?;
    }
    for k in eng.store.api_keys(Some(&id)).await? {
        if k.created_by == "memhouse connect" && k.revoked_at.is_none() {
            eng.store.api_key_end(&k.id, None).await?;
        }
    }
    let scopes = vec![perm::READ.to_string(), perm::WRITE.to_string(), perm::FORGET.to_string()];
    Ok(create_key(eng, &id, Some(scopes), None, "memhouse connect").await?.1)
}
