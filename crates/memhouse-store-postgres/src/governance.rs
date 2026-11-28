// SPDX-License-Identifier: Apache-2.0
//! Governance II on Postgres (G22, schema v12): legal holds, the deletion workflow's requests,
//! durable job runs, retention by rule with partition-drop for monthly episodic partitions
//! (TR-DB-04), row-level security as a second line (TR-DB-03), the audit head and the deletion
//! ledger as it is exported and re-applied (TR-WF-03).
//!
//! Statements are built from this file's constants, column names of `ScopeLevel::column` and
//! numbers; every value from a caller is bound.

use crate::{PgStore, SUBJECT_LOCK_SQL};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use memhouse_core::governance::{
    AuditHead, Canary, CanaryReport, DeletionRequest, DeletionStatus, JobRun, LedgerEntry, LegalHold, PurgeAge, PurgeOutcome, PurgeSpec, Reapplied, ScopeMatch, HELD_SQL,
};
use memhouse_core::intake::AuditEntry;
use memhouse_core::types::*;
use sqlx::{PgConnection, Row};
use std::collections::{BTreeMap, HashSet};
use uuid::Uuid;

/// Schema v12 (G22). Expand-only: three new tables and one nullable column on `mh_memory`;
/// nothing a version 11 build reads is changed (it still refuses to open the upgraded
/// database, by its stored version). `epart` is the month of an episodic
/// record, set by this build only on a database whose memory table is partitioned by it.
pub(crate) const SCHEMA_V12_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS mh_legal_hold (
  id          uuid PRIMARY KEY,
  tenant      text NOT NULL,
  target_kind text NOT NULL CHECK (target_kind IN ('subject', 'user', 'agent', 'source', 'org', 'team', 'session', 'tenant')),
  target      text NOT NULL,
  reason      text NOT NULL,
  placed_by   text NOT NULL,
  placed_at   timestamptz NOT NULL,
  released_by text,
  released_at timestamptz
);
CREATE INDEX IF NOT EXISTS mh_legal_hold_active_idx ON mh_legal_hold (tenant) WHERE released_at IS NULL;

-- The deletion workflow (TR-WF-01): one row per forget, from the request to its certificate.
-- Identifiers, counts and hashes only.
CREATE TABLE IF NOT EXISTS mh_deletion_request (
  id           uuid PRIMARY KEY,
  tenant       text NOT NULL,
  scope        text NOT NULL,
  value        text NOT NULL,
  actor        text NOT NULL,
  requested_at timestamptz NOT NULL,
  status       text NOT NULL CHECK (status IN ('running', 'held', 'completed')),
  completed_at timestamptz,
  deleted      bigint NOT NULL DEFAULT 0,
  held         bigint NOT NULL DEFAULT 0,
  executions   int NOT NULL DEFAULT 0,
  canaries     jsonb NOT NULL DEFAULT '[]',
  certificate  jsonb
);
CREATE INDEX IF NOT EXISTS mh_deletion_request_open_idx ON mh_deletion_request (tenant, status) WHERE status <> 'completed';
CREATE INDEX IF NOT EXISTS mh_deletion_request_tenant_idx ON mh_deletion_request (tenant, requested_at DESC);

-- Durable job runs (TR-WF-02): at most one unfinished run per tenant and job.
CREATE TABLE IF NOT EXISTS mh_job_run (
  id          uuid PRIMARY KEY,
  tenant      text NOT NULL,
  job         text NOT NULL,
  state       jsonb NOT NULL DEFAULT '{}',
  started_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS mh_job_run_open_idx ON mh_job_run (tenant, job) WHERE finished_at IS NULL;

ALTER TABLE mh_memory ADD COLUMN IF NOT EXISTS epart date;
"#;

/// The row triggers of the memory table. Run again after the table is converted to a
/// partitioned one: a trigger of the parent is cloned onto every partition.
const MEMORY_TRIGGERS_DDL: &str = r#"
CREATE OR REPLACE TRIGGER mh_memory_embedder_guard BEFORE INSERT ON mh_memory FOR EACH ROW EXECUTE FUNCTION mh_memory_embedder_guard();
CREATE OR REPLACE TRIGGER mh_memory_tsv_lang BEFORE INSERT OR UPDATE OF content, ts_config ON mh_memory
  FOR EACH ROW WHEN (NEW.ts_config IS NOT NULL) EXECUTE FUNCTION mh_memory_tsv_lang();
-- A partitioned table has no key other tables can reference, so what the foreign keys with
-- ON DELETE CASCADE did is done here: a record's structured form, code references and links
-- go with it.
CREATE OR REPLACE FUNCTION mh_memory_children() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM mh_structured WHERE memory_id = OLD.id;
  DELETE FROM mh_code_ref WHERE memory_id = OLD.id;
  DELETE FROM mh_link WHERE memory_id = OLD.id;
  RETURN OLD;
END $$;
CREATE OR REPLACE TRIGGER mh_memory_children AFTER DELETE ON mh_memory FOR EACH ROW EXECUTE FUNCTION mh_memory_children();
"#;

/// Convert the plain memory table into one partitioned by `epart` (TR-DB-04), in place: the
/// table as it is becomes the partition of rows without a month (every record written so far,
/// and every record that is not episodic), so no row is moved or rewritten. Episodic records
/// written from now on go to a partition of their month.
const PARTITION_DDL: &str = r#"
DO $$
DECLARE r record; d text; defs text[] := '{}';
BEGIN
  LOCK TABLE mh_memory IN ACCESS EXCLUSIVE MODE;
  FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint WHERE confrelid = 'mh_memory'::regclass AND contype = 'f' LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.t, r.conname);
  END LOOP;
  FOR r IN SELECT c.relname AS name, pg_get_indexdef(i.indexrelid) AS def, i.indisprimary AS pk
             FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'mh_memory'::regclass LOOP
    EXECUTE format('ALTER INDEX %I RENAME TO %I', r.name, replace(r.name, 'mh_memory_', 'mh_memory_rest_'));
    IF NOT r.pk THEN defs := defs || r.def; END IF;
  END LOOP;
  DROP TRIGGER IF EXISTS mh_memory_embedder_guard ON mh_memory;
  DROP TRIGGER IF EXISTS mh_memory_tsv_lang ON mh_memory;
  ALTER TABLE mh_memory RENAME TO mh_memory_rest;
  -- Proves to ATTACH that every row belongs to the partition of rows without a month.
  ALTER TABLE mh_memory_rest ADD CONSTRAINT mh_memory_rest_epart CHECK (epart IS NULL);
  CREATE TABLE mh_memory (LIKE mh_memory_rest INCLUDING DEFAULTS INCLUDING GENERATED INCLUDING STORAGE) PARTITION BY LIST (epart);
  ALTER TABLE mh_memory ATTACH PARTITION mh_memory_rest FOR VALUES IN (NULL);
  -- The indexes again, on the parent: each takes the table's own index as its part.
  FOREACH d IN ARRAY defs LOOP
    EXECUTE d;
  END LOOP;
END $$;
"#;

/// The tables row-level security covers (TR-DB-03): every table that holds memory content or
/// what is derived from it, by tenant and subject.
pub(crate) const RLS_TABLES: [&str; 8] = ["mh_memory", "mh_structured", "mh_code_ref", "mh_link", "mh_recall", "mh_intake", "mh_request_key", "mh_enrich_job"];
/// Content-addressed caches: no tenant to key on, so only the service reads them.
pub(crate) const RLS_SERVICE_TABLES: [&str; 2] = ["mh_embed_cache", "mh_llm_cache"];

/// What a pooled connection is set to between uses: the service's own scope, in which the
/// statements' own tenant and subject filters are the only line.
pub(crate) const RLS_RESET_SQL: &str = "SELECT set_config('memhouse.scope', 'service', false), set_config('memhouse.tenant', '', false), set_config('memhouse.subject', '', false)";

/// The policy expression of a table with `tenant` and `subject` columns: a row is visible to a
/// session narrowed to its tenant (and, if the session names one, its subject), or to the
/// service scope, which only the role that owns the tables can take. Each setting is read in
/// a scalar subquery, so it is evaluated once per statement, not once per row, and the tenant
/// comparison can still use an index.
const RLS_USING: &str = "((tenant = (SELECT current_setting('memhouse.tenant', true)) \
       AND ((SELECT coalesce(current_setting('memhouse.subject', true), '')) = '' OR subject = (SELECT current_setting('memhouse.subject', true)))) \
     OR ((SELECT current_setting('memhouse.scope', true)) = 'service' AND (SELECT mh_rls_service())))";
const RLS_SERVICE_USING: &str = "((SELECT current_setting('memhouse.scope', true)) = 'service' AND (SELECT mh_rls_service()))";
/// Changed whenever the policies or `mh_rls_service` change: a database whose marker differs
/// has them installed again at the next start.
const RLS_VERSION: &str = "1";

/// Taken shared by every transaction that deletes with regard to legal holds, and exclusive
/// by the placement of a hold (`$1` is the tenant): a hold is either committed before a
/// deletion reads the holds, or placed after the deletion has committed, never in between.
/// Taken shared by a write of a recall explanation and exclusively by the last step of a
/// tenant erasure, which removes the tenant's explanations.
pub(crate) const TENANT_ERASE_SHARED: &str = "SELECT pg_advisory_xact_lock_shared(7270006, hashtext($1))";
pub(crate) const TENANT_ERASE_EXCLUSIVE: &str = "SELECT pg_advisory_xact_lock(7270006, hashtext($1))";
pub(crate) const HOLD_GUARD_SHARED: &str = "SELECT pg_advisory_xact_lock_shared(7270005, hashtext($1))";
const HOLD_GUARD_EXCLUSIVE: &str = "SELECT pg_advisory_xact_lock(7270005, hashtext($1))";

/// What `delete_in` removed.
pub(crate) struct Deleted {
    pub subject: String,
    /// The ids that went: the record, if it was still there, and its dependents.
    pub ids: Vec<Uuid>,
    /// A dependent stayed because a legal hold matches it.
    pub kept_held: bool,
}

fn month_of(t: DateTime<Utc>) -> NaiveDate {
    NaiveDate::from_ymd_opt(t.year(), t.month(), 1).expect("the first of a month")
}

fn partition_name(month: NaiveDate) -> String {
    format!("mh_memory_e{:04}{:02}", month.year(), month.month())
}

/// The month a partition holds, from its name.
fn partition_month(name: &str) -> Option<NaiveDate> {
    let ym = name.strip_prefix("mh_memory_e")?;
    if ym.len() != 6 || !ym.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    NaiveDate::from_ymd_opt(ym[..4].parse().ok()?, ym[4..].parse().ok()?, 1)
}

fn next_month(m: NaiveDate) -> NaiveDate {
    if m.month() == 12 { NaiveDate::from_ymd_opt(m.year() + 1, 1, 1) } else { NaiveDate::from_ymd_opt(m.year(), m.month() + 1, 1) }.expect("the first of a month")
}

/// The rule of a purge as SQL over the alias `m`, with its values: `$1` is the tenant, `$2`
/// the kind, `$3` the days; scope values follow from `$4`.
fn purge_filter(spec: &PurgeSpec) -> (String, Vec<String>) {
    let mut sql = match spec.age {
        PurgeAge::OlderThanDays(_) => "m.created_at < now() - make_interval(days => $3)".to_string(),
        PurgeAge::Expired => "m.expires_at IS NOT NULL AND m.expires_at < now() AND $3 >= 0".to_string(),
    };
    let mut values = vec![];
    if let Some(ScopeMatch { level, value }) = &spec.scope {
        values.push(value.clone());
        sql.push_str(&format!(" AND m.{} = ${}", level.column(), values.len() + 3));
    }
    for ScopeMatch { level, value } in &spec.except {
        values.push(value.clone());
        sql.push_str(&format!(" AND (m.{col} IS NULL OR m.{col} <> ${n})", col = level.column(), n = values.len() + 3));
    }
    (sql, values)
}

/// The most days a rule's age is taken as: about 2,700 years, older than any record, and small
/// enough for the database's and this process's time arithmetic. A larger number means the
/// same thing (nothing is that old) and must not wrap into a cutoff in the future.
const MAX_AGE_DAYS: u32 = 1_000_000;

fn days_of(spec: &PurgeSpec) -> i32 {
    match spec.age {
        PurgeAge::OlderThanDays(d) => d.min(MAX_AGE_DAYS) as i32,
        PurgeAge::Expired => 0,
    }
}

fn hold_of(r: &sqlx::postgres::PgRow) -> anyhow::Result<LegalHold> {
    Ok(LegalHold {
        id: r.try_get("id")?,
        tenant: r.try_get("tenant")?,
        target_kind: r.try_get("target_kind")?,
        target: r.try_get("target")?,
        reason: r.try_get("reason")?,
        placed_by: r.try_get("placed_by")?,
        placed_at: r.try_get("placed_at")?,
        released_by: r.try_get("released_by")?,
        released_at: r.try_get("released_at")?,
    })
}

fn deletion_of(r: &sqlx::postgres::PgRow) -> anyhow::Result<DeletionRequest> {
    let scope: String = r.try_get("scope")?;
    let status: String = r.try_get("status")?;
    let certificate: Option<serde_json::Value> = r.try_get("certificate")?;
    Ok(DeletionRequest {
        id: r.try_get("id")?,
        tenant: r.try_get("tenant")?,
        scope: serde_json::from_value(serde_json::Value::String(scope))?,
        value: r.try_get("value")?,
        actor: r.try_get("actor")?,
        requested_at: r.try_get("requested_at")?,
        status: DeletionStatus::parse(&status).ok_or_else(|| anyhow::anyhow!("unknown deletion status '{status}' in the database"))?,
        completed_at: r.try_get("completed_at")?,
        deleted: r.try_get::<i64, _>("deleted")?.max(0) as u64,
        held: r.try_get::<i64, _>("held")?.max(0) as u64,
        executions: r.try_get::<i32, _>("executions")?.max(0) as u32,
        canaries: serde_json::from_value(r.try_get("canaries")?)?,
        certificate: certificate.map(serde_json::from_value).transpose()?,
    })
}

/// The condition of a forget scope over the alias `m` (`$2` is the value).
fn scope_condition(scope: ForgetScope) -> &'static str {
    match scope {
        // The record, what names it as a source, and what a deletion of it left behind under
        // a legal hold further down (kept by id in the store's state, see `delete_in`).
        ForgetScope::Record => {
            "(m.id = ($2::text)::uuid OR m.metadata -> 'source_ids' ? $2 OR (m.metadata ? 'promoted_from' AND m.metadata -> 'promoted_from' ? $2) \
              OR m.id IN (SELECT (jsonb_array_elements_text(k.value::jsonb))::uuid FROM mh_meta k WHERE k.key = 'state.deletion.kept.' || $1 || '.' || $2))"
        }
        ForgetScope::Subject => "m.subject = $2",
        ForgetScope::Tenant => "$2::text IS NOT NULL",
        ForgetScope::User => "(m.prov_user = $2 OR m.scope_user = $2)",
        ForgetScope::Agent => "(m.prov_agent = $2 OR m.scope_agent = $2)",
        ForgetScope::Source => "m.source = $2",
        ForgetScope::Untrusted => "(m.status = 'candidate' AND m.metadata ->> 'held' = 'untrusted_source' AND ($2 = '*' OR m.source = $2))",
    }
}

/// The rows a `forget` by user, agent, source or untrusted source matches, over `m`.
pub(crate) fn forget_condition(scope: ForgetScope) -> anyhow::Result<&'static str> {
    match scope {
        ForgetScope::User | ForgetScope::Agent | ForgetScope::Source | ForgetScope::Untrusted => Ok(scope_condition(scope)),
        s => anyhow::bail!("no row condition for forget by {}", s.as_str()),
    }
}

impl PgStore {
    /// Narrow a transaction to one tenant (and subject) for row-level security (TR-DB-03): the
    /// settings last until the transaction ends. Nothing to do when RLS is off.
    pub(crate) async fn scope_tx(&self, tx: &mut PgConnection, tenant: &str, subject: Option<&str>) -> anyhow::Result<()> {
        if self.rls {
            sqlx::query("SELECT set_config('memhouse.scope', '', true), set_config('memhouse.tenant', $1, true), set_config('memhouse.subject', $2, true)")
                .bind(tenant)
                .bind(subject.unwrap_or(""))
                .execute(&mut *tx)
                .await?;
        }
        Ok(())
    }

    /// A connection narrowed to one tenant (and subject): what the read paths run their
    /// statement on, so a statement that lost its own filter still reads nothing else. The
    /// pool resets the settings when the connection is released.
    pub(crate) async fn scoped(&self, tenant: &str, subject: Option<&str>) -> anyhow::Result<sqlx::pool::PoolConnection<sqlx::Postgres>> {
        let mut c = self.pool.acquire().await?;
        if self.rls {
            sqlx::query("SELECT set_config('memhouse.scope', '', false), set_config('memhouse.tenant', $1, false), set_config('memhouse.subject', $2, false)")
                .bind(tenant)
                .bind(subject.unwrap_or(""))
                .execute(&mut *c)
                .await?;
        }
        Ok(c)
    }

    pub(crate) async fn memory_is_partitioned(&self) -> anyhow::Result<bool> {
        Ok(sqlx::query_scalar("SELECT coalesce((SELECT relkind = 'p' FROM pg_class WHERE oid = to_regclass('mh_memory')), false)").fetch_one(&self.pool).await?)
    }

    /// The v12 step of `migrate`: the new tables, then what the configuration asks for.
    pub(crate) async fn migrate_v12(&self) -> anyhow::Result<()> {
        sqlx::raw_sql(SCHEMA_V12_DDL).execute(&self.pool).await?;
        let mut partitioned = self.memory_is_partitioned().await?;
        if self.want_partitions && !partitioned {
            // One transaction: either the table is partitioned with its indexes and triggers,
            // or it is as it was.
            let mut tx = self.pool.begin().await?;
            sqlx::raw_sql(PARTITION_DDL).execute(&mut *tx).await?;
            sqlx::raw_sql(MEMORY_TRIGGERS_DDL).execute(&mut *tx).await?;
            tx.commit().await?;
            partitioned = true;
            tracing::info!("schema: the memory table is now partitioned by month for episodic memory (TR-DB-04); existing rows were left where they are");
        } else if partitioned {
            sqlx::raw_sql(MEMORY_TRIGGERS_DDL).execute(&self.pool).await?;
        }
        self.partitioned.store(partitioned, std::sync::atomic::Ordering::Relaxed);
        if self.rls {
            self.rls_install().await?;
        }
        Ok(())
    }

    /// Policies on every memory table, enabled and forced (the owner is bound by them too).
    /// Installed once: a start that finds them in place changes nothing, so an ordinary start
    /// (and every command-line call) takes no lock on the memory tables for them.
    async fn rls_install(&self) -> anyhow::Result<()> {
        let status = self.rls().await?;
        if status["enabled_on_every_memory_table"] == true && self.meta("rls_version").await?.as_deref() == Some(RLS_VERSION) {
            return Ok(());
        }
        // Only the role that owns the tables, or a member of it, may take the service scope.
        // The owner is read from the catalog when the function runs: whichever role last
        // started the service or ran a command, the answer is the same.
        sqlx::raw_sql(
            "DO $do$ BEGIN EXECUTE format('CREATE OR REPLACE FUNCTION mh_rls_service() RETURNS boolean LANGUAGE sql STABLE AS %L', \
               format('SELECT pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid = %L::regclass), ''USAGE'')', quote_ident(current_schema()) || '.mh_meta')); END $do$;",
        )
        .execute(&self.pool)
        .await?;
        let mut tables: Vec<(String, &str)> = RLS_TABLES.iter().map(|t| (t.to_string(), RLS_USING)).collect();
        tables.extend(RLS_SERVICE_TABLES.iter().map(|t| (t.to_string(), RLS_SERVICE_USING)));
        // A partition can be read by its own name: it carries the policy too.
        for p in self.partitions().await? {
            tables.push((p, RLS_USING));
        }
        if self.partitioned.load(std::sync::atomic::Ordering::Relaxed) {
            tables.push(("mh_memory_rest".into(), RLS_USING));
        }
        let mut c = self.pool.acquire().await?;
        for (table, using) in tables {
            self.rls_on(&mut c, &table, using).await?;
        }
        sqlx::query("INSERT INTO mh_meta (key, value) VALUES ('rls_version', $1) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value")
            .bind(RLS_VERSION)
            .execute(&mut *c)
            .await?;
        Ok(())
    }

    async fn rls_on(&self, c: &mut PgConnection, table: &str, using: &str) -> anyhow::Result<()> {
        sqlx::raw_sql(sqlx::AssertSqlSafe(format!(
            "DROP POLICY IF EXISTS mh_isolation ON {table}; \
             CREATE POLICY mh_isolation ON {table} USING {using} WITH CHECK {using}; \
             ALTER TABLE {table} ENABLE ROW LEVEL SECURITY; ALTER TABLE {table} FORCE ROW LEVEL SECURITY;"
        )))
        .execute(&mut *c)
        .await?;
        Ok(())
    }

    /// The monthly partitions, oldest first.
    pub(crate) async fn partitions(&self) -> anyhow::Result<Vec<String>> {
        if !self.partitioned.load(std::sync::atomic::Ordering::Relaxed) {
            return Ok(vec![]);
        }
        let mut names: Vec<String> =
            sqlx::query_scalar("SELECT c.relname::text FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = to_regclass('mh_memory')")
                .fetch_all(&self.pool)
                .await?;
        names.retain(|n| partition_month(n).is_some());
        names.sort();
        Ok(names)
    }

    /// The partition month of a record: its month for episodic memory on a partitioned table,
    /// none otherwise.
    pub(crate) fn epart_of(&self, kind: MemoryKind, created_at: DateTime<Utc>) -> Option<NaiveDate> {
        (kind == MemoryKind::Episodic && self.partitioned.load(std::sync::atomic::Ordering::Relaxed)).then(|| month_of(created_at))
    }

    /// Make sure the partitions of these months exist, before the insert that needs them and in
    /// a transaction of their own: a partition created inside an insert that is rolled back
    /// would be gone while this process still believed in it.
    pub(crate) async fn ensure_partitions(&self, months: impl IntoIterator<Item = NaiveDate>) -> anyhow::Result<()> {
        let recent = month_of(Utc::now() - chrono::Duration::days(45));
        let mut todo: Vec<NaiveDate> = vec![];
        {
            let known = self.known_partitions.lock().unwrap();
            for m in months {
                // An old month may have been dropped by retention in another process: asked every time.
                if (m < recent || !known.contains(&m)) && !todo.contains(&m) {
                    todo.push(m);
                }
            }
        }
        for m in todo {
            let name = partition_name(m);
            let mut tx = self.pool.begin().await?;
            // One creator at a time: two concurrent CREATE TABLE IF NOT EXISTS of one name collide.
            sqlx::query("SELECT pg_advisory_xact_lock(7270003)").execute(&mut *tx).await?;
            let exists: bool = sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL").bind(&name).fetch_one(&mut *tx).await?;
            if !exists {
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE TABLE {name} PARTITION OF mh_memory (PRIMARY KEY (id)) FOR VALUES IN ('{}')", m.format("%Y-%m-%d"))))
                    .execute(&mut *tx)
                    .await?;
                if self.rls {
                    self.rls_on(&mut tx, &name, RLS_USING).await?;
                }
            }
            tx.commit().await?;
            self.known_partitions.lock().unwrap().insert(m);
        }
        Ok(())
    }

    /// Delete one record with its cascade inside the caller's transaction: its cached vectors,
    /// the facts derived from it and, with `promotions`, what was promoted from it (and from
    /// those in turn), queued promotions of any of them, and the extraction jobs that read it
    /// with their cached answers. With `respect_holds` a held record stays, and so does a held
    /// dependent. A record that is gone already still has its remaining dependents removed (a
    /// deletion a hold interrupted is finished this way). Returns the subject and how many
    /// records went, or none when nothing did.
    pub(crate) async fn delete_in(&self, tx: &mut PgConnection, tenant: &str, id: Uuid, promotions: bool, respect_holds: bool) -> anyhow::Result<Option<Deleted>> {
        let ids = id.to_string();
        if respect_holds {
            sqlx::query(HOLD_GUARD_SHARED).bind(tenant).execute(&mut *tx).await?;
        }
        let found: Option<(String, bool)> = sqlx::query_as(sqlx::AssertSqlSafe(format!("SELECT m.subject, {HELD_SQL} FROM mh_memory m WHERE m.tenant = $1 AND m.id = $2")))
            .bind(tenant)
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
        // Descendants an earlier, interrupted deletion of this record left under a legal hold.
        // Their parents went then, so no link leads from this record to them any more: they
        // are kept by id until the deletion is finished (GOV-09).
        let kept_key = format!("state.deletion.kept.{tenant}.{id}");
        let kept: Vec<Uuid> = match sqlx::query_scalar::<_, String>("SELECT value FROM mh_meta WHERE key = $1").bind(&kept_key).fetch_optional(&mut *tx).await? {
            Some(v) => serde_json::from_str(&v).unwrap_or_default(),
            None => vec![],
        };
        let dependents_of = if promotions {
            "(m.metadata -> 'source_ids' ? $2 OR (m.metadata ? 'promoted_from' AND m.metadata -> 'promoted_from' ? $2) OR m.id = ANY($3::uuid[]))"
        } else {
            "(m.metadata -> 'source_ids' ? $2 OR m.id = ANY($3::uuid[]))"
        };
        let subject = match &found {
            Some((_, true)) if respect_holds => return Ok(None),
            Some((s, _)) => s.clone(),
            None => {
                let of: Option<String> = sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT m.subject FROM mh_memory m WHERE m.tenant = $1 AND {dependents_of} LIMIT 1")))
                    .bind(tenant)
                    .bind(&ids)
                    .bind(&kept)
                    .fetch_optional(&mut *tx)
                    .await?;
                match of {
                    Some(s) => s,
                    None => {
                        sqlx::query("DELETE FROM mh_meta WHERE key = $1").bind(&kept_key).execute(&mut *tx).await?;
                        return Ok(None);
                    }
                }
            }
        };
        // No promotion in this subject is in flight while its links are followed below.
        sqlx::query(SUBJECT_LOCK_SQL).bind(tenant).bind(&subject).execute(&mut *tx).await?;
        let mut removed: Vec<Uuid> = vec![];
        if found.is_some() {
            let row = sqlx::query("DELETE FROM mh_memory WHERE tenant = $1 AND id = $2 RETURNING content, alt_hash").bind(tenant).bind(id).fetch_optional(&mut *tx).await?;
            if let Some(row) = row {
                removed.push(id);
                let content: String = row.try_get("content")?;
                let alt_hash: Option<String> = row.try_get("alt_hash")?;
                // Also drop the cached embeddings of this content (every representation goes, TR-WF-01).
                sqlx::query("DELETE FROM mh_embed_cache WHERE hash = encode(sha256(convert_to($1 || $2, 'UTF8')), 'hex') OR hash = $3")
                    .bind(&self.passage_prefix)
                    .bind(&content)
                    .bind(alt_hash)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        // Facts derived from this record and records promoted from it (MEM-05) go with it, and
        // so does everything promoted from those in turn (a note promoted to a fact, the fact to
        // a procedure), with their cached vectors.
        let recurse = if promotions {
            "UNION SELECT m.id FROM dep JOIN mh_memory m ON m.tenant = $1 AND m.metadata ? 'promoted_from' AND m.metadata -> 'promoted_from' ? dep.id::text"
        } else {
            ""
        };
        let keep_held = if respect_holds { format!("AND NOT {HELD_SQL}") } else { String::new() };
        let held_below: Vec<Uuid> = if respect_holds {
            sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
                "WITH RECURSIVE dep(id) AS (SELECT m.id FROM mh_memory m WHERE m.tenant = $1 AND {dependents_of} {recurse}) \
                 SELECT m.id FROM mh_memory m WHERE m.tenant = $1 AND m.id IN (SELECT id FROM dep) AND {HELD_SQL}"
            )))
            .bind(tenant)
            .bind(&ids)
            .bind(&kept)
            .fetch_all(&mut *tx)
            .await?
        } else {
            vec![]
        };
        let kept_held = !held_below.is_empty();
        let dependents: Vec<(Uuid, String, Option<String>)> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "WITH RECURSIVE dep(id) AS (SELECT m.id FROM mh_memory m WHERE m.tenant = $1 AND {dependents_of} {recurse}) \
             DELETE FROM mh_memory m WHERE m.tenant = $1 AND m.id IN (SELECT id FROM dep) {keep_held} RETURNING m.id, m.content, m.alt_hash"
        )))
        .bind(tenant)
        .bind(&ids)
        .bind(&kept)
        .fetch_all(&mut *tx)
        .await?;
        removed.extend(dependents.iter().map(|(d, _, _)| *d));
        // What a hold still keeps below this record stays within reach of the next attempt,
        // whatever went between it and the record; once nothing is kept, the note goes.
        if kept_held {
            sqlx::query("INSERT INTO mh_meta (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value")
                .bind(&kept_key)
                .bind(serde_json::to_string(&held_below)?)
                .execute(&mut *tx)
                .await?;
        } else if !kept.is_empty() {
            sqlx::query("DELETE FROM mh_meta WHERE key = $1").bind(&kept_key).execute(&mut *tx).await?;
        }
        if removed.is_empty() {
            return Ok(None);
        }
        let contents: Vec<&str> = dependents.iter().map(|(_, c, _)| c.as_str()).collect();
        // Both cached vectors of each dependent that went: the one of its text and the
        // alternative one, which only the deleted row named.
        let alt_hashes: Vec<&str> = dependents.iter().filter_map(|(_, _, a)| a.as_deref()).collect();
        sqlx::query("DELETE FROM mh_embed_cache WHERE hash IN (SELECT encode(sha256(convert_to($1 || c, 'UTF8')), 'hex') FROM unnest($2::text[]) c) OR hash = ANY($3)")
            .bind(&self.passage_prefix)
            .bind(&contents)
            .bind(&alt_hashes)
            .execute(&mut *tx)
            .await?;
        if promotions {
            // Promotions of this record, or of anything that went with it, that are still queued
            // (or set aside with their payload): gone with it on every erasure path, single or
            // bulk, so none is readable by its id or written later.
            let gone: Vec<String> = std::iter::once(id).chain(dependents.iter().map(|(d, _, _)| *d)).map(|u| u.to_string()).collect();
            sqlx::query(
                "DELETE FROM mh_intake q WHERE q.tenant = $1 AND q.payload IS NOT NULL AND EXISTS ( \
                   SELECT 1 FROM jsonb_array_elements(q.payload -> 'records') r, \
                                 jsonb_array_elements_text(CASE WHEN jsonb_typeof(r -> 'memory' -> 'metadata' -> 'promoted_from') = 'array' \
                                                                THEN r -> 'memory' -> 'metadata' -> 'promoted_from' ELSE '[]'::jsonb END) s \
                   WHERE s = ANY($2::text[]))",
            )
            .bind(tenant)
            .bind(&gone)
            .execute(&mut *tx)
            .await?;
        }
        // The extraction jobs that read the record or anything that went with it (a promotion
        // may itself be a round a job read), with their cached answers.
        let mut read: Vec<Uuid> = removed.clone();
        if !read.contains(&id) {
            read.push(id);
        }
        sqlx::query(
            "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND round_ids && $2::uuid[] RETURNING cache_key) \
             DELETE FROM mh_llm_cache c USING j WHERE c.key = ANY(string_to_array(j.cache_key, ','))",
        )
        .bind(tenant)
        .bind(&read)
        .execute(&mut *tx)
        .await?;
        Ok(Some(Deleted { subject, ids: removed, kept_held }))
    }

    /// Delete exactly one record and nothing it led to: how a ledger row of scope `record`
    /// (or `record-reset`, which leaves the caches) is re-applied. Such rows are written where
    /// the deletion's own cascade was cut short by a legal hold, so a replay must not run the
    /// cascade again and take what the hold kept.
    pub(crate) async fn delete_exact_in(&self, tx: &mut PgConnection, tenant: &str, id: Uuid, purge_cache: bool) -> anyhow::Result<u64> {
        let row = sqlx::query("DELETE FROM mh_memory WHERE tenant = $1 AND id = $2 RETURNING content, alt_hash").bind(tenant).bind(id).fetch_optional(&mut *tx).await?;
        let Some(row) = row else { return Ok(0) };
        if purge_cache {
            sqlx::query("DELETE FROM mh_embed_cache WHERE hash = encode(sha256(convert_to($1 || $2, 'UTF8')), 'hex') OR hash = $3")
                .bind(&self.passage_prefix)
                .bind(row.try_get::<String, _>("content")?)
                .bind(row.try_get::<Option<String>, _>("alt_hash")?)
                .execute(&mut *tx)
                .await?;
        }
        // The jobs that read it go on both paths, as they did when the record was deleted; a
        // reset leaves their cached answers, like the vectors.
        sqlx::query(
            "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND round_ids @> ARRAY[$2]::uuid[] RETURNING cache_key) \
             DELETE FROM mh_llm_cache c USING j WHERE $3 AND c.key = ANY(string_to_array(j.cache_key, ','))",
        )
        .bind(tenant)
        .bind(id)
        .bind(purge_cache)
        .execute(&mut *tx)
        .await?;
        Ok(1)
    }

    /// The ledger rows of a deletion that `delete_in` carried out: one `memory` row, which a
    /// replay re-applies with the cascade, or, when a legal hold kept a dependent, a `record`
    /// row for each id that went, which a replay re-applies exactly.
    pub(crate) async fn ledger_deleted(&self, tx: &mut PgConnection, tenant: &str, id: Uuid, d: &Deleted, actor: &str) -> anyhow::Result<()> {
        if d.kept_held {
            sqlx::query("INSERT INTO mh_deletion_ledger (tenant, subject, memory_id, scope, actor) SELECT $1, $2, i, 'record', $3 FROM unnest($4::uuid[]) AS t(i)")
                .bind(tenant)
                .bind(&d.subject)
                .bind(actor)
                .bind(&d.ids)
                .execute(&mut *tx)
                .await?;
        } else {
            sqlx::query("INSERT INTO mh_deletion_ledger (tenant, subject, memory_id, scope, actor) VALUES ($1, $2, $3, 'memory', $4)")
                .bind(tenant)
                .bind(&d.subject)
                .bind(id)
                .bind(actor)
                .execute(&mut *tx)
                .await?;
        }
        Ok(())
    }

    /// Erase a subject inside the caller's transaction, without the ledger row. With
    /// `respect_holds`, records an active hold matches stay, and with them the subject's links,
    /// remembered responses, recall explanations and queued writes: the erasure is finished
    /// when the hold is released. Returns the records removed, whether the erasure is
    /// complete, and (when it is not) the ids that went.
    pub(crate) async fn erase_subject_in(
        &self,
        tx: &mut PgConnection,
        tenant: &str,
        subject: &str,
        purge_cache: bool,
        respect_holds: bool,
    ) -> anyhow::Result<(u64, bool, Vec<Uuid>)> {
        if respect_holds {
            sqlx::query(HOLD_GUARD_SHARED).bind(tenant).execute(&mut *tx).await?;
        }
        let held: i64 = if respect_holds {
            sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT count(*) FROM mh_memory m WHERE m.tenant = $1 AND m.subject = $2 AND {HELD_SQL}")))
                .bind(tenant)
                .bind(subject)
                .fetch_one(&mut *tx)
                .await?
        } else {
            0
        };
        if held > 0 {
            if purge_cache {
                sqlx::query(sqlx::AssertSqlSafe(format!(
                    "DELETE FROM mh_embed_cache c USING mh_memory m WHERE m.tenant = $1 AND m.subject = $2 AND NOT {HELD_SQL} \
                     AND (c.hash = encode(sha256(convert_to($3 || m.content, 'UTF8')), 'hex') OR c.hash = m.alt_hash)"
                )))
                .bind(tenant)
                .bind(subject)
                .bind(&self.passage_prefix)
                .execute(&mut *tx)
                .await?;
            }
            let ids: Vec<Uuid> =
                sqlx::query_scalar(sqlx::AssertSqlSafe(format!("DELETE FROM mh_memory m WHERE m.tenant = $1 AND m.subject = $2 AND NOT {HELD_SQL} RETURNING m.id")))
                    .bind(tenant)
                    .bind(subject)
                    .fetch_all(&mut *tx)
                    .await?;
            sqlx::query(
                "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2 AND round_ids && $3::uuid[] RETURNING cache_key) \
                 DELETE FROM mh_llm_cache c USING j WHERE $4 AND c.key = ANY(string_to_array(j.cache_key, ','))",
            )
            .bind(tenant)
            .bind(subject)
            .bind(&ids)
            .bind(purge_cache)
            .execute(&mut *tx)
            .await?;
            return Ok((ids.len() as u64, false, ids));
        }
        // Queued writes first: a proposal being inserted right now holds its row, so this waits
        // for it and the deletes below then see what it wrote (nothing lands after an erasure).
        sqlx::query("DELETE FROM mh_intake WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        // A record under a hold may have been committed since the count above (a write from a
        // held source that was in flight): the delete itself keeps what a hold matches, and
        // the erasure is then partial, as if the count had seen it.
        let keep = if respect_holds { format!("AND NOT {HELD_SQL}") } else { String::new() };
        if purge_cache {
            sqlx::query(sqlx::AssertSqlSafe(format!(
                "DELETE FROM mh_embed_cache c USING mh_memory m WHERE m.tenant = $1 AND m.subject = $2 {keep} \
                 AND (c.hash = encode(sha256(convert_to($3 || m.content, 'UTF8')), 'hex') OR c.hash = m.alt_hash)"
            )))
            .bind(tenant)
            .bind(subject)
            .bind(&self.passage_prefix)
            .execute(&mut *tx)
            .await?;
        }
        let gone: Vec<Uuid> = sqlx::query_scalar(sqlx::AssertSqlSafe(format!("DELETE FROM mh_memory m WHERE m.tenant = $1 AND m.subject = $2 {keep} RETURNING m.id")))
            .bind(tenant)
            .bind(subject)
            .fetch_all(&mut *tx)
            .await?;
        let n = gone.len() as u64;
        if respect_holds {
            let left: i64 = sqlx::query_scalar("SELECT count(*) FROM mh_memory WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).fetch_one(&mut *tx).await?;
            if left > 0 {
                // The subject's links, remembered responses and explanations stay with what is held.
                sqlx::query(
                    "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2 AND round_ids && $3::uuid[] RETURNING cache_key) \
                     DELETE FROM mh_llm_cache c USING j WHERE $4 AND c.key = ANY(string_to_array(j.cache_key, ','))",
                )
                .bind(tenant)
                .bind(subject)
                .bind(&gone)
                .bind(purge_cache)
                .execute(&mut *tx)
                .await?;
                return Ok((n, false, gone));
            }
        }
        // No explanation of the subject is being written while its explanations are removed
        // (`recall_put` takes the same lock). Taken here, after the queue: a write in
        // progress holds its queue row first and this lock second, and so does this.
        sqlx::query(SUBJECT_LOCK_SQL).bind(tenant).bind(subject).execute(&mut *tx).await?;
        // Links held by the subject and links to it from others, and remembered responses.
        sqlx::query("DELETE FROM mh_link WHERE tenant = $1 AND (subject = $2 OR linked_subject = $2)").bind(tenant).bind(subject).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM mh_request_key WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM mh_recall WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        if purge_cache {
            sqlx::query(
                "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2 RETURNING cache_key) \
                 DELETE FROM mh_llm_cache c USING j WHERE c.key = ANY(string_to_array(j.cache_key, ','))",
            )
            .bind(tenant)
            .bind(subject)
            .execute(&mut *tx)
            .await?;
        } else {
            sqlx::query("DELETE FROM mh_enrich_job WHERE tenant = $1 AND subject = $2").bind(tenant).bind(subject).execute(&mut *tx).await?;
        }
        Ok((n, true, vec![]))
    }

    /// What is left of a tenant without a record, removed once every subject is erased.
    pub(crate) async fn erase_tenant_rest(&self, tx: &mut PgConnection, tenant: &str) -> anyhow::Result<()> {
        for table in ["mh_intake", "mh_link", "mh_grant", "mh_eval_suite", "mh_eval_run", "mh_request_key", "mh_session", "mh_recall"] {
            sqlx::query(sqlx::AssertSqlSafe(format!("DELETE FROM {table} WHERE tenant = $1"))).bind(tenant).execute(&mut *tx).await?;
        }
        sqlx::query(
            "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 RETURNING cache_key) DELETE FROM mh_llm_cache c USING j WHERE c.key = ANY(string_to_array(j.cache_key, ','))",
        )
        .bind(tenant)
        .execute(&mut *tx)
        .await?;
        // Notes of descendants a hold kept below a deleted record: none is left to reach.
        sqlx::query("DELETE FROM mh_meta WHERE left(key, length($1)) = $1").bind(format!("state.deletion.kept.{tenant}.")).execute(&mut *tx).await?;
        Ok(())
    }

    pub(crate) async fn active_holds(&self, tenant: &str) -> anyhow::Result<i64> {
        Ok(sqlx::query_scalar("SELECT count(*) FROM mh_legal_hold WHERE tenant = $1 AND released_at IS NULL").bind(tenant).fetch_one(&self.pool).await?)
    }

    /// The cascade of a batch of purged records, inside the batch's transaction: their cached
    /// vectors, the facts derived from them (kept when a hold matches them), the jobs that read
    /// them with their cached extractions, and a `retention` ledger row for each. Returns the
    /// facts removed.
    async fn purge_cascade(&self, tx: &mut PgConnection, tenant: &str, ids: &[Uuid], subjects: &[String], contents: &[String], alt_hashes: &[String]) -> anyhow::Result<u64> {
        let id_strs: Vec<String> = ids.iter().map(|u| u.to_string()).collect();
        sqlx::query(
            "DELETE FROM mh_embed_cache WHERE hash IN (SELECT encode(sha256(convert_to($1 || c, 'UTF8')), 'hex') FROM unnest($2::text[]) c) \
             OR hash = ANY($3)",
        )
        .bind(&self.passage_prefix)
        .bind(contents)
        .bind(alt_hashes)
        .execute(&mut *tx)
        .await?;
        // A derived fact under a legal hold stays. The ledger must then say exactly what went
        // (`record` rows): a `retention` row is re-applied with the cascade, which would take
        // the kept fact on a restore.
        let kept: bool = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT EXISTS (SELECT 1 FROM mh_memory m WHERE m.tenant = $1 AND m.metadata -> 'source_ids' ?| $2::text[] AND {HELD_SQL})"
        )))
        .bind(tenant)
        .bind(&id_strs)
        .fetch_one(&mut *tx)
        .await?;
        let fact_rows: Vec<(Uuid, String)> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "WITH d AS (DELETE FROM mh_memory m WHERE m.tenant = $1 AND m.metadata -> 'source_ids' ?| $2::text[] AND NOT {HELD_SQL} RETURNING m.id, m.subject, m.content, m.alt_hash), \
             c AS (DELETE FROM mh_embed_cache c USING d WHERE c.hash = encode(sha256(convert_to($3 || d.content, 'UTF8')), 'hex') OR c.hash = d.alt_hash) \
             SELECT id, subject FROM d"
        )))
        .bind(tenant)
        .bind(&id_strs)
        .bind(&self.passage_prefix)
        .fetch_all(&mut *tx)
        .await?;
        let facts = fact_rows.len() as i64;
        sqlx::query(
            "WITH j AS (DELETE FROM mh_enrich_job WHERE tenant = $1 AND round_ids && $2::uuid[] RETURNING cache_key) \
             DELETE FROM mh_llm_cache c USING j WHERE c.key = ANY(string_to_array(j.cache_key, ','))",
        )
        .bind(tenant)
        .bind(ids.iter().copied().chain(fact_rows.iter().map(|(i, _)| *i)).collect::<Vec<Uuid>>())
        .execute(&mut *tx)
        .await?;
        let (mut ledger_subjects, mut ledger_ids) = (subjects.to_vec(), ids.to_vec());
        if kept {
            ledger_ids.extend(fact_rows.iter().map(|(i, _)| *i));
            ledger_subjects.extend(fact_rows.iter().map(|(_, s)| s.clone()));
        }
        sqlx::query(
            "INSERT INTO mh_deletion_ledger (tenant, subject, memory_id, scope, actor) \
             SELECT $1, s, i, $4, 'system' FROM unnest($2::text[], $3::uuid[]) AS t(s, i)",
        )
        .bind(tenant)
        .bind(&ledger_subjects)
        .bind(&ledger_ids)
        .bind(if kept { "record" } else { "retention" })
        .execute(&mut *tx)
        .await?;
        Ok(facts.max(0) as u64)
    }

    async fn count_run(&self, tx: &mut PgConnection, run: &Option<(Uuid, String)>, n: u64) -> anyhow::Result<()> {
        if let Some((id, step)) = run {
            sqlx::query(
                "UPDATE mh_job_run SET updated_at = now(), state = jsonb_set(jsonb_set(state, '{counts}', coalesce(state -> 'counts', '{}'::jsonb), true), \
                   ARRAY['counts', $2], to_jsonb(coalesce((state -> 'counts' ->> $2)::bigint, 0) + $3), true) WHERE id = $1",
            )
            .bind(id)
            .bind(step)
            .bind(n as i64)
            .execute(&mut *tx)
            .await?;
        }
        Ok(())
    }

    /// Drop whole the monthly partitions a rule has made due (TR-DB-04): every row is the
    /// tenant's, older than the rule's days, outside the rule's exceptions and under no hold.
    /// The cascade of its rows, their ledger rows, the run's count and the drop are one
    /// transaction, so a drop that is interrupted leaves the partition as it was. Returns
    /// (partitions dropped, records and derived facts removed).
    async fn drop_due_partitions(&self, tenant: &str, spec: &PurgeSpec) -> anyhow::Result<(u64, u64)> {
        let PurgeAge::OlderThanDays(days) = spec.age else { return Ok((0, 0)) };
        // A bounded pass keeps to its bound: a partition is one unbounded step, so a pass with
        // a batch limit purges by row.
        if spec.kind != MemoryKind::Episodic || spec.scope.is_some() || spec.max_batches.is_some() {
            return Ok((0, 0));
        }
        let cutoff = Utc::now() - chrono::Duration::days(days.min(MAX_AGE_DAYS) as i64);
        let (mut dropped, mut removed) = (0u64, 0u64);
        for name in self.partitions().await? {
            let Some(month) = partition_month(&name) else { continue };
            // Every day of the month is before the cutoff.
            if next_month(month).and_hms_opt(0, 0, 0).expect("midnight").and_utc() > cutoff {
                continue;
            }
            let mut tx = self.pool.begin().await?;
            sqlx::query(HOLD_GUARD_SHARED).bind(tenant).execute(&mut *tx).await?;
            // No write lands in the partition between the check and the drop.
            sqlx::raw_sql(sqlx::AssertSqlSafe(format!("LOCK TABLE {name} IN ACCESS EXCLUSIVE MODE"))).execute(&mut *tx).await?;
            let mut except = String::new();
            let mut values = vec![];
            for ScopeMatch { level, value } in &spec.except {
                values.push(value.clone());
                except.push_str(&format!(" OR m.{} = ${}", level.column(), values.len() + 2));
            }
            let mut q = sqlx::query_as::<_, (i64, i64)>(sqlx::AssertSqlSafe(format!(
                "SELECT count(*), count(*) FILTER (WHERE m.tenant <> $1 OR m.kind <> 'episodic' OR m.created_at >= $2 OR {HELD_SQL}{except}) FROM {name} m"
            )))
            .bind(tenant)
            .bind(cutoff);
            for v in &values {
                q = q.bind(v);
            }
            let (rows, kept) = q.fetch_one(&mut *tx).await?;
            if kept > 0 {
                // Something in it is not due: its due rows are deleted one by one instead.
                continue;
            }
            // No lower bound on the first page: the smallest id there is belongs to it too.
            let mut after: Option<Uuid> = None;
            let mut n = 0u64;
            loop {
                let batch =
                    sqlx::query(sqlx::AssertSqlSafe(format!("SELECT id, subject, content, alt_hash FROM {name} WHERE ($1::uuid IS NULL OR id > $1) ORDER BY id LIMIT 1000")))
                        .bind(after)
                        .fetch_all(&mut *tx)
                        .await?;
                let Some(last) = batch.last() else { break };
                after = Some(last.try_get("id")?);
                let mut ids = Vec::with_capacity(batch.len());
                let mut subjects = Vec::with_capacity(batch.len());
                let mut contents = Vec::with_capacity(batch.len());
                let mut alt_hashes = vec![];
                for r in &batch {
                    ids.push(r.try_get::<Uuid, _>("id")?);
                    subjects.push(r.try_get::<String, _>("subject")?);
                    contents.push(r.try_get::<String, _>("content")?);
                    if let Some(h) = r.try_get::<Option<String>, _>("alt_hash")? {
                        alt_hashes.push(h);
                    }
                }
                // Dropping a table fires no row trigger: what hangs on the rows goes here.
                for child in ["mh_structured", "mh_code_ref", "mh_link"] {
                    sqlx::query(sqlx::AssertSqlSafe(format!("DELETE FROM {child} WHERE memory_id = ANY($1)"))).bind(&ids).execute(&mut *tx).await?;
                }
                n += ids.len() as u64 + self.purge_cascade(&mut tx, tenant, &ids, &subjects, &contents, &alt_hashes).await?;
            }
            sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP TABLE {name}"))).execute(&mut *tx).await?;
            self.count_run(&mut tx, &spec.run, n).await?;
            tx.commit().await?;
            self.known_partitions.lock().unwrap().remove(&month);
            tracing::info!(partition = %name, rows, "retention: dropped a monthly partition of episodic memory");
            dropped += 1;
            removed += n;
        }
        Ok((dropped, removed))
    }

    pub(crate) async fn purge_by(&self, tenant: &str, spec: &PurgeSpec) -> anyhow::Result<PurgeOutcome> {
        let mut out = PurgeOutcome { complete: true, ..Default::default() };
        if self.partitioned.load(std::sync::atomic::Ordering::Relaxed) {
            let (dropped, removed) = self.drop_due_partitions(tenant, spec).await?;
            out.partitions_dropped = dropped;
            out.records = removed;
        }
        let (filter, values) = purge_filter(spec);
        let days = days_of(spec);
        // Same cascade as `delete`, in batches so a large purge never holds one huge transaction.
        let sql = format!(
            "DELETE FROM mh_memory WHERE tenant = $1 AND id IN (SELECT m.id FROM mh_memory m WHERE m.tenant = $1 AND m.kind = $2 AND {filter} AND NOT {HELD_SQL} LIMIT 1000) \
             RETURNING id, subject, content, alt_hash"
        );
        let mut batches = 0usize;
        loop {
            if spec.max_batches.is_some_and(|max| batches >= max) {
                out.complete = false;
                break;
            }
            // In the service scope: the cascade also removes rows of the content-addressed
            // caches, which no tenant's session can see.
            let mut tx = self.pool.begin().await?;
            sqlx::query(HOLD_GUARD_SHARED).bind(tenant).execute(&mut *tx).await?;
            let mut q = sqlx::query(sqlx::AssertSqlSafe(sql.clone())).bind(tenant).bind(spec.kind.as_str()).bind(days);
            for v in &values {
                q = q.bind(v);
            }
            let rows = q.fetch_all(&mut *tx).await?;
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
            let n = rows.len() as u64 + self.purge_cascade(&mut tx, tenant, &ids, &subjects, &contents, &alt_hashes).await?;
            self.count_run(&mut tx, &spec.run, n).await?;
            tx.commit().await?;
            out.records += n;
            batches += 1;
        }
        if self.active_holds(tenant).await? > 0 {
            let mut q =
                sqlx::query_scalar::<_, i64>(sqlx::AssertSqlSafe(format!("SELECT count(*) FROM mh_memory m WHERE m.tenant = $1 AND m.kind = $2 AND {filter} AND {HELD_SQL}")))
                    .bind(tenant)
                    .bind(spec.kind.as_str())
                    .bind(days);
            for v in &values {
                q = q.bind(v);
            }
            out.held = q.fetch_one(&self.pool).await?.max(0) as u64;
        }
        Ok(out)
    }

    pub(crate) async fn hold_put(&self, h: &LegalHold, audit: &AuditEntry) -> anyhow::Result<()> {
        let mut tx = self.pool.begin().await?;
        // Waits for deletions of the tenant that are under way; later ones see the hold.
        sqlx::query(HOLD_GUARD_EXCLUSIVE).bind(&h.tenant).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO mh_legal_hold (id, tenant, target_kind, target, reason, placed_by, placed_at) VALUES ($1, $2, $3, $4, $5, $6, $7)")
            .bind(h.id)
            .bind(&h.tenant)
            .bind(&h.target_kind)
            .bind(&h.target)
            .bind(&h.reason)
            .bind(&h.placed_by)
            .bind(h.placed_at)
            .execute(&mut *tx)
            .await?;
        self.audit_in(&mut tx, &h.tenant, audit).await?;
        tx.commit().await?;
        Ok(())
    }

    pub(crate) async fn hold_release(&self, tenant: &str, id: Uuid, by: &str, audit: &AuditEntry) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        let n = sqlx::query("UPDATE mh_legal_hold SET released_at = now(), released_by = $3 WHERE tenant = $1 AND id = $2 AND released_at IS NULL")
            .bind(tenant)
            .bind(id)
            .bind(by)
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

    pub(crate) async fn holds(&self, tenant: &str, active_only: bool) -> anyhow::Result<Vec<LegalHold>> {
        let rows = sqlx::query("SELECT * FROM mh_legal_hold WHERE tenant = $1 AND ($2 = false OR released_at IS NULL) ORDER BY placed_at DESC, id LIMIT 1000")
            .bind(tenant)
            .bind(active_only)
            .fetch_all(&self.pool)
            .await?;
        rows.iter().map(hold_of).collect()
    }

    pub(crate) async fn hold_one(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<LegalHold>> {
        sqlx::query("SELECT * FROM mh_legal_hold WHERE tenant = $1 AND id = $2").bind(tenant).bind(id).fetch_optional(&self.pool).await?.as_ref().map(hold_of).transpose()
    }

    /// Whether an active hold keeps this record itself.
    pub(crate) async fn held_record(&self, tenant: &str, id: Uuid) -> anyhow::Result<bool> {
        let held: Option<bool> = sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT {HELD_SQL} FROM mh_memory m WHERE m.tenant = $1 AND m.id = $2")))
            .bind(tenant)
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(held.unwrap_or(false))
    }

    pub(crate) async fn held(&self, tenant: &str, scope: ForgetScope, value: &str) -> anyhow::Result<u64> {
        // Without an active hold in the tenant nothing is held: no scan.
        if self.active_holds(tenant).await? == 0 {
            return Ok(0);
        }
        let cond = scope_condition(scope);
        let n: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT count(*) FROM mh_memory m WHERE m.tenant = $1 AND {cond} AND {HELD_SQL}")))
            .bind(tenant)
            .bind(value)
            .fetch_one(&self.pool)
            .await?;
        Ok(n.max(0) as u64)
    }

    async fn deletion_write(&self, tx: &mut PgConnection, d: &DeletionRequest) -> anyhow::Result<u64> {
        Ok(sqlx::query(
            "INSERT INTO mh_deletion_request (id, tenant, scope, value, actor, requested_at, status, completed_at, deleted, held, executions, canaries, certificate) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) \
             ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, completed_at = EXCLUDED.completed_at, held = EXCLUDED.held, certificate = EXCLUDED.certificate, \
               deleted = greatest(mh_deletion_request.deleted, EXCLUDED.deleted), executions = greatest(mh_deletion_request.executions, EXCLUDED.executions) \
             WHERE mh_deletion_request.status <> 'completed'",
        )
        .bind(d.id)
        .bind(&d.tenant)
        .bind(d.scope.as_str())
        .bind(&d.value)
        .bind(&d.actor)
        .bind(d.requested_at)
        .bind(d.status.as_str())
        .bind(d.completed_at)
        .bind(d.deleted as i64)
        .bind(d.held as i64)
        .bind(d.executions as i32)
        .bind(serde_json::to_value(&d.canaries)?)
        .bind(d.certificate.as_ref().map(serde_json::to_value).transpose()?)
        .execute(&mut *tx)
        .await?
        .rows_affected())
    }

    pub(crate) async fn deletion_store(&self, d: &DeletionRequest, audit: Option<&AuditEntry>) -> anyhow::Result<()> {
        let mut tx = self.pool.begin().await?;
        let written = self.deletion_write(&mut tx, d).await?;
        // The certificate's event is written with the completion, and only by the call that completes it.
        if let Some(a) = audit.filter(|_| written > 0) {
            self.audit_in(&mut tx, &d.tenant, a).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub(crate) async fn deletion_one(&self, tenant: &str, id: Uuid) -> anyhow::Result<Option<DeletionRequest>> {
        sqlx::query("SELECT * FROM mh_deletion_request WHERE tenant = $1 AND id = $2").bind(tenant).bind(id).fetch_optional(&self.pool).await?.as_ref().map(deletion_of).transpose()
    }

    pub(crate) async fn deletion_add(&self, tenant: &str, id: Uuid, deleted: u64) -> anyhow::Result<Option<DeletionRequest>> {
        // A sum in the database: two executions each add their own count, neither overwrites.
        let row =
            sqlx::query("UPDATE mh_deletion_request SET deleted = deleted + $3, executions = executions + 1 WHERE tenant = $1 AND id = $2 AND status <> 'completed' RETURNING *")
                .bind(tenant)
                .bind(id)
                .bind(deleted as i64)
                .fetch_optional(&self.pool)
                .await?;
        match row {
            Some(r) => Ok(Some(deletion_of(&r)?)),
            // Completed meanwhile (or unknown): as it is.
            None => self.deletion_one(tenant, id).await,
        }
    }

    pub(crate) async fn deletion_open(&self, tenant: &str, after: Option<(DateTime<Utc>, Uuid)>, limit: usize) -> anyhow::Result<Vec<DeletionRequest>> {
        let rows = sqlx::query(
            "SELECT * FROM mh_deletion_request WHERE tenant = $1 AND status <> 'completed' AND ($2::timestamptz IS NULL OR (requested_at, id) > ($2, $3)) \
             ORDER BY requested_at, id LIMIT $4",
        )
        .bind(tenant)
        .bind(after.map(|a| a.0))
        .bind(after.map(|a| a.1))
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.iter().map(deletion_of).collect()
    }

    pub(crate) async fn deletion_list(&self, tenant: &str, status: Option<DeletionStatus>, limit: usize) -> anyhow::Result<Vec<DeletionRequest>> {
        let rows = sqlx::query("SELECT * FROM mh_deletion_request WHERE tenant = $1 AND ($2::text IS NULL OR status = $2) ORDER BY requested_at DESC, id LIMIT $3")
            .bind(tenant)
            .bind(status.map(|s| s.as_str()))
            .bind(limit as i64)
            .fetch_all(&self.pool)
            .await?;
        rows.iter().map(deletion_of).collect()
    }

    pub(crate) async fn canaries_of(&self, tenant: &str, scope: ForgetScope, value: &str, limit: usize) -> anyhow::Result<Vec<Canary>> {
        let cond = scope_condition(scope);
        let rows = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT m.id, m.subject, encode(sha256(convert_to($3 || m.content, 'UTF8')), 'hex') AS vec_hash, m.alt_hash \
             FROM mh_memory m WHERE m.tenant = $1 AND {cond} ORDER BY m.id LIMIT $4"
        )))
        .bind(tenant)
        .bind(value)
        .bind(&self.passage_prefix)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.iter()
            .map(|r| {
                let mut vector_hashes = vec![r.try_get::<String, _>("vec_hash")?];
                vector_hashes.extend(r.try_get::<Option<String>, _>("alt_hash")?);
                Ok(Canary { id: r.try_get("id")?, subject: r.try_get("subject")?, vector_hashes })
            })
            .collect()
    }

    pub(crate) async fn probe(&self, tenant: &str, canaries: &[Canary]) -> anyhow::Result<CanaryReport> {
        if canaries.is_empty() {
            return Ok(CanaryReport::default());
        }
        let ids: Vec<Uuid> = canaries.iter().map(|c| c.id).collect();
        let id_strs: Vec<String> = ids.iter().map(|u| u.to_string()).collect();
        let hashes: Vec<String> = canaries.iter().flat_map(|c| c.vector_hashes.iter().cloned()).collect();
        let count = |sql: &'static str| sqlx::query_scalar::<_, i64>(sql);
        let records = count("SELECT count(*) FROM mh_memory WHERE tenant = $1 AND id = ANY($2)").bind(tenant).bind(&ids).fetch_one(&self.pool).await?;
        let representations = count(
            "SELECT (SELECT count(*) FROM mh_structured WHERE memory_id = ANY($1)) + (SELECT count(*) FROM mh_code_ref WHERE memory_id = ANY($1)) \
                  + (SELECT count(*) FROM mh_link WHERE memory_id = ANY($1))",
        )
        .bind(&ids)
        .fetch_one(&self.pool)
        .await?;
        let cached_vectors = count("SELECT count(*) FROM mh_embed_cache WHERE hash = ANY($1)").bind(&hashes).fetch_one(&self.pool).await?;
        let derived = count(
            "SELECT count(*) FROM mh_memory WHERE tenant = $1 AND (metadata -> 'source_ids' ?| $2::text[] OR (metadata ? 'promoted_from' AND metadata -> 'promoted_from' ?| $2::text[]))",
        )
        .bind(tenant)
        .bind(&id_strs)
        .fetch_one(&self.pool)
        .await?;
        let queued = count("SELECT count(*) FROM mh_intake WHERE tenant = $1 AND record_ids && $2::uuid[] AND (payload IS NOT NULL OR status IN ('pending', 'running'))")
            .bind(tenant)
            .bind(&ids)
            .fetch_one(&self.pool)
            .await?;
        let jobs = count("SELECT count(*) FROM mh_enrich_job WHERE tenant = $1 AND round_ids && $2::uuid[]").bind(tenant).bind(&ids).fetch_one(&self.pool).await?;
        let u = |n: i64| n.max(0) as u64;
        Ok(CanaryReport { records: u(records), representations: u(representations), cached_vectors: u(cached_vectors), derived: u(derived), queued: u(queued), jobs: u(jobs) })
    }

    pub(crate) async fn job_open(&self, tenant: &str, job: &str) -> anyhow::Result<JobRun> {
        let id = Uuid::new_v4();
        // The partial unique index makes the second of two racing passes take the first one's run.
        let created: Option<Uuid> = sqlx::query_scalar("INSERT INTO mh_job_run (id, tenant, job) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING id")
            .bind(id)
            .bind(tenant)
            .bind(job)
            .fetch_optional(&self.pool)
            .await?;
        let r =
            sqlx::query("SELECT id, state, started_at FROM mh_job_run WHERE tenant = $1 AND job = $2 AND finished_at IS NULL").bind(tenant).bind(job).fetch_one(&self.pool).await?;
        Ok(JobRun { id: r.try_get("id")?, tenant: tenant.into(), job: job.into(), state: r.try_get("state")?, started_at: r.try_get("started_at")?, resumed: created.is_none() })
    }

    pub(crate) async fn job_counted(&self, run: Uuid, step: &str) -> anyhow::Result<u64> {
        let n: Option<i64> =
            sqlx::query_scalar("SELECT (state -> 'counts' ->> $2)::bigint FROM mh_job_run WHERE id = $1").bind(run).bind(step).fetch_optional(&self.pool).await?.flatten();
        Ok(n.unwrap_or(0).max(0) as u64)
    }

    pub(crate) async fn job_step(&self, run: Uuid, step: &str, audit: Option<&AuditEntry>) -> anyhow::Result<bool> {
        let mut tx = self.pool.begin().await?;
        let tenant: Option<String> = sqlx::query_scalar(
            "UPDATE mh_job_run SET updated_at = now(), state = jsonb_set(state, '{done}', coalesce(state -> 'done', '[]'::jsonb) || to_jsonb($2::text), true) \
             WHERE id = $1 AND NOT coalesce(state -> 'done', '[]'::jsonb) ? $2 RETURNING tenant",
        )
        .bind(run)
        .bind(step)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(tenant) = tenant else { return Ok(false) };
        if let Some(a) = audit {
            self.audit_in(&mut tx, &tenant, a).await?;
        }
        tx.commit().await?;
        Ok(true)
    }

    pub(crate) async fn head(&self) -> anyhow::Result<Option<AuditHead>> {
        let r = sqlx::query("SELECT id, hash, at FROM mh_audit ORDER BY id DESC LIMIT 1").fetch_optional(&self.pool).await?;
        r.map(|r| Ok(AuditHead { id: r.try_get("id")?, hash: r.try_get("hash")?, at: r.try_get("at")? })).transpose()
    }

    pub(crate) async fn ledger(&self) -> anyhow::Result<Vec<LedgerEntry>> {
        let rows = sqlx::query("SELECT at, tenant, subject, memory_id, scope, actor FROM mh_deletion_ledger ORDER BY id").fetch_all(&self.pool).await?;
        rows.iter()
            .map(|r| {
                Ok(LedgerEntry {
                    at: r.try_get("at")?,
                    tenant: r.try_get("tenant")?,
                    subject: r.try_get("subject")?,
                    memory_id: r.try_get("memory_id")?,
                    scope: r.try_get("scope")?,
                    actor: r.try_get("actor")?,
                })
            })
            .collect()
    }

    /// Take one record out of every proposal that still holds it with its content; a proposal
    /// left without records goes, the other records stay queued. With `promotions`, queued
    /// promotions of the record go too.
    async fn unqueue_in(&self, tx: &mut PgConnection, tenant: &str, id: Uuid, promotions: bool) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE mh_intake SET record_ids = array_remove(record_ids, $2), \
               payload = jsonb_set(payload, '{records}', coalesce((SELECT jsonb_agg(r) FROM jsonb_array_elements(payload -> 'records') r \
                                                                     WHERE r -> 'memory' ->> 'id' <> $2::text), '[]'::jsonb)) \
             WHERE tenant = $1 AND record_ids @> ARRAY[$2] AND payload IS NOT NULL",
        )
        .bind(tenant)
        .bind(id)
        .execute(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM mh_intake WHERE tenant = $1 AND cardinality(record_ids) = 0 AND status IN ('pending', 'running', 'dead')").bind(tenant).execute(&mut *tx).await?;
        if promotions {
            sqlx::query(
                "DELETE FROM mh_intake q WHERE q.tenant = $1 AND q.payload IS NOT NULL AND EXISTS ( \
                   SELECT 1 FROM jsonb_array_elements(q.payload -> 'records') r, \
                                 jsonb_array_elements_text(CASE WHEN jsonb_typeof(r -> 'memory' -> 'metadata' -> 'promoted_from') = 'array' \
                                                                THEN r -> 'memory' -> 'metadata' -> 'promoted_from' ELSE '[]'::jsonb END) s \
                   WHERE s = $2::text)",
            )
            .bind(tenant)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        }
        Ok(())
    }

    /// Re-apply a ledger to a restored database (TR-WF-03), in one transaction; a row already
    /// in the ledger is not applied twice. Legal holds do not stop it: the ledger says
    /// what was deleted, and a hold that the restore brought back is no reason to bring the
    /// data back with it.
    pub(crate) async fn ledger_replay(&self, entries: &[LedgerEntry], actor: &str, tenant: &str, mut detail: serde_json::Value) -> anyhow::Result<Reapplied> {
        anyhow::ensure!(detail.is_object() || detail.is_null(), "the detail of a restore is a JSON object");
        type Key = (i64, String, Option<String>, Option<Uuid>, String);
        let key = |e: &LedgerEntry| -> Key { (e.at.timestamp_micros(), e.tenant.clone(), e.subject.clone(), e.memory_id, e.scope.clone()) };
        let mut known: HashSet<Key> = self.ledger().await?.iter().map(key).collect();
        let mut rep = Reapplied { given: entries.len() as u64, ..Default::default() };
        let mut ordered: Vec<&LedgerEntry> = entries.iter().collect();
        ordered.sort_by_key(|e| e.at);
        // Refused before anything is applied: an unknown kind of deletion left out would be an erasure undone.
        if let Some(e) = ordered.iter().find(|e| !["memory", "retention", "record", "record-reset", "subject", "subject-reset", "tenant"].contains(&e.scope.as_str())) {
            anyhow::bail!("unknown deletion-ledger scope {:?} (row of {}); nothing was applied", e.scope, e.at.to_rfc3339());
        }
        // One transaction for the whole replay, its ledger rows, its audit events and the end
        // of the sessions: a restored database is never left with half its deletions, and a
        // row that cannot be applied leaves nothing applied.
        let mut tx = self.pool.begin().await?;
        // Retention writes a row per record: one event per tenant says how many, not one each.
        // (By the row's own scope: an exact `record` or `record-reset` row is not a retention purge.)
        let mut retention: BTreeMap<(String, String), (u64, u64)> = BTreeMap::new();
        for e in ordered {
            let k = key(e);
            if known.contains(&k) {
                rep.known += 1;
                continue;
            }
            let removed = match e.scope.as_str() {
                "record" | "record-reset" => {
                    let id = e.memory_id.ok_or_else(|| anyhow::anyhow!("a `{}` ledger row of {} without a memory id", e.scope, e.at.to_rfc3339()))?;
                    let removed = self.delete_exact_in(&mut tx, &e.tenant, id, e.scope == "record").await?;
                    // Whether or not the backup holds the record itself: a copy of it still
                    // queued leaves its proposal, and so does a queued promotion of it (the
                    // deletion took both), or the restored queue would write them again.
                    self.unqueue_in(&mut tx, &e.tenant, id, true).await?;
                    removed
                }
                "memory" | "retention" => {
                    let id = e.memory_id.ok_or_else(|| anyhow::anyhow!("a `{}` ledger row of {} without a memory id", e.scope, e.at.to_rfc3339()))?;
                    // Retention keeps what was promoted from a purged record; a deletion does not.
                    let removed = self.delete_in(&mut tx, &e.tenant, id, e.scope == "memory", false).await?.map_or(0, |d| d.ids.len() as u64);
                    // The backup may hold the record still queued: it leaves its proposal, or the
                    // restored queue would write it again.
                    self.unqueue_in(&mut tx, &e.tenant, id, false).await?;
                    removed
                }
                "subject" | "subject-reset" => {
                    let subject = e.subject.as_deref().ok_or_else(|| anyhow::anyhow!("a `{}` ledger row of {} without a subject", e.scope, e.at.to_rfc3339()))?;
                    self.erase_subject_in(&mut tx, &e.tenant, subject, e.scope == "subject", false).await?.0
                }
                _ => {
                    let mut n = 0;
                    let subjects: Vec<String> = sqlx::query_scalar("SELECT DISTINCT subject FROM mh_memory WHERE tenant = $1").bind(&e.tenant).fetch_all(&mut *tx).await?;
                    for s in subjects {
                        n += self.erase_subject_in(&mut tx, &e.tenant, &s, true, false).await?.0;
                    }
                    self.erase_tenant_rest(&mut tx, &e.tenant).await?;
                    n
                }
            };
            sqlx::query("INSERT INTO mh_deletion_ledger (at, tenant, subject, memory_id, scope, actor) VALUES ($1, $2, $3, $4, $5, $6)")
                .bind(e.at)
                .bind(&e.tenant)
                .bind(&e.subject)
                .bind(e.memory_id)
                .bind(&e.scope)
                .bind(&e.actor)
                .execute(&mut *tx)
                .await?;
            if e.scope == "retention" || e.scope.starts_with("record") {
                let t = retention.entry((e.tenant.clone(), e.scope.clone())).or_default();
                *t = (t.0 + 1, t.1 + removed);
            } else {
                let a = AuditEntry {
                    actor: actor.into(),
                    action: "deletion.reapply".into(),
                    subject: e.subject.clone(),
                    memory_id: e.memory_id,
                    detail: serde_json::json!({ "scope": e.scope, "deleted_at": e.at, "deleted_by": e.actor, "records": removed }),
                };
                self.audit_in(&mut tx, &e.tenant, &a).await?;
            }
            known.insert(k);
            rep.applied += 1;
            rep.records_removed += removed;
        }
        for ((t, scope), (entries, records)) in retention {
            let a = AuditEntry {
                actor: actor.into(),
                action: "deletion.reapply".into(),
                subject: None,
                memory_id: None,
                detail: serde_json::json!({ "scope": scope, "entries": entries, "records": records }),
            };
            self.audit_in(&mut tx, &t, &a).await?;
        }
        // A console session that was open when the backup was made may have been logged out
        // since: a restore brings none of them back (T3). Everyone logs in again.
        sqlx::query("DELETE FROM mh_session").execute(&mut *tx).await?;
        detail["ledger"] = serde_json::to_value(&rep)?;
        let a = AuditEntry { actor: actor.into(), action: "backup.restore".into(), subject: None, memory_id: None, detail };
        self.audit_in(&mut tx, tenant, &a).await?;
        tx.commit().await?;
        Ok(rep)
    }

    pub(crate) async fn rls(&self) -> anyhow::Result<serde_json::Value> {
        let mut names: Vec<String> = RLS_TABLES.iter().chain(RLS_SERVICE_TABLES.iter()).map(|t| t.to_string()).collect();
        names.extend(self.partitions().await?);
        if self.partitioned.load(std::sync::atomic::Ordering::Relaxed) {
            names.push("mh_memory_rest".into());
        }
        let rows: Vec<(String, bool, bool, i64)> = sqlx::query_as(
            "SELECT c.relname::text, c.relrowsecurity, c.relforcerowsecurity, (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) \
             FROM pg_class c WHERE c.oid = ANY(SELECT to_regclass(n) FROM unnest($1::text[]) n) ORDER BY 1",
        )
        .bind(&names)
        .fetch_all(&self.pool)
        .await?;
        let (role, bypass): (String, bool) =
            sqlx::query_as("SELECT current_user::text, (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user)").fetch_one(&self.pool).await?;
        let tables: Vec<serde_json::Value> =
            rows.iter().map(|(t, on, forced, policies)| serde_json::json!({ "table": t, "enabled": on, "forced": forced, "policies": policies })).collect();
        let all = !rows.is_empty() && rows.iter().all(|(_, on, forced, p)| *on && *forced && *p > 0);
        Ok(serde_json::json!({
            "configured": self.rls,
            "enabled_on_every_memory_table": all,
            "tables": tables,
            "service_role": role,
            // A superuser or a role with BYPASSRLS is not bound by any policy: the second line
            // then only stands for other roles.
            "service_role_bypasses": bypass,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partitions_are_named_by_month() {
        let m = NaiveDate::from_ymd_opt(2026, 11, 1).unwrap();
        assert_eq!(partition_name(m), "mh_memory_e202611");
        assert_eq!(partition_month("mh_memory_e202611"), Some(m));
        assert_eq!(partition_month("mh_memory_rest"), None);
        assert_eq!(partition_month("mh_memory_e2026xx"), None);
        assert_eq!(next_month(NaiveDate::from_ymd_opt(2026, 12, 1).unwrap()), NaiveDate::from_ymd_opt(2027, 1, 1).unwrap());
        assert_eq!(month_of(DateTime::from_timestamp(1_795_000_000, 0).unwrap()).day(), 1);
    }

    #[test]
    fn a_purge_rule_binds_its_scope_values() {
        let mut spec = PurgeSpec::older_than(MemoryKind::Episodic, 30);
        spec.scope = Some(ScopeMatch { level: memhouse_core::governance::ScopeLevel::Team, value: "legal'; DROP".into() });
        spec.except = vec![ScopeMatch { level: memhouse_core::governance::ScopeLevel::User, value: "user:ana".into() }];
        let (sql, values) = purge_filter(&spec);
        assert_eq!(sql, "m.created_at < now() - make_interval(days => $3) AND m.scope_team = $4 AND (m.scope_user IS NULL OR m.scope_user <> $5)");
        assert_eq!(values, vec!["legal'; DROP".to_string(), "user:ana".to_string()]);
        assert!(!sql.contains("DROP"));
    }
}
