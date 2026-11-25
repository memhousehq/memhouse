// SPDX-License-Identifier: Apache-2.0
//! Backup and restore of a Lite database (TR-LT-09): a snapshot taken while the store is open,
//! restored with a deletion ledger kept outside it, never brings back what was deleted since.

use chrono::{Duration, Utc};
use memhouse_core::intake::{Entry, Op, PendingRecord, Proposal};
use memhouse_core::types::*;
use memhouse_core::{IntakeQueue, Store};
use memhouse_store_sqlite::backup::{self, LedgerEntry, Manifest};
use memhouse_store_sqlite::SqliteStore;
use serde_json::json;
use std::path::Path;
use uuid::Uuid;

const T: &str = "acme";
const EMBEDDER: &str = "test:axis";

fn record(subject: &str, content: &str) -> NewMemory {
    let now = Utc::now();
    let m = Memory {
        id: Uuid::now_v7(),
        tenant: T.into(),
        subject: subject.into(),
        kind: MemoryKind::Semantic,
        status: MemoryStatus::Committed,
        content: content.into(),
        session_id: None,
        turn_ref: None,
        occurred_at: None,
        valid_from: now - Duration::seconds(1),
        valid_to: None,
        supersedes: None,
        labels: vec![],
        tags: vec![],
        source: "test".into(),
        confidence: 0.9,
        metadata: json!({}),
        created_at: now,
        expires_at: None,
        scope: Scope::default(),
        provenance: Provenance::default(),
        language: None,
    };
    let hash = memhouse_core::engine::content_hash(&m.content);
    let mut n = NewMemory::new(m, hash);
    n.embedding = Some(vec![1.0, 0.0, 0.0, 0.0]);
    n
}

async fn open(path: &Path) -> SqliteStore {
    let store = SqliteStore::open(path, "").unwrap();
    store.migrate(4, EMBEDDER).await.unwrap();
    store
}

fn keyword_hits(path: &Path, word: &str) -> i64 {
    rusqlite::Connection::open(path).unwrap().query_row("SELECT count(*) FROM mh_memory_fts WHERE mh_memory_fts MATCH ?1", [word], |r| r.get(0)).unwrap()
}

async fn ids(store: &SqliteStore) -> Vec<Uuid> {
    let mut ids: Vec<Uuid> = store.export_records(T, None, None, 1000).await.unwrap().iter().map(|r| r.id).collect();
    ids.sort();
    ids
}

#[tokio::test]
async fn a_restore_reapplies_deletions_made_after_the_snapshot() {
    let home = tempfile::tempdir().unwrap();
    let db = home.path().join("memhouse.db");
    let dir = home.path().join("backup");
    let (kept, deleted, other) = (record("user:ada", "Ada lives in Porto"), record("user:ada", "Ada owes Bob forty euros"), record("user:cy", "Cy rides a motorbike"));
    let erased = [record("user:bo", "Bo is allergic to walnuts"), record("user:bo", "Bo works nights")];
    // A fact derived from the record that will be deleted: it must go with it at the restore too.
    let mut derived = record("user:ada", "Ada has a debt");
    derived.memory.metadata = json!({ "source_ids": [deleted.memory.id] });

    let store = open(&db).await;
    store.insert(&[kept.clone(), deleted.clone(), other.clone(), derived.clone()]).await.unwrap();
    store.insert(&erased).await.unwrap();
    store.audit("test", "memory.admit", T, Some("user:ada"), Some(kept.memory.id), json!({})).await.unwrap();
    // A deletion made before the backup: already in the snapshot's ledger, not applied twice.
    let early = record("user:ada", "Ada's old phone number");
    store.insert(std::slice::from_ref(&early)).await.unwrap();
    assert!(store.delete(T, early.memory.id, "ada").await.unwrap());

    // Back up while the store stays open.
    let (snapshot, manifest) = backup::create(&store, &dir, "test").await.unwrap();
    assert_eq!((manifest.counts.records, manifest.counts.subjects, manifest.counts.ledger_entries, manifest.counts.audit_events), (6, 3, 1, 1));
    assert_eq!(manifest.embedder.as_ref().map(|e| (e.embedder.as_str(), e.dim)), Some((EMBEDDER, 4)));
    assert_eq!(manifest.schema_version, memhouse_store_sqlite::SCHEMA_VERSION);
    assert_eq!(snapshot.tenants().unwrap(), [T]);
    drop(snapshot);
    manifest.write(&dir).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        for f in [backup::SNAPSHOT_FILE, backup::LEDGER_FILE, backup::MANIFEST_FILE] {
            assert_eq!(std::fs::metadata(dir.join(f)).unwrap().permissions().mode() & 0o777, 0o600, "{f}");
        }
    }
    assert!(backup::create(&store, &dir, "test").await.is_err(), "a backup is never written over another");

    // After the backup: a record is written, one is deleted, a subject is erased.
    let later = record("user:cy", "Cy moved to Faro");
    store.insert(std::slice::from_ref(&later)).await.unwrap();
    assert!(store.delete(T, deleted.memory.id, "ada").await.unwrap());
    assert_eq!(store.delete_subject(T, "user:bo", "dpo", true).await.unwrap(), 2);
    assert_eq!(ids(&store).await.len(), 3);

    // The ledger kept outside the snapshot: the live database's, exported on its own.
    let ledger_file = home.path().join("ledger.jsonl");
    backup::write_ledger(&ledger_file, &store.ledger().unwrap()).unwrap();
    let ledger = backup::read_ledger(&ledger_file).unwrap();
    assert_eq!(ledger.iter().map(|e| e.scope.as_str()).collect::<Vec<_>>(), ["memory", "memory", "subject"]);
    drop(store);

    // Restore the earlier snapshot over the database, with the later ledger.
    let manifest = Manifest::read(&dir).unwrap();
    let from = manifest.verified_snapshot(&dir).unwrap();
    let r = backup::restore(&from, &db, &ledger, "cli", T, json!({ "snapshot_sha256": manifest.snapshot.sha256 })).await.unwrap();
    assert_eq!((r.ledger.given, r.ledger.known, r.ledger.applied), (3, 1, 2));
    // The deleted record and the fact derived from it, and the erased subject's two records.
    assert_eq!(r.ledger.records_removed, 4);
    assert_eq!(r.audit_broken_at, None);

    let store = open(&db).await;
    for gone in [&deleted, &derived, &erased[0], &erased[1], &early] {
        assert!(store.get(T, gone.memory.id).await.unwrap().is_none(), "{:?} came back", gone.memory.content);
    }
    // What the snapshot held and nobody deleted is back; what was written after it is not.
    let mut expected = vec![kept.memory.id, other.memory.id];
    expected.sort();
    assert_eq!(ids(&store).await, expected);
    assert_eq!(store.get(T, kept.memory.id).await.unwrap().unwrap().content, "Ada lives in Porto");
    assert!(store.get(T, later.memory.id).await.unwrap().is_none());
    assert!(store.subjects(T, 10).await.unwrap().iter().all(|(s, _)| s != "user:bo"));
    // Keywords and cached vectors of the removed text went with it.
    drop(store);
    assert_eq!((keyword_hits(&db, "walnuts"), keyword_hits(&db, "euros"), keyword_hits(&db, "porto")), (0, 0, 1));
    let store = open(&db).await;

    // The audit chain verifies, and says what the restore did.
    let (events, broken) = store.audit_verify().await.unwrap();
    assert_eq!(broken, None);
    assert_eq!(events, 4);
    let log = store.audit_log(T, 10).await.unwrap();
    let actions: Vec<&str> = log.iter().rev().map(|e| e.action.as_str()).collect();
    assert_eq!(actions, ["memory.admit", "deletion.reapply", "deletion.reapply", "backup.restore"]);
    assert_eq!(log[0].detail["ledger"]["applied"], 2);
    assert_eq!(log[0].detail["snapshot_sha256"], manifest.snapshot.sha256.as_str());
    assert_eq!((log[1].subject.as_deref(), log[1].detail["scope"].as_str(), log[1].detail["deleted_by"].as_str()), (Some("user:bo"), Some("subject"), Some("dpo")));
    assert_eq!(log[2].memory_id, Some(deleted.memory.id));

    // The restored database carries the whole ledger, as the deletions were made: the next restore re-applies them too.
    assert_eq!(store.ledger().unwrap(), ledger);
    // Applying it again changes nothing.
    assert_eq!(store.apply_ledger(&ledger, "cli").unwrap(), backup::Reapplied { given: 3, known: 3, applied: 0, records_removed: 0 });
    // Nothing of the work is left beside the database.
    let left: Vec<String> = std::fs::read_dir(home.path()).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).filter(|n| n.contains("restoring")).collect();
    assert!(left.is_empty(), "{left:?}");
}

#[tokio::test]
async fn a_restore_refuses_a_changed_snapshot_and_an_unknown_deletion() {
    let home = tempfile::tempdir().unwrap();
    let db = home.path().join("memhouse.db");
    let dir = home.path().join("backup");
    let a = record("user:ada", "Ada lives in Porto");
    let store = open(&db).await;
    store.insert(std::slice::from_ref(&a)).await.unwrap();
    let (snapshot, manifest) = backup::create(&store, &dir, "test").await.unwrap();
    drop(snapshot);
    manifest.write(&dir).unwrap();
    let from = manifest.verified_snapshot(&dir).unwrap();

    // A ledger row this build cannot apply stops the restore; the database stays as it was.
    store.insert(&[record("user:ada", "written after the backup")]).await.unwrap();
    drop(store);
    let unknown = LedgerEntry { at: Utc::now(), tenant: T.into(), subject: None, memory_id: None, scope: "galaxy".into(), actor: "x".into() };
    let e = backup::restore(&from, &db, &[unknown], "cli", T, json!({})).await.unwrap_err().to_string();
    assert!(e.contains("unknown deletion-ledger scope \"galaxy\""), "{e}");
    assert_eq!(ids(&open(&db).await).await.len(), 2, "a failed restore replaced the database");
    assert!(std::fs::read_dir(home.path()).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().contains("restoring")));

    // A snapshot that is not what the manifest recorded is not restored.
    let mut bytes = std::fs::read(&from).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 1;
    std::fs::write(&from, bytes).unwrap();
    let e = manifest.verified_snapshot(&dir).unwrap_err().to_string();
    assert!(e.contains("does not match its manifest") && e.contains(&manifest.snapshot.sha256), "{e}");
}

#[tokio::test]
async fn a_deletion_reapplied_keeps_what_was_written_after_it() {
    let home = tempfile::tempdir().unwrap();
    let store = open(&home.path().join("memhouse.db")).await;
    let old = record("user:bo", "Bo is allergic to walnuts");
    store.insert(std::slice::from_ref(&old)).await.unwrap();
    let erased_at = Utc::now() + Duration::milliseconds(5);
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    let new = record("user:bo", "Bo signed up again");
    store.insert(std::slice::from_ref(&new)).await.unwrap();
    let erasure = LedgerEntry { at: erased_at, tenant: T.into(), subject: Some("user:bo".into()), memory_id: None, scope: "subject".into(), actor: "dpo".into() };
    let r = store.apply_ledger(&[erasure], "cli").unwrap();
    assert_eq!((r.applied, r.records_removed), (1, 1));
    assert!(store.get(T, old.memory.id).await.unwrap().is_none());
    assert!(store.get(T, new.memory.id).await.unwrap().is_some());
}

/// TR-WF-03: a deletion is re-applied to the record it names wherever the snapshot holds it:
/// still queued (the worker had not written it when the backup was taken), or stored with a
/// `created_at` later than the deletion (an imported record keeps its file's time).
#[tokio::test]
async fn a_restore_removes_a_record_deleted_while_queued_and_one_dated_after_its_deletion() {
    let home = tempfile::tempdir().unwrap();
    let db = home.path().join("memhouse.db");
    let dir = home.path().join("backup");
    let store = open(&db).await;
    let mut dated_ahead = record("user:ada", "Ada's passport number, imported with a time ahead of the clock");
    dated_ahead.memory.created_at = Utc::now() + Duration::days(1);
    store.insert(std::slice::from_ref(&dated_ahead)).await.unwrap();
    let (forgotten, kept) = (record("user:ada", "Ada's PIN, forgotten before it was written"), record("user:ada", "Ada likes tea"));
    let pending =
        |n: &NewMemory| PendingRecord { content_hash: n.content_hash.clone(), memory: n.memory.clone(), redactions: vec![], focus: None, structured: None, code_refs: vec![] };
    let proposal = Proposal {
        id: Uuid::now_v7(),
        tenant: T.into(),
        subject: "user:ada".into(),
        actor: "agent".into(),
        user: None,
        source: "test".into(),
        op: Op::Remember,
        entry: Entry::Commit,
        records: vec![pending(&forgotten), pending(&kept)],
        session_id: None,
        enqueued_at: Utc::now(),
    };
    store.enqueue(&proposal).await.unwrap();

    // The backup holds the proposal with both records, and the stored record.
    let (snapshot, manifest) = backup::create(&store, &dir, "test").await.unwrap();
    drop(snapshot);
    manifest.write(&dir).unwrap();

    // After it: the queued record is forgotten (it never had a row), the stored one deleted.
    assert_eq!(store.discard(T, ForgetScope::Record, &forgotten.memory.id.to_string()).await.unwrap(), 1);
    assert!(!store.delete(T, forgotten.memory.id, "ada").await.unwrap(), "it was only queued");
    assert!(store.delete(T, dated_ahead.memory.id, "ada").await.unwrap());
    let ledger = store.ledger().unwrap();
    assert_eq!(ledger.iter().map(|e| (e.scope.as_str(), e.memory_id)).collect::<Vec<_>>(), [("memory", Some(forgotten.memory.id)), ("memory", Some(dated_ahead.memory.id))]);
    drop(store);

    let from = manifest.verified_snapshot(&dir).unwrap();
    let r = backup::restore(&from, &db, &ledger, "cli", T, json!({})).await.unwrap();
    assert_eq!((r.ledger.applied, r.ledger.records_removed), (2, 1));
    let store = open(&db).await;
    assert!(store.get(T, dated_ahead.memory.id).await.unwrap().is_none(), "a record dated after its deletion came back");
    assert!(store.pending(T, forgotten.memory.id).await.unwrap().is_none(), "a record forgotten while queued is queued again");
    // The other record of the proposal is still queued, and is the only one a worker gets.
    assert_eq!(store.pending(T, kept.memory.id).await.unwrap().map(|m| m.content), Some("Ada likes tea".to_string()));
    let claimed = store.claim(5, 60, Some((T, "user:ada"))).await.unwrap();
    assert_eq!(claimed[0].proposal.records.iter().map(|r| r.memory.id).collect::<Vec<_>>(), [kept.memory.id]);
    assert_eq!(store.ledger().unwrap(), ledger);
}

/// A backup's tenants are those with a record or a link: a tenant that only links subjects
/// gets its canonical export too.
#[tokio::test]
async fn a_tenant_with_links_alone_is_exported() {
    let home = tempfile::tempdir().unwrap();
    let store = open(&home.path().join("memhouse.db")).await;
    store.insert(&[record("user:ada", "Ada lives in Porto")]).await.unwrap();
    let link = Link {
        tenant: "links-only".into(),
        subject: "user:bo".into(),
        linked_subject: "team:ops".into(),
        link_type: "member".into(),
        memory_id: None,
        created_by: "test".into(),
        created_at: Utc::now(),
    };
    store.link_put(&link).await.unwrap();
    assert_eq!(store.tenants().unwrap(), [T, "links-only"]);
}
