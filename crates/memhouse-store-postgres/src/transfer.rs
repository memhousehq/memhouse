// SPDX-License-Identifier: Apache-2.0
//! The Standard side of a migration between stores (`memhouse migrate`, TR-MIG-01): what the
//! database holds, its vectors as they are stored, and its tables row by row in the logical
//! form of `memhouse_core::migrate`. Statements are built from that module's table and column
//! names only; every value is bound.

use crate::PgStore;
use chrono::{DateTime, Utc};
use memhouse_core::migrate::{table, Col, Queued, RecordCount, RecordVectors, Summary, Table, TABLES};
use memhouse_core::Store;
use sqlx::postgres::{PgArguments, PgRow};
use sqlx::Row;
use uuid::Uuid;

/// The key under which a migration's marker is kept in `mh_meta`.
const MARKER: &str = "migration";

type Query<'q> = sqlx::query::Query<'q, sqlx::Postgres, PgArguments>;

fn col_of(t: &Table, name: &str) -> Col {
    t.cols.iter().find(|(c, _)| *c == name).map(|(_, ty)| *ty).unwrap_or(Col::Text)
}

fn micros(v: &serde_json::Value) -> anyhow::Result<Option<DateTime<Utc>>> {
    match v {
        serde_json::Value::Null => Ok(None),
        v => {
            let us = v.as_i64().ok_or_else(|| anyhow::anyhow!("{v} is not a time in microseconds"))?;
            Ok(Some(DateTime::from_timestamp_micros(us).ok_or_else(|| anyhow::anyhow!("{us} microseconds is outside the range of a timestamp"))?))
        }
    }
}

fn text(v: &serde_json::Value) -> anyhow::Result<Option<String>> {
    match v {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::String(s) => Ok(Some(s.clone())),
        v => anyhow::bail!("{v} is not a text"),
    }
}

fn texts(v: &serde_json::Value) -> anyhow::Result<Option<Vec<String>>> {
    match v {
        serde_json::Value::Null => Ok(None),
        v => Ok(Some(serde_json::from_value(v.clone())?)),
    }
}

fn uuid(v: &serde_json::Value) -> anyhow::Result<Option<Uuid>> {
    text(v)?.map(|s| Ok(Uuid::parse_str(&s)?)).transpose()
}

fn uuids(v: &serde_json::Value) -> anyhow::Result<Option<Vec<Uuid>>> {
    texts(v)?.map(|l| l.iter().map(|s| Ok(Uuid::parse_str(s)?)).collect()).transpose()
}

/// Bind one value of a migration row as the type its column has here.
fn bind<'q>(q: Query<'q>, ty: Col, v: &serde_json::Value) -> anyhow::Result<Query<'q>> {
    Ok(match ty {
        Col::Text => q.bind(text(v)?),
        Col::Int => q.bind(match v {
            serde_json::Value::Null => None,
            v => Some(v.as_i64().ok_or_else(|| anyhow::anyhow!("{v} is not an integer"))?),
        }),
        Col::Bool => q.bind(match v {
            serde_json::Value::Null => None,
            v => Some(v.as_bool().ok_or_else(|| anyhow::anyhow!("{v} is not a boolean"))?),
        }),
        Col::Time => q.bind(micros(v)?),
        Col::Json => q.bind(if v.is_null() { None } else { Some(v.clone()) }),
        Col::Texts => q.bind(texts(v)?),
        Col::Uuid => q.bind(uuid(v)?),
        Col::Uuids => q.bind(uuids(v)?),
        Col::Bytes => q.bind(text(v)?.map(hex::decode).transpose()?),
    })
}

/// A placeholder with the cast that makes its type unambiguous to the planner.
fn placeholder(ty: Col, n: usize) -> String {
    match ty {
        Col::Text => format!("${n}::text"),
        // Narrower integer columns take it by assignment.
        Col::Int => format!("${n}::bigint"),
        Col::Bool => format!("${n}::bool"),
        Col::Time => format!("${n}::timestamptz"),
        Col::Json => format!("${n}::jsonb"),
        Col::Texts => format!("${n}::text[]"),
        Col::Uuid => format!("${n}::uuid"),
        Col::Uuids => format!("${n}::uuid[]"),
        Col::Bytes => format!("${n}::bytea"),
    }
}

/// A stored value in the logical form of a migration row.
fn cell(r: &PgRow, i: usize, ty: Col) -> anyhow::Result<serde_json::Value> {
    use serde_json::Value as J;
    Ok(match ty {
        Col::Text => r.try_get::<Option<String>, _>(i)?.map_or(J::Null, J::String),
        Col::Int => r.try_get::<Option<i64>, _>(i)?.map_or(J::Null, J::from),
        Col::Bool => r.try_get::<Option<bool>, _>(i)?.map_or(J::Null, J::Bool),
        Col::Time => r.try_get::<Option<DateTime<Utc>>, _>(i)?.map_or(J::Null, |t| J::from(t.timestamp_micros())),
        Col::Json => r.try_get::<Option<J>, _>(i)?.unwrap_or(J::Null),
        Col::Texts => r.try_get::<Option<Vec<String>>, _>(i)?.map_or(J::Null, J::from),
        Col::Uuid => r.try_get::<Option<Uuid>, _>(i)?.map_or(J::Null, |u| J::String(u.to_string())),
        Col::Uuids => r.try_get::<Option<Vec<Uuid>>, _>(i)?.map_or(J::Null, |l| J::from(l.iter().map(Uuid::to_string).collect::<Vec<_>>())),
        Col::Bytes => r.try_get::<Option<Vec<u8>>, _>(i)?.map_or(J::Null, |b| J::String(hex::encode(b))),
    })
}

impl PgStore {
    pub(crate) async fn vectors_of(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<RecordVectors>> {
        let rows = sqlx::query("SELECT id, embedding::real[] AS embedding, embedding_alt::real[] AS alt FROM mh_memory WHERE tenant = $1 AND id = ANY($2)")
            .bind(tenant)
            .bind(ids)
            .fetch_all(&self.pool)
            .await?;
        rows.iter().map(|r| Ok(RecordVectors { id: r.try_get("id")?, embedding: r.try_get("embedding")?, alt: r.try_get("alt")? })).collect()
    }

    /// Sessions on this database besides the one asking: a server that still has it open is
    /// among them. Asked before the pool opens a second connection of its own.
    pub async fn other_sessions(&self) -> anyhow::Result<i64> {
        Ok(sqlx::query_scalar("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'")
            .fetch_one(&self.pool)
            .await?)
    }

    async fn has_table(&self, name: &str) -> anyhow::Result<bool> {
        Ok(sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL").bind(name).fetch_one(&self.pool).await?)
    }

    pub(crate) async fn summary(&self) -> anyhow::Result<Summary> {
        let Some(version) = self.meta("schema_version").await? else { return Ok(Summary::default()) };
        let mut s = Summary { schema_version: version.parse().ok(), ..Default::default() };
        (s.identity, s.reembed_target) = self.embedding_identity().await?;
        let rows = sqlx::query("SELECT tenant, kind, status, count(*) AS n FROM mh_memory GROUP BY 1, 2, 3").fetch_all(&self.pool).await?;
        for r in &rows {
            s.records.push(RecordCount { tenant: r.try_get("tenant")?, kind: r.try_get("kind")?, status: r.try_get("status")?, records: r.try_get::<i64, _>("n")? as u64 });
        }
        // By bytes, as the other store orders them: the database's collation is its own.
        s.records.sort_by(|a, b| (&a.tenant, &a.kind, &a.status).cmp(&(&b.tenant, &b.kind, &b.status)));
        let r = sqlx::query(
            "SELECT count(embedding) AS v, count(embedding_alt) AS a, max(updated_at) AS last, \
             sum((extract(epoch FROM updated_at) * 1000000)::bigint % 1000000007)::bigint AS changes FROM mh_memory",
        )
        .fetch_one(&self.pool)
        .await?;
        s.vectors = r.try_get::<i64, _>("v")? as u64;
        s.second_vectors = r.try_get::<i64, _>("a")? as u64;
        s.last_change = r.try_get::<Option<DateTime<Utc>>, _>("last")?.map(|t| t.timestamp_micros());
        s.change_sum = r.try_get("changes")?;
        let names = TABLES.iter().map(|t| (t.name, true)).chain(["embed_cache", "llm_cache", "recall", "request_key"].map(|t| (t, false)));
        for (name, moves) in names {
            // A database of an older schema may lack a table: it counts as empty.
            let n: i64 = if self.has_table(&format!("mh_{name}")).await? {
                sqlx::query_scalar(sqlx::AssertSqlSafe(format!("SELECT count(*) FROM mh_{name}"))).fetch_one(&self.pool).await?
            } else {
                0
            };
            if moves { &mut s.tables } else { &mut s.left_behind }.insert(name.into(), n as u64);
        }
        let mut queue = [(0u64, 0u64, None::<i64>); 2];
        for (i, t) in ["mh_intake", "mh_enrich_job"].iter().enumerate() {
            if !self.has_table(t).await? {
                continue;
            }
            // A claim that has run out is work waiting again.
            let r = sqlx::query(sqlx::AssertSqlSafe(format!(
                "SELECT count(*) FILTER (WHERE status = 'pending' OR (status = 'running' AND coalesce(locked_until, '-infinity') <= now())) AS pending, \
                        count(*) FILTER (WHERE status = 'running' AND locked_until > now()) AS leased, \
                        max(locked_until) FILTER (WHERE status = 'running' AND locked_until > now()) AS until FROM {t}"
            )))
            .fetch_one(&self.pool)
            .await?;
            queue[i] =
                (r.try_get::<i64, _>("pending")? as u64, r.try_get::<i64, _>("leased")? as u64, r.try_get::<Option<DateTime<Utc>>, _>("until")?.map(|t| t.timestamp_micros()));
        }
        let dead: i64 =
            if self.has_table("mh_intake").await? { sqlx::query_scalar("SELECT count(*) FROM mh_intake WHERE status = 'dead'").fetch_one(&self.pool).await? } else { 0 };
        s.queued = Queued {
            intake_pending: queue[0].0,
            intake_leased: queue[0].1,
            intake_dead: dead as u64,
            enrich_pending: queue[1].0,
            enrich_leased: queue[1].1,
            leased_until: queue[0].2.max(queue[1].2),
        };
        // Postgres stores no NUL character in text or JSON: there is none to find.
        s.nul_records = 0;
        s.audit_head = sqlx::query_as("SELECT id, hash FROM mh_audit ORDER BY id DESC LIMIT 1").fetch_optional(&self.pool).await?;
        s.size_bytes = sqlx::query_scalar::<_, i64>("SELECT pg_database_size(current_database())").fetch_optional(&self.pool).await?.map(|n| n as u64);
        Ok(s)
    }

    pub(crate) async fn dump(&self, name: &str, after: Option<&serde_json::Value>, limit: usize) -> anyhow::Result<Vec<serde_json::Value>> {
        let t = table(name)?;
        let cols = t.cols.iter().map(|(c, ty)| if *ty == Col::Int { format!("\"{c}\"::bigint") } else { format!("\"{c}\"") }).collect::<Vec<_>>().join(", ");
        let key = t.key.iter().map(|k| format!("\"{k}\"")).collect::<Vec<_>>().join(", ");
        let mut sql = format!("SELECT {cols} FROM mh_{name}");
        if after.is_some() {
            let marks = t.key.iter().enumerate().map(|(i, k)| placeholder(col_of(t, k), i + 1)).collect::<Vec<_>>().join(", ");
            sql += &format!(" WHERE ({key}) > ({marks})");
        }
        sql += &format!(" ORDER BY {key} LIMIT {}", i64::try_from(limit).unwrap_or(i64::MAX));
        let mut q = sqlx::query(sqlx::AssertSqlSafe(sql));
        if let Some(row) = after {
            for k in t.key {
                q = bind(q, col_of(t, k), &row[*k])?;
            }
        }
        let rows = q.fetch_all(&self.pool).await?;
        rows.iter()
            .map(|r| {
                let mut row = serde_json::Map::new();
                for (i, (c, ty)) in t.cols.iter().enumerate() {
                    row.insert((*c).into(), cell(r, i, *ty).map_err(|e| anyhow::anyhow!("mh_{name}.{c}: {e}"))?);
                }
                Ok(serde_json::Value::Object(row))
            })
            .collect()
    }

    pub(crate) async fn load(&self, name: &str, rows: &[serde_json::Value]) -> anyhow::Result<u64> {
        let t = table(name)?;
        let cols = t.cols.iter().map(|(c, _)| format!("\"{c}\"")).collect::<Vec<_>>().join(", ");
        let mut tx = self.pool.begin().await?;
        let mut n = 0;
        // Postgres takes at most 65,535 parameters in a statement.
        for chunk in rows.chunks((60_000 / t.cols.len()).clamp(1, 1000)) {
            let values = (0..chunk.len())
                .map(|r| format!("({})", t.cols.iter().enumerate().map(|(c, (_, ty))| placeholder(*ty, r * t.cols.len() + c + 1)).collect::<Vec<_>>().join(", ")))
                .collect::<Vec<_>>()
                .join(", ");
            let mut q = sqlx::query(sqlx::AssertSqlSafe(format!("INSERT INTO mh_{name} ({cols}) VALUES {values} ON CONFLICT DO NOTHING")));
            for row in chunk {
                for (c, ty) in t.cols {
                    q = bind(q, *ty, &row[*c]).map_err(|e| anyhow::anyhow!("mh_{name}.{c}: {e}"))?;
                }
            }
            n += q.execute(&mut *tx).await?.rows_affected();
        }
        if t.serial {
            // The rows kept their numbers: the next one the database assigns comes after them.
            let key = t.key[0];
            sqlx::query(sqlx::AssertSqlSafe(format!(
                "SELECT setval(pg_get_serial_sequence('mh_{name}', '{key}'), max(\"{key}\")) FROM mh_{name} HAVING max(\"{key}\") IS NOT NULL"
            )))
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(n)
    }

    pub(crate) async fn marker(&self) -> anyhow::Result<Option<serde_json::Value>> {
        Ok(self.meta(MARKER).await?.map(|v| serde_json::from_str(&v)).transpose()?)
    }

    pub(crate) async fn set_marker(&self, marker: &serde_json::Value) -> anyhow::Result<()> {
        sqlx::query("INSERT INTO mh_meta (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = excluded.value")
            .bind(MARKER)
            .bind(marker.to_string())
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
