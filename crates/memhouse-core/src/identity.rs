// SPDX-License-Identifier: Apache-2.0
//! Principals and credentials (GOV-01, GOV-13, TR-LT-07): who is calling, verified on every call.
//!
//! - A **principal** is an agent, a user or an admin, bound to one tenant.
//! - An **API key** belongs to one principal and carries permissions (a subset of the principal's
//!   role). Only a hash of its secret is stored: `mh_<id>_<secret>`, looked up by `id`.
//! - An **agent token** is short-lived (at most an hour) and signed by the deployment: it names an
//!   agent principal, optionally the user it acts for (verified when a user key issued it, or
//!   asserted by a principal trusted to act for users), and narrower permissions.
//! - Keys in `[server] api_keys` are bootstrap keys of the built-in principal `admin:bootstrap`.
//!
//! [`Authenticator`] turns a presented credential into an [`Identity`], with a 5-second cache so a
//! revocation or a disabled principal takes effect within 5 seconds.

use crate::config::Config;
use crate::error;
use crate::traits::Store;
use crate::types::MemoryKind;
use chrono::{DateTime, Utc};
use rand::RngExt;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Permissions a key or token can carry. Every operation needs one (`access::Operation`).
pub mod perm {
    pub const READ: &str = "memory:read";
    pub const WRITE: &str = "memory:write";
    pub const FORGET: &str = "memory:forget";
    pub const ERASE: &str = "memory:erase";
    pub const LABEL: &str = "memory:label";
    pub const REVIEW: &str = "memory:review";
    pub const TOKEN: &str = "token:issue";
    pub const OPS: &str = "ops:read";
    pub const AUDIT: &str = "audit:read";
    /// Read the tenant's policies, validate and diff specs (G08).
    pub const POLICY_READ: &str = "policy:read";
    /// Propose a policy spec.
    pub const POLICY_PROPOSE: &str = "policy:propose";
    /// Approve a proposed spec, or roll back to an earlier one.
    pub const POLICY_APPROVE: &str = "policy:approve";
    /// Create, list and revoke grants between agents (INT-06).
    pub const GRANT: &str = "grant:manage";
    pub const ALL: [&str; 13] = [READ, WRITE, FORGET, ERASE, LABEL, REVIEW, TOKEN, OPS, AUDIT, POLICY_READ, POLICY_PROPOSE, POLICY_APPROVE, GRANT];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PrincipalKind {
    /// Software acting for users: proposes memories, recalls them.
    Agent,
    /// A person, calling directly or through an agent it delegates to.
    User,
    /// Operates the deployment: erasure, review, audit.
    Admin,
}

impl PrincipalKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            PrincipalKind::Agent => "agent",
            PrincipalKind::User => "user",
            PrincipalKind::Admin => "admin",
        }
    }

    pub fn parse(s: &str) -> Option<PrincipalKind> {
        [PrincipalKind::Agent, PrincipalKind::User, PrincipalKind::Admin].into_iter().find(|k| k.as_str() == s)
    }

    /// The most a key of this kind of principal may carry.
    pub fn permissions(&self) -> Vec<String> {
        let p: &[&str] = match self {
            PrincipalKind::Agent => &[perm::READ, perm::WRITE, perm::FORGET, perm::TOKEN],
            PrincipalKind::User => &[perm::READ, perm::WRITE, perm::FORGET, perm::LABEL, perm::TOKEN],
            PrincipalKind::Admin => &perm::ALL,
        };
        p.iter().map(|s| s.to_string()).collect()
    }
}

/// An agent, user or admin. Ids are unique across tenants (`agent:support-bot`, `user:ana`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Principal {
    pub id: String,
    pub tenant: String,
    pub kind: PrincipalKind,
    #[serde(default)]
    pub name: Option<String>,
    /// Subjects it may use: exact names or prefixes ending in `*` (`customer:*`); `*` is all.
    pub subjects: Vec<String>,
    /// Memory kinds it may read and write; empty is all.
    #[serde(default)]
    pub kinds: Vec<MemoryKind>,
    /// Labels it may never read or write, on top of the role's and the tenant's.
    #[serde(default)]
    pub denied_labels: Vec<String>,
    /// Scope attributes injected into its recalls (MEM-04).
    #[serde(default)]
    pub org: Option<String>,
    #[serde(default)]
    pub team: Option<String>,
    /// Agents only: writes commit directly instead of being proposed (GOV-08). An audited grant.
    #[serde(default)]
    pub can_commit: bool,
    /// May state which user it acts for (`x-memhouse-user`, or `user` when issuing a token): a
    /// trusted backend that authenticated the user itself.
    #[serde(default)]
    pub act_as: bool,
    #[serde(default)]
    pub disabled_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub created_by: String,
}

impl Principal {
    pub fn new(id: &str, tenant: &str, kind: PrincipalKind, created_by: &str) -> Principal {
        Principal {
            id: id.into(),
            tenant: tenant.into(),
            kind,
            name: None,
            subjects: vec!["*".into()],
            kinds: vec![],
            denied_labels: vec![],
            org: None,
            team: None,
            can_commit: false,
            act_as: false,
            disabled_at: None,
            created_at: Utc::now(),
            created_by: created_by.into(),
        }
    }

    pub fn may_use_subject(&self, subject: &str) -> bool {
        self.subjects.iter().any(|p| p == "*" || p == subject || p.strip_suffix('*').is_some_and(|pre| subject.starts_with(pre)))
    }

    /// Principal ids look like `<kind>:<name>`.
    pub fn check_id(id: &str, kind: PrincipalKind) -> anyhow::Result<()> {
        let ok = id
            .strip_prefix(kind.as_str())
            .and_then(|r| r.strip_prefix(':'))
            .is_some_and(|n| !n.is_empty() && n.len() <= 120 && n.chars().all(|c| c.is_ascii_alphanumeric() || "-_.@:".contains(c)));
        if !ok {
            return Err(error::invalid(format!("principal id must be {}:<name> (letters, digits, - _ . @ :), got '{id}'", kind.as_str())));
        }
        Ok(())
    }
}

/// A stored API key: the hash of its secret, never the secret.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiKey {
    pub id: String,
    pub principal_id: String,
    /// sha256 of the secret part, hex.
    pub hash: String,
    pub scopes: Vec<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub created_by: String,
}

const KEY_CHARS: &[u8] = b"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";

fn random(n: usize) -> String {
    let mut r = rand::rng();
    (0..n).map(|_| KEY_CHARS[r.random_range(0..KEY_CHARS.len())] as char).collect()
}

fn sha256_hex(b: &[u8]) -> String {
    hex::encode(Sha256::digest(b))
}

/// A new key for a principal: the stored record and the full key, shown once.
pub fn new_key(principal_id: &str, scopes: Vec<String>, expires_at: Option<DateTime<Utc>>, created_by: &str) -> (ApiKey, String) {
    let (id, secret) = (random(12), random(32));
    let key = ApiKey {
        id: id.clone(),
        principal_id: principal_id.into(),
        hash: sha256_hex(secret.as_bytes()),
        scopes,
        expires_at,
        revoked_at: None,
        created_at: Utc::now(),
        created_by: created_by.into(),
    };
    (key, format!("mh_{id}_{secret}"))
}

fn parse_key(k: &str) -> Option<(&str, &str)> {
    let rest = k.strip_prefix("mh_")?;
    let (id, secret) = rest.split_once('_')?;
    (id.len() == 12 && secret.len() == 32).then_some((id, secret))
}

pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// HMAC-SHA256 (RFC 2104).
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let (mut ipad, mut opad) = ([0x36u8; 64], [0x5cu8; 64]);
    for i in 0..64 {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let inner = Sha256::new().chain_update(ipad).chain_update(msg).finalize();
    Sha256::new().chain_update(opad).chain_update(inner).finalize().into()
}

const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64url(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..=c.len() {
            out.push(B64[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

fn unb64url(s: &str) -> Option<Vec<u8>> {
    let vals: Vec<u32> = s.bytes().map(|b| B64.iter().position(|&x| x == b).map(|p| p as u32)).collect::<Option<_>>()?;
    let mut out = vec![];
    for c in vals.chunks(4) {
        if c.len() == 1 {
            return None;
        }
        let n = c.iter().enumerate().fold(0u32, |n, (i, v)| n | v << (18 - 6 * i));
        out.extend(&[(n >> 16) as u8, (n >> 8) as u8, n as u8][..c.len() - 1]);
    }
    Some(out)
}

/// What an agent token says. Signed with the deployment's signing key `kid`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenClaims {
    pub kid: String,
    /// The agent principal.
    pub sub: String,
    pub ten: String,
    /// The verified user it acts for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usr: Option<String>,
    pub scp: Vec<String>,
    /// The key that issued it: revoking the key revokes its tokens.
    pub key: String,
    pub iat: i64,
    pub exp: i64,
}

pub fn sign_token(claims: &TokenClaims, secret: &[u8]) -> String {
    let body = b64url(serde_json::to_string(claims).expect("claims serialize").as_bytes());
    let sig = b64url(&hmac_sha256(secret, body.as_bytes()));
    format!("mht.{body}.{sig}")
}

/// The claims of a token, unverified (to find its signing key).
fn token_parts(t: &str) -> Option<(TokenClaims, &str, &str)> {
    let rest = t.strip_prefix("mht.")?;
    let (body, sig) = rest.split_once('.')?;
    let claims = serde_json::from_slice(&unb64url(body)?).ok()?;
    Some((claims, body, sig))
}

/// How the caller proved who it is.
#[derive(Debug, Clone, PartialEq, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    /// An API key of the principal.
    Key,
    /// A short-lived agent token.
    Token,
    /// A key from `[server] api_keys`.
    Bootstrap,
    /// The CLI and the benchmark, which hold the database credentials themselves.
    Operator,
}

/// A verified caller.
#[derive(Debug, Clone)]
pub struct Identity {
    pub principal: Principal,
    /// The user the call acts for: the principal itself for a user, the token's or asserted user
    /// for an agent.
    pub user: Option<String>,
    /// Permissions of this credential (within the principal's role).
    pub scopes: Vec<String>,
    /// The key presented, or the key that issued the token.
    pub key_id: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub via: Via,
}

pub const BOOTSTRAP: &str = "admin:bootstrap";

impl Identity {
    /// The trusted local operator (CLI, benchmark): an admin of the configured tenant.
    pub fn operator(cfg: &Config, name: &str) -> Identity {
        let mut p = Principal::new(&format!("admin:{name}"), &cfg.memory.tenant, PrincipalKind::Admin, "config");
        p.created_at = DateTime::<Utc>::UNIX_EPOCH;
        Identity { principal: p, user: None, scopes: perm::ALL.iter().map(|s| s.to_string()).collect(), key_id: None, expires_at: None, via: Via::Operator }
    }

    pub fn id(&self) -> &str {
        &self.principal.id
    }

    pub fn is_admin(&self) -> bool {
        self.principal.kind == PrincipalKind::Admin
    }

    pub fn has(&self, permission: &str) -> bool {
        self.scopes.iter().any(|s| s == permission)
    }
}

/// Why a credential was refused. The reason goes to the audit log, never the credential.
#[derive(Debug, Clone)]
pub struct AuthFailure {
    pub reason: &'static str,
    pub key_id: Option<String>,
    pub principal: Option<String>,
}

impl std::fmt::Display for AuthFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.reason)
    }
}

type Cached = (Instant, Result<Identity, AuthFailure>);

/// Verifies credentials, issues tokens.
pub struct Authenticator {
    store: Arc<dyn Store>,
    cfg: Arc<Config>,
    cache: Mutex<HashMap<String, Cached>>,
    ttl: Duration,
}

/// What `issue_token` returns.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TokenResponse {
    /// Send as `Authorization: Bearer <token>`.
    pub token: String,
    pub expires_at: DateTime<Utc>,
    /// The agent principal the token acts as.
    pub agent: String,
    /// The user it acts for, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    pub scopes: Vec<String>,
}

impl Authenticator {
    pub fn new(store: Arc<dyn Store>, cfg: Arc<Config>) -> Authenticator {
        Authenticator { store, cfg, cache: Mutex::new(HashMap::new()), ttl: Duration::from_secs(5) }
    }

    /// Cache lifetime (tests set zero to see revocations at once).
    pub fn with_cache_ttl(mut self, ttl: Duration) -> Authenticator {
        self.ttl = ttl;
        self
    }

    /// Verify a presented key or token, and the user it asserts (`x-memhouse-user`).
    pub async fn authenticate(&self, presented: &str, asserted_user: Option<&str>) -> Result<Identity, AuthFailure> {
        let cache_key = sha256_hex(format!("{presented}\u{1f}{}", asserted_user.unwrap_or("")).as_bytes());
        if let Some((at, r)) = self.cache.lock().expect("cache lock").get(&cache_key) {
            if at.elapsed() < self.ttl {
                return r.clone();
            }
        }
        let r = self.verify(presented, asserted_user).await;
        let mut cache = self.cache.lock().expect("cache lock");
        if cache.len() > 10_000 {
            cache.clear();
        }
        cache.insert(cache_key, (Instant::now(), r.clone()));
        r
    }

    async fn verify(&self, presented: &str, asserted_user: Option<&str>) -> Result<Identity, AuthFailure> {
        let fail = |reason, key_id: Option<&str>, principal: Option<&str>| AuthFailure { reason, key_id: key_id.map(String::from), principal: principal.map(String::from) };
        let presented = presented.trim();
        if presented.starts_with("mht.") {
            let (claims, body, sig) = token_parts(presented).ok_or_else(|| fail("malformed token", None, None))?;
            let secret = match self.store.signing_key(&claims.kid).await {
                Ok(Some(s)) => s,
                _ => return Err(fail("unknown signing key", Some(&claims.key), Some(&claims.sub))),
            };
            let expect = b64url(&hmac_sha256(&secret, body.as_bytes()));
            if !constant_time_eq(expect.as_bytes(), sig.as_bytes()) {
                return Err(fail("forged token", Some(&claims.key), Some(&claims.sub)));
            }
            if claims.exp <= Utc::now().timestamp() {
                return Err(fail("expired token", Some(&claims.key), Some(&claims.sub)));
            }
            if asserted_user.is_some_and(|u| Some(u) != claims.usr.as_deref()) {
                return Err(fail("a token's user can't be overridden", Some(&claims.key), Some(&claims.sub)));
            }
            // The issuing key must still be valid; bootstrap keys issue under their own name.
            if claims.key != BOOTSTRAP {
                let key = self.store.api_key_get(&claims.key).await.ok().flatten();
                if !key.is_some_and(|k| k.revoked_at.is_none() && k.expires_at.is_none_or(|e| e > Utc::now())) {
                    return Err(fail("the key that issued this token is revoked or expired", Some(&claims.key), Some(&claims.sub)));
                }
            }
            let principal = self.live_principal(&claims.sub).await.map_err(|r| fail(r, Some(&claims.key), Some(&claims.sub)))?;
            if principal.tenant != claims.ten || principal.kind != PrincipalKind::Agent {
                return Err(fail("token doesn't match its principal", Some(&claims.key), Some(&claims.sub)));
            }
            let allowed = principal.kind.permissions();
            let scopes = claims.scp.iter().filter(|s| allowed.contains(s) && s.as_str() != perm::TOKEN).cloned().collect();
            return Ok(Identity {
                principal,
                user: claims.usr.clone(),
                scopes,
                key_id: Some(claims.key.clone()),
                expires_at: DateTime::from_timestamp(claims.exp, 0),
                via: Via::Token,
            });
        }
        if self.cfg.server.api_keys.iter().any(|k| constant_time_eq(k.as_bytes(), presented.as_bytes())) {
            let mut id = Identity::operator(&self.cfg, "bootstrap");
            id.via = Via::Bootstrap;
            id.key_id = Some(BOOTSTRAP.into());
            id.user = asserted_user.map(String::from);
            return Ok(id);
        }
        let (key_id, secret) = parse_key(presented).ok_or_else(|| fail("unknown credential", None, None))?;
        let key = match self.store.api_key_get(key_id).await {
            Ok(Some(k)) => k,
            _ => return Err(fail("unknown key", Some(key_id), None)),
        };
        if !constant_time_eq(key.hash.as_bytes(), sha256_hex(secret.as_bytes()).as_bytes()) {
            return Err(fail("wrong key secret", Some(key_id), Some(&key.principal_id)));
        }
        if key.revoked_at.is_some() {
            return Err(fail("revoked key", Some(key_id), Some(&key.principal_id)));
        }
        if key.expires_at.is_some_and(|e| e <= Utc::now()) {
            return Err(fail("expired key", Some(key_id), Some(&key.principal_id)));
        }
        let principal = self.live_principal(&key.principal_id).await.map_err(|r| fail(r, Some(key_id), Some(&key.principal_id)))?;
        let allowed = principal.kind.permissions();
        let scopes = key.scopes.iter().filter(|s| allowed.contains(s)).cloned().collect();
        let user = match (principal.kind, asserted_user) {
            (PrincipalKind::User, Some(u)) if u != principal.id => return Err(fail("a user key acts only for its own user", Some(key_id), Some(&principal.id))),
            (PrincipalKind::User, _) => Some(principal.id.clone()),
            (_, Some(u)) if principal.act_as || principal.kind == PrincipalKind::Admin => Some(u.to_string()),
            (_, Some(_)) => return Err(fail("this principal may not state which user it acts for (act_as)", Some(key_id), Some(&principal.id))),
            (_, None) => None,
        };
        Ok(Identity { principal, user, scopes, key_id: Some(key_id.into()), expires_at: key.expires_at, via: Via::Key })
    }

    async fn live_principal(&self, id: &str) -> Result<Principal, &'static str> {
        match self.store.principal_get(id).await {
            Ok(Some(p)) if p.disabled_at.is_none() => Ok(p),
            Ok(Some(_)) => Err("disabled principal"),
            _ => Err("unknown principal"),
        }
    }

    /// Sign a token for `agent`, acting for `user`, with `scopes` (already authorized).
    pub async fn sign(&self, agent: &Principal, user: Option<String>, scopes: Vec<String>, issuing_key: &str, ttl_secs: u64) -> anyhow::Result<TokenResponse> {
        let (kid, secret) = self.store.signing_key_current().await?;
        let now = Utc::now();
        let ttl = ttl_secs.clamp(1, self.cfg.access.token_ttl_secs.min(3600));
        let exp = now + chrono::Duration::seconds(ttl as i64);
        let claims = TokenClaims {
            kid,
            sub: agent.id.clone(),
            ten: agent.tenant.clone(),
            usr: user.clone(),
            scp: scopes.clone(),
            key: issuing_key.into(),
            iat: now.timestamp(),
            exp: exp.timestamp(),
        };
        Ok(TokenResponse { token: sign_token(&claims, &secret), expires_at: DateTime::from_timestamp(exp.timestamp(), 0).unwrap_or(exp), agent: agent.id.clone(), user, scopes })
    }
}

/// A fresh random signing secret.
pub fn new_signing_secret() -> (String, Vec<u8>) {
    let mut r = rand::rng();
    (random(8), (0..32).map(|_| r.random::<u8>()).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_matches_rfc_4231() {
        assert_eq!(hex::encode(hmac_sha256(b"Jefe", b"what do ya want for nothing?")), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
        assert_eq!(
            hex::encode(hmac_sha256(&[0xaa; 131], b"Test Using Larger Than Block-Size Key - Hash Key First")),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        );
    }

    #[test]
    fn base64url_round_trips() {
        for n in 0..40 {
            let data: Vec<u8> = (0..n).map(|i| (i * 37 + 11) as u8).collect();
            assert_eq!(unb64url(&b64url(&data)).unwrap(), data, "{n}");
        }
        assert_eq!(b64url(b"Man"), "TWFu");
        assert!(unb64url("a").is_none() && unb64url("ab=c").is_none());
    }

    #[test]
    fn tokens_detect_tampering() {
        let claims =
            TokenClaims { kid: "k1".into(), sub: "agent:a".into(), ten: "t".into(), usr: Some("user:u".into()), scp: vec![perm::READ.into()], key: "abc".into(), iat: 0, exp: 10 };
        let t = sign_token(&claims, b"secret");
        let (c, body, sig) = token_parts(&t).unwrap();
        assert_eq!(c.usr.as_deref(), Some("user:u"));
        assert_eq!(b64url(&hmac_sha256(b"secret", body.as_bytes())), sig);
        let mut forged = claims.clone();
        forged.usr = Some("user:admin".into());
        let f = sign_token(&forged, b"guess");
        let (_, fb, fs) = token_parts(&f).unwrap();
        assert_ne!(b64url(&hmac_sha256(b"secret", fb.as_bytes())), fs);
    }

    #[test]
    fn keys_and_subject_patterns() {
        let (k, full) = new_key("agent:a", vec![], None, "test");
        let (id, secret) = parse_key(&full).unwrap();
        assert_eq!(id, k.id);
        assert_eq!(sha256_hex(secret.as_bytes()), k.hash);
        assert!(parse_key("mh_short_x").is_none());
        let mut p = Principal::new("agent:a", "t", PrincipalKind::Agent, "test");
        p.subjects = vec!["customer:*".into(), "repo:api".into()];
        assert!(p.may_use_subject("customer:42") && p.may_use_subject("repo:api"));
        assert!(!p.may_use_subject("repo:apis") && !p.may_use_subject("user:ana"));
        assert!(Principal::check_id("agent:support-bot", PrincipalKind::Agent).is_ok());
        assert!(Principal::check_id("user:support-bot", PrincipalKind::Agent).is_err());
        assert!(Principal::check_id("agent:", PrincipalKind::Agent).is_err());
    }
}
