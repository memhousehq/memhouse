// SPDX-License-Identifier: Apache-2.0
//! The Lite side of a migration between stores (`memhouse migrate`, TR-MIG-01): what the file
//! holds, its vectors as they are stored, and its tables row by row in the logical form of
//! `memhouse_core::migrate`; and opening a file as a migration's source, which never writes to it.

use crate::util::{exec, first, rows, uuid_of};
use crate::vector::from_half;
use crate::{meta, SqliteStore};
use memhouse_core::migrate::{table, Col, Queued, RecordCount, RecordVectors, Summary, Table, TABLES};
use rusqlite::types::{Value, ValueRef};
use rusqlite::{params, Connection, OpenFlags, TransactionBehavior};
use std::path::Path;
use uuid::Uuid;

/// The key under which a migration's marker is kept in `mh_meta`.
const MARKER: &str = "migration";

/// Held while a file is the source of a migration: the write lock, so nothing else writes to
/// the file meanwhile (another process's write waits, then fails). Nothing is written through it.
pub struct SourceLock {
    conn: Connection,
}

impl Drop for SourceLock {
    fn drop(&mut self) {
        let _ = self.conn.execute_batch("ROLLBACK;");
    }
}

/// A connection that leaves the file as it finds it: closing it folds no write-ahead log in.
fn untouching(path: &Path) -> anyhow::Result<Connection> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .map_err(|e| anyhow::anyhow!("cannot open the SQLite database {}: {e}", path.display()))?;
    conn.set_db_config(rusqlite::config::DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true)?;
    Ok(conn)
}

fn is_busy(e: &rusqlite::Error) -> bool {
    matches!(e.sqlite_error_code(), Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked))
}

impl SqliteStore {
    /// Open the file as the source of a migration: read-only, after checking that no other
    /// process has it open, and with the write lock held until the returned lock is dropped.
    /// A file of an older schema is not upgraded here (that would change it): the summary
    /// reports its version and the migration refuses it.
    pub fn open_source(path: &Path, passage_prefix: &str) -> anyhow::Result<(SqliteStore, SourceLock)> {
        anyhow::ensure!(path.is_file(), "there is no database at {}", path.display());
        crate::private_dir(path.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new(".")))?;
        const IN_USE: &str = "another process has it open: stop `memhouse serve` and the agents using it, then run the migration again";
        // In write-ahead mode every connection keeps a shared lock on the file for as long as it
        // is open, so asking for the file exclusively fails while any other process has it open,
        // idle or not. (A file in rollback-journal mode shows only a process that is in a
        // transaction at this moment.)
        {
            let probe = untouching(path)?;
            probe.execute_batch("PRAGMA locking_mode = EXCLUSIVE;")?;
            match probe.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0)) {
                Err(e) if is_busy(&e) => anyhow::bail!("the database {} is in use; {IN_USE}", path.display()),
                Err(e) => anyhow::bail!("{} is not a MemHouse database: {e}", path.display()),
                Ok(_) => {}
            }
        }
        let conn = untouching(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(2))?;
        match conn.execute_batch("BEGIN IMMEDIATE;") {
            Err(e) if is_busy(&e) => anyhow::bail!("the database {} is being written to; {IN_USE}", path.display()),
            other => other?,
        }
        Ok((SqliteStore::open_read_only(path, passage_prefix)?, SourceLock { conn }))
    }

    pub(crate) fn vectors_of(&self, tenant: &str, ids: &[Uuid]) -> anyhow::Result<Vec<RecordVectors>> {
        let half = |r: &rusqlite::Row, i: usize| -> anyhow::Result<Option<Vec<f32>>> { Ok(r.get_ref(i)?.as_blob_or_null()?.map(from_half)) };
        rows(
            &self.read(),
            // By id: `+` keeps the planner off the tenant's index, which would read the whole tenant.
            "SELECT id, embedding, embedding_alt FROM mh_memory WHERE id IN (SELECT value FROM json_each(?2)) AND +tenant = ?1",
            params![tenant, crate::util::ids_json(ids)],
            |r| Ok(RecordVectors { id: uuid_of(&r.get::<_, String>(0)?)?, embedding: half(r, 1)?, alt: half(r, 2)? }),
        )
    }

    pub(crate) fn summary(&self) -> anyhow::Result<Summary> {
        let c = self.read();
        // One state of the file for every number.
        let c = c.unchecked_transaction()?;
        let Some(version) = meta(&c, "schema_version")? else { return Ok(Summary::default()) };
        let count = |sql: &str| -> anyhow::Result<u64> { Ok(first(&c, sql, [], |r| Ok(r.get::<_, i64>(0)?))?.unwrap_or(0) as u64) };
        // A file of an older schema may lack a table: it counts as empty, and the version is what is reported.
        let has = |t: &str| -> anyhow::Result<bool> { Ok(first(&c, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [t], |_| Ok(()))?.is_some()) };
        let mut s = Summary { schema_version: version.parse().ok(), ..Default::default() };
        s.records = rows(&c, "SELECT tenant, kind, status, count(*) FROM mh_memory GROUP BY 1, 2, 3 ORDER BY 1, 2, 3", [], |r| {
            Ok(RecordCount { tenant: r.get(0)?, kind: r.get(1)?, status: r.get(2)?, records: r.get::<_, i64>(3)? as u64 })
        })?;
        (s.vectors, s.second_vectors, s.last_change) = first(&c, "SELECT count(embedding), count(embedding_alt), max(updated_at) FROM mh_memory", [], |r| {
            Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64, r.get(2)?))
        })?
        .unwrap_or_default();
        for t in TABLES {
            let n = if has(&format!("mh_{}", t.name))? { count(&format!("SELECT count(*) FROM mh_{}", t.name))? } else { 0 };
            s.tables.insert(t.name.into(), n);
        }
        for t in ["embed_cache", "llm_cache", "recall", "request_key"] {
            let n = if has(&format!("mh_{t}"))? { count(&format!("SELECT count(*) FROM mh_{t}"))? } else { 0 };
            s.left_behind.insert(t.into(), n);
        }
        let now = crate::util::now();
        let queue = |t: &str| -> anyhow::Result<(u64, u64, Option<i64>)> {
            if !has(t)? {
                return Ok((0, 0, None));
            }
            // A claim that has run out is work waiting again.
            Ok(first(
                &c,
                &format!(
                    "SELECT coalesce(sum(status = 'pending' OR (status = 'running' AND coalesce(locked_until, 0) <= ?1)), 0), \
                            coalesce(sum(status = 'running' AND locked_until > ?1), 0), max(CASE WHEN status = 'running' AND locked_until > ?1 THEN locked_until END) FROM {t}"
                ),
                [now],
                |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64, r.get(2)?)),
            )?
            .unwrap_or_default())
        };
        let (intake, enrich) = (queue("mh_intake")?, queue("mh_enrich_job")?);
        s.queued = Queued {
            intake_pending: intake.0,
            intake_leased: intake.1,
            intake_dead: if has("mh_intake")? { count("SELECT count(*) FROM mh_intake WHERE status = 'dead'")? } else { 0 },
            enrich_pending: enrich.0,
            enrich_leased: enrich.1,
            leased_until: intake.2.max(enrich.2),
        };
        // Candidates by their text, then looked at exactly: `\u0000` in JSON text is also how a
        // backslash followed by "u0000" is written, which is no NUL.
        let suspects = rows(
            &c,
            "SELECT m.content, m.metadata, s.attrs FROM mh_memory m LEFT JOIN mh_structured s ON s.memory_id = m.id \
             WHERE instr(m.content, char(0)) > 0 OR instr(m.metadata, '\\u0000') > 0 OR instr(coalesce(s.attrs, ''), '\\u0000') > 0",
            [],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?)),
        )?;
        let nul = |json: &str| serde_json::from_str::<serde_json::Value>(json).map(|v| has_nul(&v)).unwrap_or(true);
        s.nul_records = suspects.iter().filter(|(content, metadata, attrs)| content.contains('\0') || nul(metadata) || attrs.as_deref().is_some_and(nul)).count() as u64;
        s.audit_head = first(&c, "SELECT id, hash FROM mh_audit ORDER BY id DESC LIMIT 1", [], |r| Ok((r.get(0)?, r.get(1)?)))?;
        let pages: i64 = c.query_row("PRAGMA page_count", [], |r| r.get(0))?;
        let page: i64 = c.query_row("PRAGMA page_size", [], |r| r.get(0))?;
        s.size_bytes = Some((pages * page) as u64);
        Ok(s)
    }

    pub(crate) fn dump(&self, name: &str, after: Option<&serde_json::Value>, limit: usize) -> anyhow::Result<Vec<serde_json::Value>> {
        let t = table(name)?;
        let cols = t.cols.iter().map(|(c, _)| format!("\"{c}\"")).collect::<Vec<_>>().join(", ");
        let key = t.key.iter().map(|k| format!("\"{k}\"")).collect::<Vec<_>>().join(", ");
        let mut binds: Vec<Value> = vec![];
        let mut sql = format!("SELECT {cols} FROM mh_{name}");
        if let Some(row) = after {
            for k in t.key {
                binds.push(to_sql(col_of(t, k), &row[*k])?);
            }
            sql += &format!(" WHERE ({key}) > ({})", (1..=t.key.len()).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", "));
        }
        binds.push(Value::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        sql += &format!(" ORDER BY {key} LIMIT ?{}", binds.len());
        rows(&self.read(), &sql, rusqlite::params_from_iter(binds), |r| {
            let mut row = serde_json::Map::new();
            for (i, (c, ty)) in t.cols.iter().enumerate() {
                row.insert((*c).into(), from_sql(*ty, r.get_ref(i)?).map_err(|e| anyhow::anyhow!("mh_{name}.{c}: {e}"))?);
            }
            Ok(serde_json::Value::Object(row))
        })
    }

    pub(crate) fn load(&self, name: &str, rows: &[serde_json::Value]) -> anyhow::Result<u64> {
        let t = table(name)?;
        let sql = format!(
            "INSERT INTO mh_{name} ({}) VALUES ({}) ON CONFLICT DO NOTHING",
            t.cols.iter().map(|(c, _)| format!("\"{c}\"")).collect::<Vec<_>>().join(", "),
            (1..=t.cols.len()).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
        );
        let mut c = self.conn();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut n = 0;
        for row in rows {
            let values = t.cols.iter().map(|(c, ty)| to_sql(*ty, &row[*c]).map_err(|e| anyhow::anyhow!("mh_{name}.{c}: {e}"))).collect::<anyhow::Result<Vec<Value>>>()?;
            n += exec(&tx, &sql, rusqlite::params_from_iter(values)).map_err(|e| self.explain(&tx, e))?;
        }
        tx.commit()?;
        Ok(n)
    }

    pub(crate) fn marker(&self) -> anyhow::Result<Option<serde_json::Value>> {
        Ok(meta(&self.read(), MARKER)?.map(|v| serde_json::from_str(&v)).transpose()?)
    }

    pub(crate) fn set_marker(&self, marker: &serde_json::Value) -> anyhow::Result<()> {
        exec(&self.conn(), "INSERT INTO mh_meta (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [MARKER, marker.to_string().as_str()])?;
        Ok(())
    }
}

fn has_nul(v: &serde_json::Value) -> bool {
    match v {
        serde_json::Value::String(s) => s.contains('\0'),
        serde_json::Value::Array(a) => a.iter().any(has_nul),
        serde_json::Value::Object(o) => o.iter().any(|(k, v)| k.contains('\0') || has_nul(v)),
        _ => false,
    }
}

fn col_of(t: &Table, name: &str) -> Col {
    t.cols.iter().find(|(c, _)| *c == name).map(|(_, ty)| *ty).unwrap_or(Col::Text)
}

/// A stored value in the logical form of a migration row.
fn from_sql(ty: Col, v: ValueRef<'_>) -> anyhow::Result<serde_json::Value> {
    use serde_json::Value as J;
    Ok(match (ty, v) {
        (_, ValueRef::Null) => J::Null,
        (Col::Text, ValueRef::Text(t)) => J::String(std::str::from_utf8(t)?.to_string()),
        (Col::Int | Col::Time, ValueRef::Integer(n)) => J::from(n),
        (Col::Bool, ValueRef::Integer(n)) => J::Bool(n != 0),
        (Col::Json | Col::Texts, ValueRef::Text(t)) => serde_json::from_slice(t)?,
        (Col::Uuid, ValueRef::Text(t)) => J::String(uuid_of(std::str::from_utf8(t)?)?.to_string()),
        (Col::Uuids, ValueRef::Text(t)) => J::from(crate::util::uuids(std::str::from_utf8(t)?)?.iter().map(Uuid::to_string).collect::<Vec<_>>()),
        (Col::Bytes, ValueRef::Blob(b)) => J::String(hex::encode(b)),
        (ty, other) => anyhow::bail!("a {:?} value where a {ty:?} column is expected", other.data_type()),
    })
}

/// A value of a migration row as this store keeps it.
fn to_sql(ty: Col, v: &serde_json::Value) -> anyhow::Result<Value> {
    use serde_json::Value as J;
    let bad = || anyhow::anyhow!("{v} is not a {ty:?} value");
    Ok(match (ty, v) {
        (_, J::Null) => Value::Null,
        (Col::Text, J::String(s)) => Value::Text(s.clone()),
        (Col::Int | Col::Time, J::Number(n)) => Value::Integer(n.as_i64().ok_or_else(bad)?),
        (Col::Bool, J::Bool(b)) => Value::Integer(i64::from(*b)),
        (Col::Json, v) => Value::Text(v.to_string()),
        (Col::Texts | Col::Uuids, J::Array(_)) => Value::Text(v.to_string()),
        (Col::Uuid, J::String(s)) => Value::Text(Uuid::parse_str(s)?.to_string()),
        (Col::Bytes, J::String(s)) => Value::Blob(hex::decode(s)?),
        _ => return Err(bad()),
    })
}
