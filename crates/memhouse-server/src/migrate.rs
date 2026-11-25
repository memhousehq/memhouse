// SPDX-License-Identifier: Apache-2.0
//! `memhouse migrate` (TR-MIG-01, TR-MIG-03, PROF-03): move an installation between the Lite
//! and Standard profiles. This module names the two databases, opens them (the source for
//! reading only), runs [`memhouse_core::migrate`], and switches the configuration file over
//! once everything verified. A database password never leaves it: every message, the marker,
//! the audit event and the report name a database by its [`Endpoint::label`].

use memhouse_core::migrate::{self as core, Attention, Plan, Report, TargetState};
use memhouse_core::{Config, Store};
use memhouse_store_postgres::PgStore;
use memhouse_store_sqlite::SqliteStore;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// pgvector stores at most this many dimensions in a `vector` column.
const PGVECTOR_MAX_DIM: usize = 16_000;

/// Records a second that the reference run migrated, copy and verification together, by the
/// target's profile: one million records with 384-dimension vectors and an audit event each, on
/// a laptop (`memhouse bench migrate`; 8,327 a second into Postgres on 25 November 2026, and
/// 6,724 into another SQLite file at 100,000 records). A dry run cannot write to the target, so
/// its estimate uses these beside the read rate it measures.
const REFERENCE_RATE_POSTGRES: f64 = 8_000.0;
const REFERENCE_RATE_SQLITE: f64 = 6_500.0;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Place {
    Sqlite(PathBuf),
    Postgres,
}

/// One side of a migration.
#[derive(Clone)]
pub struct Endpoint {
    /// The database URL as the configuration holds it (for Postgres, with its password).
    pub url: String,
    /// The same without credentials: what is printed, logged, audited and compared.
    pub label: String,
    pub place: Place,
}

// Never the URL: a debug print of an endpoint must not show a password.
impl std::fmt::Debug for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Endpoint({})", self.label)
    }
}

/// A database URL without its credentials.
pub fn redact(url: &str) -> String {
    memhouse_store_postgres::redact_url(url)
}

/// Read a database URL: `sqlite:<path>` (also `sqlite://<path>` and `lite://<path>`) or
/// `postgres://…`.
pub fn endpoint(url: &str) -> anyhow::Result<Endpoint> {
    let lite = url.strip_prefix("lite://").or_else(|| url.strip_prefix("lite:")).map(PathBuf::from).or_else(|| crate::sqlite_path(url));
    if let Some(path) = lite {
        anyhow::ensure!(!path.as_os_str().is_empty(), "the database URL names no file: write sqlite:/path/to/memhouse.db");
        // One name for one file, however it was written: the marker in the target compares it.
        let path = std::path::absolute(&path).unwrap_or(path);
        let path = match (path.parent().and_then(|d| d.canonicalize().ok()), path.file_name()) {
            (Some(dir), Some(name)) => dir.join(name),
            _ => path,
        };
        let url = format!("sqlite:{}", path.display());
        return Ok(Endpoint { label: url.clone(), url, place: Place::Sqlite(path) });
    }
    anyhow::ensure!(
        url.starts_with("postgres://") || url.starts_with("postgresql://"),
        "{} is not a database URL this command knows: use sqlite:<path> for a Lite database or postgres://… for a Standard one",
        redact(url)
    );
    // The driver writes a parameter it does not know to the log, value and all.
    for key in url.split_once('?').map(|(_, q)| q).unwrap_or_default().split('&').filter_map(|p| p.split_once('=').map(|(k, _)| k)) {
        let k = key.to_ascii_lowercase();
        // The driver decodes a name before it reads it, so an encoded one could spell anything.
        anyhow::ensure!(!key.contains('%'), "the database URL has a parameter whose name is percent-encoded (`{key}`): write parameter names plainly");
        anyhow::ensure!(
            k == "password" || !["pass", "secret", "token"].iter().any(|w| k.contains(w)),
            "the database URL has a parameter `{key}` that the Postgres driver does not know: it would be ignored, and logged with its value. Remove it (a password goes before the host, or in `password`)"
        );
    }
    Ok(Endpoint { url: url.to_string(), label: redact(url), place: Place::Postgres })
}

pub struct Request {
    pub from: Endpoint,
    pub to: Endpoint,
    /// The configuration in effect: the tenant the migration is audited under, the language packs.
    pub cfg: Config,
    /// The file whose `[database] url` is switched to the target after a verified migration.
    pub config_path: Option<PathBuf>,
    /// Told what is going on while it runs.
    pub progress: Option<core::Progress>,
}

/// What became of the configuration file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Switch {
    /// `[database] url` now names the target; the file as it was is kept in `backup`.
    Switched {
        config: PathBuf,
        backup: PathBuf,
    },
    AlreadyOnTarget {
        config: PathBuf,
    },
    /// The file names another database than the source: it was left alone.
    PointsElsewhere {
        config: PathBuf,
        configured: String,
    },
    NoConfigFile {
        config: PathBuf,
    },
    /// The caller asked for no switch.
    NotAsked,
}

struct Opened {
    source: Arc<dyn Store>,
    /// `None` in a dry run when the target is a file that does not exist yet.
    target: Option<Arc<dyn Store>>,
    options: core::Options,
    /// Dropped last: the source's write lock (SQLite).
    _lock: Option<memhouse_store_sqlite::transfer::SourceLock>,
}

async fn open(req: &Request, dry_run: bool) -> anyhow::Result<Opened> {
    anyhow::ensure!(req.from.label != req.to.label, "the source and the target are the same database ({})", req.from.label);
    let mut extra = vec![];
    let (source, lock): (Arc<dyn Store>, _) = match &req.from.place {
        Place::Sqlite(path) => {
            let (store, lock) = SqliteStore::open_source(path, "")?;
            (Arc::new(store), Some(lock))
        }
        Place::Postgres => {
            let store = PgStore::connect(&req.from.url, 4, "").await?;
            let others = store.other_sessions().await.unwrap_or(0);
            if others > 0 {
                extra.push(Attention::note(format!(
                    "{others} other sessions are connected to the source database: if a MemHouse server is among them, stop it first (a migration whose source changed meanwhile fails its verification)"
                )));
            }
            (Arc::new(store), None)
        }
    };
    // The target is given the source's identity, so its vectors can be written as they are.
    let prefix = source.migration_summary().await?.identity.map(|i| i.passage_prefix).unwrap_or_default();
    let writers: usize = if req.to.place == Place::Postgres { 4 } else { 1 };
    let target: Option<Arc<dyn Store>> = match &req.to.place {
        Place::Sqlite(path) if dry_run && !path.exists() => None,
        // A dry run changes nothing, and opening a file for writing would.
        Place::Sqlite(path) if dry_run => Some(Arc::new(SqliteStore::open_read_only(path, &prefix)?)),
        Place::Sqlite(path) => Some(Arc::new(SqliteStore::open(path, &prefix)?)),
        Place::Postgres => Some(Arc::new(PgStore::connect(&req.to.url, writers as u32 + 2, &prefix).await?)),
    };
    // As the engine sets it up: a record's keyword index is in its language's configuration.
    let languages = memhouse_core::lang::Languages::load(&req.cfg.language)?;
    if let Some(t) = &target {
        t.set_languages(&languages.packs().iter().map(|p| (p.code().to_string(), p.file.text_search.clone())).collect::<Vec<_>>());
        if let Err(e) = t.check_text_search(&languages.text_search()).await {
            extra.push(Attention::stop(format!("{e:#}")));
        }
    }
    if Config::env_database_url().is_some() {
        extra.push(Attention::note(
            "the environment sets the database URL (MEMHOUSE_DATABASE_URL or DATABASE_URL) over the configuration file: change it to the target after the migration".to_string(),
        ));
    }
    let mut options = core::Options::new(&req.from.label, &req.to.label, &req.cfg.memory.tenant);
    options.writers = writers;
    options.target_refuses_nul = req.to.place == Place::Postgres;
    options.target_max_dim = (req.to.place == Place::Postgres).then_some(PGVECTOR_MAX_DIM);
    options.extra = extra;
    options.progress = req.progress.clone();
    Ok(Opened { source, target, options, _lock: lock })
}

/// The dry run (TR-MIG-03): what would move, how long it should take, and what needs attention.
/// Changes nothing in either database or in the configuration.
pub async fn plan(req: &Request) -> anyhow::Result<Plan> {
    let o = open(req, true).await?;
    core::inspect(o.source.as_ref(), o.target.as_deref(), &o.options, true).await
}

/// Migrate: copy, verify, record the migration on the target, then switch the configuration
/// file over. Any failure before the switch leaves the configuration and the source as they were.
pub async fn run(req: &Request) -> anyhow::Result<(Report, Switch)> {
    let o = open(req, false).await?;
    let target = o.target.clone().ok_or_else(|| anyhow::anyhow!("the target was not opened"))?;
    let report = core::run(o.source.clone(), target, &o.options).await?;
    // The target holds what the source held when it was verified (in this run, or in the
    // earlier one that completed: `core::run` refuses a source that changed since). The last
    // look at the source comes immediately before the file is changed; a SQLite source is also
    // locked against writes until this function returns.
    let switch = match &req.config_path {
        Some(path) => {
            let verified = report.verified.as_ref().ok_or_else(|| anyhow::anyhow!("the migration does not say what the source held when it was verified: nothing was switched"))?;
            core::ensure_source_unchanged(o.source.as_ref(), verified, "after it was verified, before the configuration was switched").await?;
            switch_config(path, &req.from, &req.to)?
        }
        None => Switch::NotAsked,
    };
    Ok((report, switch))
}

/// The server and port of a Postgres URL (`host:5432` when it names no port).
fn server_of(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let authority = &rest[..rest.find(['/', '?', '#']).unwrap_or(rest.len())];
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h).to_ascii_lowercase();
    // A port follows the last colon, unless that colon is inside an IPv6 address.
    let has_port = host.rsplit_once(':').is_some_and(|(_, p)| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    Some(if has_port { host } else { format!("{host}:5432") })
}

/// Whether a configured database URL names this endpoint.
fn names(url: &str, e: &Endpoint) -> bool {
    endpoint(url).is_ok_and(|c| c.url == e.url)
}

/// Point the configuration file at the target, keeping the file as it was beside it.
pub fn switch_config(path: &Path, from: &Endpoint, to: &Endpoint) -> anyhow::Result<Switch> {
    let config = path.to_path_buf();
    if !path.exists() {
        return Ok(Switch::NoConfigFile { config });
    }
    // What the file says, without the environment: a URL given for one run is not written into it.
    let mut cfg = Config::load_file(Some(path))?;
    if names(&cfg.database.url, to) {
        return Ok(Switch::AlreadyOnTarget { config });
    }
    if !names(&cfg.database.url, from) {
        return Ok(Switch::PointsElsewhere { config, configured: redact(&cfg.database.url) });
    }
    let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ");
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(format!(".before-migrate-{stamp}"));
    let backup = path.with_file_name(name);
    // The old file holds the old URL, with its password if it had one: private, like the file itself.
    let mut out = memhouse_store_sqlite::backup::create_private(&backup)?;
    std::io::Write::write_all(&mut out, &std::fs::read(path)?)?;
    out.sync_all()?;
    cfg.database.url = to.url.clone();
    // The managed container is the one that serves the source. It still serves the target only
    // when that is another database on the same server; a file needs none, and another server
    // is not this container (`memhouse down` would stop the wrong thing).
    let same_server = from.place == Place::Postgres && to.place == Place::Postgres && server_of(&from.url).is_some_and(|s| Some(s) == server_of(&to.url));
    if !same_server {
        cfg.database.container = None;
    }
    cfg.save(Some(path))?;
    Ok(Switch::Switched { config, backup })
}

fn size(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 30 => format!("{:.1} GB", b as f64 / (1u64 << 30) as f64),
        b if b >= 1 << 20 => format!("{:.1} MB", b as f64 / (1u64 << 20) as f64),
        b => format!("{:.0} KB", b as f64 / 1024.0),
    }
}

fn duration(secs: f64) -> String {
    if secs < 90.0 {
        format!("{:.0} s", secs.max(1.0))
    } else {
        format!("{:.0} min", (secs / 60.0).ceil())
    }
}

/// The source's size where it lives: the file with its write-ahead log, or what Postgres reports.
fn source_size(from: &Endpoint, plan: &Plan) -> Option<u64> {
    match &from.place {
        Place::Sqlite(path) => {
            let len = |p: PathBuf| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            Some(len(path.clone()) + len(PathBuf::from(format!("{}-wal", path.display()))))
        }
        Place::Postgres => plan.source.size_bytes,
    }
}

/// The dry run's report, as text.
pub fn describe_plan(req: &Request, plan: &Plan) -> String {
    let s = &plan.source;
    let mut o = String::new();
    let _ = writeln!(o, "Migration plan (nothing is changed by looking)");
    let _ = writeln!(o, "  from: {}", req.from.label);
    let _ = writeln!(o, "  to:   {}", req.to.label);
    if let Some(id) = &s.identity {
        let _ = writeln!(o, "  vectors: made with {id}; copied as they are, nothing is embedded again");
    }
    let _ = writeln!(o, "\nRecords: {} in {} tenant(s), {} with a vector, {} with a second vector", s.record_total(), s.tenants().len(), s.vectors, s.second_vectors);
    // By kind and state, over every tenant.
    let mut by: std::collections::BTreeMap<(&str, &str), u64> = Default::default();
    for r in &s.records {
        *by.entry((r.kind.as_str(), r.status.as_str())).or_default() += r.records;
    }
    for ((kind, status), n) in &by {
        let _ = writeln!(o, "  {kind:<12} {status:<12} {n}");
    }
    let _ = writeln!(o, "\nWith them:");
    for t in core::TABLES {
        let n = s.tables.get(t.name).copied().unwrap_or(0);
        if n > 0 {
            let _ = writeln!(o, "  {:<18} {n}", t.name);
        }
    }
    let left: Vec<String> = s.left_behind.iter().filter(|(_, n)| **n > 0).map(|(t, n)| format!("{n} {t}")).collect();
    if !left.is_empty() {
        let _ = writeln!(o, "Left behind (caches, recall explanations and idempotency keys are not memory): {}", left.join(", "));
    }
    if let Some(bytes) = source_size(&req.from, plan) {
        let _ = writeln!(o, "\nSize of the source: {}", size(bytes));
    }
    let _ = match plan.source_audit {
        (n, None) => writeln!(o, "Audit chain of the source: intact ({n} events)"),
        (_, Some(id)) => writeln!(o, "Audit chain of the source: broken at event {id}"),
    };
    let records = s.record_total() as f64;
    if let Some((n, secs)) = plan.sample.filter(|_| records > 0.0) {
        let read = n as f64 / secs.max(1e-6);
        let reference = if req.to.place == Place::Postgres { REFERENCE_RATE_POSTGRES } else { REFERENCE_RATE_SQLITE };
        // The source is read twice (the copy, then the vectors and the checks of the verification).
        let rate = reference.min(read / 2.0);
        let _ = writeln!(
            o,
            "Estimated duration: about {} for the copy and the verification. An estimate, extrapolated: the reference run migrated {reference:.0} records a second into a database of the \
             target's kind, and this source was read at {read:.0} a second on a sample of {n}, which {}. The target itself was not measured: a dry run writes nothing",
            duration(records / rate),
            if rate < reference { "is what limits it here" } else { "does not hold it back" }
        );
    }
    let _ = writeln!(
        o,
        "Target: {}",
        match plan.target_state {
            TargetState::Empty => "empty",
            TargetState::Resume => "holds an unfinished run of this migration",
            TargetState::Complete => "holds this migration, completed",
            TargetState::Occupied => "not empty",
        }
    );
    if plan.attention.is_empty() {
        let _ = writeln!(o, "\nNeeds attention: nothing");
    } else {
        let _ = writeln!(o, "\nNeeds attention:");
        for a in &plan.attention {
            let _ = writeln!(o, "  {} {}", if a.blocking { "✗" } else { "!" }, a.text);
        }
    }
    if plan.blocked() {
        let _ = writeln!(o, "\nThe migration cannot run until what is marked ✗ is dealt with.");
    } else {
        let _ = writeln!(o, "\nStop `memhouse serve` and the agents writing to the source before migrating: writes made during the copy are not carried over, and fail it.");
    }
    o
}

/// What a migration did, and what to do next.
pub fn describe_report(req: &Request, report: &Report, switch: &Switch) -> String {
    let mut o = String::new();
    if !report.ran {
        let _ = writeln!(o, "✓ this migration had already completed: {} holds everything from {}", req.to.label, req.from.label);
    } else {
        let _ = writeln!(
            o,
            "✓ migrated {} records{} from {} to {}",
            report.records,
            if report.resumed { format!(" (resumed: {} written by this run)", report.records_written) } else { String::new() },
            req.from.label,
            req.to.label
        );
        let moved: Vec<String> = report.tables.iter().filter(|(_, n)| **n > 0).map(|(t, n)| format!("{n} {t}")).collect();
        if !moved.is_empty() {
            let _ = writeln!(o, "  with them: {}", moved.join(", "));
        }
        let _ = writeln!(o, "  verified: every record read back from the target has the hash it had in the source; every other table matches row for row");
        if report.respelled > 0 {
            let ids: Vec<String> = report.respelled_ids.iter().map(|u| u.to_string()).collect();
            let _ = writeln!(
                o,
                "  ! {} records are equal in value, but the target writes a number in their JSON differently (1e16 as 10000000000000000); the first: {}",
                report.respelled,
                ids.join(", ")
            );
        }
        let _ = match report.vector_max_gap {
            0.0 => writeln!(o, "  vectors: copied as they were ({} compared on a sample, identical)", report.vectors_compared),
            g => writeln!(
                o,
                "  ! vectors: the target stores them at half precision, so they were rounded ({} compared on a sample, largest change of a component {g:.6}); recall ranks by them as before, to within that precision",
                report.vectors_compared
            ),
        };
        let _ = match report.audit_broken_at {
            None => writeln!(o, "  audit chain: verifies on the target ({} events, and one for this migration)", report.audit_events),
            Some(id) => writeln!(o, "  ! audit chain: broken at event {id}, as in the source"),
        };
        let _ = writeln!(o, "  copy {:.1} s, verification {:.1} s", report.copy_secs, report.verify_secs);
    }
    let _ = match switch {
        Switch::Switched { config, backup } => {
            writeln!(o, "✓ {} now names the target in [database] url; the file as it was is kept in {} (delete it once you are satisfied)", config.display(), backup.display())
        }
        Switch::AlreadyOnTarget { config } => writeln!(o, "✓ {} already names the target", config.display()),
        Switch::PointsElsewhere { config, configured } => {
            writeln!(o, "! {} names another database ({configured}), not the source: it was left as it is. Set [database] url to the target yourself", config.display())
        }
        Switch::NoConfigFile { config } => writeln!(o, "! there is no configuration file at {}: set the database URL to the target where you configure MemHouse", config.display()),
        Switch::NotAsked => Ok(()),
    };
    // Cut over only when the URL the server will read names the target: the file's, unless the
    // environment sets one over it.
    // The URL the server will read: the environment's when it sets one, else the file's.
    let file_on_target = matches!(switch, Switch::Switched { .. } | Switch::AlreadyOnTarget { .. });
    let env = Config::env_database_url();
    let cut_over = match env.as_deref() {
        Some(url) => names(url, &req.to),
        None => file_on_target,
    };
    let _ = writeln!(o, "\nNext:");
    if cut_over {
        let _ = writeln!(o, "  1. Start the server again: `memhouse serve`. Agents keep their configuration and their keys.");
        let _ = writeln!(o, "  2. `memhouse doctor` checks the new database; `memhouse audit --verify` checks the audit chain.");
        let _ = writeln!(
            o,
            "  3. The source was not changed and is no longer used: {}. Keep it until you are satisfied, then remove it yourself; it holds everything, including what you erase from now on.",
            req.from.label
        );
        if !file_on_target {
            let _ = writeln!(
                o,
                "  ! The target is named by the environment (MEMHOUSE_DATABASE_URL or DATABASE_URL); the configuration file does not name it. \
                 Set [database] url to the target as well, or a start without that variable opens whatever the file names."
            );
        }
    } else {
        let what = if env.is_some() {
            "the environment sets the database URL (MEMHOUSE_DATABASE_URL or DATABASE_URL) over the configuration file, and it does not name the target: change it to the target, or unset it"
        } else {
            "set the database URL to the target ([database] url in the configuration file)"
        };
        let _ = writeln!(o, "  ! MemHouse is not pointed at the target ({}) yet, as far as this command can tell: do not start the server before it is.", req.to.label);
        let _ = writeln!(o, "  1. Point MemHouse at the target: {what}.");
        let _ = writeln!(o, "  2. Then start the server (`memhouse serve`) and check with `memhouse doctor` and `memhouse audit --verify`.");
        let _ = writeln!(
            o,
            "  3. The source was not changed: {}. A write made to it from now on is not in the target; check which database MemHouse opens before you start anything.",
            req.from.label
        );
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_encoded_parameter_name_is_refused_and_never_printed() {
        let e = endpoint("postgres://h/db?p%61ssword=s3cret").unwrap_err().to_string(); // secret-scan: allow (fake fixture)
        assert!(e.contains("percent-encoded") && !e.contains("s3cret"), "{e}");
        assert!(endpoint("postgres://h/db?sslmode=require&password=s3cret").is_ok());
        // secret-scan: allow (fake fixture)
    }

    #[test]
    fn a_postgres_url_names_its_server() {
        assert_eq!(server_of("postgres://u:pw@Db.Internal:5433/memhouse?sslmode=require").as_deref(), Some("db.internal:5433")); // secret-scan: allow (fake fixture)
        assert_eq!(server_of("postgres://db.internal/memhouse").as_deref(), Some("db.internal:5432"));
        assert_eq!(server_of("postgres://u@[::1]/memhouse").as_deref(), Some("[::1]:5432"));
        assert_eq!(server_of("postgres://h/db?password=p@x:1").as_deref(), Some("h:5432")); // secret-scan: allow (fake fixture)
        assert_eq!(server_of("sqlite:/var/lib/memhouse.db"), None);
    }

    /// Switch a configuration that names `from` (with a managed container) to `to`; the container afterwards.
    fn container_after(from: &str, to: &str) -> Option<String> {
        let dir = std::env::temp_dir().join(format!("memhouse-switch-test-{}", uuid::Uuid::now_v7().simple()));
        memhouse_store_sqlite::private_dir(&dir).unwrap();
        let mut cfg = Config::default();
        cfg.database.url = from.into();
        cfg.database.container = Some("memhouse-pg".into());
        let path = cfg.save(Some(&dir.join("config.toml"))).unwrap();
        let switch = switch_config(&path, &endpoint(from).unwrap(), &endpoint(to).unwrap()).unwrap();
        let now = Config::load_file(Some(&path)).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(matches!(switch, Switch::Switched { .. }), "{switch:?}");
        assert_eq!(endpoint(&now.database.url).unwrap().label, endpoint(to).unwrap().label);
        now.database.container
    }

    #[test]
    fn the_managed_container_is_kept_only_for_another_database_on_its_server() {
        let source = "postgres://memhouse@127.0.0.1:54329/memhouse";
        // Another database of the same server: the container still serves it.
        assert_eq!(container_after(source, "postgres://memhouse@127.0.0.1:54329/memhouse_new").as_deref(), Some("memhouse-pg"));
        // Another port, another host, a file: it does not.
        assert_eq!(container_after(source, "postgres://memhouse@127.0.0.1:5432/memhouse"), None);
        assert_eq!(container_after(source, "postgres://memhouse@db.internal:54329/memhouse"), None);
        assert_eq!(container_after(source, "sqlite:/var/lib/memhouse/memhouse.db"), None);
        assert_eq!(container_after("sqlite:/var/lib/memhouse/memhouse.db", "postgres://memhouse@db.internal/memhouse"), None);
    }
}
