// SPDX-License-Identifier: Apache-2.0
//! `memhouse migrate` end to end, between two Lite files (no Postgres needed): the dry run
//! changes nothing, a migration switches the configuration file over only after it verified and
//! keeps the old file, the source is only read, and a password in a URL is never printed.

use memhouse_conformance::migration::{seed, DIM, EMBEDDER, PREFIX};
use memhouse_core::{Config, Store};
use memhouse_store_sqlite::backup::sha256_file;
use memhouse_store_sqlite::SqliteStore;
use std::path::Path;
use std::process::{Command, Output};

fn memhouse(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_memhouse"))
        .args(args)
        .env("MEMHOUSE_HOME", home)
        .env_remove("MEMHOUSE_CONFIG")
        .env_remove("MEMHOUSE_DATABASE_URL")
        .env_remove("DATABASE_URL")
        .env_remove("MEMHOUSE_MIGRATE_FROM")
        .env_remove("MEMHOUSE_MIGRATE_TO")
        .output()
        .expect("run memhouse")
}

/// (stdout, stderr), also printed: `cargo test -- --nocapture` shows what the operator sees.
fn text(out: &Output) -> (String, String) {
    let (stdout, stderr) = (String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned());
    println!("{stdout}{stderr}\n----");
    (stdout, stderr)
}

#[tokio::test]
async fn migrate_dry_run_then_migrate_then_switch_over() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let (source, target) = (home.join("memhouse.db"), home.join("moved.db"));
    let seeded = {
        let store = SqliteStore::open(&source, PREFIX).unwrap();
        store.migrate(DIM, EMBEDDER).await.unwrap();
        seed(&store).await.unwrap()
    };
    let mut cfg = Config::default();
    cfg.database.url = format!("sqlite:{}", source.display());
    cfg.database.container = Some("left-over".into());
    cfg.memory.tenant = "acme".into();
    let config = cfg.save(Some(&home.join("config.toml"))).unwrap();
    let original = std::fs::read(&config).unwrap();
    let bytes = sha256_file(&source).unwrap();
    // `lite://` is another spelling of `sqlite:`.
    let to = format!("lite://{}", target.display());

    // The dry run: counts, size, an estimate, what needs attention; nothing changes.
    let out = memhouse(&home, &["migrate", "--to", &to, "--dry-run"]);
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "{stdout}\n{stderr}");
    for expected in [
        format!("Records: {} in 2 tenant(s)", seeded.records),
        "semantic     committed".into(),
        "preference   superseded   1".into(),
        "Size of the source:".into(),
        "Estimated duration: about".into(),
        "An estimate, extrapolated:".into(),
        "Audit chain of the source: intact".into(),
        "Target: empty".into(),
        "queued writes and 1 enrichment jobs are not finished".into(),
        "Left behind".into(),
    ] {
        assert!(stdout.contains(&expected), "the dry run does not say {expected:?}:\n{stdout}");
    }
    assert!(!target.exists(), "a dry run created the target");
    assert_eq!((std::fs::read(&config).unwrap(), sha256_file(&source).unwrap()), (original.clone(), bytes.clone()), "a dry run changed something");

    // A target that cannot be reached: an error, nothing changed, and no password in it.
    let out = memhouse(&home, &["migrate", "--to", "postgres://someone:s3kr1t-Pw@127.0.0.1:9/nowhere", "--yes"]); // secret-scan: allow (fake fixture)
    let (stdout, stderr) = text(&out);
    assert!(!out.status.success());
    assert!(!stdout.contains("s3kr1t-Pw") && !stderr.contains("s3kr1t-Pw"), "the password was printed:\n{stdout}\n{stderr}");
    assert!(stderr.contains("postgres://***@127.0.0.1:9/nowhere"), "{stderr}");
    assert_eq!(std::fs::read(&config).unwrap(), original);

    // The migration.
    let out = memhouse(&home, &["migrate", "--to", &to, "--yes"]);
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "{stdout}\n{stderr}");
    assert!(
        stdout.contains(&format!("✓ migrated {} records", seeded.records)) && stdout.contains("verified:") && stdout.contains("audit chain: verifies on the target"),
        "{stdout}"
    );
    assert!(stdout.contains("memhouse serve") && stdout.contains("The source was not changed"), "{stdout}");
    assert_eq!(sha256_file(&source).unwrap(), bytes, "the source file changed");
    // The configuration names the target; the file as it was is kept beside it.
    let now = Config::load_file(Some(&config)).unwrap();
    assert_eq!((now.database.url.as_str(), now.database.container.as_deref()), (format!("sqlite:{}", target.display()).as_str(), None));
    assert_eq!(now.memory.tenant, "acme", "the rest of the configuration is kept");
    let backups: Vec<_> = std::fs::read_dir(&home).unwrap().filter_map(|e| e.ok()).filter(|e| e.file_name().to_string_lossy().starts_with("config.toml.before-migrate-")).collect();
    assert_eq!(backups.len(), 1);
    assert_eq!(std::fs::read(backups[0].path()).unwrap(), original);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(backups[0].path()).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let moved = SqliteStore::open_read_only(&target, "").unwrap();
    assert_eq!(moved.migration_summary().await.unwrap().record_total() as usize, seeded.records);
    drop(moved);

    // Again, from the old database by name: already done, and the file is already switched.
    let from = format!("sqlite:{}", source.display());
    let out = memhouse(&home, &["migrate", "--from", &from, "--to", &to, "--yes"]);
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "{stdout}\n{stderr}");
    assert!(stdout.contains("already completed") && stdout.contains("already names the target"), "{stdout}");

    // Into a database that holds something else: refused before anything is written.
    let out = memhouse(&home, &["migrate", "--to", &from, "--yes"]);
    let (stdout, stderr) = text(&out);
    assert!(!out.status.success() && stdout.contains("✗") && stderr.contains("cannot run yet"), "{stdout}\n{stderr}");
    assert_eq!(sha256_file(&source).unwrap(), bytes);
}
