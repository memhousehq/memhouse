// SPDX-License-Identifier: Apache-2.0
//! Postgres store adapter: pgvector for exact per-subject vector scoring, built-in full-text search
//! for keywords, hybrid fusion in a single SQL statement (TR-RQ), hash-chained audit, deletion ledger.

use async_trait::async_trait;
use chrono::{DateTime, SubsecRound, Utc};
use memhouse_core::format::{PolicyLine, RecordLine};
use memhouse_core::types::*;
use memhouse_core::Store;
use sha2::{Digest, Sha256};
use sqlx::postgres::{PgPool, PgPoolOptions, PgRow};
use sqlx::Row;
use uuid::Uuid;

/// A statement `format!`ted from this file's constants, numbers and fixed column names only;
/// values from callers are always bound, never formatted in (what sqlx's `AssertSqlSafe` asserts).
macro_rules! trusted_sql {
    ($($t:tt)*) => {
        sqlx::AssertSqlSafe(format!($($t)*))
    };
}

/// The logical schema version this build migrates to (see `docs/schema.md`).
pub const SCHEMA_VERSION: u32 = memhouse_core::format::SCHEMA_VERSION;

#[derive(Clone)]
pub struct PgStore {
    pub pool: PgPool,
    /// Prefix the engine adds to passages before embedding; needed to purge cache entries on deletion.
    passage_prefix: String,
    /// The embedder this process writes with (set by `migrate`), stamped on every row so the
    /// database refuses vectors from a process left on the old model after a re-embedding.
    embedder: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    /// Configuration hash of that embedder (model, dimension, prefix), stamped with every vector.
    embedder_config: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    /// When the database's embedder was last compared with ours (recall checks every 5 s).
    checked: std::sync::Arc<std::sync::Mutex<Option<std::time::Instant>>>,
    recheck: std::time::Duration,
}

fn drop_next_columns() -> String {
    let cols: Vec<String> = NEXT_COLS.iter().map(|(next, _)| format!("DROP COLUMN IF EXISTS {next}")).collect();
    format!("ALTER TABLE mh_memory {}", cols.join(", "))
}

/// Columns that hold vectors for the re-embedding target until the switch.
const NEXT_COLS: [(&str, &str); 5] = [
    ("embedding_next", "embedding"),
    ("embedding_alt_next", "embedding_alt"),
    ("alt_hash_next", "alt_hash"),
    ("embedder_next", "embedder"),
    ("embedder_config_next", "embedder_config"),
];

const COLS: &str = "m.id, m.tenant, m.subject, m.kind, m.status, m.content, m.session_id, m.turn_ref, \
    m.occurred_at, m.valid_from, m.valid_to, m.supersedes, m.labels, m.tags, m.source, m.confidence, \
    m.metadata, m.created_at, m.expires_at, m.scope_org, m.scope_team, m.scope_agent, m.scope_user, m.scope_session, \
    m.prov_agent, m.prov_user, m.policy_version, m.request_key, m.extractor, m.extractor_config";

fn vec_literal(v: &[f32]) -> String {
    let mut s = String::with_capacity(v.len() * 10 + 2);
    s.push('[');
    for (i, x) in v.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!("{x}"));
    }
    s.push(']');
    s
}

/// Turn free text into an OR-of-terms tsquery string that is always syntactically valid.
pub fn or_query(text: &str) -> String {
    let mut terms: Vec<String> = text.split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() >= 2).map(|w| w.to_lowercase()).collect();
    terms.sort();
    terms.dedup();
    terms.truncate(64);
    terms.join(" | ")
}

fn row_to_memory(r: &PgRow) -> anyhow::Result<Memory> {
    let kind: String = r.try_get("kind")?;
    let status: String = r.try_get("status")?;
    Ok(Memory {
        id: r.try_get("id")?,
        tenant: r.try_get("tenant")?,
        subject: r.try_get("subject")?,
        kind: MemoryKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown kind '{kind}' in the database"))?,
        status: MemoryStatus::parse(&status).ok_or_else(|| anyhow::anyhow!("unknown status '{status}' in the database"))?,
        content: r.try_get("content")?,
        session_id: r.try_get("session_id")?,
        turn_ref: r.try_get("turn_ref")?,
        occurred_at: r.try_get("occurred_at")?,
        valid_from: r.try_get("valid_from")?,
        valid_to: r.try_get("valid_to")?,
        supersedes: r.try_get("supersedes")?,
        labels: r.try_get("labels")?,
        tags: r.try_get("tags")?,
        source: r.try_get("source")?,
        confidence: r.try_get("confidence")?,
        metadata: r.try_get("metadata")?,
        created_at: r.try_get("created_at")?,
        expires_at: r.try_get("expires_at")?,
        scope: Scope {
            org: r.try_get("scope_org")?,
            team: r.try_get("scope_team")?,
            agent: r.try_get("scope_agent")?,
            user: r.try_get("scope_user")?,
            session: r.try_get("scope_session")?,
        },
        provenance: Provenance {
            agent: r.try_get("prov_agent")?,
            user: r.try_get("prov_user")?,
            policy_version: r.try_get("policy_version")?,
            request_key: r.try_get("request_key")?,
            extractor: r.try_get("extractor")?,
            extractor_config: r.try_get("extractor_config")?,
        },
    })
}

fn row_to_link(r: &PgRow) -> anyhow::Result<Link> {
    Ok(Link {
        tenant: r.try_get("tenant")?,
        subject: r.try_get("subject")?,
        linked_subject: r.try_get("linked_subject")?,
        link_type: r.try_get("link_type")?,
        memory_id: r.try_get("memory_id")?,
        created_by: r.try_get("created_by")?,
        created_at: r.try_get("created_at")?,
    })
}

/// A full export record: the memory plus what only the store holds.
fn row_to_record(r: &PgRow) -> anyhow::Result<RecordLine> {
    let m = row_to_memory(r)?;
    let record_type: Option<String> = r.try_get("record_type")?;
    let attrs: Option<serde_json::Value> = r.try_get("attrs")?;
    let code_refs: serde_json::Value = r.try_get("code_refs")?;
    Ok(RecordLine {
        id: m.id,
        tenant: m.tenant,
        subject: m.subject,
        kind: m.kind,
        status: m.status,
        content: m.content,
        content_hash: r.try_get("content_hash")?,
        session_id: m.session_id,
        turn_ref: m.turn_ref,
        occurred_at: m.occurred_at,
        valid_from: m.valid_from,
        valid_to: m.valid_to,
        expires_at: m.expires_at,
        supersedes: m.supersedes,
        superseded_by: r.try_get("superseded_by")?,
        labels: m.labels,
        tags: m.tags,
        scope: m.scope,
        source: m.source,
        confidence: m.confidence,
        provenance: m.provenance,
        alt_hash: r.try_get("alt_hash")?,
        structured: record_type.map(|t| Structured { record_type: t, attrs: attrs.unwrap_or_else(|| serde_json::json!({})) }),
        code_refs: serde_json::from_value(code_refs)?,
        metadata: m.metadata,
        created_at: m.created_at,
        updated_at: r.try_get("updated_at")?,
    })
}

/// The v2 additions (`docs/schema.md`). Expand-only: new columns are nullable and new tables
/// stand alone, so a v1 process keeps working against a v2 database.
const SCHEMA_V2_DDL: &str = r#"
ALTER TABLE mh_memory
  ADD COLUMN IF NOT EXISTS expires_at       timestamptz,
  ADD COLUMN IF NOT EXISTS scope_org        text,
  ADD COLUMN IF NOT EXISTS scope_team       text,
  ADD COLUMN IF NOT EXISTS scope_agent      text,
  ADD COLUMN IF NOT EXISTS scope_user       text,
  ADD COLUMN IF NOT EXISTS scope_session    text,
  ADD COLUMN IF NOT EXISTS prov_agent       text,
  ADD COLUMN IF NOT EXISTS prov_user        text,
  ADD COLUMN IF NOT EXISTS policy_version   text,
  ADD COLUMN IF NOT EXISTS request_key      text,
  ADD COLUMN IF NOT EXISTS extractor        text,
  ADD COLUMN IF NOT EXISTS extractor_config text,
  ADD COLUMN IF NOT EXISTS embedder_config  text;
CREATE INDEX IF NOT EXISTS mh_memory_expiry_idx ON mh_memory (tenant, expires_at) WHERE expires_at IS NOT NULL;

-- Structured records (HYB-02): the queryable form, under the text record's id (HYB-04).
CREATE TABLE IF NOT EXISTS mh_structured (
  memory_id   uuid PRIMARY KEY REFERENCES mh_memory (id) ON DELETE CASCADE,
  tenant      text NOT NULL,
  subject     text NOT NULL,
  record_type text NOT NULL,
  attrs       jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS mh_structured_type_idx ON mh_structured (tenant, subject, record_type);
CREATE INDEX IF NOT EXISTS mh_structured_attrs_idx ON mh_structured USING gin (attrs jsonb_path_ops);

-- Files a memory is about (TR-TPL-02); a changed blob hash marks the memory stale.
CREATE TABLE IF NOT EXISTS mh_code_ref (
  memory_id  uuid NOT NULL REFERENCES mh_memory (id) ON DELETE CASCADE,
  tenant     text NOT NULL,
  subject    text NOT NULL,
  path       text NOT NULL,
  blob_hash  text NOT NULL,
  PRIMARY KEY (memory_id, path)
);
CREATE INDEX IF NOT EXISTS mh_code_ref_path_idx ON mh_code_ref (tenant, subject, path);

-- Links between subjects (ACC-06), held by the subject that has them.
CREATE TABLE IF NOT EXISTS mh_link (
  tenant         text NOT NULL,
  subject        text NOT NULL,
  linked_subject text NOT NULL,
  link_type      text NOT NULL,
  memory_id      uuid REFERENCES mh_memory (id) ON DELETE CASCADE,
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  PRIMARY KEY (tenant, subject, linked_subject, link_type)
);
CREATE INDEX IF NOT EXISTS mh_link_linked_idx ON mh_link (tenant, linked_subject);

-- Idempotency keys (CORE-06): the first response to a key is returned for its repeats.
CREATE TABLE IF NOT EXISTS mh_request_key (
  tenant       text NOT NULL,
  key          text NOT NULL,
  subject      text NOT NULL,
  operation    text NOT NULL,
  request_hash text NOT NULL,
  response     jsonb NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant, key)
);
CREATE INDEX IF NOT EXISTS mh_request_key_subject_idx ON mh_request_key (tenant, subject);

-- Compiled policies that admitted records (provenance.policy_version).
CREATE TABLE IF NOT EXISTS mh_policy (
  version    text PRIMARY KEY,
  body       jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
"#;

/// The v3 additions (G06): principals, their API keys and the token signing keys. Identity is not
/// memory: these tables are not exported in the Memory Format.
const SCHEMA_V3_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_principal (
  id            text PRIMARY KEY,
  tenant        text NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('agent', 'user', 'admin')),
  name          text,
  subjects      text[] NOT NULL DEFAULT '{*}',
  kinds         text[] NOT NULL DEFAULT '{}',
  denied_labels text[] NOT NULL DEFAULT '{}',
  org           text,
  team          text,
  can_commit    boolean NOT NULL DEFAULT false,
  act_as        boolean NOT NULL DEFAULT false,
  disabled_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text NOT NULL
);
CREATE INDEX IF NOT EXISTS mh_principal_tenant_idx ON mh_principal (tenant);

-- Only the sha256 of a key's secret is kept; the key id is public.
CREATE TABLE IF NOT EXISTS mh_api_key (
  id           text PRIMARY KEY,
  principal_id text NOT NULL REFERENCES mh_principal (id),
  hash         text NOT NULL,
  scopes       text[] NOT NULL,
  expires_at   timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text NOT NULL
);
CREATE INDEX IF NOT EXISTS mh_api_key_principal_idx ON mh_api_key (principal_id);

-- Secrets that sign agent tokens; the newest unretired one signs, any listed one verifies.
CREATE TABLE IF NOT EXISTS mh_signing_key (
  id         text PRIMARY KEY,
  secret     bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz
);
"#;

/// The v4 addition (G07): recall explanations (GOV-04). Kept with their subject: erasing the
/// subject, user or tenant erases them, and retention purges them.
const SCHEMA_V4_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_recall (
  id          uuid PRIMARY KEY,
  tenant      text NOT NULL,
  subject     text NOT NULL,
  principal   text NOT NULL,
  acting_user text,
  at          timestamptz NOT NULL,
  body        jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS mh_recall_subject_idx ON mh_recall (tenant, subject);
CREATE INDEX IF NOT EXISTS mh_recall_user_idx ON mh_recall (tenant, acting_user) WHERE acting_user IS NOT NULL;
CREATE INDEX IF NOT EXISTS mh_recall_at_idx ON mh_recall (at);
"#;

/// The v5 additions (G08): behaviour policy specs, their approval and activations. Specs are
/// numbered per tenant; an activation names an approved spec or, with no version, the default
/// policy. The trigger refuses to activate anything else (POL-03).
/// v6 (G10): the intake queue of the write pipeline (ADR 0004). Content is redacted before it
/// gets here; a finished proposal keeps only its ids and outcome until it is pruned.
const SCHEMA_V6_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_intake (
  id           uuid PRIMARY KEY,
  seq          bigserial,
  tenant       text NOT NULL,
  subject      text NOT NULL,
  record_ids   uuid[] NOT NULL,
  agent        text,
  acting_user  text,
  source       text,
  scope_agent  text,
  scope_user   text,
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'dead')),
  attempts     int NOT NULL DEFAULT 0,
  run_after    timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  enqueued_at  timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  payload      jsonb,
  outcome      jsonb,
  error        text
);
-- Small by design: only unfinished proposals are indexed for claiming, and finished ones are pruned.
CREATE INDEX IF NOT EXISTS mh_intake_queue_idx ON mh_intake (seq) WHERE status IN ('pending', 'running');
CREATE INDEX IF NOT EXISTS mh_intake_order_idx ON mh_intake (tenant, subject, seq) WHERE status IN ('pending', 'running');
CREATE INDEX IF NOT EXISTS mh_intake_records_idx ON mh_intake USING gin (record_ids);
CREATE INDEX IF NOT EXISTS mh_intake_done_idx ON mh_intake (finished_at) WHERE status = 'done';
-- A process still on the old model after a re-embedding can't queue writes either.
ALTER TABLE mh_intake ADD COLUMN IF NOT EXISTS embedder text;
CREATE OR REPLACE TRIGGER mh_intake_embedder_guard BEFORE INSERT ON mh_intake FOR EACH ROW EXECUTE FUNCTION mh_memory_embedder_guard();
"#;

/// v7 (G11): grants between agents (INT-06), and an index for the links a promoted record keeps
/// to its sources (MEM-05), so deleting a source finds what was promoted from it.
const SCHEMA_V7_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_grant (
  id         uuid PRIMARY KEY,
  tenant     text NOT NULL,
  grantor    text NOT NULL,
  grantee    text NOT NULL,
  subjects   text NOT NULL DEFAULT '*',
  kinds      text[] NOT NULL DEFAULT '{}',
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  CHECK (grantor <> grantee)
);
CREATE INDEX IF NOT EXISTS mh_grant_grantee_idx ON mh_grant (tenant, grantee) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS mh_memory_promoted_idx ON mh_memory USING gin ((metadata -> 'promoted_from')) WHERE metadata ? 'promoted_from';
CREATE INDEX IF NOT EXISTS mh_memory_session_idx ON mh_memory (tenant, subject, scope_session) WHERE scope_session IS NOT NULL;
"#;

const SCHEMA_V5_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_policy_spec (
  tenant      text NOT NULL,
  version     int NOT NULL CHECK (version > 0),
  name        text NOT NULL,
  spec        jsonb NOT NULL,
  spec_hash   text NOT NULL,
  status      text NOT NULL CHECK (status IN ('proposed', 'approved')),
  note        text,
  proposed_by text NOT NULL,
  proposed_at timestamptz NOT NULL DEFAULT now(),
  approved_by text,
  approved_at timestamptz,
  PRIMARY KEY (tenant, version),
  CHECK ((status = 'approved') = (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS mh_policy_activation (
  id       bigserial PRIMARY KEY,
  tenant   text NOT NULL,
  version  int,
  compiled text NOT NULL,
  action   text NOT NULL,
  by_whom  text NOT NULL,
  at       timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (tenant, version) REFERENCES mh_policy_spec (tenant, version)
);
CREATE INDEX IF NOT EXISTS mh_policy_activation_tenant_idx ON mh_policy_activation (tenant, id DESC);

CREATE OR REPLACE FUNCTION mh_policy_activation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.version IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM mh_policy_spec WHERE tenant = NEW.tenant AND version = NEW.version AND status = 'approved'
  ) THEN
    RAISE EXCEPTION 'policy v% of tenant % is not approved; only approved policies execute', NEW.version, NEW.tenant;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER mh_policy_activation_guard BEFORE INSERT ON mh_policy_activation FOR EACH ROW EXECUTE FUNCTION mh_policy_activation_guard();
"#;

impl PgStore {
    /// One probe's recall statement (the `db.search` span is the caller's).
    async fn search_one(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>> {
        self.ensure_current().await?;
        let p = Probe::of(q);
        let sql = search_sql(!q.shared_agents.is_empty());
        let rows = search_query(sql, q, &p.tsq, p.kinds.clone(), p.use_kw, p.use_vec).fetch_all(&self.pool).await?;
        rows.iter().map(row_to_hit).collect()
    }
}

const SPEC_COLS: &str = "tenant, version, name, spec, spec_hash, status, note, proposed_by, proposed_at, approved_by, approved_at";

fn row_to_spec(r: &PgRow) -> anyhow::Result<memhouse_core::policy::PolicySpecRecord> {
    let status: String = r.try_get("status")?;
    let version: i32 = r.try_get("version")?;
    Ok(memhouse_core::policy::PolicySpecRecord {
        tenant: r.try_get("tenant")?,
        version: version as u32,
        name: r.try_get("name")?,
        spec: r.try_get("spec")?,
        spec_hash: r.try_get("spec_hash")?,
        status: memhouse_core::policy::SpecStatus::parse(&status).ok_or_else(|| anyhow::anyhow!("unknown policy status {status}"))?,
        note: r.try_get("note")?,
        proposed_by: r.try_get("proposed_by")?,
        proposed_at: r.try_get("proposed_at")?,
        approved_by: r.try_get("approved_by")?,
        approved_at: r.try_get("approved_at")?,
    })
}

fn row_to_principal(r: &PgRow) -> anyhow::Result<memhouse_core::identity::Principal> {
    use memhouse_core::identity::{Principal, PrincipalKind};
    let kind: String = r.try_get("kind")?;
    let kinds: Vec<String> = r.try_get("kinds")?;
    Ok(Principal {
        id: r.try_get("id")?,
        tenant: r.try_get("tenant")?,
        kind: PrincipalKind::parse(&kind).ok_or_else(|| anyhow::anyhow!("unknown principal kind {kind}"))?,
        name: r.try_get("name")?,
        subjects: r.try_get("subjects")?,
        kinds: kinds.iter().map(|k| MemoryKind::parse(k).ok_or_else(|| anyhow::anyhow!("unknown kind {k}"))).collect::<anyhow::Result<_>>()?,
        denied_labels: r.try_get("denied_labels")?,
        org: r.try_get("org")?,
        team: r.try_get("team")?,
        can_commit: r.try_get("can_commit")?,
        act_as: r.try_get("act_as")?,
        disabled_at: r.try_get("disabled_at")?,
        created_at: r.try_get("created_at")?,
        created_by: r.try_get("created_by")?,
    })
}

fn row_to_key(r: &PgRow) -> anyhow::Result<memhouse_core::identity::ApiKey> {
    Ok(memhouse_core::identity::ApiKey {
        id: r.try_get("id")?,
        principal_id: r.try_get("principal_id")?,
        hash: r.try_get("hash")?,
        scopes: r.try_get("scopes")?,
        expires_at: r.try_get("expires_at")?,
        revoked_at: r.try_get("revoked_at")?,
        created_at: r.try_get("created_at")?,
        created_by: r.try_get("created_by")?,
    })
}

// One argument per hashed field, in hash order; a struct would hide that order.
#[allow(clippy::too_many_arguments)]
fn audit_hash(prev: &str, at: &DateTime<Utc>, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<Uuid>, detail: &str) -> String {
    let mut h = Sha256::new();
    for part in [
        prev,
        &at.to_rfc3339_opts(chrono::SecondsFormat::Micros, true),
        actor,
        action,
        tenant,
        subject.unwrap_or(""),
        &memory_id.map(|u| u.to_string()).unwrap_or_default(),
        detail,
    ] {
        h.update(part.as_bytes());
        h.update([0x1f]);
    }
    hex::encode(h.finalize())
}

impl PgStore {
    pub async fn connect(url: &str, max_connections: u32, passage_prefix: &str) -> anyhow::Result<PgStore> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(std::time::Duration::from_secs(10))
            .connect(url)
            .await
            .map_err(|e| anyhow::anyhow!("cannot connect to Postgres at {}: {e}", redact_url(url)))?;
        Ok(PgStore {
            pool,
            passage_prefix: passage_prefix.to_string(),
            embedder: Default::default(),
            embedder_config: Default::default(),
            checked: Default::default(),
            recheck: std::time::Duration::from_secs(5),
        })
    }

    pub async fn meta(&self, key: &str) -> anyhow::Result<Option<String>> {
        let exists: bool = sqlx::query_scalar("SELECT to_regclass('mh_meta') IS NOT NULL").fetch_one(&self.pool).await?;
        if !exists {
            return Ok(None);
        }
        Ok(sqlx::query_scalar("SELECT value FROM mh_meta WHERE key = $1").bind(key).fetch_optional(&self.pool).await?)
    }

    /// How often recall compares the database's embedder with this process's (default 5 s).
    pub fn with_identity_recheck(mut self, every: std::time::Duration) -> PgStore {
        self.recheck = every;
        self
    }

    /// Fail recall in a process whose model is no longer the database's (after `memhouse reembed`).
    /// Writes are refused by the database itself; this covers reads, checked every `recheck`.
    async fn ensure_current(&self) -> anyhow::Result<()> {
        let Some(mine) = self.embedder.lock().unwrap().clone() else { return Ok(()) };
        {
            let mut at = self.checked.lock().unwrap();
            if at.is_some_and(|t| t.elapsed() < self.recheck) {
                return Ok(());
            }
            *at = Some(std::time::Instant::now());
        }
        match self.meta("embedder").await? {
            // A conflict, not a failure: recall refuses instead of degrading to an empty result.
            Some(db) if db != mine => {
                Err(memhouse_core::error::conflict(format!("this database is now embedded with {db}, not {mine}; restart with the new [embedding] configuration")))
            }
            _ => Ok(()),
        }
    }

    async fn has_next_columns(&self) -> anyhow::Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'mh_memory' AND column_name = 'embedding_next')",
        )
        .fetch_one(&self.pool)
        .await?)
    }

    async fn identity_of(&self, prefix: &str) -> anyhow::Result<Option<EmbeddingIdentity>> {
        let (Some(embedder), Some(dim)) = (self.meta(&format!("{prefix}embedder")).await?, self.meta(&format!("{prefix}embedding_dim")).await?) else {
            return Ok(None);
        };
        let passage_prefix = self.meta(&format!("{prefix}passage_prefix")).await?.unwrap_or_default();
        Ok(Some(EmbeddingIdentity { embedder, dim: dim.parse()?, passage_prefix }))
    }
}

pub fn redact_url(url: &str) -> String {
    match (url.find("://"), url.rfind('@')) {
        (Some(s), Some(at)) if at > s => format!("{}://***@{}", &url[..s], &url[at + 1..]),
        _ => url.to_string(),
    }
}

/// The scope filter on the agent level. A reader with grants (INT-06) gets its own statement,
/// so the statement of every other recall stays exactly the one the guard's latency baselines
/// were measured with.
const AGENT_FILTER: &str = "    AND ($22::text IS NULL OR m.scope_agent IS NULL OR m.scope_agent = $22)\n";
/// Another agent's records only with a grant: for every kind (`*`), or for the record's kind.
const AGENT_FILTER_SHARED: &str = "    AND ($22::text IS NULL OR m.scope_agent IS NULL OR m.scope_agent = $22\n         \
     OR (m.scope_agent || chr(31) || '*') = ANY($26::text[]) OR (m.scope_agent || chr(31) || m.kind) = ANY($26::text[]))\n";

/// The filters of a recall, for a reader with (`shared`) or without grants.
fn search_filters(shared: bool) -> String {
    SEARCH_FILTERS.replace("{AGENT}\n", if shared { AGENT_FILTER_SHARED } else { AGENT_FILTER })
}

/// The single-statement hybrid recall (keyword + vector candidates fused by RRF, section 4.5).
const SEARCH_FILTERS: &str = r#"    -- As-of recall also sees versions superseded since; validity below keeps the one true then.
    AND (m.status = 'committed' OR ($7::timestamptz IS NOT NULL AND m.status = 'superseded') OR ($25::bool AND m.status = 'candidate'))
    AND ($4::text[] IS NULL OR m.kind = ANY($4))
    AND ($5::text[] IS NULL OR m.tags && $5)
    AND NOT (m.labels && $6::text[])
    AND m.valid_from <= $16 AND (m.valid_to IS NULL OR m.valid_to > $16)
    AND (m.expires_at IS NULL OR m.expires_at > $16)
    AND ($20::text IS NULL OR m.scope_org IS NULL OR m.scope_org = $20)
    AND ($21::text IS NULL OR m.scope_team IS NULL OR m.scope_team = $21)
{AGENT}
    AND ($23::text IS NULL OR m.scope_user IS NULL OR m.scope_user = $23)
    AND ($24::text IS NULL OR m.scope_session IS NULL OR m.scope_session = $24)
    AND ($7::timestamptz IS NULL OR m.occurred_at IS NULL OR m.occurred_at <= $7)
    AND (cardinality($18::timestamptz[]) = 0 OR EXISTS (
      SELECT 1 FROM unnest($18::timestamptz[], $19::timestamptz[]) w(s, e)
      WHERE m.occurred_at >= w.s AND m.occurred_at < w.e))
"#;

/// The recall statement. `filtered = false` drops every filter but tenant and subject: the
/// candidates a recall explanation classifies (why each was excluded).
fn search_sql_with(filtered: bool, shared: bool) -> String {
    let filters = if filtered { search_filters(shared) } else { String::new() };
    format!(
        r#"
WITH q AS (
  SELECT CASE WHEN $3 = '' THEN NULL ELSE to_tsquery('english', $3) END AS tsq
),
base AS (
  SELECT m.id, m.tsv, m.embedding, m.embedding_alt
  FROM mh_memory m
  WHERE m.tenant = $1 AND m.subject = $2
{filters}),
-- BM25 (k1 = 1.2, b = 0.75) over the subject's memories. Term frequencies come from the stored
-- tsvector positions, document frequencies from the matched rows (a row matches a term iff it
-- contains it), document length is the number of distinct lexemes.
matched AS (
  SELECT b.id, b.tsv FROM base b, q
  WHERE $10 AND q.tsq IS NOT NULL AND b.tsv @@ q.tsq
),
qterms AS (
  SELECT DISTINCT lex FROM unnest(tsvector_to_array(to_tsvector('english', $17))) AS lex
),
stats AS (
  SELECT count(*)::float8 AS n, greatest(avg(length(tsv)), 1)::float8 AS avgdl FROM base
),
tf AS (
  SELECT mt.id, u.lexeme, coalesce(array_length(u.positions, 1), 1)::float8 AS tf, length(mt.tsv)::float8 AS dl
  FROM matched mt, unnest(mt.tsv) u
  WHERE u.lexeme IN (SELECT lex FROM qterms)
),
df AS (SELECT lexeme, count(*)::float8 AS df FROM tf GROUP BY lexeme),
kw AS (
  SELECT id, row_number() OVER (ORDER BY bm25 DESC, id) AS rk FROM (
    SELECT tf.id, sum(ln(1 + (st.n - df.df + 0.5) / (df.df + 0.5))
                      * tf.tf * 2.2 / (tf.tf + 1.2 * (0.25 + 0.75 * tf.dl / st.avgdl))) AS bm25
    FROM tf JOIN df USING (lexeme), stats st
    GROUP BY tf.id
  ) s
  ORDER BY rk LIMIT $8
),
vec AS (
  SELECT id, row_number() OVER (ORDER BY dist, id) AS rk, 1 - dist AS sim FROM (
    SELECT b.id, least(b.embedding <=> $9::vector, coalesce(b.embedding_alt <=> $9::vector, 2)) AS dist
    FROM base b
    WHERE $11 AND b.embedding IS NOT NULL
  ) d
  ORDER BY rk LIMIT $8
),
fused AS (
  SELECT id, sum(s) AS score, max(krk) AS krk, max(vrk) AS vrk, max(sim) AS sim FROM (
    SELECT id, $13::float8 / ($12::float8 + rk) AS s, rk::int AS krk, NULL::int AS vrk, NULL::float8 AS sim FROM kw
    UNION ALL
    SELECT id, $14::float8 / ($12::float8 + rk), NULL, rk::int, sim FROM vec
  ) u GROUP BY id
),
-- Rank first, then fetch only the top rows, each by primary key. The tenant and subject filter
-- keeps this step inside the subject too (TR-RQ-01) without steering the planner off the key.
top AS (
  SELECT * FROM fused ORDER BY score DESC, sim DESC NULLS LAST LIMIT $15
)
SELECT {COLS}, f.score, f.krk, f.vrk, f.sim, 0 AS probe
FROM top f CROSS JOIN LATERAL (
  SELECT * FROM mh_memory x WHERE x.id = f.id AND x.tenant = $1 AND x.subject = $2 LIMIT 1
) m
ORDER BY f.score DESC, f.sim DESC NULLS LAST
"#
    )
}

/// The rows a `forget` by user, agent or source matches (`$2` is the value).
fn forget_condition(scope: ForgetScope) -> anyhow::Result<&'static str> {
    Ok(match scope {
        ForgetScope::User => "(prov_user = $2 OR scope_user = $2)",
        ForgetScope::Agent => "(prov_agent = $2 OR scope_agent = $2)",
        ForgetScope::Source => "source = $2",
        s => anyhow::bail!("no row condition for forget by {}", s.as_str()),
    })
}

fn search_sql(shared: bool) -> String {
    search_sql_with(true, shared)
}

/// Several probes of one recall as one statement (PERF-02: one round trip): each probe's search,
/// with its own parameters, under `UNION ALL`, rows tagged with the probe's position.
fn multi_search_sql(n: usize, shared: bool) -> String {
    let one = search_sql(shared);
    (0..n).map(|i| format!("({})", renumber(&one, i * SEARCH_PARAMS).replace("0 AS probe", &format!("{i} AS probe")))).collect::<Vec<_>>().join("\nUNION ALL\n")
}

/// Parameters of one recall statement (the last, the granting agents, is only read by the
/// statement of a reader that has grants).
const SEARCH_PARAMS: usize = 26;

/// Shift every `$N` in `sql` by `by`.
fn renumber(sql: &str, by: usize) -> String {
    if by == 0 {
        return sql.to_string();
    }
    let mut out = String::with_capacity(sql.len() + 64);
    let mut chars = sql.char_indices().peekable();
    while let Some((_, c)) = chars.next() {
        out.push(c);
        if c == '$' {
            let mut n = String::new();
            while let Some((_, d)) = chars.peek().filter(|(_, d)| d.is_ascii_digit()) {
                n.push(*d);
                chars.next();
            }
            if n.is_empty() {
                continue;
            }
            out.push_str(&(n.parse::<usize>().expect("digits") + by).to_string());
        }
    }
    out
}

/// Bind a `SearchQuery` to `sql` (the recall statement, or an EXPLAIN of it).
fn search_query<'a>(
    sql: String,
    q: &'a SearchQuery,
    tsq: &'a str,
    kinds: Option<Vec<String>>,
    use_kw: bool,
    use_vec: bool,
) -> sqlx::query::Query<'a, sqlx::Postgres, sqlx::postgres::PgArguments> {
    bind_search(sqlx::query(sqlx::AssertSqlSafe(sql)), q, tsq, kinds, use_kw, use_vec)
}

/// The probe-dependent values of a `SearchQuery`.
struct Probe {
    tsq: String,
    kinds: Option<Vec<String>>,
    use_kw: bool,
    use_vec: bool,
}

impl Probe {
    fn of(q: &SearchQuery) -> Probe {
        let use_kw = q.mode != RetrievalMode::Dense;
        Probe {
            tsq: if use_kw { or_query(&q.text) } else { String::new() },
            kinds: q.kinds.as_ref().map(|ks| ks.iter().map(|k| k.as_str().to_string()).collect()),
            use_kw,
            use_vec: q.mode != RetrievalMode::Keyword && q.embedding.is_some(),
        }
    }
}

fn row_to_hit(r: &PgRow) -> anyhow::Result<Hit> {
    Ok(Hit {
        memory: row_to_memory(r)?,
        score: r.try_get::<f64, _>("score")? as f32,
        keyword_rank: r.try_get("krk")?,
        vector_rank: r.try_get("vrk")?,
        similarity: r.try_get::<Option<f64>, _>("sim")?.map(|s| s as f32),
        rerank_score: None,
        exact: false,
        working: false,
    })
}

/// Bind one probe's parameters (`SEARCH_PARAMS` of them, in order).
fn bind_search<'a>(
    query: sqlx::query::Query<'a, sqlx::Postgres, sqlx::postgres::PgArguments>,
    q: &'a SearchQuery,
    tsq: &'a str,
    kinds: Option<Vec<String>>,
    use_kw: bool,
    use_vec: bool,
) -> sqlx::query::Query<'a, sqlx::Postgres, sqlx::postgres::PgArguments> {
    query
        .bind(&q.tenant)
        .bind(&q.subject)
        .bind(tsq)
        .bind(kinds)
        .bind(q.tags.clone())
        .bind(&q.denied_labels)
        .bind(q.as_of)
        .bind(q.per_retriever as i64)
        .bind(q.embedding.as_ref().map(|v| vec_literal(v)))
        .bind(use_kw)
        .bind(use_vec)
        .bind(q.rrf_k as f64)
        .bind(q.keyword_weight as f64)
        .bind(q.vector_weight as f64)
        .bind(q.limit as i64)
        .bind(q.valid_at)
        .bind(&q.text)
        .bind(q.windows.iter().map(|w| w.0).collect::<Vec<_>>())
        .bind(q.windows.iter().map(|w| w.1).collect::<Vec<_>>())
        .bind(&q.scope.org)
        .bind(&q.scope.team)
        .bind(&q.scope.agent)
        .bind(&q.scope.user)
        .bind(&q.scope.session)
        .bind(q.include_candidates)
        .bind(&q.shared_agents)
}

/// The schema as it was at version 1, kept verbatim: `migrate` runs it, then the v2 additions,
/// and the upgrade test builds a v1 database from it.
pub fn schema_v1_ddl(dim: usize) -> String {
    format!(
        r#"
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS mh_meta (key text PRIMARY KEY, value text NOT NULL);
CREATE TABLE IF NOT EXISTS mh_memory (
  id            uuid PRIMARY KEY,
  tenant        text NOT NULL,
  subject       text NOT NULL,
  kind          text NOT NULL,
  status        text NOT NULL,
  content       text NOT NULL,
  content_hash  text NOT NULL,
  tsv           tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  embedding     vector({dim}),
  embedding_alt vector({dim}),
  alt_hash      text,
  embedder      text,
  session_id    text,
  turn_ref      text,
  occurred_at   timestamptz,
  valid_from    timestamptz NOT NULL,
  valid_to      timestamptz,
  supersedes    uuid,
  superseded_by uuid,
  labels        text[] NOT NULL DEFAULT '{{}}',
  tags          text[] NOT NULL DEFAULT '{{}}',
  source        text NOT NULL,
  confidence    real NOT NULL DEFAULT 1,
  metadata      jsonb NOT NULL DEFAULT '{{}}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
-- Second vector for episodic rounds: the user's own words, so a passing remark is not drowned
-- out by a long assistant reply. alt_hash is its embedding-cache key (purged on deletion).
ALTER TABLE mh_memory ADD COLUMN IF NOT EXISTS embedding_alt vector({dim});
ALTER TABLE mh_memory ADD COLUMN IF NOT EXISTS alt_hash text;
CREATE INDEX IF NOT EXISTS mh_memory_subject_idx ON mh_memory (tenant, subject, status, kind);
CREATE INDEX IF NOT EXISTS mh_memory_hash_idx ON mh_memory (tenant, subject, content_hash);
CREATE INDEX IF NOT EXISTS mh_memory_tsv_idx ON mh_memory USING gin (tsv);
CREATE INDEX IF NOT EXISTS mh_memory_tags_idx ON mh_memory USING gin (tags);
CREATE INDEX IF NOT EXISTS mh_memory_created_idx ON mh_memory (tenant, kind, created_at);
-- No approximate vector index on subject data: per-subject scoring is exact (SCALE-03).

CREATE TABLE IF NOT EXISTS mh_embed_cache (
  model     text NOT NULL,
  hash      text NOT NULL,
  embedding real[] NOT NULL,
  PRIMARY KEY (model, hash)
);

CREATE TABLE IF NOT EXISTS mh_audit (
  id        bigserial PRIMARY KEY,
  at        timestamptz NOT NULL,
  actor     text NOT NULL,
  action    text NOT NULL,
  tenant    text NOT NULL,
  subject   text,
  memory_id uuid,
  detail    text NOT NULL,
  prev_hash text NOT NULL,
  hash      text NOT NULL
);
CREATE INDEX IF NOT EXISTS mh_audit_subject_idx ON mh_audit (tenant, subject);

-- Every deletion is recorded so it can be re-applied after a restore from backup (TR-WF-03).
CREATE TABLE IF NOT EXISTS mh_deletion_ledger (
  id           bigserial PRIMARY KEY,
  at           timestamptz NOT NULL DEFAULT now(),
  tenant       text NOT NULL,
  subject      text,
  memory_id    uuid,
  scope        text NOT NULL,
  actor        text NOT NULL
);

-- Enrichment queue: one job per ingested session, claimed by workers with SKIP LOCKED.
CREATE TABLE IF NOT EXISTS mh_enrich_job (
  id           bigserial PRIMARY KEY,
  tenant       text NOT NULL,
  subject      text NOT NULL,
  session_id   text NOT NULL,
  round_ids    uuid[] NOT NULL,
  status       text NOT NULL DEFAULT 'pending',
  attempts     int NOT NULL DEFAULT 0,
  run_after    timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  enqueued_at  timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  cache_key    text,
  outcome      jsonb,
  error        text
);
CREATE INDEX IF NOT EXISTS mh_enrich_job_queue_idx ON mh_enrich_job (status, run_after) WHERE status IN ('pending', 'running');
CREATE INDEX IF NOT EXISTS mh_enrich_job_subject_idx ON mh_enrich_job (tenant, subject);
CREATE INDEX IF NOT EXISTS mh_enrich_job_rounds_idx ON mh_enrich_job USING gin (round_ids);
CREATE INDEX IF NOT EXISTS mh_memory_sources_idx ON mh_memory USING gin ((metadata -> 'source_ids'));

-- Extraction answers keyed by model + prompt version + input, so a repeated session is free.
CREATE TABLE IF NOT EXISTS mh_llm_cache (
  key        text PRIMARY KEY,
  model      text NOT NULL,
  response   text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Every row carries the embedder that wrote it; after a re-embedding, a process still on the old
-- model can't add vectors that would be compared with the new ones.
CREATE OR REPLACE FUNCTION mh_memory_embedder_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE current text := (SELECT value FROM mh_meta WHERE key = 'embedder');
BEGIN
  IF NEW.embedder IS NOT NULL AND NEW.embedder IS DISTINCT FROM current THEN
    RAISE EXCEPTION 'this database is now embedded with %, not %; restart with the new [embedding] configuration', current, NEW.embedder;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER mh_memory_embedder_guard BEFORE INSERT ON mh_memory FOR EACH ROW EXECUTE FUNCTION mh_memory_embedder_guard();
"#
    )
}

/// ADR 0007: refuse pgvector below 0.5, warn below 0.7.0 (half-precision and binary vectors).
async fn check_pgvector(pool: &PgPool) -> anyhow::Result<()> {
    let v: Option<String> = sqlx::query_scalar("SELECT extversion FROM pg_extension WHERE extname = 'vector'").fetch_optional(pool).await?;
    let v = v.ok_or_else(|| anyhow::anyhow!("the pgvector extension is not installed"))?;
    let parts: Vec<u32> = v.split('.').map(|p| p.parse().unwrap_or(0)).collect();
    let (major, minor) = (parts.first().copied().unwrap_or(0), parts.get(1).copied().unwrap_or(0));
    if (major, minor) < (0, 5) {
        anyhow::bail!("pgvector {v} is too old; MemHouse needs 0.5 or later and recommends 0.8 (ALTER EXTENSION vector UPDATE)");
    }
    if (major, minor) < (0, 7) {
        tracing::warn!("pgvector {v} works, but half-precision and binary vectors need 0.7.0 or later; 0.8 is recommended");
    }
    Ok(())
}

/// A record and its vectors as columns: one path for `insert` and `import_records`.
struct WriteRow<'a> {
    r: &'a RecordLine,
    embedding: Option<String>,
    alt: Option<String>,
}

impl PgStore {
    /// Fill the v2 columns of records written under schema v1, in batches (the same rules as
    /// `format::legacy_provenance`), then record schema version 2.
    async fn backfill_v2(&self, embedder: &str, config: &str) -> anyhow::Result<()> {
        loop {
            let n = sqlx::query(
                "UPDATE mh_memory SET \
                   prov_agent = CASE WHEN source LIKE 'enrich:%' THEN 'enrich' ELSE source END, \
                   policy_version = $3, \
                   extractor = CASE WHEN metadata ->> 'derived' = 'true' THEN metadata ->> 'extractor' END, \
                   extractor_config = CASE WHEN metadata ->> 'derived' = 'true' THEN metadata ->> 'prompt_version' END, \
                   embedder = CASE WHEN embedding IS NOT NULL THEN coalesce(embedder, $1) END, \
                   embedder_config = CASE WHEN embedding IS NOT NULL THEN $2 END \
                 WHERE id IN (SELECT id FROM mh_memory WHERE policy_version IS NULL LIMIT 5000)",
            )
            .bind(embedder)
            .bind(config)
            .bind(memhouse_core::format::LEGACY_POLICY)
            .execute(&self.pool)
            .await?
            .rows_affected();
            if n == 0 {
                break;
            }
        }
        // v1 stamped supersessions and status changes with the database's clock, which can trail
        // the application's by milliseconds; raise those stamps to the record's own times so
        // every record satisfies the format's ordering rules.
        sqlx::query(
            "UPDATE mh_memory SET updated_at = greatest(updated_at, created_at), valid_to = greatest(valid_to, valid_from) \
             WHERE updated_at < created_at OR valid_to < valid_from",
        )
        .execute(&self.pool)
        .await?;
        sqlx::query("UPDATE mh_meta SET value = $1 WHERE key = 'schema_version' AND value::int < $2")
            .bind(SCHEMA_VERSION.to_string())
            .bind(SCHEMA_VERSION as i32)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Insert records with every column; `skip_existing` ignores ids already present. Returns
    /// the ids inserted.
    async fn write_rows(&self, rows: &[WriteRow<'_>], skip_existing: bool) -> anyhow::Result<Vec<Uuid>> {
        let mut tx = self.pool.begin().await?;
        let inserted = self.write_rows_in(&mut tx, rows, skip_existing).await?;
        tx.commit().await?;
        Ok(inserted)
    }

    /// `write_rows` inside a transaction the caller commits.
    async fn write_rows_in(&self, tx: &mut sqlx::PgConnection, rows: &[WriteRow<'_>], skip_existing: bool) -> anyhow::Result<Vec<Uuid>> {
        let embedder = self.embedder.lock().unwrap().clone();
        let config = self.embedder_config.lock().unwrap().clone();
        let mut inserted = vec![];
        for chunk in rows.chunks(400) {
            let mut qb = sqlx::QueryBuilder::new(
                "INSERT INTO mh_memory (id, tenant, subject, kind, status, content, content_hash, embedding, embedding_alt, alt_hash, embedder, embedder_config, \
                 session_id, turn_ref, occurred_at, valid_from, valid_to, expires_at, supersedes, superseded_by, labels, tags, \
                 scope_org, scope_team, scope_agent, scope_user, scope_session, source, confidence, \
                 prov_agent, prov_user, policy_version, request_key, extractor, extractor_config, metadata, created_at, updated_at) ",
            );
            qb.push_values(chunk, |mut b, w| {
                let r = w.r;
                let has_vec = w.embedding.is_some();
                b.push_bind(r.id)
                    .push_bind(&r.tenant)
                    .push_bind(&r.subject)
                    .push_bind(r.kind.as_str())
                    .push_bind(r.status.as_str())
                    .push_bind(&r.content)
                    .push_bind(&r.content_hash)
                    .push_bind(w.embedding.clone())
                    .push_unseparated("::vector")
                    .push_bind(w.alt.clone())
                    .push_unseparated("::vector")
                    .push_bind(w.alt.as_ref().and(r.alt_hash.clone()))
                    .push_bind(embedder.clone().filter(|_| has_vec))
                    .push_bind(config.clone().filter(|_| has_vec))
                    .push_bind(&r.session_id)
                    .push_bind(&r.turn_ref)
                    .push_bind(r.occurred_at)
                    .push_bind(r.valid_from)
                    .push_bind(r.valid_to)
                    .push_bind(r.expires_at)
                    .push_bind(r.supersedes)
                    .push_bind(r.superseded_by)
                    .push_bind(&r.labels)
                    .push_bind(&r.tags)
                    .push_bind(&r.scope.org)
                    .push_bind(&r.scope.team)
                    .push_bind(&r.scope.agent)
                    .push_bind(&r.scope.user)
                    .push_bind(&r.scope.session)
                    .push_bind(&r.source)
                    .push_bind(r.confidence)
                    .push_bind(&r.provenance.agent)
                    .push_bind(&r.provenance.user)
                    .push_bind(&r.provenance.policy_version)
                    .push_bind(&r.provenance.request_key)
                    .push_bind(&r.provenance.extractor)
                    .push_bind(&r.provenance.extractor_config)
                    .push_bind(&r.metadata)
                    .push_bind(r.created_at)
                    .push_bind(r.updated_at);
            });
            if skip_existing {
                qb.push(" ON CONFLICT (id) DO NOTHING");
            }
            qb.push(" RETURNING id");
            let ids: Vec<Uuid> = qb.build_query_scalar().fetch_all(&mut *tx).await?;
            inserted.extend(ids);
        }
        let done: std::collections::HashSet<Uuid> = inserted.iter().copied().collect();
        for w in rows.iter().filter(|w| done.contains(&w.r.id)) {
            let r = w.r;
            if let Some(st) = &r.structured {
                sqlx::query("INSERT INTO mh_structured (memory_id, tenant, subject, record_type, attrs) VALUES ($1, $2, $3, $4, $5)")
                    .bind(r.id)
                    .bind(&r.tenant)
                    .bind(&r.subject)
                    .bind(&st.record_type)
                    .bind(&st.attrs)
                    .execute(&mut *tx)
                    .await?;
            }
            for c in &r.code_refs {
                sqlx::query("INSERT INTO mh_code_ref (memory_id, tenant, subject, path, blob_hash) VALUES ($1, $2, $3, $4, $5)")
                    .bind(r.id)
                    .bind(&r.tenant)
                    .bind(&r.subject)
                    .bind(&c.path)
                    .bind(&c.blob_hash)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        Ok(inserted)
    }

    /// One audit event inside the caller's transaction (the chain lock is held until it commits).
    async fn audit_in(&self, tx: &mut sqlx::PgConnection, tenant: &str, a: &memhouse_core::intake::AuditEntry) -> anyhow::Result<()> {
        let (actor, action, subject, memory_id) = (a.actor.as_str(), a.action.as_str(), a.subject.as_deref(), a.memory_id);
        let detail = a.detail.to_string();
        let at = Utc::now().trunc_subsecs(6);
        sqlx::query("SELECT pg_advisory_xact_lock(7270001)").execute(&mut *tx).await?;
        let prev: Option<String> = sqlx::query_scalar("SELECT hash FROM mh_audit ORDER BY id DESC LIMIT 1").fetch_optional(&mut *tx).await?;
        let prev = prev.unwrap_or_else(|| "genesis".into());
        let hash = audit_hash(&prev, &at, actor, action, tenant, subject, memory_id, &detail);
        sqlx::query("INSERT INTO mh_audit (at, actor, action, tenant, subject, memory_id, detail, prev_hash, hash) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)")
            .bind(at)
            .bind(actor)
            .bind(action)
            .bind(tenant)
            .bind(subject)
            .bind(memory_id)
            .bind(&detail)
            .bind(&prev)
            .bind(&hash)
            .execute(&mut *tx)
            .await?;
        Ok(())
    }

    /// The record lines of new memories (the shape `write_rows` takes).
    fn lines_of(records: &[NewMemory]) -> Vec<RecordLine> {
        records
            .iter()
            .map(|n| {
                let m = &n.memory;
                RecordLine {
                    id: m.id,
                    tenant: m.tenant.clone(),
                    subject: m.subject.clone(),
                    kind: m.kind,
                    status: m.status,
                    content: m.content.clone(),
                    content_hash: n.content_hash.clone(),
                    session_id: m.session_id.clone(),
                    turn_ref: m.turn_ref.clone(),
                    occurred_at: m.occurred_at,
                    valid_from: m.valid_from,
                    valid_to: m.valid_to,
                    expires_at: m.expires_at,
                    supersedes: m.supersedes,
                    superseded_by: None,
                    labels: m.labels.clone(),
                    tags: m.tags.clone(),
                    scope: m.scope.clone(),
                    source: m.source.clone(),
                    confidence: m.confidence,
                    provenance: m.provenance.clone(),
                    alt_hash: n.alt.as_ref().map(|(h, _)| h.clone()),
                    structured: n.structured.clone(),
                    code_refs: n.code_refs.clone(),
                    metadata: m.metadata.clone(),
                    created_at: m.created_at,
                    updated_at: m.created_at,
                }
            })
            .collect()
    }
}

/// The SQL that supersedes `$2` by `$3` (see `set_superseded`).
/// Serializes, per tenant and subject, the writes that add a promotion link with the deletions
/// that follow those links (MEM-05). A deletion's cascade reads one snapshot: without this, a
/// promotion of a dependent that commits while the cascade waits on a row would be missed.
/// `$1` is the tenant, `$2` the subject; held until the transaction ends.
pub const SUBJECT_LOCK_SQL: &str = "SELECT pg_advisory_xact_lock(7270002, hashtext($1 || chr(31) || $2))";

const SUPERSEDE_SQL: &str = "UPDATE mh_memory SET status = 'superseded', superseded_by = $3, \
     valid_to = least(COALESCE(valid_to, 'infinity'), greatest(COALESCE((SELECT n.valid_from FROM mh_memory n WHERE n.tenant = $1 AND n.id = $3), now()), valid_from)), \
     updated_at = greatest(now(), created_at) \
     WHERE tenant = $1 AND id = $2 AND status = 'committed'";

fn proposal_of(payload: serde_json::Value) -> anyhow::Result<memhouse_core::intake::Proposal> {
    serde_json::from_value(payload).map_err(|e| anyhow::anyhow!("unreadable intake proposal: {e}"))
}

#[async_trait]
impl memhouse_core::IntakeQueue for PgStore {
    fn name(&self) -> &'static str {
        "postgres"
    }

    #[tracing::instrument(name = "db.intake_enqueue", skip_all, fields(db.system = "postgresql", db.operation = "INSERT"))]
    async fn enqueue(&self, p: &memhouse_core::intake::Proposal) -> anyhow::Result<()> {
        let first = p.records.first().map(|r| &r.memory);
        let embedder = self.embedder.lock().unwrap().clone();
        // Durable on return: the insert commits with synchronous_commit (TR-LT-05).
        let r = sqlx::query(
            "INSERT INTO mh_intake (id, tenant, subject, record_ids, agent, acting_user, source, scope_agent, scope_user, payload, enqueued_at, embedder) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        )
        .bind(p.id)
        .bind(&p.tenant)
        .bind(&p.subject)
        .bind(p.record_ids())
        .bind(&p.actor)
        .bind(&p.user)
        .bind(&p.source)
        .bind(first.and_then(|m| m.scope.agent.clone()))
        .bind(first.and_then(|m| m.scope.user.clone()))
        .bind(serde_json::to_value(p)?)
        .bind(p.enqueued_at)
        .bind(embedder)
        .execute(&self.pool)
        .await;
        match r {
            Ok(_) => Ok(()),
            Err(e) if e.to_string().contains("is now embedded with") => Err(memhouse_core::error::conflict(e.to_string())),
            Err(e) => Err(e.into()),
        }
    }

    #[tracing::instrument(name = "db.intake_claim", skip_all, fields(db.system = "postgresql", db.operation = "UPDATE"))]
    async fn claim(&self, limit: usize, lease_secs: u64, subject: Option<(&str, &str)>) -> anyhow::Result<Vec<memhouse_core::intake::IntakeJob>> {
        // The oldest unfinished proposal of each subject only, so one subject's writes take effect
        // in the order they were acknowledged; SKIP LOCKED lets workers claim different subjects.
        let rows = sqlx::query(
            "UPDATE mh_intake j SET status = 'running', attempts = j.attempts + 1, locked_until = now() + make_interval(secs => $2) \
             WHERE j.id IN (SELECT c.id FROM mh_intake c \
               WHERE ((c.status = 'pending' AND c.run_after <= now()) OR (c.status = 'running' AND c.locked_until < now())) \
                 AND ($3::text IS NULL OR (c.tenant = $3 AND c.subject = $4)) \
                 AND NOT EXISTS (SELECT 1 FROM mh_intake o WHERE o.tenant = c.tenant AND o.subject = c.subject \
                                 AND o.status IN ('pending', 'running') AND o.seq < c.seq) \
               ORDER BY c.seq LIMIT $1 FOR UPDATE SKIP LOCKED) \
             RETURNING j.payload, j.attempts",
        )
        .bind(limit as i64)
        .bind(lease_secs as f64)
        .bind(subject.map(|s| s.0))
        .bind(subject.map(|s| s.1))
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|r| {
                let payload: Option<serde_json::Value> = r.try_get("payload")?;
                Ok(memhouse_core::intake::IntakeJob {
                    proposal: proposal_of(payload.ok_or_else(|| anyhow::anyhow!("a claimed proposal has no content"))?)?,
                    attempts: r.try_get("attempts")?,
                })
            })
            .collect()
    }

    async fn finish(&self, id: Uuid, outcome: &serde_json::Value) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE mh_intake SET status = 'done', finished_at = now(), locked_until = NULL, payload = NULL, outcome = $2 WHERE id = $1 AND status IN ('pending', 'running')",
        )
        .bind(id)
        .bind(outcome)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn fail(&self, id: Uuid, attempt: i32, error: &str, dead: bool, keep_payload: bool) -> anyhow::Result<()> {
        // Backoff 0.5, 1, 2, 4 ... seconds, at most 30. Only the attempt that holds the claim: a
        // worker whose lease expired must not reset a proposal another worker now runs.
        sqlx::query(
            "UPDATE mh_intake SET status = CASE WHEN $3 THEN 'dead' ELSE 'pending' END, locked_until = NULL, error = $2, \
               run_after = now() + make_interval(secs => least(power(2, attempts) * 0.25, 30)), \
               finished_at = CASE WHEN $3 THEN now() END, payload = CASE WHEN $4 THEN payload END \
             WHERE id = $1 AND status IN ('pending', 'running') AND attempts = $5",
        )
        .bind(id)
        .bind(error)
        .bind(dead)
        .bind(keep_payload)
        .bind(attempt)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn pending(&self, tenant: &str, record_id: Uuid) -> anyhow::Result<Option<Memory>> {
        let row = sqlx::query(
            "SELECT status, payload, error FROM mh_intake WHERE tenant = $1 AND record_ids @> ARRAY[$2]::uuid[] \
             AND status IN ('pending', 'running', 'dead') AND payload IS NOT NULL ORDER BY seq DESC LIMIT 1",
        )
        .bind(tenant)
        .bind(record_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else { return Ok(None) };
        let status: String = row.try_get("status")?;
        let p = proposal_of(row.try_get("payload")?)?;
        Ok(p.records.into_iter().find(|r| r.memory.id == record_id).map(|r| {
            let mut m = r.memory;
            if status == "dead" {
                m.status = MemoryStatus::Quarantined;
                m.metadata["quarantine_reasons"] = serde_json::json!(["intake_failed"]);
            }
            m
        }))
    }

    async fn pending_proposal(&self, tenant: &str, record_id: Uuid) -> anyhow::Result<Option<Uuid>> {
        Ok(sqlx::query_scalar("SELECT id FROM mh_intake WHERE tenant = $1 AND record_ids @> ARRAY[$2]::uuid[] AND status IN ('pending', 'running') LIMIT 1")
            .bind(tenant)
            .bind(record_id)
            .fetch_optional(&self.pool)
            .await?)
    }

    async fn unfinished(&self, id: Uuid) -> anyhow::Result<bool> {
        Ok(sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM mh_intake WHERE id = $1 AND status IN ('pending', 'running'))").bind(id).fetch_one(&self.pool).await?)
    }

    async fn subject_unfinished(&self, tenant: &str, subject: &str) -> anyhow::Result<bool> {
        Ok(sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM mh_intake WHERE tenant = $1 AND subject = $2 AND status IN ('pending', 'running'))")
            .bind(tenant)
            .bind(subject)
            .fetch_one(&self.pool)
            .await?)
    }

    async fn outcome(&self, id: Uuid) -> anyhow::Result<Option<serde_json::Value>> {
        Ok(sqlx::query_scalar("SELECT outcome FROM mh_intake WHERE (id = $1 OR record_ids @> ARRAY[$1]::uuid[]) AND outcome IS NOT NULL LIMIT 1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?)
    }

    async fn status(&self, tenant: Option<&str>) -> anyhow::Result<IntakeStatus> {
        let rows: Vec<(String, i64)> =
            sqlx::query_as("SELECT status, count(*) FROM mh_intake WHERE ($1::text IS NULL OR tenant = $1) GROUP BY status").bind(tenant).fetch_all(&self.pool).await?;
        let mut st = IntakeStatus::default();
        for (s, n) in rows {
            match s.as_str() {
                "pending" => st.pending = n,
                "running" => st.running = n,
                "done" => st.done = n,
                _ => st.dead = n,
            }
        }
        st.oldest_pending_secs = sqlx::query_scalar(
            "SELECT extract(epoch FROM now() - min(enqueued_at))::float8 FROM mh_intake WHERE ($1::text IS NULL OR tenant = $1) AND status IN ('pending', 'running')",
        )
        .bind(tenant)
        .fetch_one(&self.pool)
        .await?;
        Ok(st)
    }

    async fn prune(&self, done_older_than_secs: u64) -> anyhow::Result<u64> {
        Ok(sqlx::query("DELETE FROM mh_intake WHERE status = 'done' AND finished_at < now() - make_interval(secs => $1)")
            .bind(done_older_than_secs as f64)
            .execute(&self.pool)
            .await?
            .rows_affected())
    }

    async fn discard(&self, tenant: &str, scope: ForgetScope, value: &str) -> anyhow::Result<u64> {
        if scope == ForgetScope::Record {
            // One record leaves its proposal; the other records stay queued (or kept for the
            // operator). The update waits for an insert holding the row, which then has no payload.
            let id: Uuid = value.parse()?;
            let mut tx = self.pool.begin().await?;
            let n = sqlx::query(
                "UPDATE mh_intake SET record_ids = array_remove(record_ids, $2), \
                   payload = jsonb_set(payload, '{records}', coalesce((SELECT jsonb_agg(r) FROM jsonb_array_elements(payload -> 'records') r \
                                                                         WHERE r -> 'memory' ->> 'id' <> $2::text), '[]'::jsonb)) \
                 WHERE tenant = $1 AND record_ids @> ARRAY[$2] AND payload IS NOT NULL AND status IN ('pending', 'running', 'dead')",
            )
            .bind(tenant)
            .bind(id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
            sqlx::query("DELETE FROM mh_intake WHERE tenant = $1 AND cardinality(record_ids) = 0 AND status IN ('pending', 'running', 'dead')")
                .bind(tenant)
                .execute(&mut *tx)
                .await?;
            // A promotion of this record that is still queued (or set aside with its content)
            // goes with it (MEM-05): it is no longer readable by its id, and never written.
            let promoted = sqlx::query(
                "DELETE FROM mh_intake WHERE tenant = $1 AND payload IS NOT NULL \
                 AND jsonb_path_exists(payload, '$.records[*].memory.metadata.promoted_from[*] ? (@ == $id)', jsonb_build_object('id', $2::text))",
            )
            .bind(tenant)
            .bind(id.to_string())
            .execute(&mut *tx)
            .await?
            .rows_affected();
            tx.commit().await?;
            return Ok(n + promoted);
        }
        let filter = match scope {
            ForgetScope::Subject => "subject = $2",
            ForgetScope::Tenant => "$2 = $2",
            ForgetScope::User => "(acting_user = $2 OR scope_user = $2)",
            ForgetScope::Agent => "(agent = $2 OR scope_agent = $2)",
            ForgetScope::Source => "source = $2",
            ForgetScope::Record => unreachable!("handled above"),
        };
        Ok(sqlx::query(trusted_sql!("DELETE FROM mh_intake WHERE tenant = $1 AND {filter} AND (payload IS NOT NULL OR status IN ('pending', 'running'))"))
            .bind(tenant)
            .bind(value)
            .execute(&self.pool)
            .await?
            .rows_affected())
    }
}

#[async_trait]
impl Store for PgStore {
    async fn migrate(&self, dim: usize, embedder_id: &str) -> anyhow::Result<()> {
        let mine = EmbeddingIdentity { embedder: embedder_id.to_string(), dim, passage_prefix: self.passage_prefix.clone() };
        if let Some(db) = self.identity_of("").await? {
            // Databases from before the prefix was recorded take the configured one.
            let prefix_known = self.meta("passage_prefix").await?.is_some();
            let same = db.embedder == mine.embedder && db.dim == mine.dim && (!prefix_known || db.passage_prefix == mine.passage_prefix);
            if !same {
                let unfinished = self.identity_of("reembed_target_").await?.is_some_and(|t| t == mine);
                anyhow::bail!(
                    "this database's memories are embedded with {db}, but the configuration says {mine}. {}",
                    if unfinished {
                        "A re-embedding to it is unfinished: run `memhouse reembed` to complete it."
                    } else {
                        "Run `memhouse reembed` to re-embed every memory with the configured model, or go back to the previous [embedding] settings."
                    }
                );
            }
        }
        let stored_version: Option<u32> = self.meta("schema_version").await?.map(|v| v.parse()).transpose()?;
        if let Some(v) = stored_version.filter(|v| *v > SCHEMA_VERSION) {
            anyhow::bail!("this database has schema version {v}, newer than this build ({SCHEMA_VERSION}); upgrade MemHouse");
        }
        sqlx::raw_sql(sqlx::AssertSqlSafe(schema_v1_ddl(dim))).execute(&self.pool).await?;
        check_pgvector(&self.pool).await?;
        sqlx::raw_sql(SCHEMA_V2_DDL).execute(&self.pool).await?;
        sqlx::raw_sql(SCHEMA_V3_DDL).execute(&self.pool).await?;
        sqlx::raw_sql(SCHEMA_V4_DDL).execute(&self.pool).await?;
        sqlx::raw_sql(SCHEMA_V5_DDL).execute(&self.pool).await?;
        sqlx::raw_sql(SCHEMA_V6_DDL).execute(&self.pool).await?;
        sqlx::raw_sql(SCHEMA_V7_DDL).execute(&self.pool).await?;
        for (k, v) in [
            ("schema_version", SCHEMA_VERSION.to_string()),
            ("embedding_dim", dim.to_string()),
            ("embedder", embedder_id.to_string()),
            ("passage_prefix", self.passage_prefix.clone()),
        ] {
            sqlx::query("INSERT INTO mh_meta(key, value) VALUES ($1, $2) ON CONFLICT (key) DO NOTHING").bind(k).bind(v).execute(&self.pool).await?;
        }
        let config = mine.config_hash();
        if stored_version.is_some_and(|v| v < 2) {
            self.backfill_v2(embedder_id, &config).await?;
        }
        // v3 to v7 only add tables and indexes.
        sqlx::query("UPDATE mh_meta SET value = $1 WHERE key = 'schema_version' AND value::int < $2")
            .bind(SCHEMA_VERSION.to_string())
            .bind(SCHEMA_VERSION as i32)
            .execute(&self.pool)
            .await?;
        *self.embedder.lock().unwrap() = Some(embedder_id.to_string());
        *self.embedder_config.lock().unwrap() = Some(config);
        Ok(())
    }

    #[tracing::instrument(name = "db.insert", skip_all, fields(db.system = "postgresql", db.operation = "INSERT", rows = records.len()))]
    async fn insert(&self, records: &[NewMemory]) -> anyhow::Result<()> {
        if records.is_empty() {
            return Ok(());
        }
        let lines = Self::lines_of(records);
        let rows: Vec<WriteRow> = lines
            .iter()
            .zip(records)
            .map(|(r, n)| WriteRow { r, embedding: n.embedding.as_ref().map(|v| vec_literal(v)), alt: n.alt.as_ref().map(|(_, v)| vec_literal(v)) })
            .collect();
        self.write_rows(&rows, false).await?;
        Ok(())
    }

    fn intake_queue(&self) -> Option<std::sync::Arc<dyn memhouse_core::IntakeQueue>> {
        Some(std::sync::Arc::new(self.clone()))
    }

    #[tracing::instrument(name = "db.apply_intake", skip_all, fields(db.system = "postgresql", db.operation = "INSERT", rows = w.records.len()))]
    async fn apply_intake(&self, w: &memhouse_core::intake::IntakeWrite) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        if let Some(pid) = w.proposal {
            // Locks the proposal: an erasure that deletes it waits for this insert, then removes
            // what it wrote; a proposal already erased writes nothing.
            let row: Option<(String, Vec<Uuid>)> = sqlx::query_as("SELECT status, record_ids FROM mh_intake WHERE id = $1 FOR UPDATE").bind(pid).fetch_optional(&mut *tx).await?;
            let Some((status, queued)) = row else { return Ok(false) };
            if status == "done" {
                return Ok(false);
            }
            // A record forgotten while this attempt ran left the proposal: retry with what is left.
            anyhow::ensure!(w.records.iter().all(|r| queued.contains(&r.memory.id)), "a record of proposal {pid} was forgotten while it was being written");
        }
        if !w.records.is_empty() {
            // Exactly once in effect (TR-IN-03): the record ids are the proposal's idempotency key.
            let ids: Vec<Uuid> = w.records.iter().map(|r| r.memory.id).collect();
            // A proposal's records are written in one transaction, so they are all there or none.
            let seen: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory WHERE tenant = $1 AND id = ANY($2)").bind(&w.tenant).bind(&ids).fetch_one(&mut *tx).await?;
            anyhow::ensure!(seen == 0 || seen as usize == ids.len(), "{seen} of the proposal's {} records are already stored", ids.len());
            if seen > 0 {
                if let Some(pid) = w.proposal {
                    sqlx::query("UPDATE mh_intake SET status = 'done', finished_at = now(), locked_until = NULL, payload = NULL WHERE id = $1").bind(pid).execute(&mut *tx).await?;
                    tx.commit().await?;
                }
                return Ok(false);
            }
            let lines = Self::lines_of(&w.records);
            let rows: Vec<WriteRow> = lines
                .iter()
                .zip(&w.records)
                .map(|(r, n)| WriteRow { r, embedding: n.embedding.as_ref().map(|v| vec_literal(v)), alt: n.alt.as_ref().map(|(_, v)| vec_literal(v)) })
                .collect();
            self.write_rows_in(&mut tx, &rows, false).await?;
        }
        if !w.requires.is_empty() {
            if let Some(first) = w.records.first() {
                sqlx::query(SUBJECT_LOCK_SQL).bind(&w.tenant).bind(&first.memory.subject).execute(&mut *tx).await?;
            }
            // The sources of a promotion, locked until this commits: a `forget` of one waits,
            // then finds and removes what was promoted from it; one already gone stops the insert.
            let there: i64 = sqlx::query_scalar("SELECT count(*) FROM (SELECT 1 FROM mh_memory WHERE tenant = $1 AND id = ANY($2) FOR SHARE) s")
                .bind(&w.tenant)
                .bind(&w.requires)
                .fetch_one(&mut *tx)
                .await?;
            anyhow::ensure!(there as usize == w.requires.len(), "a source of a promotion was deleted while it was being written");
        }
        for (old, new) in &w.supersede {
            let n = sqlx::query(SUPERSEDE_SQL).bind(&w.tenant).bind(old).bind(new).execute(&mut *tx).await?.rows_affected();
            // The pipeline checked it was current; another write got there first: retry the
            // proposal, which then sees the new state.
            anyhow::ensure!(n == 1, "memory {old} stopped being current while {new} was being written");
        }
        for (plan, by) in &w.confirm {
            // Still a held, unexpired plan at commit time; otherwise retry, which then sees it.
            let n = sqlx::query(
                "UPDATE mh_memory SET status = 'committed', expires_at = NULL, metadata = (metadata - 'held') || jsonb_build_object('confirmed_by', $3::text), \
                 updated_at = greatest(now(), created_at) WHERE tenant = $1 AND id = $2 AND status = 'candidate' AND metadata ->> 'held' = 'plan' \
                 AND (expires_at IS NULL OR expires_at > now())",
            )
            .bind(&w.tenant)
            .bind(plan)
            .bind(by.to_string())
            .execute(&mut *tx)
            .await?
            .rows_affected();
            anyhow::ensure!(n == 1, "plan {plan} stopped being a held candidate while {by} was being written");
        }
        for (held, by, commit) in &w.signals {
            // Still a held, unexpired signal at commit time; otherwise retry, which then sees it.
            let n = sqlx::query(
                "UPDATE mh_memory SET status = CASE WHEN $4 THEN 'committed' ELSE status END, expires_at = CASE WHEN $4 THEN NULL ELSE expires_at END, \
                 metadata = (CASE WHEN $4 THEN metadata - 'held' ELSE metadata END) \
                   || jsonb_build_object('signals', coalesce((metadata ->> 'signals')::int, 1) + 1, 'last_signal', $3::text), \
                 updated_at = greatest(now(), created_at) WHERE tenant = $1 AND id = $2 AND status = 'candidate' AND metadata ->> 'held' = 'signal' \
                 AND (expires_at IS NULL OR expires_at > now())",
            )
            .bind(&w.tenant)
            .bind(held)
            .bind(by.to_string())
            .bind(commit)
            .execute(&mut *tx)
            .await?
            .rows_affected();
            anyhow::ensure!(n == 1, "signal {held} stopped being a held candidate while {by} was being written");
        }
        if let Some((subject, session, rounds)) = &w.enrich {
            sqlx::query("INSERT INTO mh_enrich_job (tenant, subject, session_id, round_ids) VALUES ($1, $2, $3, $4)")
                .bind(&w.tenant)
                .bind(subject)
                .bind(session)
                .bind(rounds)
                .execute(&mut *tx)
                .await?;
        }
        if let Some(pid) = w.proposal {
            sqlx::query(
                "UPDATE mh_intake SET status = CASE WHEN $2::text IS NULL THEN 'done' ELSE 'dead' END, finished_at = now(), locked_until = NULL, \
                 payload = NULL, outcome = $3, error = $2 WHERE id = $1",
            )
            .bind(pid)
            .bind(&w.dead)
            .bind(&w.outcome)
            .execute(&mut *tx)
            .await?;
        }
        // Last: the chain lock is held only for the commit.
        for a in &w.audit {
            self.audit_in(&mut tx, &w.tenant, a).await?;
        }
        tx.commit().await?;
        Ok(true)
    }

    #[tracing::instrument(name = "db.structured_lookup", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn structured_lookup(&self, q: &SearchQuery, record_type: Option<&str>, attrs: Option<&serde_json::Value>, values: &[String]) -> anyhow::Result<Vec<Hit>> {
        let p = Probe::of(q);
        // The recall filters (status, labels, validity, scope) with the recall's own parameters,
        // then the exact match on the structured row.
        let filters = search_filters(!q.shared_agents.is_empty());
        let sql = format!(
            "SELECT {COLS}, 1.0::float8 AS score, NULL::int AS krk, NULL::int AS vrk, NULL::float8 AS sim, 0 AS probe \
             FROM mh_structured s JOIN mh_memory m ON m.id = s.memory_id \
             WHERE s.tenant = $1 AND s.subject = $2 AND m.tenant = $1 AND m.subject = $2 \
             {filters} \
             AND ($27::text IS NULL OR s.record_type = $27) AND ($28::jsonb IS NULL OR s.attrs @> $28) \
             AND (cardinality($29::text[]) = 0 OR EXISTS (SELECT 1 FROM jsonb_each_text(s.attrs) e WHERE lower(e.value) = ANY($29))) \
             ORDER BY m.created_at DESC, m.id LIMIT $15"
        );
        let lower: Vec<String> = values.iter().map(|v| v.to_lowercase()).collect();
        let rows = search_query(sql, q, &p.tsq, p.kinds.clone(), p.use_kw, p.use_vec).bind(record_type).bind(attrs).bind(lower).fetch_all(&self.pool).await?;
        rows.iter().map(row_to_hit).collect()
    }

    async fn nearest_held(&self, tenant: &str, subject: &str, embedding: &[f32], limit: usize, which: &memhouse_core::traits::Held<'_>) -> anyhow::Result<Vec<(Uuid, f32)>> {
        let (held, kind, scope) = (which.reason, which.kind, which.scope);
        let rows: Vec<(Uuid, f64)> = sqlx::query_as(
            "SELECT id, 1 - (embedding <=> $3::vector) AS sim FROM mh_memory \
             WHERE tenant = $1 AND subject = $2 AND status = 'candidate' AND embedding IS NOT NULL \
             AND metadata ->> 'held' = $5 AND (expires_at IS NULL OR expires_at > now()) \
             AND ($6::text IS NULL OR kind = $6) \
             AND scope_org IS NOT DISTINCT FROM $7 AND scope_team IS NOT DISTINCT FROM $8 AND scope_agent IS NOT DISTINCT FROM $9 \
             AND scope_user IS NOT DISTINCT FROM $10 AND scope_session IS NOT DISTINCT FROM $11 \
             ORDER BY embedding <=> $3::vector LIMIT $4",
        )
        .bind(tenant)
        .bind(subject)
        .bind(vec_literal(embedding))
        .bind(limit as i64)
        .bind(held)
        .bind(kind.map(|k| k.as_str()))
        .bind(&scope.org)
        .bind(&scope.team)
        .bind(&scope.agent)
        .bind(&scope.user)
        .bind(&scope.session)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|(id, s)| (id, s as f32)).collect())
    }

    #[tracing::instrument(name = "db.search", skip_all, fields(db.system = "postgresql", db.operation = "SELECT", probes = 1))]
    async fn search(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>> {
        self.search_one(q).await
    }

    #[tracing::instrument(name = "db.search", skip_all, fields(db.system = "postgresql", db.operation = "SELECT", probes = qs.len()))]
    async fn search_many(&self, qs: &[SearchQuery]) -> anyhow::Result<Vec<Vec<Hit>>> {
        if qs.len() == 1 {
            return Ok(vec![self.search_one(&qs[0]).await?]);
        }
        self.ensure_current().await?;
        let probes: Vec<Probe> = qs.iter().map(Probe::of).collect();
        let sql = multi_search_sql(qs.len(), qs.iter().any(|q| !q.shared_agents.is_empty()));
        let mut query = sqlx::query(sqlx::AssertSqlSafe(sql));
        for (q, p) in qs.iter().zip(&probes) {
            query = bind_search(query, q, &p.tsq, p.kinds.clone(), p.use_kw, p.use_vec);
        }
        let mut out: Vec<Vec<Hit>> = vec![vec![]; qs.len()];
        for r in query.fetch_all(&self.pool).await? {
            let i: i32 = r.try_get("probe")?;
            out[i as usize].push(row_to_hit(&r)?);
        }
        Ok(out)
    }

    fn statements_per_recall(&self, _probes: usize) -> usize {
        1
    }

    #[tracing::instrument(name = "db.search_unfiltered", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn search_unfiltered(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>> {
        let p = Probe::of(q);
        let sql = search_sql_with(false, false);
        let rows = search_query(sql, q, &p.tsq, p.kinds.clone(), p.use_kw, p.use_vec).fetch_all(&self.pool).await?;
        rows.iter().map(row_to_hit).collect()
    }

    async fn search_plan(&self, q: &SearchQuery) -> anyhow::Result<Option<serde_json::Value>> {
        // Fresh statistics, so the plan is the one the planner would pick on this data.
        sqlx::query("ANALYZE mh_memory").execute(&self.pool).await?;
        let use_kw = q.mode != RetrievalMode::Dense;
        let use_vec = q.mode != RetrievalMode::Keyword && q.embedding.is_some();
        let tsq = if use_kw { or_query(&q.text) } else { String::new() };
        let kinds: Option<Vec<String>> = q.kinds.as_ref().map(|ks| ks.iter().map(|k| k.as_str().to_string()).collect());
        let sql = format!("EXPLAIN (FORMAT JSON) {}", search_sql(!q.shared_agents.is_empty()));
        let row = search_query(sql, q, &tsq, kinds, use_kw, use_vec).fetch_one(&self.pool).await?;
        Ok(Some(row.try_get::<serde_json::Value, _>(0)?))
    }

    #[tracing::instrument(name = "db.get", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn get(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<Memory>> {
        let row = sqlx::query(trusted_sql!("SELECT {COLS} FROM mh_memory m WHERE m.tenant = $1 AND m.id = $2")).bind(tenant).bind(id).fetch_optional(&self.pool).await?;
        row.map(|r| row_to_memory(&r)).transpose()
    }

    #[tracing::instrument(name = "db.list", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn list(&self, q: &ListQuery) -> anyhow::Result<Vec<Memory>> {
        let kinds: Option<Vec<String>> = q.kinds.as_ref().map(|ks| ks.iter().map(|k| k.as_str().to_string()).collect());
        let rows = sqlx::query(trusted_sql!(
            "SELECT {COLS} FROM mh_memory m WHERE m.tenant = $1 AND ($2::text IS NULL OR m.subject = $2) \
             AND ($3::text[] IS NULL OR m.kind = ANY($3)) AND ($4 OR m.status = 'committed') \
             AND ($7::timestamptz IS NULL OR (m.created_at, m.id) < ($7, $8)) \
             AND NOT (m.labels && $9::text[]) \
             AND ($10::text IS NULL OR m.scope_org IS NULL OR m.scope_org = $10) \
             AND ($11::text IS NULL OR m.scope_team IS NULL OR m.scope_team = $11) \
             AND ($12::text IS NULL OR m.scope_agent IS NULL OR m.scope_agent = $12 \
                  OR (m.scope_agent || chr(31) || '*') = ANY($15::text[]) OR (m.scope_agent || chr(31) || m.kind) = ANY($15::text[])) \
             AND ($13::text IS NULL OR m.scope_user IS NULL OR m.scope_user = $13) \
             AND ($14::text IS NULL OR m.scope_session IS NULL OR m.scope_session = $14) \
             AND ($16::text IS NULL OR m.scope_session = $16) \
             ORDER BY m.created_at DESC, m.id DESC LIMIT $5 OFFSET $6"
        ))
        .bind(&q.tenant)
        .bind(&q.subject)
        .bind(kinds)
        .bind(q.include_inactive)
        .bind(q.limit as i64)
        .bind(q.offset as i64)
        .bind(q.before.map(|b| b.0))
        .bind(q.before.map(|b| b.1))
        .bind(&q.denied_labels)
        .bind(&q.scope.org)
        .bind(&q.scope.team)
        .bind(&q.scope.agent)
        .bind(&q.scope.user)
        .bind(&q.scope.session)
        .bind(&q.shared_agents)
        .bind(&q.session)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_memory).collect()
    }

    #[tracing::instrument(name = "db.find_by_hash", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn find_by_hash(&self, tenant: &str, subject: &str, hash: &str) -> anyhow::Result<Option<Uuid>> {
        Ok(sqlx::query_scalar("SELECT id FROM mh_memory WHERE tenant = $1 AND subject = $2 AND content_hash = $3 AND status <> 'superseded' LIMIT 1")
            .bind(tenant)
            .bind(subject)
            .bind(hash)
            .fetch_optional(&self.pool)
            .await?)
    }

    #[tracing::instrument(name = "db.existing_hashes", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn existing_hashes(&self, tenant: &str, subject: &str, hashes: &[String]) -> anyhow::Result<std::collections::HashSet<String>> {
        if hashes.is_empty() {
            return Ok(Default::default());
        }
        let v: Vec<String> = sqlx::query_scalar("SELECT content_hash FROM mh_memory WHERE tenant = $1 AND subject = $2 AND content_hash = ANY($3)")
            .bind(tenant)
            .bind(subject)
            .bind(hashes)
            .fetch_all(&self.pool)
            .await?;
        Ok(v.into_iter().collect())
    }

    #[tracing::instrument(name = "db.nearest", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn nearest_many(&self, tenant: &str, subject: &str, kind: MemoryKind, embedding: &[f32], n: usize, scope: &Scope) -> anyhow::Result<Vec<(Uuid, f32)>> {
        let rows: Vec<(Uuid, f64)> = sqlx::query_as(
            "SELECT id, 1 - (embedding <=> $4::vector) AS sim FROM mh_memory \
             WHERE tenant = $1 AND subject = $2 AND kind = $3 AND status = 'committed' AND embedding IS NOT NULL \
             AND scope_org IS NOT DISTINCT FROM $6 AND scope_team IS NOT DISTINCT FROM $7 AND scope_agent IS NOT DISTINCT FROM $8 \
             AND scope_user IS NOT DISTINCT FROM $9 AND scope_session IS NOT DISTINCT FROM $10 \
             ORDER BY embedding <=> $4::vector LIMIT $5",
        )
        .bind(tenant)
        .bind(subject)
        .bind(kind.as_str())
        .bind(vec_literal(embedding))
        .bind(n as i64)
        .bind(&scope.org)
        .bind(&scope.team)
        .bind(&scope.agent)
        .bind(&scope.user)
        .bind(&scope.session)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|(id, s)| (id, s as f32)).collect())
    }

    async fn nearest(&self, tenant: &str, subject: &str, kind: MemoryKind, embedding: &[f32]) -> anyhow::Result<Option<(Uuid, f32)>> {
        let row = sqlx::query(
            "SELECT id, 1 - (embedding <=> $4::vector) AS sim FROM mh_memory \
             WHERE tenant = $1 AND subject = $2 AND kind = $3 AND status = 'committed' AND embedding IS NOT NULL \
             ORDER BY embedding <=> $4::vector LIMIT 1",
        )
        .bind(tenant)
        .bind(subject)
        .bind(kind.as_str())
        .bind(vec_literal(embedding))
        .fetch_optional(&self.pool)
        .await?;
        Ok(match row {
            Some(r) => Some((r.try_get("id")?, r.try_get::<f64, _>("sim")? as f32)),
            None => None,
        })
    }

    #[tracing::instrument(name = "db.set_superseded", skip_all, fields(db.system = "postgresql", db.operation = "UPDATE"))]
    async fn set_superseded(&self, tenant: &str, id: Uuid, by: Uuid) -> anyhow::Result<bool> {
        // A version stops being true when its successor starts (even if it had a later end of its
        // own), so as-of recall finds exactly one version at any time. The successor's time comes
        // from the same clock as the version's own, not the database's.
        let r = sqlx::query(SUPERSEDE_SQL).bind(tenant).bind(id).bind(by).execute(&self.pool).await?;
        Ok(r.rows_affected() > 0)
    }

    #[tracing::instrument(name = "db.set_status", skip_all, fields(db.system = "postgresql", db.operation = "UPDATE"))]
    async fn set_status(&self, tenant: &str, id: Uuid, status: MemoryStatus) -> anyhow::Result<bool> {
        // Only the transitions of the lifecycle (CORE-02); anything else changes nothing.
        let from: Vec<&str> = MemoryStatus::sources_of(status).iter().map(|s| s.as_str()).collect();
        // greatest(): the database's clock may trail the application's, which set created_at.
        let r = sqlx::query("UPDATE mh_memory SET status = $3, updated_at = greatest(now(), created_at) WHERE tenant = $1 AND id = $2 AND status = ANY($4)")
            .bind(tenant)
            .bind(id)
            .bind(status.as_str())
            .bind(&from)
            .execute(&self.pool)
            .await?;
        Ok(r.rows_affected() > 0)
    }

    #[tracing::instrument(name = "db.delete", skip_all, fields(db.system = "postgresql", db.operation = "DELETE"))]
    async fn delete(&self, tenant: &str, id: Uuid, actor: &str) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        // No promotion in this subject is in flight while its links are followed below.
        let Some(of): Option<String> = sqlx::query_scalar("SELECT subject FROM mh_memory WHERE tenant = $1 AND id = $2").bind(tenant).bind(id).fetch_optional(&mut *tx).await?
        else {
            return Ok(false);
        };
        sqlx::query(SUBJECT_LOCK_SQL).bind(tenant).bind(&of).execute(&mut *tx).await?;
        let row = sqlx::query("DELETE FROM mh_memory WHERE tenant = $1 AND id = $2 RETURNING subject, content, alt_hash").bind(tenant).bind(id).fetch_optional(&mut *tx).await?;
        let Some(row) = row else { return Ok(false) };
        let subject: String = row.try_get("subject")?;
        let content: String = row.try_get("content")?;
        let alt_hash: Option<String> = row.try_get("alt_hash")?;
        // Also drop the cached embeddings of this content (every representation goes, TR-WF-01).
        sqlx::query("DELETE FROM mh_embed_cache WHERE hash = encode(sha256(convert_to($1 || $2, 'UTF8')), 'hex') OR hash = $3")
            .bind(&self.passage_prefix)
            .bind(&content)
            .bind(alt_hash)
            .execute(&mut *tx)
            .await?;
        // Facts derived from this record and records promoted from it (MEM-05) go with it, and
        // so does everything promoted from those in turn (a note promoted to a fact, the fact to
        // a procedure), with their cached vectors; and the cached extraction of every session
        // job that read it.
        sqlx::query(
            "WITH RECURSIVE dep(id) AS ( \
               SELECT id FROM mh_memory WHERE tenant = $1 AND (metadata -> 'source_ids' ? $2 \
                 OR (metadata ? 'promoted_from' AND metadata -> 'promoted_from' ? $2)) \
               UNION \
               SELECT m.id FROM dep JOIN mh_memory m ON m.tenant = $1 AND m.metadata ? 'promoted_from' AND m.metadata -> 'promoted_from' ? dep.id::text), \
             d AS (DELETE FROM mh_memory WHERE tenant = $1 AND id IN (SELECT id FROM dep) RETURNING content) \
             DELETE FROM mh_embed_cache c USING d WHERE c.hash = encode(sha256(convert_to($3 || d.content, 'UTF8')), 'hex')",
        )
        .bind(tenant)
        .bind(id.to_string())
        .bind(&self.passage_prefix)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND round_ids @> ARRAY[$2]::uuid[] RETURNING cache_key) \
             DELETE FROM mh_llm_cache c USING j WHERE c.key = j.cache_key",
        )
        .bind(tenant)
        .bind(id)
        .execute(&mut *tx)
        .await?;
        sqlx::query("INSERT INTO mh_deletion_ledger (tenant, subject, memory_id, scope, actor) VALUES ($1, $2, $3, 'memory', $4)")
            .bind(tenant)
            .bind(&subject)
            .bind(id)
            .bind(actor)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(true)
    }

    #[tracing::instrument(name = "db.delete_subject", skip_all, fields(db.system = "postgresql", db.operation = "DELETE"))]
    async fn delete_subject(&self, tenant: &str, subject: &str, actor: &str, purge_cache: bool) -> anyhow::Result<u64> {
        let mut tx = self.pool.begin().await?;
        // Queued writes first: a proposal being inserted right now holds its row, so this waits
        // for it and the deletes below then see what it wrote (nothing lands after an erasure).
        sqlx::query("DELETE FROM mh_intake WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        if purge_cache {
            sqlx::query(
                "DELETE FROM mh_embed_cache c USING mh_memory m WHERE m.tenant = $1 AND m.subject = $2 \
                 AND (c.hash = encode(sha256(convert_to($3 || m.content, 'UTF8')), 'hex') OR c.hash = m.alt_hash)",
            )
            .bind(tenant)
            .bind(subject)
            .bind(&self.passage_prefix)
            .execute(&mut *tx)
            .await?;
        }
        let n = sqlx::query("DELETE FROM mh_memory WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?.rows_affected();
        // Links held by the subject and links to it from others, and remembered responses.
        sqlx::query("DELETE FROM mh_link WHERE tenant = $1 AND (subject = $2 OR linked_subject = $2)").bind(tenant).bind(subject).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM mh_request_key WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM mh_recall WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        if purge_cache {
            sqlx::query(
                "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2 RETURNING cache_key) \
                 DELETE FROM mh_llm_cache c USING j WHERE c.key = j.cache_key",
            )
            .bind(tenant)
            .bind(subject)
            .execute(&mut *tx)
            .await?;
        } else {
            sqlx::query("DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        }
        sqlx::query("INSERT INTO mh_deletion_ledger (tenant, subject, scope, actor) VALUES ($1, $2, $4, $3)")
            .bind(tenant)
            .bind(subject)
            .bind(actor)
            .bind(if purge_cache { "subject" } else { "subject-reset" })
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(n)
    }

    async fn purge_older_than(&self, tenant: &str, kind: MemoryKind, days: u32) -> anyhow::Result<u64> {
        // Same cascade as `delete`, in batches so a large purge never holds one huge transaction:
        // the rounds, their cached vectors, facts derived from them (and their vectors), the jobs
        // that read them (and their cached extractions), and a ledger row per round.
        let mut total = 0u64;
        loop {
            let mut tx = self.pool.begin().await?;
            let rows = sqlx::query(
                "DELETE FROM mh_memory WHERE id IN (SELECT id FROM mh_memory WHERE tenant = $1 AND kind = $3 \
                 AND created_at < now() - make_interval(days => $2) LIMIT 1000) RETURNING id, subject, content, alt_hash",
            )
            .bind(tenant)
            .bind(days as i32)
            .bind(kind.as_str())
            .fetch_all(&mut *tx)
            .await?;
            if rows.is_empty() {
                break;
            }
            let mut ids = Vec::with_capacity(rows.len());
            let mut subjects = Vec::with_capacity(rows.len());
            let mut contents = Vec::with_capacity(rows.len());
            let mut alt_hashes = vec![];
            for r in &rows {
                ids.push(r.try_get::<Uuid, _>("id")?);
                subjects.push(r.try_get::<String, _>("subject")?);
                contents.push(r.try_get::<String, _>("content")?);
                if let Some(h) = r.try_get::<Option<String>, _>("alt_hash")? {
                    alt_hashes.push(h);
                }
            }
            let id_strs: Vec<String> = ids.iter().map(|u| u.to_string()).collect();
            sqlx::query(
                "DELETE FROM mh_embed_cache WHERE hash IN (SELECT encode(sha256(convert_to($1 || c, 'UTF8')), 'hex') FROM unnest($2::text[]) c) \
                 OR hash = ANY($3)",
            )
            .bind(&self.passage_prefix)
            .bind(&contents)
            .bind(&alt_hashes)
            .execute(&mut *tx)
            .await?;
            let facts: i64 = sqlx::query_scalar(
                "WITH d AS (DELETE FROM mh_memory WHERE tenant = $1 AND metadata -> 'source_ids' ?| $2::text[] RETURNING content), \
                 c AS (DELETE FROM mh_embed_cache c USING d WHERE c.hash = encode(sha256(convert_to($3 || d.content, 'UTF8')), 'hex')) \
                 SELECT count(*) FROM d",
            )
            .bind(tenant)
            .bind(&id_strs)
            .bind(&self.passage_prefix)
            .fetch_one(&mut *tx)
            .await?;
            sqlx::query(
                "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND round_ids && $2::uuid[] RETURNING cache_key) \
                 DELETE FROM mh_llm_cache c USING j WHERE c.key = j.cache_key",
            )
            .bind(tenant)
            .bind(&ids)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "INSERT INTO mh_deletion_ledger (tenant, subject, memory_id, scope, actor) \
                 SELECT $1, s, i, 'retention', 'system' FROM unnest($2::text[], $3::uuid[]) AS t(s, i)",
            )
            .bind(tenant)
            .bind(&subjects)
            .bind(&ids)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
            total += rows.len() as u64 + facts as u64;
        }
        Ok(total)
    }

    #[tracing::instrument(name = "db.embed_cache_get", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn embed_cache_get(&self, model: &str, hashes: &[String]) -> anyhow::Result<Vec<(String, Vec<f32>)>> {
        if hashes.is_empty() {
            return Ok(vec![]);
        }
        let rows = sqlx::query("SELECT hash, embedding FROM mh_embed_cache WHERE model = $1 AND hash = ANY($2)").bind(model).bind(hashes).fetch_all(&self.pool).await?;
        rows.iter().map(|r| Ok((r.try_get("hash")?, r.try_get("embedding")?))).collect()
    }

    #[tracing::instrument(name = "db.embed_cache_put", skip_all, fields(db.system = "postgresql", db.operation = "INSERT"))]
    async fn embed_cache_put(&self, model: &str, items: &[(String, Vec<f32>)]) -> anyhow::Result<()> {
        for chunk in items.chunks(500) {
            let mut qb = sqlx::QueryBuilder::new("INSERT INTO mh_embed_cache (model, hash, embedding) ");
            qb.push_values(chunk, |mut b, (h, v)| {
                b.push_bind(model).push_bind(h).push_bind(v);
            });
            qb.push(" ON CONFLICT DO NOTHING");
            qb.build().execute(&self.pool).await?;
        }
        Ok(())
    }

    #[tracing::instrument(name = "db.audit", skip_all, fields(db.system = "postgresql", db.operation = "INSERT"))]
    async fn audit(&self, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<Uuid>, detail: serde_json::Value) -> anyhow::Result<()> {
        let detail = detail.to_string();
        let at = Utc::now().trunc_subsecs(6);
        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock(7270001)").execute(&mut *tx).await?;
        let prev: Option<String> = sqlx::query_scalar("SELECT hash FROM mh_audit ORDER BY id DESC LIMIT 1").fetch_optional(&mut *tx).await?;
        let prev = prev.unwrap_or_else(|| "genesis".into());
        let hash = audit_hash(&prev, &at, actor, action, tenant, subject, memory_id, &detail);
        sqlx::query("INSERT INTO mh_audit (at, actor, action, tenant, subject, memory_id, detail, prev_hash, hash) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)")
            .bind(at)
            .bind(actor)
            .bind(action)
            .bind(tenant)
            .bind(subject)
            .bind(memory_id)
            .bind(&detail)
            .bind(&prev)
            .bind(&hash)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    async fn audit_log(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<AuditEvent>> {
        let rows = sqlx::query("SELECT * FROM mh_audit WHERE tenant = $1 ORDER BY id DESC LIMIT $2").bind(tenant).bind(limit as i64).fetch_all(&self.pool).await?;
        rows.iter()
            .map(|r| {
                let detail: String = r.try_get("detail")?;
                Ok(AuditEvent {
                    id: r.try_get("id")?,
                    at: r.try_get("at")?,
                    actor: r.try_get("actor")?,
                    action: r.try_get("action")?,
                    tenant: r.try_get("tenant")?,
                    subject: r.try_get("subject")?,
                    memory_id: r.try_get("memory_id")?,
                    detail: serde_json::from_str(&detail).unwrap_or(serde_json::Value::String(detail)),
                    prev_hash: r.try_get("prev_hash")?,
                    hash: r.try_get("hash")?,
                })
            })
            .collect()
    }

    async fn audit_verify(&self) -> anyhow::Result<(u64, Option<i64>)> {
        use futures::TryStreamExt;
        let mut rows = sqlx::query("SELECT * FROM mh_audit ORDER BY id").fetch(&self.pool);
        let mut prev = "genesis".to_string();
        let mut n = 0u64;
        while let Some(r) = rows.try_next().await? {
            n += 1;
            let id: i64 = r.try_get("id")?;
            let stored_prev: String = r.try_get("prev_hash")?;
            let stored: String = r.try_get("hash")?;
            let subject: Option<String> = r.try_get("subject")?;
            let h = audit_hash(
                &prev,
                &r.try_get("at")?,
                &r.try_get::<String, _>("actor")?,
                &r.try_get::<String, _>("action")?,
                &r.try_get::<String, _>("tenant")?,
                subject.as_deref(),
                r.try_get("memory_id")?,
                &r.try_get::<String, _>("detail")?,
            );
            if stored_prev != prev || h != stored {
                return Ok((n, Some(id)));
            }
            prev = stored;
        }
        Ok((n, None))
    }

    async fn stats(&self, tenant: &str) -> anyhow::Result<Stats> {
        let r = sqlx::query(
            "SELECT count(*) AS total, count(*) FILTER (WHERE status = 'committed') AS committed, \
             count(*) FILTER (WHERE status = 'quarantined') AS quarantined, count(*) FILTER (WHERE status = 'superseded') AS superseded, \
             count(DISTINCT subject) AS subjects FROM mh_memory WHERE tenant = $1",
        )
        .bind(tenant)
        .fetch_one(&self.pool)
        .await?;
        let audit: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_audit WHERE tenant = $1").bind(tenant).fetch_one(&self.pool).await?;
        let by_kind: Vec<(String, i64)> = sqlx::query_as("SELECT kind, count(*) FROM mh_memory WHERE tenant = $1 AND status = 'committed' GROUP BY kind ORDER BY 2 DESC")
            .bind(tenant)
            .fetch_all(&self.pool)
            .await?;
        Ok(Stats {
            memories: r.try_get("total")?,
            committed: r.try_get("committed")?,
            quarantined: r.try_get("quarantined")?,
            superseded: r.try_get("superseded")?,
            subjects: r.try_get("subjects")?,
            audit_events: audit,
            by_kind,
        })
    }

    async fn subjects(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<(String, i64)>> {
        Ok(sqlx::query_as("SELECT subject, count(*) FROM mh_memory WHERE tenant = $1 AND status = 'committed' GROUP BY subject ORDER BY max(created_at) DESC LIMIT $2")
            .bind(tenant)
            .bind(limit as i64)
            .fetch_all(&self.pool)
            .await?)
    }

    async fn representations(&self, tenant: &str, id: Uuid) -> anyhow::Result<(Option<Structured>, Vec<CodeRef>)> {
        let structured = sqlx::query("SELECT s.record_type, s.attrs FROM mh_structured s JOIN mh_memory m ON m.id = s.memory_id WHERE m.tenant = $1 AND s.memory_id = $2")
            .bind(tenant)
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
            .map(|r| -> anyhow::Result<Structured> { Ok(Structured { record_type: r.try_get("record_type")?, attrs: r.try_get("attrs")? }) })
            .transpose()?;
        let code_refs =
            sqlx::query("SELECT c.path, c.blob_hash FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id WHERE m.tenant = $1 AND c.memory_id = $2 ORDER BY c.path")
                .bind(tenant)
                .bind(id)
                .fetch_all(&self.pool)
                .await?
                .iter()
                .map(|r| Ok(CodeRef { path: r.try_get("path")?, blob_hash: r.try_get("blob_hash")? }))
                .collect::<anyhow::Result<Vec<_>>>()?;
        Ok((structured, code_refs))
    }

    #[tracing::instrument(name = "db.recall_put", skip_all, fields(db.system = "postgresql", db.operation = "INSERT"))]
    async fn recall_put(&self, r: &RecallRecord) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_recall (id, tenant, subject, principal, acting_user, at, body) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (id) DO NOTHING")
            .bind(r.recall_id)
            .bind(&r.tenant)
            .bind(&r.subject)
            .bind(&r.principal)
            .bind(&r.user)
            .bind(r.at)
            .bind(serde_json::to_value(r)?)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn recall_get(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<RecallRecord>> {
        let body: Option<serde_json::Value> =
            sqlx::query_scalar("SELECT body FROM mh_recall WHERE tenant = $1 AND id = $2").bind(tenant).bind(id).fetch_optional(&self.pool).await?;
        Ok(body.map(serde_json::from_value).transpose()?)
    }

    async fn recalls_delete(&self, tenant: &str, user: Option<&str>, older_than_days: Option<u32>) -> anyhow::Result<u64> {
        let r = sqlx::query("DELETE FROM mh_recall WHERE tenant = $1 AND ($2::text IS NULL OR acting_user = $2) AND ($3::int IS NULL OR at < now() - make_interval(days => $3))")
            .bind(tenant)
            .bind(user)
            .bind(older_than_days.map(|d| d as i32))
            .execute(&self.pool)
            .await?;
        Ok(r.rows_affected())
    }

    async fn set_labels(&self, tenant: &str, id: Uuid, labels: &[String]) -> anyhow::Result<bool> {
        let r = sqlx::query("UPDATE mh_memory SET labels = $3, updated_at = greatest(now(), created_at) WHERE tenant = $1 AND id = $2")
            .bind(tenant)
            .bind(id)
            .bind(labels)
            .execute(&self.pool)
            .await?;
        Ok(r.rows_affected() > 0)
    }

    async fn set_status_many(&self, tenant: &str, ids: &[Uuid], status: MemoryStatus) -> anyhow::Result<u64> {
        let from: Vec<&str> = MemoryStatus::sources_of(status).iter().map(|s| s.as_str()).collect();
        let r = sqlx::query("UPDATE mh_memory SET status = $3, updated_at = greatest(now(), created_at) WHERE tenant = $1 AND id = ANY($2) AND status = ANY($4)")
            .bind(tenant)
            .bind(ids)
            .bind(status.as_str())
            .bind(&from)
            .execute(&self.pool)
            .await?;
        Ok(r.rows_affected())
    }

    async fn principal_get(&self, id: &str) -> anyhow::Result<Option<memhouse_core::identity::Principal>> {
        sqlx::query("SELECT * FROM mh_principal WHERE id = $1").bind(id).fetch_optional(&self.pool).await?.as_ref().map(row_to_principal).transpose()
    }

    async fn principal_put(&self, p: &memhouse_core::identity::Principal) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO mh_principal (id, tenant, kind, name, subjects, kinds, denied_labels, org, team, can_commit, act_as, disabled_at, created_at, created_by) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) \
             ON CONFLICT (id) DO UPDATE SET name = $4, subjects = $5, kinds = $6, denied_labels = $7, org = $8, team = $9, can_commit = $10, act_as = $11, disabled_at = $12 \
             WHERE mh_principal.tenant = $2 AND mh_principal.kind = $3",
        )
        .bind(&p.id)
        .bind(&p.tenant)
        .bind(p.kind.as_str())
        .bind(&p.name)
        .bind(&p.subjects)
        .bind(p.kinds.iter().map(|k| k.as_str()).collect::<Vec<_>>())
        .bind(&p.denied_labels)
        .bind(&p.org)
        .bind(&p.team)
        .bind(p.can_commit)
        .bind(p.act_as)
        .bind(p.disabled_at)
        .bind(p.created_at)
        .bind(&p.created_by)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn principals(&self, tenant: Option<&str>) -> anyhow::Result<Vec<memhouse_core::identity::Principal>> {
        sqlx::query("SELECT * FROM mh_principal WHERE $1::text IS NULL OR tenant = $1 ORDER BY id").bind(tenant).fetch_all(&self.pool).await?.iter().map(row_to_principal).collect()
    }

    async fn api_key_get(&self, id: &str) -> anyhow::Result<Option<memhouse_core::identity::ApiKey>> {
        sqlx::query("SELECT * FROM mh_api_key WHERE id = $1").bind(id).fetch_optional(&self.pool).await?.as_ref().map(row_to_key).transpose()
    }

    async fn api_key_put(&self, k: &memhouse_core::identity::ApiKey) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_api_key (id, principal_id, hash, scopes, expires_at, revoked_at, created_at, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)")
            .bind(&k.id)
            .bind(&k.principal_id)
            .bind(&k.hash)
            .bind(&k.scopes)
            .bind(k.expires_at)
            .bind(k.revoked_at)
            .bind(k.created_at)
            .bind(&k.created_by)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn api_key_end(&self, id: &str, expire_at: Option<chrono::DateTime<chrono::Utc>>) -> anyhow::Result<bool> {
        let r = match expire_at {
            None => sqlx::query("UPDATE mh_api_key SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL").bind(id).execute(&self.pool).await?,
            Some(at) => {
                sqlx::query("UPDATE mh_api_key SET expires_at = least(COALESCE(expires_at, 'infinity'), $2) WHERE id = $1 AND revoked_at IS NULL")
                    .bind(id)
                    .bind(at)
                    .execute(&self.pool)
                    .await?
            }
        };
        Ok(r.rows_affected() > 0)
    }

    async fn api_keys(&self, principal: Option<&str>) -> anyhow::Result<Vec<memhouse_core::identity::ApiKey>> {
        sqlx::query("SELECT * FROM mh_api_key WHERE $1::text IS NULL OR principal_id = $1 ORDER BY principal_id, created_at")
            .bind(principal)
            .fetch_all(&self.pool)
            .await?
            .iter()
            .map(row_to_key)
            .collect()
    }

    async fn signing_key(&self, kid: &str) -> anyhow::Result<Option<Vec<u8>>> {
        Ok(sqlx::query_scalar("SELECT secret FROM mh_signing_key WHERE id = $1").bind(kid).fetch_optional(&self.pool).await?)
    }

    async fn signing_key_current(&self) -> anyhow::Result<(String, Vec<u8>)> {
        let q = "SELECT id, secret FROM mh_signing_key WHERE retired_at IS NULL ORDER BY created_at, id LIMIT 1";
        if let Some(r) = sqlx::query_as::<_, (String, Vec<u8>)>(q).fetch_optional(&self.pool).await? {
            return Ok(r);
        }
        let (id, secret) = memhouse_core::identity::new_signing_secret();
        // Two processes may race here; both keys stay valid, the oldest wins from then on.
        sqlx::query("INSERT INTO mh_signing_key (id, secret) VALUES ($1, $2) ON CONFLICT DO NOTHING").bind(&id).bind(&secret).execute(&self.pool).await?;
        Ok(sqlx::query_as::<_, (String, Vec<u8>)>("SELECT id, secret FROM mh_signing_key WHERE retired_at IS NULL ORDER BY created_at, id LIMIT 1").fetch_one(&self.pool).await?)
    }

    async fn forget_matches(&self, tenant: &str, scope: ForgetScope, value: &str, limit: usize) -> anyhow::Result<Vec<Uuid>> {
        let cond = forget_condition(scope)?;
        Ok(sqlx::query_scalar(trusted_sql!("SELECT id FROM mh_memory WHERE tenant = $1 AND {cond} ORDER BY id LIMIT $3"))
            .bind(tenant)
            .bind(value)
            .bind(limit as i64)
            .fetch_all(&self.pool)
            .await?)
    }

    async fn forget_count(&self, tenant: &str, scope: ForgetScope, value: &str) -> anyhow::Result<u64> {
        let cond = match scope {
            ForgetScope::Tenant => "true",
            ForgetScope::Subject => "subject = $2",
            s => forget_condition(s)?,
        };
        let n: i64 = sqlx::query_scalar(trusted_sql!("SELECT count(*) FROM mh_memory WHERE tenant = $1 AND ($2::text IS NOT NULL) AND {cond}"))
            .bind(tenant)
            .bind(value)
            .fetch_one(&self.pool)
            .await?;
        Ok(n as u64)
    }

    async fn delete_tenant(&self, tenant: &str, actor: &str) -> anyhow::Result<u64> {
        let mut total = 0;
        sqlx::query("DELETE FROM mh_intake WHERE tenant = $1").bind(tenant).execute(&self.pool).await?;
        loop {
            // Every subject, in any state (`subjects` lists only those with committed records).
            let subjects: Vec<String> = sqlx::query_scalar("SELECT DISTINCT subject FROM mh_memory WHERE tenant = $1 LIMIT 500").bind(tenant).fetch_all(&self.pool).await?;
            if subjects.is_empty() {
                break;
            }
            for s in subjects {
                total += self.delete_subject(tenant, &s, actor, true).await?;
            }
        }
        // What is left without a record: links, remembered responses, queued jobs and writes.
        sqlx::query("DELETE FROM mh_intake WHERE tenant = $1").bind(tenant).execute(&self.pool).await?;
        sqlx::query("DELETE FROM mh_link WHERE tenant = $1").bind(tenant).execute(&self.pool).await?;
        sqlx::query("DELETE FROM mh_grant WHERE tenant = $1").bind(tenant).execute(&self.pool).await?;
        sqlx::query("DELETE FROM mh_request_key WHERE tenant = $1").bind(tenant).execute(&self.pool).await?;
        sqlx::query("DELETE FROM mh_recall WHERE tenant = $1").bind(tenant).execute(&self.pool).await?;
        sqlx::query("WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 RETURNING cache_key) DELETE FROM mh_llm_cache c USING j WHERE c.key = j.cache_key")
            .bind(tenant)
            .execute(&self.pool)
            .await?;
        sqlx::query("INSERT INTO mh_deletion_ledger (tenant, scope, actor) VALUES ($1, 'tenant', $2)").bind(tenant).bind(actor).execute(&self.pool).await?;
        Ok(total)
    }

    async fn get_many(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<Memory>> {
        let rows = sqlx::query(trusted_sql!("SELECT {COLS} FROM mh_memory m WHERE m.tenant = $1 AND m.id = ANY($2)")).bind(tenant).bind(ids).fetch_all(&self.pool).await?;
        rows.iter().map(row_to_memory).collect()
    }

    async fn enrich_enqueue(&self, tenant: &str, subject: &str, session_id: &str, round_ids: &[Uuid]) -> anyhow::Result<i64> {
        Ok(sqlx::query_scalar("INSERT INTO mh_enrich_job (tenant, subject, session_id, round_ids) VALUES ($1, $2, $3, $4) RETURNING id")
            .bind(tenant)
            .bind(subject)
            .bind(session_id)
            .bind(round_ids)
            .fetch_one(&self.pool)
            .await?)
    }

    async fn enrich_claim(&self, limit: usize, lease_secs: i64) -> anyhow::Result<Vec<EnrichJob>> {
        let rows = sqlx::query(
            "UPDATE mh_enrich_job j SET status = 'running', attempts = j.attempts + 1, \
               locked_until = now() + make_interval(secs => $2) \
             WHERE j.id IN (SELECT c.id FROM mh_enrich_job c \
               WHERE ((c.status = 'pending' AND c.run_after <= now()) OR (c.status = 'running' AND c.locked_until < now())) \
                 AND NOT EXISTS (SELECT 1 FROM mh_enrich_job o WHERE o.tenant = c.tenant AND o.subject = c.subject \
                                 AND o.status IN ('pending', 'running') AND o.id < c.id) \
               ORDER BY c.id LIMIT $1 FOR UPDATE SKIP LOCKED) \
             RETURNING j.id, j.tenant, j.subject, j.session_id, j.round_ids, j.attempts",
        )
        .bind(limit as i64)
        .bind(lease_secs as f64)
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|r| {
                Ok(EnrichJob {
                    id: r.try_get("id")?,
                    tenant: r.try_get("tenant")?,
                    subject: r.try_get("subject")?,
                    session_id: r.try_get("session_id")?,
                    round_ids: r.try_get("round_ids")?,
                    attempts: r.try_get("attempts")?,
                })
            })
            .collect()
    }

    async fn enrich_finish(&self, id: i64, cache_key: Option<&str>, outcome: &EnrichOutcome) -> anyhow::Result<()> {
        // The lag is measured in the database so it is not skewed by the worker's clock.
        sqlx::query(
            "UPDATE mh_enrich_job SET status = 'done', finished_at = now(), locked_until = NULL, cache_key = $2, \
             outcome = jsonb_set($3::jsonb, '{lag_ms}', to_jsonb(extract(epoch FROM now() - enqueued_at) * 1000)) WHERE id = $1",
        )
        .bind(id)
        .bind(cache_key)
        .bind(serde_json::to_value(outcome)?)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn enrich_fail(&self, id: i64, error: &str, max_attempts: i32) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE mh_enrich_job SET error = $2, locked_until = NULL, \
               status = CASE WHEN attempts >= $3 THEN 'failed' ELSE 'pending' END, \
               run_after = now() + make_interval(secs => 2 ^ attempts) WHERE id = $1",
        )
        .bind(id)
        .bind(error)
        .bind(max_attempts)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn enrich_status(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<EnrichStatus> {
        let rows: Vec<(String, i64)> = sqlx::query_as("SELECT status, count(*) FROM mh_enrich_job WHERE tenant = $1 AND ($2::text IS NULL OR subject = $2) GROUP BY status")
            .bind(tenant)
            .bind(subject)
            .fetch_all(&self.pool)
            .await?;
        let oldest: Option<f64> = sqlx::query_scalar(
            "SELECT extract(epoch FROM now() - min(enqueued_at))::float8 FROM mh_enrich_job WHERE tenant = $1 AND ($2::text IS NULL OR subject = $2) AND status IN ('pending', 'running')",
        )
        .bind(tenant)
        .bind(subject)
        .fetch_one(&self.pool)
        .await?;
        let mut st = EnrichStatus { oldest_pending_secs: oldest, ..Default::default() };
        for (s, n) in rows {
            match s.as_str() {
                "pending" => st.pending = n,
                "running" => st.running = n,
                "done" => st.done = n,
                _ => st.failed += n,
            }
        }
        Ok(st)
    }

    async fn enrich_outcomes(&self, tenant: &str, subject: &str) -> anyhow::Result<Vec<EnrichOutcome>> {
        let rows: Vec<(serde_json::Value,)> = sqlx::query_as("SELECT outcome FROM mh_enrich_job WHERE tenant = $1 AND subject = $2 AND status = 'done' AND outcome IS NOT NULL")
            .bind(tenant)
            .bind(subject)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.into_iter().filter_map(|(v,)| serde_json::from_value(v).ok()).collect())
    }

    async fn llm_cache_get(&self, key: &str) -> anyhow::Result<Option<String>> {
        Ok(sqlx::query_scalar("SELECT response FROM mh_llm_cache WHERE key = $1").bind(key).fetch_optional(&self.pool).await?)
    }

    async fn llm_cache_put(&self, key: &str, model: &str, text: &str) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_llm_cache (key, model, response) VALUES ($1, $2, $3) ON CONFLICT (key) DO NOTHING")
            .bind(key)
            .bind(model)
            .bind(text)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn export_records(&self, tenant: &str, subject: Option<&str>, after: Option<Uuid>, limit: usize) -> anyhow::Result<Vec<RecordLine>> {
        let rows = sqlx::query(trusted_sql!(
            "SELECT {COLS}, m.content_hash, m.superseded_by, m.updated_at, m.alt_hash, s.record_type, s.attrs, \
               coalesce((SELECT jsonb_agg(jsonb_build_object('path', c.path, 'blob_hash', c.blob_hash) ORDER BY c.path) \
                         FROM mh_code_ref c WHERE c.memory_id = m.id), '[]'::jsonb) AS code_refs \
             FROM mh_memory m LEFT JOIN mh_structured s ON s.memory_id = m.id \
             WHERE m.tenant = $1 AND ($2::text IS NULL OR m.subject = $2) AND ($3::uuid IS NULL OR m.id > $3) \
             ORDER BY m.id LIMIT $4"
        ))
        .bind(tenant)
        .bind(subject)
        .bind(after)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_record).collect()
    }

    async fn export_links(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<Vec<Link>> {
        let rows = sqlx::query(
            "SELECT tenant, subject, linked_subject, link_type, memory_id, created_by, created_at FROM mh_link \
             WHERE tenant = $1 AND ($2::text IS NULL OR subject = $2) ORDER BY subject, linked_subject, link_type",
        )
        .bind(tenant)
        .bind(subject)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_link).collect()
    }

    async fn export_policies(&self) -> anyhow::Result<Vec<PolicyLine>> {
        let rows = sqlx::query("SELECT version, body, created_at FROM mh_policy ORDER BY version").fetch_all(&self.pool).await?;
        rows.iter().map(|r| Ok(PolicyLine { version: r.try_get("version")?, body: r.try_get("body")?, created_at: r.try_get("created_at")? })).collect()
    }

    async fn import_records(&self, rows: &[ImportRow]) -> anyhow::Result<u64> {
        let w: Vec<WriteRow> =
            rows.iter().map(|i| WriteRow { r: &i.record, embedding: i.embedding.as_ref().map(|v| vec_literal(v)), alt: i.alt.as_ref().map(|(_, v)| vec_literal(v)) }).collect();
        Ok(self.write_rows(&w, true).await?.len() as u64)
    }

    async fn policy_put(&self, p: &PolicyLine) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_policy (version, body, created_at) VALUES ($1, $2, $3) ON CONFLICT (version) DO NOTHING")
            .bind(&p.version)
            .bind(&p.body)
            .bind(p.created_at.trunc_subsecs(6))
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn policy_body(&self, version: &str) -> anyhow::Result<Option<serde_json::Value>> {
        Ok(sqlx::query_scalar("SELECT body FROM mh_policy WHERE version = $1").bind(version).fetch_optional(&self.pool).await?)
    }

    async fn policy_propose(
        &self,
        tenant: &str,
        name: &str,
        spec: &serde_json::Value,
        spec_hash: &str,
        by: &str,
        note: Option<&str>,
    ) -> anyhow::Result<memhouse_core::policy::PolicySpecRecord> {
        let sql = trusted_sql!(
            "INSERT INTO mh_policy_spec (tenant, version, name, spec, spec_hash, status, note, proposed_by) \
             SELECT $1, coalesce(max(version), 0) + 1, $2, $3, $4, 'proposed', $5, $6 FROM mh_policy_spec WHERE tenant = $1 \
             RETURNING {SPEC_COLS}"
        );
        let r = sqlx::query(sql).bind(tenant).bind(name).bind(spec).bind(spec_hash).bind(note).bind(by).fetch_one(&self.pool).await?;
        row_to_spec(&r)
    }

    async fn policy_spec(&self, tenant: &str, version: u32) -> anyhow::Result<Option<memhouse_core::policy::PolicySpecRecord>> {
        let sql = trusted_sql!("SELECT {SPEC_COLS} FROM mh_policy_spec WHERE tenant = $1 AND version = $2");
        let r = sqlx::query(sql).bind(tenant).bind(version as i32).fetch_optional(&self.pool).await?;
        r.as_ref().map(row_to_spec).transpose()
    }

    async fn policy_specs(&self, tenant: &str) -> anyhow::Result<Vec<memhouse_core::policy::PolicySpecRecord>> {
        let sql = trusted_sql!("SELECT {SPEC_COLS} FROM mh_policy_spec WHERE tenant = $1 ORDER BY version");
        sqlx::query(sql).bind(tenant).fetch_all(&self.pool).await?.iter().map(row_to_spec).collect()
    }

    async fn policy_approve(&self, tenant: &str, version: u32, approver: &str, compiled: &str) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        let n = sqlx::query("UPDATE mh_policy_spec SET status = 'approved', approved_by = $3, approved_at = now() WHERE tenant = $1 AND version = $2 AND status = 'proposed'")
            .bind(tenant)
            .bind(version as i32)
            .bind(approver)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        if n == 0 {
            return Ok(false);
        }
        sqlx::query("INSERT INTO mh_policy_activation (tenant, version, compiled, action, by_whom) VALUES ($1, $2, $3, 'approve', $4)")
            .bind(tenant)
            .bind(version as i32)
            .bind(compiled)
            .bind(approver)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(true)
    }

    async fn policy_activate(&self, tenant: &str, version: Option<u32>, compiled: &str, action: &str, by: &str) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_policy_activation (tenant, version, compiled, action, by_whom) VALUES ($1, $2, $3, $4, $5)")
            .bind(tenant)
            .bind(version.map(|v| v as i32))
            .bind(compiled)
            .bind(action)
            .bind(by)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn policy_active(&self, tenant: &str) -> anyhow::Result<Option<memhouse_core::policy::PolicySpecRecord>> {
        let sql = trusted_sql!(
            "SELECT {} FROM (SELECT version FROM mh_policy_activation WHERE tenant = $1 ORDER BY id DESC LIMIT 1) a \
             JOIN mh_policy_spec s ON s.tenant = $1 AND s.version = a.version",
            SPEC_COLS.split(", ").map(|c| format!("s.{c}")).collect::<Vec<_>>().join(", ")
        );
        let r = sqlx::query(sql).bind(tenant).fetch_optional(&self.pool).await?;
        r.as_ref().map(row_to_spec).transpose()
    }

    async fn policy_history(&self, tenant: &str, limit: usize) -> anyhow::Result<Vec<memhouse_core::policy::PolicyActivation>> {
        let rows = sqlx::query("SELECT id, tenant, version, compiled, action, by_whom, at FROM mh_policy_activation WHERE tenant = $1 ORDER BY id DESC LIMIT $2")
            .bind(tenant)
            .bind(limit as i64)
            .fetch_all(&self.pool)
            .await?;
        rows.iter()
            .map(|r| {
                let version: Option<i32> = r.try_get("version")?;
                Ok(memhouse_core::policy::PolicyActivation {
                    id: r.try_get("id")?,
                    tenant: r.try_get("tenant")?,
                    version: version.map(|v| v as u32),
                    compiled: r.try_get("compiled")?,
                    action: r.try_get("action")?,
                    by: r.try_get("by_whom")?,
                    at: r.try_get("at")?,
                })
            })
            .collect()
    }

    async fn link_put(&self, l: &Link) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO mh_link (tenant, subject, linked_subject, link_type, memory_id, created_by, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7) \
             ON CONFLICT DO NOTHING",
        )
        .bind(&l.tenant)
        .bind(&l.subject)
        .bind(&l.linked_subject)
        .bind(&l.link_type)
        .bind(l.memory_id)
        .bind(&l.created_by)
        .bind(l.created_at.trunc_subsecs(6))
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn links(&self, tenant: &str, subject: &str) -> anyhow::Result<Vec<Link>> {
        self.export_links(tenant, Some(subject)).await
    }

    #[tracing::instrument(name = "db.request_get", skip_all, fields(db.system = "postgresql", db.operation = "SELECT"))]
    async fn request_get(&self, tenant: &str, key: &str) -> anyhow::Result<Option<(String, serde_json::Value)>> {
        Ok(sqlx::query_as("SELECT request_hash, response FROM mh_request_key WHERE tenant = $1 AND key = $2").bind(tenant).bind(key).fetch_optional(&self.pool).await?)
    }

    #[tracing::instrument(name = "db.request_put", skip_all, fields(db.system = "postgresql", db.operation = "INSERT"))]
    async fn request_put(&self, tenant: &str, key: &str, subject: &str, operation: &str, request_hash: &str, response: &serde_json::Value) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_request_key (tenant, key, subject, operation, request_hash, response) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING")
            .bind(tenant)
            .bind(key)
            .bind(subject)
            .bind(operation)
            .bind(request_hash)
            .bind(response)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn session_extend(&self, tenant: &str, subject: &str, session: &str, until: DateTime<Utc>) -> anyhow::Result<u64> {
        Ok(sqlx::query(
            "UPDATE mh_memory SET expires_at = $4, updated_at = greatest(now(), created_at) WHERE tenant = $1 AND subject = $2 AND scope_session = $3 \
             AND kind = 'working' AND status = 'committed' AND metadata ->> 'ttl' = 'session' AND expires_at < $4 AND expires_at > now()",
        )
        .bind(tenant)
        .bind(subject)
        .bind(session)
        .bind(until)
        .execute(&self.pool)
        .await?
        .rows_affected())
    }

    async fn grant_put(&self, g: &Grant, audit: &memhouse_core::intake::AuditEntry) -> anyhow::Result<()> {
        let kinds: Vec<&str> = g.kinds.iter().map(|k| k.as_str()).collect();
        let mut tx = self.pool.begin().await?;
        sqlx::query("INSERT INTO mh_grant (id, tenant, grantor, grantee, subjects, kinds, created_by, created_at, expires_at, revoked_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)")
            .bind(g.id)
            .bind(&g.tenant)
            .bind(&g.grantor)
            .bind(&g.grantee)
            .bind(&g.subjects)
            .bind(&kinds)
            .bind(&g.created_by)
            .bind(g.created_at)
            .bind(g.expires_at)
            .bind(g.revoked_at)
            .execute(&mut *tx)
            .await?;
        self.audit_in(&mut tx, &g.tenant, audit).await?;
        tx.commit().await?;
        Ok(())
    }

    async fn promotion_merge(
        &self,
        tenant: &str,
        id: Uuid,
        sources: &[Uuid],
        kinds: &[String],
        labels: &[String],
        audit: &memhouse_core::intake::AuditEntry,
    ) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        // The subject's lock first, then the record's row: the order a deletion takes them in.
        let Some(subject): Option<String> =
            sqlx::query_scalar("SELECT subject FROM mh_memory WHERE tenant = $1 AND id = $2").bind(tenant).bind(id).fetch_optional(&mut *tx).await?
        else {
            return Ok(false);
        };
        sqlx::query(SUBJECT_LOCK_SQL).bind(tenant).bind(&subject).execute(&mut *tx).await?;
        // It must (still) be a promotion.
        let row: Option<(serde_json::Value, Vec<String>)> =
            sqlx::query_as("SELECT metadata, labels FROM mh_memory WHERE tenant = $1 AND id = $2 FOR UPDATE").bind(tenant).bind(id).fetch_optional(&mut *tx).await?;
        let Some((mut metadata, mut all_labels)) = row.filter(|(m, _)| m.get("promoted_from").is_some_and(|f| f.is_array())) else { return Ok(false) };
        // As for a new promotion: the sources are locked, so a `forget` of one waits and then
        // finds this record through the link added here.
        let there: i64 = sqlx::query_scalar("SELECT count(*) FROM (SELECT 1 FROM mh_memory WHERE tenant = $1 AND id = ANY($2) FOR SHARE) s")
            .bind(tenant)
            .bind(sources)
            .fetch_one(&mut *tx)
            .await?;
        anyhow::ensure!(there as usize == sources.len(), "a source of a promotion was deleted while it was being written");
        // Sources and their kinds are parallel lists: merged as pairs, a source once.
        let strings = |v: Option<&serde_json::Value>| -> Vec<String> { v.and_then(|a| a.as_array()).into_iter().flatten().filter_map(|x| x.as_str().map(String::from)).collect() };
        let mut from = strings(metadata.get("promoted_from"));
        let mut from_kinds = strings(metadata.get("promoted_from_kinds"));
        from_kinds.resize(from.len(), String::new());
        for (i, source) in sources.iter().enumerate() {
            let source = source.to_string();
            if !from.contains(&source) {
                from.push(source);
                from_kinds.push(kinds.get(i).cloned().unwrap_or_default());
            }
        }
        metadata["promoted_from"] = serde_json::json!(from);
        metadata["promoted_from_kinds"] = serde_json::json!(from_kinds);
        all_labels.extend(labels.iter().cloned());
        all_labels.sort();
        all_labels.dedup();
        sqlx::query("UPDATE mh_memory SET metadata = $3, labels = $4, updated_at = greatest(now(), created_at) WHERE tenant = $1 AND id = $2")
            .bind(tenant)
            .bind(id)
            .bind(&metadata)
            .bind(&all_labels)
            .execute(&mut *tx)
            .await?;
        self.audit_in(&mut tx, tenant, audit).await?;
        tx.commit().await?;
        Ok(true)
    }

    async fn grants(&self, tenant: &str, grantee: Option<&str>) -> anyhow::Result<Vec<Grant>> {
        let rows = sqlx::query(
            "SELECT id, tenant, grantor, grantee, subjects, kinds, created_by, created_at, expires_at, revoked_at FROM mh_grant \
             WHERE tenant = $1 AND ($2::text IS NULL OR (grantee = $2 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now()))) \
             ORDER BY created_at DESC, id DESC LIMIT CASE WHEN $2::text IS NULL THEN 1000 END",
        )
        .bind(tenant)
        .bind(grantee)
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|r| {
                let kinds: Vec<String> = r.try_get("kinds")?;
                Ok(Grant {
                    id: r.try_get("id")?,
                    tenant: r.try_get("tenant")?,
                    grantor: r.try_get("grantor")?,
                    grantee: r.try_get("grantee")?,
                    subjects: r.try_get("subjects")?,
                    kinds: kinds.iter().filter_map(|k| MemoryKind::parse(k)).collect(),
                    created_by: r.try_get("created_by")?,
                    created_at: r.try_get("created_at")?,
                    expires_at: r.try_get("expires_at")?,
                    revoked_at: r.try_get("revoked_at")?,
                })
            })
            .collect()
    }

    async fn grant_revoke(&self, tenant: &str, id: Uuid, audit: &memhouse_core::intake::AuditEntry) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        let n = sqlx::query("UPDATE mh_grant SET revoked_at = now() WHERE tenant = $1 AND id = $2 AND revoked_at IS NULL")
            .bind(tenant)
            .bind(id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        if n == 0 {
            return Ok(false);
        }
        self.audit_in(&mut tx, tenant, audit).await?;
        tx.commit().await?;
        Ok(true)
    }

    async fn expire_due(&self, tenant: &str) -> anyhow::Result<u64> {
        let from: Vec<&str> = MemoryStatus::sources_of(MemoryStatus::Expired).iter().map(|s| s.as_str()).collect();
        Ok(sqlx::query("UPDATE mh_memory SET status = 'expired', updated_at = greatest(now(), created_at) WHERE tenant = $1 AND expires_at <= now() AND status = ANY($2)")
            .bind(tenant)
            .bind(&from)
            .execute(&self.pool)
            .await?
            .rows_affected())
    }

    async fn structured_query(&self, tenant: &str, subject: &str, record_type: &str, attrs: &serde_json::Value) -> anyhow::Result<Vec<(Uuid, serde_json::Value)>> {
        Ok(sqlx::query_as(
            "SELECT s.memory_id, s.attrs FROM mh_structured s JOIN mh_memory m ON m.id = s.memory_id \
             WHERE s.tenant = $1 AND s.subject = $2 AND s.record_type = $3 AND s.attrs @> $4 AND m.status = 'committed' ORDER BY s.memory_id",
        )
        .bind(tenant)
        .bind(subject)
        .bind(record_type)
        .bind(attrs)
        .fetch_all(&self.pool)
        .await?)
    }

    async fn stale_code_refs(&self, tenant: &str, subject: &str, path: &str, blob_hash: &str) -> anyhow::Result<Vec<Uuid>> {
        Ok(sqlx::query_scalar(
            "SELECT c.memory_id FROM mh_code_ref c JOIN mh_memory m ON m.id = c.memory_id \
             WHERE c.tenant = $1 AND c.subject = $2 AND c.path = $3 AND c.blob_hash <> $4 AND m.status = 'committed' ORDER BY c.memory_id",
        )
        .bind(tenant)
        .bind(subject)
        .bind(path)
        .bind(blob_hash)
        .fetch_all(&self.pool)
        .await?)
    }

    async fn embedding_identity(&self) -> anyhow::Result<(Option<EmbeddingIdentity>, Option<EmbeddingIdentity>)> {
        Ok((self.identity_of("").await?, self.identity_of("reembed_target_").await?))
    }

    async fn reembed_estimate(&self) -> anyhow::Result<ReembedEstimate> {
        let (records, second_vectors, characters): (i64, i64, i64) =
            sqlx::query_as("SELECT count(*), count(alt_hash), coalesce(sum(length(content)), 0)::bigint FROM mh_memory WHERE embedding IS NOT NULL").fetch_one(&self.pool).await?;
        let done: i64 = if self.has_next_columns().await? && self.meta("reembed_target_embedder").await?.is_some() {
            sqlx::query_scalar("SELECT count(*) FROM mh_memory WHERE embedding IS NOT NULL AND embedding_next IS NOT NULL").fetch_one(&self.pool).await?
        } else {
            0
        };
        Ok(ReembedEstimate { records: records as u64, second_vectors: second_vectors as u64, characters: characters as u64, done: done as u64 })
    }

    async fn reembed_begin(&self, target: &EmbeddingIdentity) -> anyhow::Result<()> {
        let version: u32 = self.meta("schema_version").await?.unwrap_or_default().parse().unwrap_or(0);
        anyhow::ensure!(
            version == SCHEMA_VERSION,
            "the database is at schema version {version}; start MemHouse once with the previous [embedding] settings to upgrade it to {SCHEMA_VERSION}, then re-embed"
        );
        match self.identity_of("reembed_target_").await? {
            Some(t) if t == *target => return Ok(()),
            Some(t) => anyhow::bail!("an unfinished re-embedding to {t} exists; abort it first"),
            None => {}
        }
        let mut tx = self.pool.begin().await?;
        // Leftovers of a run that crashed before recording its target.
        sqlx::query(sqlx::AssertSqlSafe(drop_next_columns())).execute(&mut *tx).await?;
        let dim = target.dim;
        sqlx::query(trusted_sql!(
            "ALTER TABLE mh_memory ADD COLUMN embedding_next vector({dim}), ADD COLUMN embedding_alt_next vector({dim}), \
             ADD COLUMN alt_hash_next text, ADD COLUMN embedder_next text, ADD COLUMN embedder_config_next text"
        ))
        .execute(&mut *tx)
        .await?;
        for (k, v) in [
            ("reembed_target_embedder", target.embedder.clone()),
            ("reembed_target_embedding_dim", dim.to_string()),
            ("reembed_target_passage_prefix", target.passage_prefix.clone()),
        ] {
            sqlx::query("INSERT INTO mh_meta(key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value").bind(k).bind(v).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn reembed_pending(&self, after: Option<Uuid>, limit: usize) -> anyhow::Result<Vec<ReembedRow>> {
        let rows = sqlx::query(
            "SELECT id, content, alt_hash FROM mh_memory WHERE embedding IS NOT NULL AND embedding_next IS NULL \
             AND ($1::uuid IS NULL OR id > $1) ORDER BY id LIMIT $2",
        )
        .bind(after)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(|r| Ok(ReembedRow { id: r.try_get("id")?, content: r.try_get("content")?, alt_hash: r.try_get("alt_hash")? })).collect()
    }

    async fn reembed_write(&self, target: &EmbeddingIdentity, rows: &[ReembedVectors]) -> anyhow::Result<()> {
        if rows.iter().any(|r| r.embedding.len() != target.dim || r.alt.as_ref().is_some_and(|(_, v)| v.len() != target.dim)) {
            anyhow::bail!("re-embedding produced vectors that are not {}-dimensional", target.dim);
        }
        let ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
        let emb: Vec<String> = rows.iter().map(|r| vec_literal(&r.embedding)).collect();
        let alt: Vec<Option<String>> = rows.iter().map(|r| r.alt.as_ref().map(|(_, v)| vec_literal(v))).collect();
        let hash: Vec<Option<String>> = rows.iter().map(|r| r.alt.as_ref().map(|(h, _)| h.clone())).collect();
        sqlx::query(
            "UPDATE mh_memory m SET embedding_next = u.e::vector, embedding_alt_next = u.a::vector, alt_hash_next = u.h, embedder_next = $5, embedder_config_next = $6 \
             FROM unnest($1::uuid[], $2::text[], $3::text[], $4::text[]) AS u(id, e, a, h) WHERE m.id = u.id",
        )
        .bind(&ids)
        .bind(&emb)
        .bind(&alt)
        .bind(&hash)
        .bind(&target.embedder)
        .bind(target.config_hash())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn reembed_cutover(&self, target: &EmbeddingIdentity) -> anyhow::Result<Option<u64>> {
        let mut tx = self.pool.begin().await?;
        // Blocks writers (and other re-embedders) but not readers, until commit.
        sqlx::query("LOCK TABLE mh_memory IN SHARE ROW EXCLUSIVE MODE").execute(&mut *tx).await?;
        let recorded: Option<String> = sqlx::query_scalar("SELECT value FROM mh_meta WHERE key = 'reembed_target_embedder'").fetch_optional(&mut *tx).await?;
        anyhow::ensure!(recorded.as_deref() == Some(target.embedder.as_str()), "no re-embedding to {} is in progress", target.embedder);
        let pending: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory WHERE embedding IS NOT NULL AND embedding_next IS NULL").fetch_one(&mut *tx).await?;
        if pending > 0 {
            tx.rollback().await?;
            return Ok(Some(pending as u64));
        }
        let old: Option<String> = sqlx::query_scalar("SELECT value FROM mh_meta WHERE key = 'embedder'").fetch_optional(&mut *tx).await?;
        let drops: Vec<String> = NEXT_COLS.iter().map(|(_, cur)| format!("DROP COLUMN {cur}")).collect();
        sqlx::query(trusted_sql!("ALTER TABLE mh_memory {}", drops.join(", "))).execute(&mut *tx).await?;
        for (next, cur) in NEXT_COLS {
            sqlx::query(trusted_sql!("ALTER TABLE mh_memory RENAME COLUMN {next} TO {cur}")).execute(&mut *tx).await?;
        }
        for (k, v) in [("embedder", target.embedder.clone()), ("embedding_dim", target.dim.to_string()), ("passage_prefix", target.passage_prefix.clone())] {
            sqlx::query("INSERT INTO mh_meta(key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value").bind(k).bind(v).execute(&mut *tx).await?;
        }
        sqlx::query("DELETE FROM mh_meta WHERE key LIKE 'reembed_target_%'").execute(&mut *tx).await?;
        // The old model's cached vectors are copies of content under a model no longer used; they
        // go, so deletions never have to chase them (TR-WF-01).
        if let Some(old) = old {
            sqlx::query("DELETE FROM mh_embed_cache WHERE model = $1").bind(old).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(None)
    }

    async fn reembed_abort(&self) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        sqlx::query(sqlx::AssertSqlSafe(drop_next_columns())).execute(&mut *tx).await?;
        let removed = sqlx::query("DELETE FROM mh_meta WHERE key LIKE 'reembed_target_%'").execute(&mut *tx).await?.rows_affected();
        tx.commit().await?;
        Ok(removed > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn or_query_is_safe() {
        assert_eq!(or_query("What's my dog's name? (it's & | !)"), "dog | it | my | name | what");
        assert_eq!(or_query("!!!"), "");
    }
}
