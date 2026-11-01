//! Postgres store adapter: pgvector for exact per-subject vector scoring, built-in full-text search
//! for keywords, hybrid fusion in a single SQL statement (TR-RQ), hash-chained audit, deletion ledger.

use async_trait::async_trait;
use chrono::{DateTime, SubsecRound, Utc};
use memhouse_core::types::*;
use memhouse_core::Store;
use sha2::{Digest, Sha256};
use sqlx::postgres::{PgPool, PgPoolOptions, PgRow};
use sqlx::Row;
use uuid::Uuid;

pub const SCHEMA_VERSION: &str = "1";

#[derive(Clone)]
pub struct PgStore {
    pub pool: PgPool,
    /// Prefix the engine adds to passages before embedding; needed to purge cache entries on deletion.
    passage_prefix: String,
}

const COLS: &str = "m.id, m.tenant, m.subject, m.kind, m.status, m.content, m.session_id, m.turn_ref, \
    m.occurred_at, m.valid_from, m.valid_to, m.supersedes, m.labels, m.tags, m.source, m.confidence, \
    m.metadata, m.created_at";

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
    let mut terms: Vec<String> = text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.chars().count() >= 2)
        .map(|w| w.to_lowercase())
        .collect();
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
        kind: MemoryKind::parse(&kind).unwrap_or(MemoryKind::Semantic),
        status: MemoryStatus::parse(&status),
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
    })
}

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
        Ok(PgStore { pool, passage_prefix: passage_prefix.to_string() })
    }

    pub async fn meta(&self, key: &str) -> anyhow::Result<Option<String>> {
        let exists: bool = sqlx::query_scalar("SELECT to_regclass('mh_meta') IS NOT NULL").fetch_one(&self.pool).await?;
        if !exists {
            return Ok(None);
        }
        Ok(sqlx::query_scalar("SELECT value FROM mh_meta WHERE key = $1").bind(key).fetch_optional(&self.pool).await?)
    }
}

pub fn redact_url(url: &str) -> String {
    match (url.find("://"), url.rfind('@')) {
        (Some(s), Some(at)) if at > s => format!("{}://***@{}", &url[..s], &url[at + 1..]),
        _ => url.to_string(),
    }
}

#[async_trait]
impl Store for PgStore {
    async fn migrate(&self, dim: usize, embedder_id: &str) -> anyhow::Result<()> {
        if let Some(existing) = self.meta("embedding_dim").await? {
            if existing != dim.to_string() {
                anyhow::bail!(
                    "this database stores {existing}-dimensional embeddings but the configured model produces {dim}. \
                     Use the model it was created with, or a new database (re-embedding is not automatic yet)."
                );
            }
        }
        let ddl = format!(
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
"#
        );
        sqlx::raw_sql(&ddl).execute(&self.pool).await?;
        for (k, v) in [("schema_version", SCHEMA_VERSION.to_string()), ("embedding_dim", dim.to_string()), ("embedder", embedder_id.to_string())] {
            sqlx::query("INSERT INTO mh_meta(key, value) VALUES ($1, $2) ON CONFLICT (key) DO NOTHING")
                .bind(k)
                .bind(v)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    async fn insert(&self, records: &[NewMemory]) -> anyhow::Result<()> {
        if records.is_empty() {
            return Ok(());
        }
        let mut tx = self.pool.begin().await?;
        for chunk in records.chunks(500) {
            let mut qb = sqlx::QueryBuilder::new(
                "INSERT INTO mh_memory (id, tenant, subject, kind, status, content, content_hash, embedding, embedding_alt, alt_hash, embedder, \
                 session_id, turn_ref, occurred_at, valid_from, valid_to, supersedes, labels, tags, source, confidence, metadata, created_at) ",
            );
            qb.push_values(chunk, |mut b, r| {
                let m = &r.memory;
                b.push_bind(m.id)
                    .push_bind(&m.tenant)
                    .push_bind(&m.subject)
                    .push_bind(m.kind.as_str())
                    .push_bind(m.status.as_str())
                    .push_bind(&m.content)
                    .push_bind(&r.content_hash)
                    .push_bind(r.embedding.as_ref().map(|v| vec_literal(v)))
                    .push_unseparated("::vector")
                    .push_bind(r.alt.as_ref().map(|(_, v)| vec_literal(v)))
                    .push_unseparated("::vector")
                    .push_bind(r.alt.as_ref().map(|(h, _)| h.clone()))
                    .push_bind(Option::<String>::None)
                    .push_bind(&m.session_id)
                    .push_bind(&m.turn_ref)
                    .push_bind(m.occurred_at)
                    .push_bind(m.valid_from)
                    .push_bind(m.valid_to)
                    .push_bind(m.supersedes)
                    .push_bind(&m.labels)
                    .push_bind(&m.tags)
                    .push_bind(&m.source)
                    .push_bind(m.confidence)
                    .push_bind(&m.metadata)
                    .push_bind(m.created_at);
            });
            qb.build().execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn search(&self, q: &SearchQuery) -> anyhow::Result<Vec<Hit>> {
        let use_kw = q.mode != RetrievalMode::Dense;
        let use_vec = q.mode != RetrievalMode::Keyword && q.embedding.is_some();
        let tsq = if use_kw { or_query(&q.text) } else { String::new() };
        let kinds: Option<Vec<String>> = q.kinds.as_ref().map(|ks| ks.iter().map(|k| k.as_str().to_string()).collect());
        let sql = format!(
            r#"
WITH q AS (
  SELECT CASE WHEN $3 = '' THEN NULL ELSE to_tsquery('english', $3) END AS tsq
),
base AS (
  SELECT m.id, m.tsv, m.embedding, m.embedding_alt
  FROM mh_memory m
  WHERE m.tenant = $1 AND m.subject = $2 AND m.status = 'committed'
    AND ($4::text[] IS NULL OR m.kind = ANY($4))
    AND ($5::text[] IS NULL OR m.tags && $5)
    AND NOT (m.labels && $6::text[])
    AND m.valid_from <= $16 AND (m.valid_to IS NULL OR m.valid_to > $16)
    AND ($7::timestamptz IS NULL OR m.occurred_at IS NULL OR m.occurred_at <= $7)
    AND (cardinality($18::timestamptz[]) = 0 OR EXISTS (
      SELECT 1 FROM unnest($18::timestamptz[], $19::timestamptz[]) w(s, e)
      WHERE m.occurred_at >= w.s AND m.occurred_at < w.e))
),
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
)
SELECT {COLS}, f.score, f.krk, f.vrk, f.sim
FROM fused f JOIN mh_memory m ON m.id = f.id
ORDER BY f.score DESC, f.sim DESC NULLS LAST
LIMIT $15
"#
        );
        let rows = sqlx::query(&sql)
            .bind(&q.tenant)
            .bind(&q.subject)
            .bind(&tsq)
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
            .fetch_all(&self.pool)
            .await?;
        rows.iter()
            .map(|r| {
                Ok(Hit {
                    memory: row_to_memory(r)?,
                    score: r.try_get::<f64, _>("score")? as f32,
                    keyword_rank: r.try_get("krk")?,
                    vector_rank: r.try_get("vrk")?,
                    similarity: r.try_get::<Option<f64>, _>("sim")?.map(|s| s as f32),
                    rerank_score: None,
                })
            })
            .collect()
    }

    async fn get(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<Memory>> {
        let row = sqlx::query(&format!("SELECT {COLS} FROM mh_memory m WHERE m.tenant = $1 AND m.id = $2"))
            .bind(tenant)
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|r| row_to_memory(&r)).transpose()
    }

    async fn list(&self, q: &ListQuery) -> anyhow::Result<Vec<Memory>> {
        let kinds: Option<Vec<String>> = q.kinds.as_ref().map(|ks| ks.iter().map(|k| k.as_str().to_string()).collect());
        let rows = sqlx::query(&format!(
            "SELECT {COLS} FROM mh_memory m WHERE m.tenant = $1 AND ($2::text IS NULL OR m.subject = $2) \
             AND ($3::text[] IS NULL OR m.kind = ANY($3)) AND ($4 OR m.status = 'committed') \
             ORDER BY m.created_at DESC, m.id DESC LIMIT $5 OFFSET $6"
        ))
        .bind(&q.tenant)
        .bind(&q.subject)
        .bind(kinds)
        .bind(q.include_inactive)
        .bind(q.limit as i64)
        .bind(q.offset as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(row_to_memory).collect()
    }

    async fn find_by_hash(&self, tenant: &str, subject: &str, hash: &str) -> anyhow::Result<Option<Uuid>> {
        Ok(sqlx::query_scalar(
            "SELECT id FROM mh_memory WHERE tenant = $1 AND subject = $2 AND content_hash = $3 AND status <> 'superseded' LIMIT 1",
        )
        .bind(tenant)
        .bind(subject)
        .bind(hash)
        .fetch_optional(&self.pool)
        .await?)
    }

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

    async fn set_superseded(&self, tenant: &str, id: Uuid, by: Uuid) -> anyhow::Result<bool> {
        let r = sqlx::query(
            "UPDATE mh_memory SET status = 'superseded', superseded_by = $3, valid_to = COALESCE(valid_to, now()), updated_at = now() \
             WHERE tenant = $1 AND id = $2 AND status <> 'superseded'",
        )
        .bind(tenant)
        .bind(id)
        .bind(by)
        .execute(&self.pool)
        .await?;
        Ok(r.rows_affected() > 0)
    }

    async fn set_status(&self, tenant: &str, id: Uuid, status: MemoryStatus) -> anyhow::Result<bool> {
        let r = sqlx::query("UPDATE mh_memory SET status = $3, updated_at = now() WHERE tenant = $1 AND id = $2")
            .bind(tenant)
            .bind(id)
            .bind(status.as_str())
            .execute(&self.pool)
            .await?;
        Ok(r.rows_affected() > 0)
    }

    async fn delete(&self, tenant: &str, id: Uuid, actor: &str) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query("DELETE FROM mh_memory WHERE tenant = $1 AND id = $2 RETURNING subject, content, alt_hash")
            .bind(tenant)
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
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
        // Facts derived from this record go with it, with their cached vectors, and so does the
        // cached extraction of every session job that read it.
        sqlx::query(
            "WITH d AS (DELETE FROM mh_memory WHERE tenant = $1 AND metadata -> 'source_ids' ? $2 RETURNING content) \
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

    async fn delete_subject(&self, tenant: &str, subject: &str, actor: &str, purge_cache: bool) -> anyhow::Result<u64> {
        let mut tx = self.pool.begin().await?;
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
        let n = sqlx::query("DELETE FROM mh_memory WHERE tenant = $1 AND subject = $2")
            .bind(tenant)
            .bind(subject)
            .execute(&mut *tx)
            .await?
            .rows_affected();
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
            sqlx::query("DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2")
                .bind(tenant)
                .bind(subject)
                .execute(&mut *tx)
                .await?;
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

    async fn purge_episodic_older_than(&self, tenant: &str, days: u32) -> anyhow::Result<u64> {
        // Same cascade as `delete`, in batches so a large purge never holds one huge transaction:
        // the rounds, their cached vectors, facts derived from them (and their vectors), the jobs
        // that read them (and their cached extractions), and a ledger row per round.
        let mut total = 0u64;
        loop {
            let mut tx = self.pool.begin().await?;
            let rows = sqlx::query(
                "DELETE FROM mh_memory WHERE id IN (SELECT id FROM mh_memory WHERE tenant = $1 AND kind = 'episodic' \
                 AND created_at < now() - make_interval(days => $2) LIMIT 1000) RETURNING id, subject, content, alt_hash",
            )
            .bind(tenant)
            .bind(days as i32)
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

    async fn embed_cache_get(&self, model: &str, hashes: &[String]) -> anyhow::Result<Vec<(String, Vec<f32>)>> {
        if hashes.is_empty() {
            return Ok(vec![]);
        }
        let rows = sqlx::query("SELECT hash, embedding FROM mh_embed_cache WHERE model = $1 AND hash = ANY($2)")
            .bind(model)
            .bind(hashes)
            .fetch_all(&self.pool)
            .await?;
        rows.iter().map(|r| Ok((r.try_get("hash")?, r.try_get("embedding")?))).collect()
    }

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

    async fn audit(&self, actor: &str, action: &str, tenant: &str, subject: Option<&str>, memory_id: Option<Uuid>, detail: serde_json::Value) -> anyhow::Result<()> {
        let detail = detail.to_string();
        let at = Utc::now().trunc_subsecs(6);
        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT pg_advisory_xact_lock(7270001)").execute(&mut *tx).await?;
        let prev: Option<String> = sqlx::query_scalar("SELECT hash FROM mh_audit ORDER BY id DESC LIMIT 1")
            .fetch_optional(&mut *tx)
            .await?;
        let prev = prev.unwrap_or_else(|| "genesis".into());
        let hash = audit_hash(&prev, &at, actor, action, tenant, subject, memory_id, &detail);
        sqlx::query(
            "INSERT INTO mh_audit (at, actor, action, tenant, subject, memory_id, detail, prev_hash, hash) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        )
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
        let rows = sqlx::query("SELECT * FROM mh_audit WHERE tenant = $1 ORDER BY id DESC LIMIT $2")
            .bind(tenant)
            .bind(limit as i64)
            .fetch_all(&self.pool)
            .await?;
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
        Ok(sqlx::query_as(
            "SELECT subject, count(*) FROM mh_memory WHERE tenant = $1 AND status = 'committed' GROUP BY subject ORDER BY max(created_at) DESC LIMIT $2",
        )
        .bind(tenant)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?)
    }

    async fn get_many(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<Memory>> {
        let rows = sqlx::query(&format!("SELECT {COLS} FROM mh_memory m WHERE m.tenant = $1 AND m.id = ANY($2)"))
            .bind(tenant)
            .bind(ids)
            .fetch_all(&self.pool)
            .await?;
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
             WHERE j.id IN (SELECT id FROM mh_enrich_job \
               WHERE (status = 'pending' AND run_after <= now()) OR (status = 'running' AND locked_until < now()) \
               ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED) \
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
        let rows: Vec<(String, i64)> = sqlx::query_as(
            "SELECT status, count(*) FROM mh_enrich_job WHERE tenant = $1 AND ($2::text IS NULL OR subject = $2) GROUP BY status",
        )
        .bind(tenant)
        .bind(subject)
        .fetch_all(&self.pool)
        .await?;
        let mut st = EnrichStatus::default();
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
        let rows: Vec<(serde_json::Value,)> =
            sqlx::query_as("SELECT outcome FROM mh_enrich_job WHERE tenant = $1 AND subject = $2 AND status = 'done' AND outcome IS NOT NULL")
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
