// SPDX-License-Identifier: Apache-2.0
//! What makes the governance suite store-neutral: a fresh, empty store of the profile under
//! test (a scratch Postgres database, or an SQLite file in a private directory), and a raw look
//! at its tables for the facts the `Store` trait does not give.
//!
//! The two stores have the same logical schema (table and column names) and different physical
//! types, so a check states its query once when the SQL means the same on both ([`Sql::same`])
//! and once per store when it does not ([`Sql::each`]): never a query that merely runs.

use memhouse_core::traits::Store;
use memhouse_core::Engine;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

/// The deployment profile of the store under test (strategy: Standard on Postgres, Lite on SQLite).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Profile {
    Postgres,
    Sqlite,
}

impl Profile {
    pub(crate) fn of_url(url: &str) -> Profile {
        if memhouse_server::sqlite_path(url).is_some() {
            Profile::Sqlite
        } else {
            Profile::Postgres
        }
    }

    pub(crate) fn of(engine: &Engine) -> Profile {
        Profile::of_url(&engine.cfg.database.url)
    }

    /// The name in reports and in `bench/baselines.json`.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Profile::Postgres => "postgres",
            Profile::Sqlite => "sqlite",
        }
    }

    /// The name in a check's title.
    pub(crate) fn title(self) -> &'static str {
        match self {
            Profile::Postgres => "Postgres",
            Profile::Sqlite => "SQLite",
        }
    }
}

/// A check that proves nothing on this profile because what it inspects does not exist there.
/// Raised as an error by the check and turned into a not-applicable result, never into a pass.
#[derive(Debug)]
pub(crate) struct NotApplicable(pub(crate) String);

impl std::fmt::Display for NotApplicable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "not applicable to this profile: {}", self.0)
    }
}

impl std::error::Error for NotApplicable {}

/// `Err(NotApplicable)` when the engine under test is on SQLite: for checks of something only
/// the Postgres store has. The reason is shown in the report.
pub(crate) fn postgres_only(engine: &Engine, reason: &str) -> anyhow::Result<()> {
    match Profile::of(engine) {
        Profile::Postgres => Ok(()),
        Profile::Sqlite => Err(anyhow::Error::new(NotApplicable(reason.to_string()))),
    }
}

/// The store at `url`, opened the way the checks need it: several of them open a second engine
/// on a database another one is changing, so nothing about the database's identity is cached.
pub(crate) async fn open_store(url: &str, connections: u32, passage_prefix: &str) -> anyhow::Result<Arc<dyn Store>> {
    Ok(match memhouse_server::sqlite_path(url) {
        // The SQLite store reads the database's identity with every statement that depends on it.
        Some(path) => Arc::new(memhouse_store_sqlite::SqliteStore::open(&path, passage_prefix)?),
        None => Arc::new(memhouse_store_postgres::PgStore::connect(url, connections, passage_prefix).await?.with_identity_recheck(std::time::Duration::ZERO)),
    })
}

/// `open_store` with what a deployment can turn on in its Postgres database (row-level
/// security, monthly episodic partitions); a SQLite store has neither.
pub(crate) async fn open_store_with(url: &str, connections: u32, options: memhouse_store_postgres::PgOptions) -> anyhow::Result<Arc<dyn Store>> {
    Ok(match memhouse_server::sqlite_path(url) {
        Some(path) => Arc::new(memhouse_store_sqlite::SqliteStore::open(&path, "")?),
        None => Arc::new(memhouse_store_postgres::PgStore::connect_with(url, connections, "", options).await?.with_identity_recheck(std::time::Duration::ZERO)),
    })
}

/// A fresh database next to the benchmark one, for checks that change a whole database.
pub(crate) struct Scratch {
    pub(crate) url: String,
    place: Place,
}

enum Place {
    Postgres {
        admin: sqlx::PgPool,
        db: String,
    },
    /// A directory of the user's own (the SQLite store refuses any other), removed with the scratch.
    Sqlite {
        dir: PathBuf,
    },
}

impl Scratch {
    pub(crate) async fn create(engine: &Engine, suffix: &str) -> anyhow::Result<Scratch> {
        Scratch::create_as(Profile::of(engine), engine, suffix).await
    }

    /// A scratch store of the profile asked for, whatever the engine under test runs on: for the
    /// checks that move data between profiles. A Postgres one is made next to the engine's
    /// database, so it needs the engine to be on Postgres.
    pub(crate) async fn create_as(profile: Profile, engine: &Engine, suffix: &str) -> anyhow::Result<Scratch> {
        match profile {
            Profile::Postgres => {
                anyhow::ensure!(Profile::of(engine) == Profile::Postgres, "a scratch Postgres database is created beside the engine's, which is not on Postgres");
                let admin = sqlx::postgres::PgPoolOptions::new().max_connections(1).connect(&engine.cfg.database.url).await?;
                let db: String = sqlx::query_scalar("SELECT current_database() || '_' || $1").bind(suffix).fetch_one(&admin).await?;
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP DATABASE IF EXISTS \"{db}\" WITH (FORCE)"))).execute(&admin).await?;
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE DATABASE \"{db}\""))).execute(&admin).await?;
                let (head, tail) = engine.cfg.database.url.rsplit_once('/').ok_or_else(|| anyhow::anyhow!("unexpected database url"))?;
                let query = tail.split_once('?').map(|(_, q)| format!("?{q}")).unwrap_or_default();
                Ok(Scratch { url: format!("{head}/{db}{query}"), place: Place::Postgres { admin, db } })
            }
            Profile::Sqlite => {
                // A new name every time: nothing of an earlier run is ever opened.
                let dir = std::env::temp_dir().join(format!("memhouse-gov-{suffix}-{}", Uuid::now_v7().simple()));
                memhouse_store_sqlite::private_dir(&dir)?;
                Ok(Scratch { url: format!("sqlite:{}", dir.join("scratch.db").display()), place: Place::Sqlite { dir } })
            }
        }
    }

    pub(crate) fn profile(&self) -> Profile {
        match self.place {
            Place::Postgres { .. } => Profile::Postgres,
            Place::Sqlite { .. } => Profile::Sqlite,
        }
    }

    /// A second, empty database beside this one, gone with it (SQLite: another file of the
    /// same directory). Only where a check needs one for a single step.
    pub(crate) fn sqlite_sibling(&self, name: &str) -> Option<String> {
        match &self.place {
            Place::Sqlite { dir } => Some(format!("sqlite:{}", dir.join(format!("{name}.db")).display())),
            Place::Postgres { .. } => None,
        }
    }

    /// A copy of this database as it is now, under another name: what a backup taken at this
    /// moment restores to. Postgres copies the database as a template, for which nothing else
    /// may be connected to it: the sessions of the checks' own pools are ended first (a pool
    /// opens new ones when it is next used). SQLite takes a consistent snapshot of the file.
    pub(crate) async fn copy(&self, suffix: &str) -> anyhow::Result<Scratch> {
        match &self.place {
            Place::Postgres { admin, db } => {
                let copy = format!("{db}_{suffix}");
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP DATABASE IF EXISTS \"{copy}\" WITH (FORCE)"))).execute(admin).await?;
                let mut made = Ok(());
                // A pool may reconnect between the two statements: tried a few times.
                for _ in 0..5 {
                    sqlx::query("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()").bind(db).execute(admin).await?;
                    made = sqlx::raw_sql(sqlx::AssertSqlSafe(format!("CREATE DATABASE \"{copy}\" TEMPLATE \"{db}\""))).execute(admin).await.map(|_| ());
                    if made.is_ok() {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                }
                made?;
                let (head, tail) = self.url.rsplit_once('/').ok_or_else(|| anyhow::anyhow!("unexpected database url"))?;
                let query = tail.split_once('?').map(|(_, q)| format!("?{q}")).unwrap_or_default();
                Ok(Scratch { url: format!("{head}/{copy}{query}"), place: Place::Postgres { admin: admin.clone(), db: copy } })
            }
            Place::Sqlite { dir } => {
                let to = std::env::temp_dir().join(format!("memhouse-gov-{suffix}-{}", Uuid::now_v7().simple()));
                memhouse_store_sqlite::private_dir(&to)?;
                memhouse_store_sqlite::SqliteStore::open(&dir.join("scratch.db"), "")?.snapshot_to(&to.join("scratch.db"))?;
                Ok(Scratch { url: format!("sqlite:{}", to.join("scratch.db").display()), place: Place::Sqlite { dir: to } })
            }
        }
    }

    /// A raw look at this database, on a connection of the check's own.
    pub(crate) async fn db(&self) -> anyhow::Result<Db> {
        Db::open(&self.url).await
    }

    pub(crate) async fn drop(self) -> anyhow::Result<()> {
        match self.place {
            Place::Postgres { admin, db } => {
                sqlx::raw_sql(sqlx::AssertSqlSafe(format!("DROP DATABASE IF EXISTS \"{db}\" WITH (FORCE)"))).execute(&admin).await?;
            }
            Place::Sqlite { dir } => {
                let _ = std::fs::remove_dir_all(&dir);
            }
        }
        Ok(())
    }
}

/// One query for both stores, or one for each.
#[derive(Clone, Copy)]
pub(crate) struct Sql<'a> {
    postgres: &'a str,
    sqlite: Option<&'a str>,
}

impl<'a> Sql<'a> {
    /// The statement means the same on both stores as written (`$1` is read as `?1` by SQLite).
    pub(crate) fn same(sql: &'a str) -> Sql<'a> {
        Sql { postgres: sql, sqlite: None }
    }

    /// The Postgres statement, and the SQLite statement that establishes the same fact.
    pub(crate) fn each(postgres: &'a str, sqlite: &'a str) -> Sql<'a> {
        Sql { postgres, sqlite: Some(sqlite) }
    }

    fn for_sqlite(&self) -> String {
        match self.sqlite {
            Some(s) => s.to_string(),
            None => numbered(self.postgres),
        }
    }
}

/// `$1` → `?1`: SQLite's numbered parameters.
fn numbered(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len());
    let mut chars = sql.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '$' && chars.peek().is_some_and(|n| n.is_ascii_digit()) {
            out.push('?');
        } else {
            out.push(c);
        }
    }
    out
}

/// A bound value. Ids are `uuid` in Postgres and text in SQLite; a list of ids is a `uuid[]`
/// in Postgres and a JSON array of texts in SQLite (read with `json_each`).
#[derive(Debug, Clone)]
pub(crate) enum Arg {
    Text(String),
    Int(i64),
    /// Where Postgres wants an `int4` (a function argument, an `integer` column).
    Int32(i32),
    Id(Uuid),
    Ids(Vec<Uuid>),
}

impl From<&str> for Arg {
    fn from(s: &str) -> Arg {
        Arg::Text(s.to_string())
    }
}
impl From<String> for Arg {
    fn from(s: String) -> Arg {
        Arg::Text(s)
    }
}
impl From<&String> for Arg {
    fn from(s: &String) -> Arg {
        Arg::Text(s.clone())
    }
}
impl From<i64> for Arg {
    fn from(n: i64) -> Arg {
        Arg::Int(n)
    }
}
impl From<i32> for Arg {
    fn from(n: i32) -> Arg {
        Arg::Int32(n)
    }
}
impl From<Uuid> for Arg {
    fn from(id: Uuid) -> Arg {
        Arg::Id(id)
    }
}
impl From<&[Uuid]> for Arg {
    fn from(ids: &[Uuid]) -> Arg {
        Arg::Ids(ids.to_vec())
    }
}
impl From<&Vec<Uuid>> for Arg {
    fn from(ids: &Vec<Uuid>) -> Arg {
        Arg::Ids(ids.clone())
    }
}

/// One value of a result row. Booleans are integers (as SQLite has them); ids and JSON are text.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Cell {
    Null,
    Int(i64),
    Real(f64),
    Text(String),
}

impl Cell {
    pub(crate) fn int(&self) -> Option<i64> {
        match self {
            Cell::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub(crate) fn bool(&self) -> Option<bool> {
        self.int().map(|n| n != 0)
    }

    pub(crate) fn text(&self) -> Option<String> {
        match self {
            Cell::Text(s) => Some(s.clone()),
            _ => None,
        }
    }

    pub(crate) fn id(&self) -> Option<Uuid> {
        self.text().and_then(|s| Uuid::parse_str(&s).ok())
    }
}

/// A raw connection to a database under test.
#[derive(Clone)]
pub(crate) enum Db {
    Postgres(sqlx::PgPool),
    /// One connection, taken for a statement at a time and never across an await.
    Sqlite(Arc<Mutex<rusqlite::Connection>>),
}

impl Db {
    pub(crate) async fn open(url: &str) -> anyhow::Result<Db> {
        Ok(match memhouse_server::sqlite_path(url) {
            Some(path) => {
                let conn = rusqlite::Connection::open(&path)?;
                // As the store opens it: cascades on, and a writer waits its turn.
                conn.execute_batch("PRAGMA foreign_keys = ON;")?;
                conn.busy_timeout(std::time::Duration::from_secs(10))?;
                Db::Sqlite(Arc::new(Mutex::new(conn)))
            }
            None => Db::Postgres(sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(url).await?),
        })
    }

    pub(crate) async fn close(&self) {
        if let Db::Postgres(pool) = self {
            pool.close().await;
        }
    }

    /// Every row of a query.
    pub(crate) async fn rows(&self, sql: Sql<'_>, args: &[Arg]) -> anyhow::Result<Vec<Vec<Cell>>> {
        match self {
            Db::Postgres(pool) => {
                let rows = bind_pg(sqlx::query(sqlx::AssertSqlSafe(sql.postgres.to_string())), args).fetch_all(pool).await?;
                rows.iter().map(pg_row).collect()
            }
            Db::Sqlite(conn) => {
                let conn = conn.lock().unwrap_or_else(|e| e.into_inner());
                let mut stmt = conn.prepare(&sql.for_sqlite())?;
                let n = stmt.column_count();
                let mut rows = stmt.query(rusqlite::params_from_iter(args.iter().map(lite_arg)))?;
                let mut out = vec![];
                while let Some(row) = rows.next()? {
                    out.push((0..n).map(|i| lite_cell(row, i)).collect::<anyhow::Result<Vec<Cell>>>()?);
                }
                Ok(out)
            }
        }
    }

    /// The first value of the first row, as a count.
    pub(crate) async fn count(&self, sql: Sql<'_>, args: &[Arg]) -> anyhow::Result<i64> {
        let rows = self.rows(sql, args).await?;
        rows.first().and_then(|r| r.first()).and_then(Cell::int).ok_or_else(|| anyhow::anyhow!("the query returned no number: {}", sql.postgres))
    }

    /// The first value of the first row as text: `None` without a row, or when it is null.
    pub(crate) async fn text(&self, sql: Sql<'_>, args: &[Arg]) -> anyhow::Result<Option<String>> {
        Ok(self.rows(sql, args).await?.first().and_then(|r| r.first()).and_then(Cell::text))
    }

    /// The first column of every row, as text (nulls left out).
    pub(crate) async fn texts(&self, sql: Sql<'_>, args: &[Arg]) -> anyhow::Result<Vec<String>> {
        Ok(self.rows(sql, args).await?.iter().filter_map(|r| r.first().and_then(Cell::text)).collect())
    }

    /// One statement that changes rows; the number changed.
    pub(crate) async fn execute(&self, sql: Sql<'_>, args: &[Arg]) -> anyhow::Result<u64> {
        match self {
            Db::Postgres(pool) => Ok(bind_pg(sqlx::query(sqlx::AssertSqlSafe(sql.postgres.to_string())), args).execute(pool).await?.rows_affected()),
            Db::Sqlite(conn) => {
                let conn = conn.lock().unwrap_or_else(|e| e.into_inner());
                Ok(conn.execute(&sql.for_sqlite(), rusqlite::params_from_iter(args.iter().map(lite_arg)))? as u64)
            }
        }
    }

    /// Several statements without parameters (DDL for a fault a check injects).
    pub(crate) async fn batch(&self, sql: Sql<'_>) -> anyhow::Result<()> {
        match self {
            Db::Postgres(pool) => {
                sqlx::raw_sql(sqlx::AssertSqlSafe(sql.postgres.to_string())).execute(pool).await?;
            }
            Db::Sqlite(conn) => conn.lock().unwrap_or_else(|e| e.into_inner()).execute_batch(&sql.for_sqlite())?,
        }
        Ok(())
    }
}

type PgQuery<'q> = sqlx::query::Query<'q, sqlx::Postgres, sqlx::postgres::PgArguments>;

fn bind_pg<'q>(mut q: PgQuery<'q>, args: &[Arg]) -> PgQuery<'q> {
    for a in args {
        q = match a.clone() {
            Arg::Text(s) => q.bind(s),
            Arg::Int(n) => q.bind(n),
            Arg::Int32(n) => q.bind(n),
            Arg::Id(id) => q.bind(id),
            Arg::Ids(ids) => q.bind(ids),
        };
    }
    q
}

fn pg_row(row: &sqlx::postgres::PgRow) -> anyhow::Result<Vec<Cell>> {
    use sqlx::{Row, TypeInfo, ValueRef};
    (0..row.len())
        .map(|i| {
            let raw = row.try_get_raw(i)?;
            if raw.is_null() {
                return Ok(Cell::Null);
            }
            let ty = raw.type_info().name().to_string();
            Ok(match ty.as_str() {
                "BOOL" => Cell::Int(i64::from(row.try_get::<bool, _>(i)?)),
                "INT2" => Cell::Int(i64::from(row.try_get::<i16, _>(i)?)),
                "INT4" => Cell::Int(i64::from(row.try_get::<i32, _>(i)?)),
                "INT8" => Cell::Int(row.try_get::<i64, _>(i)?),
                "FLOAT4" => Cell::Real(f64::from(row.try_get::<f32, _>(i)?)),
                "FLOAT8" => Cell::Real(row.try_get::<f64, _>(i)?),
                "TEXT" | "VARCHAR" | "NAME" | "BPCHAR" => Cell::Text(row.try_get::<String, _>(i)?),
                "UUID" => Cell::Text(row.try_get::<Uuid, _>(i)?.to_string()),
                "JSON" | "JSONB" => Cell::Text(row.try_get::<serde_json::Value, _>(i)?.to_string()),
                other => anyhow::bail!("column {i} has type {other}: cast it to text or a number in the query"),
            })
        })
        .collect()
}

fn lite_arg(a: &Arg) -> rusqlite::types::Value {
    use rusqlite::types::Value;
    match a {
        Arg::Text(s) => Value::Text(s.clone()),
        Arg::Int(n) => Value::Integer(*n),
        Arg::Int32(n) => Value::Integer(i64::from(*n)),
        Arg::Id(id) => Value::Text(id.to_string()),
        Arg::Ids(ids) => Value::Text(serde_json::to_string(&ids.iter().map(Uuid::to_string).collect::<Vec<_>>()).unwrap_or_default()),
    }
}

fn lite_cell(row: &rusqlite::Row<'_>, i: usize) -> anyhow::Result<Cell> {
    use rusqlite::types::ValueRef;
    Ok(match row.get_ref(i)? {
        ValueRef::Null => Cell::Null,
        ValueRef::Integer(n) => Cell::Int(n),
        ValueRef::Real(x) => Cell::Real(x),
        ValueRef::Text(t) => Cell::Text(String::from_utf8_lossy(t).into_owned()),
        ValueRef::Blob(_) => anyhow::bail!("column {i} is a blob: read it with hex() or length() in the query"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbered_parameters_for_sqlite() {
        assert_eq!(numbered("SELECT $1, '$x', a FROM t WHERE b = $12"), "SELECT ?1, '$x', a FROM t WHERE b = ?12");
        assert_eq!(Sql::each("SELECT $1::uuid", "SELECT ?1").for_sqlite(), "SELECT ?1");
    }

    #[tokio::test]
    async fn sqlite_rows_arguments_and_cells() -> anyhow::Result<()> {
        let conn = rusqlite::Connection::open_in_memory()?;
        conn.execute_batch("CREATE TABLE t (id TEXT, n INTEGER, x REAL, note TEXT); INSERT INTO t VALUES ('00000000-0000-0000-0000-000000000001', 7, 0.5, NULL);")?;
        let db = Db::Sqlite(Arc::new(Mutex::new(conn)));
        let id = Uuid::from_u128(1);
        let rows = db.rows(Sql::same("SELECT id, n, x, note FROM t WHERE id = $1"), &[id.into()]).await?;
        assert_eq!(rows, vec![vec![Cell::Text(id.to_string()), Cell::Int(7), Cell::Real(0.5), Cell::Null]]);
        assert_eq!(rows[0][0].id(), Some(id));
        // A list of ids is a JSON array, read with json_each.
        let n =
            db.count(Sql::each("SELECT count(*) FROM t WHERE id = ANY($1)", "SELECT count(*) FROM t WHERE id IN (SELECT value FROM json_each(?1))"), &[(&vec![id]).into()]).await?;
        assert_eq!(n, 1);
        assert_eq!(db.execute(Sql::same("UPDATE t SET n = $1"), &[9i64.into()]).await?, 1);
        assert_eq!(db.text(Sql::same("SELECT note FROM t"), &[]).await?, None);
        Ok(())
    }
}
