// SPDX-License-Identifier: Apache-2.0
//! Migration between two Lite files (TR-MIG-01, PROF-02), without Postgres: everything an
//! installation holds arrives, record for record by hash, the audit chain verifies on the
//! other side, nothing erased comes back, and a migration that does not verify says which
//! record and which field. The same checks run across profiles in the governance suite.

use memhouse_conformance::migration::{differences, fingerprint, seed, DIM, EMBEDDER, PREFIX, TENANT};
use memhouse_core::migrate::{self, Marker, Options, Report, TargetState, VerificationFailed, AUDIT_ACTION};
use memhouse_core::types::*;
use memhouse_core::{IntakeQueue, Store};
use memhouse_store_sqlite::backup::sha256_file;
use memhouse_store_sqlite::SqliteStore;
use std::path::Path;
use std::sync::Arc;

fn label(path: &Path) -> String {
    format!("sqlite:{}", path.display())
}

fn options(from: &Path, to: &Path) -> Options {
    Options::new(&label(from), &label(to), TENANT)
}

/// A seeded database file, closed.
async fn seeded(path: &Path) -> memhouse_conformance::migration::Seeded {
    let store = SqliteStore::open(path, PREFIX).unwrap();
    store.migrate(DIM, EMBEDDER).await.unwrap();
    seed(&store).await.unwrap()
}

/// As `memhouse migrate` opens them: the source read-only and locked, the target with the
/// source's passage prefix.
async fn migrate_files(from: &Path, to: &Path) -> anyhow::Result<Report> {
    let (source, _lock) = SqliteStore::open_source(from, "")?;
    let prefix = source.migration_summary().await?.identity.map(|i| i.passage_prefix).unwrap_or_default();
    let target = SqliteStore::open(to, &prefix)?;
    migrate::run(Arc::new(source), Arc::new(target), &options(from, to)).await
}

async fn fingerprint_of(path: &Path) -> memhouse_conformance::migration::Fingerprint {
    let store = SqliteStore::open_read_only(path, "").unwrap();
    fingerprint(&store).await.unwrap()
}

#[tokio::test]
async fn everything_moves_to_another_file_by_record_hash() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    let seeded = seeded(&a).await;
    let before = fingerprint_of(&a).await;
    assert_eq!(before.records.len(), seeded.records);
    assert!(before.tables.values().all(|rows| !rows.is_empty()), "the seed fills every table: {:?}", before.tables.iter().map(|(t, r)| (t, r.len())).collect::<Vec<_>>());
    let bytes = sha256_file(&a).unwrap();

    let report = migrate_files(&a, &b).await.unwrap();
    assert!(report.ran && !report.resumed);
    assert_eq!((report.records as usize, report.records_written as usize, report.respelled), (seeded.records, seeded.records, 0));
    assert_eq!((report.vector_max_gap, report.audit_broken_at), (0.0, None));
    assert!(report.vectors_compared > 0);
    // The source was only read.
    assert_eq!(sha256_file(&a).unwrap(), bytes, "the source file changed");
    assert_eq!(differences(&before, &fingerprint_of(&a).await, 0), Vec::<String>::new(), "the source changed");

    // The target holds the same, and one audit event for the migration.
    let after = fingerprint_of(&b).await;
    assert_eq!(differences(&before, &after, 1), Vec::<String>::new());
    assert_eq!(after.audit, (before.audit.0 + 1, None), "the audit chain verifies on the target");
    {
        let target = SqliteStore::open(&b, PREFIX).unwrap();
        target.migrate(DIM, EMBEDDER).await.unwrap();
        // The migration is recorded, without anything but the databases' names.
        let event = &target.audit_log(TENANT, 1).await.unwrap()[0];
        assert_eq!(event.action, AUDIT_ACTION);
        assert_eq!((event.detail["source"].as_str(), event.detail["records"].as_u64()), (Some(label(&a).as_str()), Some(seeded.records as u64)));
        assert_eq!(event.detail["verification"]["records_differing"], 0);
        let marker: Marker = serde_json::from_value(target.migration_marker().await.unwrap().unwrap()).unwrap();
        assert_eq!((marker.state.as_str(), marker.source), ("complete", label(&a)));
        // Nothing erased came back, and the ledger that says so moved.
        assert!(target.get(TENANT, seeded.deleted).await.unwrap().is_none());
        assert_eq!(
            target
                .list(&ListQuery { tenant: TENANT.into(), subject: Some(seeded.erased_subject.clone()), limit: 10, include_inactive: true, ..Default::default() })
                .await
                .unwrap()
                .len(),
            0
        );
        assert_eq!(target.ledger().unwrap().iter().map(|e| e.scope.as_str()).collect::<Vec<_>>(), ["memory", "subject"]);
        let all = serde_json::to_string(&target.export_records(TENANT, None, None, 1000).await.unwrap()).unwrap();
        let raw = rusqlite::Connection::open(&b).unwrap();
        for word in &seeded.gone_words {
            assert!(!all.contains(word.as_str()), "{word} is back");
            let hits: i64 = raw.query_row("SELECT count(*) FROM mh_memory_fts WHERE mh_memory_fts MATCH ?1", [word], |r| r.get(0)).unwrap();
            assert_eq!(hits, 0, "{word} is in the keyword index");
        }
        // Versions keep their links; the queue still hands out the write that was waiting.
        let old = target.export_records(TENANT, None, None, 1000).await.unwrap().into_iter().find(|r| r.id == seeded.superseded).unwrap();
        assert_eq!((old.status, old.superseded_by), (MemoryStatus::Superseded, Some(seeded.successor)));
        let waiting = target.claim(5, 60, None).await.unwrap();
        assert_eq!(waiting.iter().map(|j| j.proposal.subject.as_str()).collect::<Vec<_>>(), ["user:q1"]);
        assert_eq!(target.enrich_status(TENANT, None).await.unwrap().pending, 1);
        // The caches stayed behind.
        let left: i64 =
            raw.query_row("SELECT (SELECT count(*) FROM mh_embed_cache) + (SELECT count(*) FROM mh_llm_cache) + (SELECT count(*) FROM mh_request_key)", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
        // A number the store assigns continues after the ones that moved.
        target.audit("test", "after.migration", TENANT, None, None, serde_json::json!({})).await.unwrap();
        assert_eq!(target.audit_verify().await.unwrap(), (before.audit.0 + 2, None));
    }

    // Running it again does nothing: the migration is complete.
    let again = migrate_files(&a, &b).await.unwrap();
    assert!(!again.ran);
}

#[tokio::test]
async fn a_round_trip_ends_where_it_started() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b, c) = (dir.path().join("a.db"), dir.path().join("b.db"), dir.path().join("c.db"));
    seeded(&a).await;
    let before = fingerprint_of(&a).await;
    migrate_files(&a, &b).await.unwrap();
    migrate_files(&b, &c).await.unwrap();
    let after = fingerprint_of(&c).await;
    assert_eq!(differences(&before, &after, 2), Vec::<String>::new());
    assert_eq!(before.records, after.records, "identical by record hashes");
    assert_eq!(before.vectors, after.vectors);
}

#[tokio::test]
async fn a_dry_run_reports_and_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    let seeded = seeded(&a).await;
    let bytes = sha256_file(&a).unwrap();
    let (source, lock) = SqliteStore::open_source(&a, "").unwrap();
    let plan = migrate::inspect(&source, None, &options(&a, &b), true).await.unwrap();
    assert_eq!(plan.source.record_total() as usize, seeded.records);
    assert_eq!((plan.target_state, plan.blocked(), plan.source_audit.1), (TargetState::Empty, false, None));
    assert_eq!(plan.sample.map(|s| s.0 as usize), Some(seeded.records));
    assert!(plan.source.size_bytes.is_some_and(|b| b > 0));
    assert_eq!((plan.source.vectors as usize, plan.source.second_vectors), (seeded.records - 1, 1));
    assert_eq!(plan.source.left_behind.values().sum::<u64>(), 3);
    // Queued work is named: it moves as it is.
    let q = &plan.source.queued;
    assert_eq!((q.intake_pending, q.intake_leased, q.intake_dead, q.enrich_pending, q.enrich_leased), (1, 0, 1, 1, 0));
    assert!(plan.attention.iter().any(|a| !a.blocking && a.text.contains("1 queued writes and 1 enrichment jobs")), "{:?}", plan.attention);
    drop((source, lock));
    assert_eq!(sha256_file(&a).unwrap(), bytes);

    // A target that holds something else stops the migration; so does a write being worked on.
    seeded_at(&b).await;
    let (source, _lock) = SqliteStore::open_source(&a, "").unwrap();
    let other = SqliteStore::open_read_only(&b, "").unwrap();
    let plan = migrate::inspect(&source, Some(&other), &options(&a, &b), false).await.unwrap();
    assert_eq!(plan.target_state, TargetState::Occupied);
    assert!(plan.blocked() && plan.attention.iter().any(|a| a.blocking && a.text.contains("already holds data")), "{:?}", plan.attention);
    let err = migrate::run(Arc::new(source), Arc::new(SqliteStore::open(&dir.path().join("b.db"), PREFIX).unwrap()), &options(&a, &b)).await.unwrap_err();
    assert!(err.to_string().contains("cannot start"), "{err:#}");
}

async fn seeded_at(path: &Path) {
    seeded(path).await;
}

#[tokio::test]
async fn a_source_in_use_or_of_another_schema_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    seeded(&a).await;
    {
        // Another connection has the file open, as a running server would.
        let server = SqliteStore::open(&a, PREFIX).unwrap();
        let err = SqliteStore::open_source(&a, "").err().expect("refused").to_string();
        assert!(err.contains("in use") && err.contains("memhouse serve"), "{err}");
        // A write it has claimed and not finished: its claim says a server is at work.
        server.migrate(DIM, EMBEDDER).await.unwrap();
        assert_eq!(server.claim(1, 600, None).await.unwrap().len(), 1);
    }
    let (source, lock) = SqliteStore::open_source(&a, "").unwrap();
    let plan = migrate::inspect(&source, None, &options(&a, &b), false).await.unwrap();
    assert!(plan.attention.iter().any(|a| a.blocking && a.text.contains("being worked on right now")), "{:?}", plan.attention);
    drop((source, lock));

    // While the source is locked for a migration, another process cannot write to it.
    let (_source, lock) = SqliteStore::open_source(&a, "").unwrap();
    let writer = rusqlite::Connection::open(&a).unwrap();
    assert!(writer.execute("UPDATE mh_meta SET value = value WHERE key = 'embedder'", []).is_err(), "a write got through the migration's lock");
    drop(lock);
    writer.execute("UPDATE mh_intake SET status = 'pending', locked_until = NULL WHERE status = 'running'", []).unwrap();
    // A file of an older schema is not upgraded by a migration (that would change the source).
    writer.execute("UPDATE mh_meta SET value = '8' WHERE key = 'schema_version'", []).unwrap();
    drop((writer, _source));
    let (source, _lock) = SqliteStore::open_source(&a, "").unwrap();
    let plan = migrate::inspect(&source, None, &options(&a, &b), false).await.unwrap();
    assert!(plan.attention.iter().any(|a| a.blocking && a.text.contains("schema version 8")), "{:?}", plan.attention);
}

#[tokio::test]
async fn an_interrupted_migration_resumes_and_a_changed_record_fails_it() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b, c) = (dir.path().join("a.db"), dir.path().join("b.db"), dir.path().join("c.db"));
    let seeded = seeded(&a).await;
    let before = fingerprint_of(&a).await;
    let marker = serde_json::to_value(Marker {
        source: label(&a),
        identity: EmbeddingIdentity { embedder: EMBEDDER.into(), dim: DIM, passage_prefix: PREFIX.into() },
        state: "copying".into(),
        started_at: chrono::Utc::now(),
        completed_at: None,
        verified: None,
    })
    .unwrap();
    let source_records = SqliteStore::open_read_only(&a, "").unwrap().export_records(TENANT, None, None, 1000).await.unwrap();

    // A run that stopped after four records: the next one keeps them and copies the rest.
    {
        let target = SqliteStore::open(&b, PREFIX).unwrap();
        target.migrate(DIM, EMBEDDER).await.unwrap();
        target.set_migration_marker(&marker).await.unwrap();
        let rows: Vec<ImportRow> = source_records.iter().take(4).cloned().map(|record| ImportRow { record, embedding: None, alt: None }).collect();
        assert_eq!(target.import_records(&rows).await.unwrap(), 4);
    }
    // The four have no vectors, as if the run had died between a record and its vector: that is
    // not what a resume may leave behind, and the verification says so.
    let err = migrate_files(&a, &b).await.unwrap_err();
    let failed = err.downcast_ref::<VerificationFailed>().expect("a verification failure");
    assert!(failed.problems.iter().any(|p| p.contains("vectors differ")), "{:?}", failed.problems);

    // The same with whole records: resumed, completed, and equal to the source.
    {
        let (source, _lock) = SqliteStore::open_source(&a, "").unwrap();
        let ids: Vec<uuid::Uuid> = source_records.iter().take(4).map(|r| r.id).collect();
        let vectors = source.export_vectors(TENANT, &ids).await.unwrap();
        let target = SqliteStore::open(&c, PREFIX).unwrap();
        target.migrate(DIM, EMBEDDER).await.unwrap();
        target.set_migration_marker(&marker).await.unwrap();
        let rows: Vec<ImportRow> = source_records
            .iter()
            .take(4)
            .cloned()
            .map(|record| {
                let v = vectors.iter().find(|v| v.id == record.id).unwrap();
                let alt = v.alt.clone().zip(record.alt_hash.clone()).map(|(v, h)| (h, v));
                ImportRow { record, embedding: v.embedding.clone(), alt }
            })
            .collect();
        assert_eq!(target.import_records(&rows).await.unwrap(), 4);
    }
    let report = migrate_files(&a, &c).await.unwrap();
    assert!(report.ran && report.resumed);
    assert_eq!(report.records_written as usize, seeded.records - 4);
    assert_eq!(differences(&before, &fingerprint_of(&c).await, 1), Vec::<String>::new());

    // A record that is not the source's: named, with the field, and nothing is marked complete.
    let d = dir.path().join("d.db");
    let changed = source_records[1].clone();
    {
        let target = SqliteStore::open(&d, PREFIX).unwrap();
        target.migrate(DIM, EMBEDDER).await.unwrap();
        target.set_migration_marker(&marker).await.unwrap();
        let mut record = changed.clone();
        record.content = format!("{} (changed on the way)", record.content);
        record.confidence = 0.5;
        let (source, _lock) = SqliteStore::open_source(&a, "").unwrap();
        let v = source.export_vectors(TENANT, &[record.id]).await.unwrap().remove(0);
        target.import_records(&[ImportRow { record, embedding: v.embedding, alt: None }]).await.unwrap();
    }
    let bytes = sha256_file(&a).unwrap();
    let err = migrate_files(&a, &d).await.unwrap_err();
    let failed = err.downcast_ref::<VerificationFailed>().expect("a verification failure");
    let named = failed.problems.iter().find(|p| p.contains(&changed.id.to_string())).unwrap_or_else(|| panic!("the record is not named: {:?}", failed.problems));
    assert!(named.contains("content") && named.contains("confidence") && named.contains("1 records differ"), "{named}");
    assert_eq!(sha256_file(&a).unwrap(), bytes, "the source file changed");
    let target = SqliteStore::open_read_only(&d, "").unwrap();
    let marker: Marker = serde_json::from_value(target.migration_marker().await.unwrap().unwrap()).unwrap();
    assert_eq!(marker.state, "copying");
    assert!(target.audit_log(TENANT, 100).await.unwrap().iter().all(|e| e.action != AUDIT_ACTION), "a failed migration is not recorded as complete");
}

#[tokio::test]
async fn full_precision_vectors_are_rounded_once_and_then_travel_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    // What a vector from Postgres looks like: single precision, not representable in half.
    let full: Vec<f32> = (0..DIM).map(|i| 0.123_456_79 + i as f32 * 0.071_234_57).collect();
    let id = {
        let store = SqliteStore::open(&a, "").unwrap();
        store.migrate(DIM, EMBEDDER).await.unwrap();
        let record = memhouse_core::format::parse_line(
            &serde_json::json!({
                "type": "record", "id": uuid::Uuid::now_v7(), "tenant": TENANT, "subject": "user:v", "kind": "semantic", "status": "committed", "content": "A vector.",
                "content_hash": memhouse_core::engine::content_hash("A vector."), "valid_from": "2026-11-01T00:00:00Z", "source": "test", "confidence": 1.0,
                "created_at": "2026-11-01T00:00:00Z", "updated_at": "2026-11-01T00:00:00Z"
            })
            .to_string(),
        )
        .unwrap();
        let memhouse_core::format::Line::Record(record) = record else { unreachable!() };
        let id = record.id;
        store.import_records(&[ImportRow { record: *record, embedding: Some(full.clone()), alt: None }]).await.unwrap();
        id
    };
    let stored = SqliteStore::open_read_only(&a, "").unwrap().export_vectors(TENANT, &[id]).await.unwrap().remove(0).embedding.unwrap();
    let gap = stored.iter().zip(&full).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max);
    assert!(gap > 0.0 && gap < 2.5e-4, "landing in the Lite store rounds to half precision: {gap}");
    // From there on, a migration carries the stored values exactly.
    let report = migrate_files(&a, &b).await.unwrap();
    assert_eq!(report.vector_max_gap, 0.0);
    assert_eq!(SqliteStore::open_read_only(&b, "").unwrap().export_vectors(TENANT, &[id]).await.unwrap().remove(0).embedding.unwrap(), stored);
}

#[tokio::test]
async fn a_source_that_changes_during_the_copy_fails_the_migration() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    seeded(&a).await;
    // Opened as a store that takes no lock (what a Postgres source is like), and written to
    // once the records are across: a server that was left running.
    let source = SqliteStore::open(&a, PREFIX).unwrap();
    let target = SqliteStore::open(&b, PREFIX).unwrap();
    let mut o = options(&a, &b);
    let file = a.clone();
    o.progress = Some(Arc::new(move |said: &str| {
        if said.starts_with("records:") && said.contains("copied in") {
            let writer = rusqlite::Connection::open(&file).unwrap();
            writer.execute("UPDATE mh_memory SET status = 'rejected', updated_at = updated_at + 1000000 WHERE status = 'quarantined'", []).unwrap();
        }
    }));
    let err = migrate::run(Arc::new(source), Arc::new(target), &o).await.unwrap_err();
    let failed = err.downcast_ref::<VerificationFailed>().expect("a verification failure");
    assert!(failed.problems.iter().any(|p| p.contains("the source changed while it was being copied")), "{:?}", failed.problems);
    let marker: Marker = serde_json::from_value(SqliteStore::open_read_only(&b, "").unwrap().migration_marker().await.unwrap().unwrap()).unwrap();
    assert_eq!(marker.state, "copying");

    // The same once the copy is done and the target is being read back: the target matches
    // what was copied, and the source no longer does.
    let (c, d) = (dir.path().join("c.db"), dir.path().join("d.db"));
    seeded(&c).await;
    let mut o = options(&c, &d);
    let file = c.clone();
    o.progress = Some(Arc::new(move |said: &str| {
        if said.starts_with("records: read back") {
            let writer = rusqlite::Connection::open(&file).unwrap();
            writer.execute("UPDATE mh_memory SET status = 'rejected', updated_at = updated_at + 1000000 WHERE status = 'quarantined'", []).unwrap();
        }
    }));
    let err = migrate::run(Arc::new(SqliteStore::open(&c, PREFIX).unwrap()), Arc::new(SqliteStore::open(&d, PREFIX).unwrap()), &o).await.unwrap_err();
    let failed = err.downcast_ref::<VerificationFailed>().expect("a verification failure");
    assert_eq!(failed.problems.len(), 1, "{:?}", failed.problems);
    assert!(failed.problems[0].contains("the source changed while the copy was being verified"), "{:?}", failed.problems);
    let target = SqliteStore::open_read_only(&d, "").unwrap();
    let marker: Marker = serde_json::from_value(target.migration_marker().await.unwrap().unwrap()).unwrap();
    assert_eq!((marker.state.as_str(), marker.verified), ("copying", None));
    assert!(target.audit_log(TENANT, 100).await.unwrap().iter().all(|e| e.action != AUDIT_ACTION));
}

#[tokio::test]
async fn a_completed_migration_is_complete_only_while_the_source_is_what_was_verified() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    seeded(&a).await;
    migrate_files(&a, &b).await.unwrap();
    // The marker records what the source held; a rerun over the same source has nothing to do.
    let marker: Marker = serde_json::from_value(SqliteStore::open_read_only(&b, "").unwrap().migration_marker().await.unwrap().unwrap()).unwrap();
    let verified = marker.verified.clone().expect("the verified state of the source");
    {
        let (source, _lock) = SqliteStore::open_source(&a, "").unwrap();
        migrate::ensure_source_unchanged(&source, &verified, "since").await.unwrap();
    }
    assert!(!migrate_files(&a, &b).await.unwrap().ran);

    // The source is written to afterwards (the server was started on it again): the target
    // does not hold that, and a rerun says so instead of reporting a completed migration.
    {
        let store = SqliteStore::open(&a, PREFIX).unwrap();
        store.migrate(DIM, EMBEDDER).await.unwrap();
        store.audit("agent-1", "memory.admit", TENANT, Some("user:ada"), None, serde_json::json!({})).await.unwrap();
    }
    let (source, lock) = SqliteStore::open_source(&a, "").unwrap();
    assert!(migrate::ensure_source_unchanged(&source, &verified, "since").await.is_err());
    let target = SqliteStore::open_read_only(&b, "").unwrap();
    let plan = migrate::inspect(&source, Some(&target), &options(&a, &b), false).await.unwrap();
    assert_eq!(plan.target_state, TargetState::Complete);
    assert!(plan.attention.iter().any(|a| a.blocking && a.text.contains("the source has changed since")), "{:?}", plan.attention);
    drop((source, lock, target));
    let err = migrate_files(&a, &b).await.unwrap_err().to_string();
    assert!(err.contains("cannot start") && err.contains("the source has changed since"), "{err}");
}

/// A queued job that fails: its row changes in place, no row is added, no audit event is written.
fn fail_a_queued_job(file: &Path) {
    let writer = rusqlite::Connection::open(file).unwrap();
    let n = writer.execute("UPDATE mh_enrich_job SET status = 'failed', error = 'the model is down', attempts = 3 WHERE status = 'pending'", []).unwrap();
    assert_eq!(n, 1);
}

#[tokio::test]
async fn a_row_changed_in_place_is_a_changed_source() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    seeded(&a).await;
    migrate_files(&a, &b).await.unwrap();
    let marker: Marker = serde_json::from_value(SqliteStore::open_read_only(&b, "").unwrap().migration_marker().await.unwrap().unwrap()).unwrap();
    let verified = marker.verified.expect("the verified state of the source");
    assert!(verified.digests.len() == migrate::TABLES.len() - 1 && !verified.digests.contains_key("audit"), "{:?}", verified.digests.keys());
    assert!(!migrate_files(&a, &b).await.unwrap().ran);

    // After the migration completed: the counts, the newest record change and the last audit
    // event are what they were, and the source is not what the target holds.
    let figures = |file: &Path| {
        let file = file.to_path_buf();
        async move { migrate::SourceState::of(&SqliteStore::open_read_only(&file, "").unwrap().migration_summary().await.unwrap()) }
    };
    let before = figures(&a).await;
    fail_a_queued_job(&a);
    assert_eq!(figures(&a).await, before, "nothing a summary counts has moved");
    let (source, lock) = SqliteStore::open_source(&a, "").unwrap();
    assert!(migrate::ensure_source_unchanged(&source, &verified, "since").await.is_err());
    drop((source, lock));
    let err = migrate_files(&a, &b).await.unwrap_err().to_string();
    assert!(err.contains("cannot start") && err.contains("the source has changed since"), "{err}");

    // The same change while a migration is verifying its copy fails that migration.
    let (c, d) = (dir.path().join("c.db"), dir.path().join("d.db"));
    seeded(&c).await;
    let mut o = options(&c, &d);
    let file = c.clone();
    o.progress = Some(Arc::new(move |said: &str| {
        if said.starts_with("records: read back") {
            fail_a_queued_job(&file);
        }
    }));
    let err = migrate::run(Arc::new(SqliteStore::open(&c, PREFIX).unwrap()), Arc::new(SqliteStore::open(&d, PREFIX).unwrap()), &o).await.unwrap_err();
    let failed = err.downcast_ref::<VerificationFailed>().expect("a verification failure");
    assert!(failed.problems.len() == 1 && failed.problems[0].contains("the source changed while the copy was being verified"), "{:?}", failed.problems);
    let marker: Marker = serde_json::from_value(SqliteStore::open_read_only(&d, "").unwrap().migration_marker().await.unwrap().unwrap()).unwrap();
    assert_eq!((marker.state.as_str(), marker.verified), ("copying", None));

    // A marker of before digests were recorded reads as a changed source, never as an equal one.
    let (e, f) = (dir.path().join("e.db"), dir.path().join("f.db"));
    seeded(&e).await;
    migrate_files(&e, &f).await.unwrap();
    {
        let target = SqliteStore::open(&f, PREFIX).unwrap();
        let mut old = target.migration_marker().await.unwrap().unwrap();
        old["verified"].as_object_mut().unwrap().remove("digests");
        target.set_migration_marker(&old).await.unwrap();
    }
    let err = migrate_files(&e, &f).await.unwrap_err().to_string();
    assert!(err.contains("the source has changed since"), "{err}");
}

#[tokio::test]
async fn text_postgres_cannot_hold_is_found_before_anything_is_written() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.db"), dir.path().join("b.db"));
    seeded(&a).await;
    {
        // A NUL character in a record's text, and one in another's metadata. A backslash
        // followed by "u0000" is no NUL, and is not counted.
        let store = SqliteStore::open(&a, PREFIX).unwrap();
        store.migrate(DIM, EMBEDDER).await.unwrap();
        let template = store.export_records(TENANT, None, None, 1000).await.unwrap().into_iter().find(|r| r.alt_hash.is_none() && r.structured.is_none()).unwrap();
        let odd = |content: &str, metadata: serde_json::Value| {
            let mut record = template.clone();
            record.id = uuid::Uuid::now_v7();
            record.content = content.into();
            record.metadata = metadata;
            ImportRow { record, embedding: None, alt: None }
        };
        let rows = [
            odd("A NUL \0 in the text.", serde_json::json!({})),
            odd("A NUL in the metadata.", serde_json::json!({ "note": "before\0after" })),
            odd("No NUL at all.", serde_json::json!({ "note": "a backslash: \\u0000" })),
        ];
        assert_eq!(store.import_records(&rows).await.unwrap(), 3);
    }
    let (source, _lock) = SqliteStore::open_source(&a, "").unwrap();
    let mut o = options(&a, &b);
    let plan = migrate::inspect(&source, None, &o, false).await.unwrap();
    assert_eq!(plan.source.nul_records, 2);
    assert!(!plan.blocked(), "another Lite file holds them as they are: {:?}", plan.attention);
    o.target_refuses_nul = true;
    let plan = migrate::inspect(&source, None, &o, false).await.unwrap();
    assert!(plan.attention.iter().any(|a| a.blocking && a.text.contains("2 records hold a NUL character")), "{:?}", plan.attention);
}
