// SPDX-License-Identifier: Apache-2.0
//! The parts of the store interface the conformance kits do not reach, each exercised against
//! what the Postgres store does: filters, cascades, the write stage, queues, policies,
//! identities, export and import, re-embedding.

use chrono::{DateTime, Duration, Utc};
use memhouse_core::intake::{AuditEntry, Entry, IntakeWrite, Op, PendingRecord, Proposal};
use memhouse_core::traits::Held;
use memhouse_core::types::*;
use memhouse_core::{IntakeQueue, Store};
use memhouse_store_sqlite::SqliteStore;
use serde_json::json;
use uuid::Uuid;

const DIM: usize = 8;
const T: &str = "acme";
const S: &str = "user:ada";

/// A unit vector along one axis, tilted a little towards the next.
fn axis(i: usize, tilt: f32) -> Vec<f32> {
    let mut v = vec![0.0; DIM];
    v[i % DIM] = 1.0;
    v[(i + 1) % DIM] = tilt;
    v
}

fn memory(subject: &str, content: &str) -> Memory {
    let now = Utc::now();
    Memory {
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
        stale_since: None,
    }
}

fn new(m: Memory, embedding: Option<Vec<f32>>) -> NewMemory {
    let hash = memhouse_core::engine::content_hash(&m.content);
    let mut n = NewMemory::new(m, hash);
    n.embedding = embedding;
    n
}

fn query(subject: &str, text: &str, embedding: Option<Vec<f32>>) -> SearchQuery {
    SearchQuery {
        tenant: T.into(),
        subject: subject.into(),
        text: text.into(),
        embedding,
        kinds: None,
        tags: None,
        denied_labels: vec![],
        as_of: None,
        valid_at: Utc::now(),
        mode: RetrievalMode::Hybrid,
        per_retriever: 50,
        limit: 10,
        rrf_k: 60.0,
        keyword_weight: 1.0,
        vector_weight: 1.0,
        windows: vec![],
        scope: Scope::default(),
        include_candidates: false,
        shared_agents: vec![],
        with_vectors: false,
        include_stale: false,
    }
}

fn list(subject: &str) -> ListQuery {
    ListQuery { tenant: T.into(), subject: Some(subject.into()), include_inactive: true, limit: 100, ..Default::default() }
}

fn audit(action: &str) -> AuditEntry {
    AuditEntry { actor: "test".into(), action: action.into(), subject: Some(S.into()), memory_id: None, detail: json!({ "why": "test" }) }
}

fn proposal(records: Vec<Memory>) -> Proposal {
    Proposal {
        id: records[0].id,
        tenant: T.into(),
        subject: records[0].subject.clone(),
        actor: "agent-1".into(),
        user: Some("ada".into()),
        source: "test".into(),
        op: Op::Remember,
        entry: Entry::Commit,
        records: records
            .into_iter()
            .map(|m| PendingRecord {
                content_hash: memhouse_core::engine::content_hash(&m.content),
                memory: m,
                redactions: vec![],
                focus: None,
                structured: None,
                code_refs: vec![],
                refs_inherited: false,
                refs_from: None,
            })
            .collect(),
        session_id: None,
        enqueued_at: Utc::now(),
    }
}

async fn store() -> (tempfile::TempDir, SqliteStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteStore::open(&dir.path().join("memhouse.db"), "passage: ").unwrap();
    store.migrate(DIM, "test:model").await.unwrap();
    (dir, store)
}

fn ids(hits: &[Hit]) -> Vec<Uuid> {
    hits.iter().map(|h| h.memory.id).collect()
}

async fn count(s: &SqliteStore, subject: &str) -> usize {
    s.list(&list(subject)).await.unwrap().len()
}

#[tokio::test]
async fn records_round_trip_and_filters() {
    let (_dir, s) = store().await;
    let mut a = memory(S, "Ada keeps her bicycle in the shed behind the house.");
    a.labels = vec!["private".into()];
    a.tags = vec!["home".into()];
    a.occurred_at = Some(Utc::now() - Duration::days(10));
    a.scope = Scope { org: Some("org-1".into()), team: None, agent: Some("agent-1".into()), user: Some("ada".into()), session: None };
    a.provenance = Provenance { agent: Some("agent-1".into()), user: Some("ada".into()), policy_version: Some("p1".into()), ..Default::default() };
    a.metadata = json!({ "note": "kept", "n": 3 });
    a.language = Some("en".into());
    let mut b = memory(S, "The bicycle needs a new chain before the spring.");
    b.kind = MemoryKind::Commitment;
    b.created_at = a.created_at + Duration::milliseconds(5);
    let mut w = memory(S, "Scratch note of the session about bicycles.");
    w.kind = MemoryKind::Working;
    w.scope.session = Some("sess-1".into());
    w.metadata = json!({ "ttl": "session" });
    w.expires_at = Some(Utc::now() + Duration::minutes(5));
    w.created_at = a.created_at + Duration::milliseconds(9);
    let (ida, idb, idw) = (a.id, b.id, w.id);
    let mut na = new(a.clone(), Some(axis(0, 0.0)));
    na.alt = Some(("alt-key".into(), axis(3, 0.0)));
    na.structured = Some(Structured { record_type: "vehicle".into(), attrs: json!({ "type": "Bicycle", "wheels": 2, "kept": { "in": "shed" } }) });
    na.code_refs = vec![CodeRef::new("src/shed.rs", "h1")];
    s.insert(&[na, new(b, Some(axis(1, 0.0))), new(w, Some(axis(2, 0.0)))]).await.unwrap();

    // Every field of the record comes back (timestamps at microsecond precision, as in Postgres).
    let got = s.get(T, ida).await.unwrap().unwrap();
    assert_eq!((got.labels.clone(), got.tags.clone(), got.scope.clone(), got.metadata.clone()), (a.labels.clone(), a.tags.clone(), a.scope.clone(), a.metadata.clone()));
    assert_eq!((got.provenance.policy_version.as_deref(), got.language.as_deref(), got.confidence), (Some("p1"), Some("en"), 0.9));
    assert_eq!(got.created_at.timestamp_micros(), a.created_at.timestamp_micros());
    assert_eq!(got.occurred_at.map(|t| t.timestamp_micros()), a.occurred_at.map(|t| t.timestamp_micros()));
    assert!(s.get("other", ida).await.unwrap().is_none());
    assert_eq!(s.get_many(T, &[ida, idb, Uuid::now_v7()]).await.unwrap().len(), 2);
    assert_eq!(s.find_by_hash(T, S, &memhouse_core::engine::content_hash(&a.content)).await.unwrap(), Some(ida));
    assert_eq!(s.existing_hashes(T, S, &[memhouse_core::engine::content_hash(&a.content), "nope".into()]).await.unwrap().len(), 1);
    // Inserting the same id again is an error, not a silent skip.
    assert!(s.insert(&[new(a.clone(), None)]).await.is_err());
    // A vector of another size is refused, as a `vector(n)` column refuses it.
    assert!(s.insert(&[new(memory(S, "wrong size"), Some(vec![1.0; DIM + 1]))]).await.is_err());

    // list: newest first, keyset paging, kinds, labels, tags, scope, session, validity.
    let all = s.list(&list(S)).await.unwrap();
    assert_eq!(all.iter().map(|m| m.id).collect::<Vec<_>>(), vec![idw, idb, ida]);
    let page = s.list(&ListQuery { before: Some((all[0].created_at, all[0].id)), limit: 1, ..list(S) }).await.unwrap();
    assert_eq!(page.iter().map(|m| m.id).collect::<Vec<_>>(), vec![idb]);
    assert_eq!(s.list(&ListQuery { offset: 2, ..list(S) }).await.unwrap()[0].id, ida);
    assert_eq!(s.list(&ListQuery { kinds: Some(vec![MemoryKind::Commitment]), ..list(S) }).await.unwrap().len(), 1);
    assert_eq!(s.list(&ListQuery { denied_labels: vec!["private".into()], ..list(S) }).await.unwrap().len(), 2);
    assert_eq!(s.list(&ListQuery { tags: Some(vec!["home".into(), "x".into()]), ..list(S) }).await.unwrap().len(), 1);
    assert_eq!(s.list(&ListQuery { tags: Some(vec![]), ..list(S) }).await.unwrap().len(), 0);
    assert_eq!(s.list(&ListQuery { session: Some("sess-1".into()), ..list(S) }).await.unwrap().len(), 1);
    let scoped = |agent: &str, shared: Vec<String>| ListQuery { scope: Scope { agent: Some(agent.into()), ..Default::default() }, shared_agents: shared, ..list(S) };
    assert_eq!(s.list(&scoped("agent-2", vec![])).await.unwrap().len(), 2);
    assert_eq!(s.list(&scoped("agent-2", vec!["agent-1\u{1f}*".into()])).await.unwrap().len(), 3);
    assert_eq!(s.list(&scoped("agent-2", vec!["agent-1\u{1f}semantic".into()])).await.unwrap().len(), 3);
    assert_eq!(s.list(&scoped("agent-2", vec!["agent-1\u{1f}working".into()])).await.unwrap().len(), 2);
    let session = |v: &str| ListQuery { scope: Scope { session: Some(v.into()), ..Default::default() }, ..list(S) };
    assert_eq!(s.list(&session("sess-2")).await.unwrap().len(), 2);
    assert_eq!(s.list(&session(memhouse_core::access::NOBODY)).await.unwrap().len(), 2, "no session named: working memory stays session-local");
    assert_eq!(s.list(&ListQuery { live_at: Some(Utc::now() + Duration::hours(1)), ..list(S) }).await.unwrap().len(), 2, "the working note has expired by then");

    // Search: keyword and vector fused; the same filters.
    let hits = s.search(&query(S, "where is the bicycle kept", Some(axis(0, 0.1)))).await.unwrap();
    assert_eq!(hits[0].memory.id, ida);
    assert_eq!((hits[0].keyword_rank.is_some(), hits[0].vector_rank), (true, Some(1)));
    assert!(hits[0].embedding.is_none() && hits[0].similarity.unwrap() > 0.9);
    // Stemming: "bicycles" finds "bicycle"; a question of stop words alone finds nothing.
    let kw = |text: &str| SearchQuery { mode: RetrievalMode::Keyword, ..query(S, text, None) };
    assert_eq!(s.search(&kw("bicycles")).await.unwrap().len(), 3);
    assert!(s.search(&kw("where is the")).await.unwrap().is_empty());
    assert!(s.search(&kw("\"unbalanced (AND OR NOT *")).await.unwrap().is_empty());
    assert!(s.search(&SearchQuery { subject: "user:bob".into(), ..kw("bicycle") }).await.unwrap().is_empty());
    assert!(s.search(&SearchQuery { tenant: "other".into(), ..kw("bicycle") }).await.unwrap().is_empty());
    // The second vector counts: the query along its axis ranks the record first.
    let dense = |v: Vec<f32>| SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(v)) };
    // Its similarity is the second vector's: every first vector is orthogonal to this query, so
    // a scan that ignored the second one would tie them all at 0.
    let by_alt = s.search(&dense(axis(3, 0.0))).await.unwrap();
    assert_eq!(by_alt[0].memory.id, ida);
    assert!(by_alt[0].similarity.unwrap() > 0.99 && by_alt[1].similarity.unwrap() < 0.01, "{:?}", by_alt.iter().map(|h| h.similarity).collect::<Vec<_>>());
    let with = s.search(&SearchQuery { with_vectors: true, limit: 1, ..dense(axis(1, 0.0)) }).await.unwrap();
    assert_eq!((with[0].memory.id, with[0].embedding.as_ref().map(|v| v.len())), (idb, Some(DIM)));
    assert_eq!(ids(&s.search(&SearchQuery { kinds: Some(vec![MemoryKind::Working]), ..dense(axis(0, 0.0)) }).await.unwrap()), vec![idw]);
    assert_eq!(s.search(&SearchQuery { tags: Some(vec!["home".into()]), ..dense(axis(1, 0.0)) }).await.unwrap().len(), 1);
    assert_eq!(s.search(&SearchQuery { denied_labels: vec!["private".into()], ..dense(axis(0, 0.0)) }).await.unwrap().len(), 2);
    let window = |from: i64, to: i64| SearchQuery { windows: vec![(Utc::now() - Duration::days(from), Utc::now() - Duration::days(to))], ..dense(axis(0, 0.0)) };
    assert_eq!(ids(&s.search(&window(11, 9)).await.unwrap()), vec![ida]);
    assert!(s.search(&window(5, 1)).await.unwrap().is_empty());
    let agent = |shared: Vec<String>| SearchQuery { scope: Scope { agent: Some("agent-2".into()), ..Default::default() }, shared_agents: shared, ..dense(axis(0, 0.0)) };
    assert_eq!(s.search(&agent(vec![])).await.unwrap().len(), 2);
    assert_eq!(s.search(&agent(vec!["agent-1\u{1f}semantic".into()])).await.unwrap().len(), 3);
    let in_session = |v: &str| SearchQuery { scope: Scope { session: Some(v.into()), ..Default::default() }, ..dense(axis(2, 0.0)) };
    assert_eq!(s.search(&in_session("sess-1")).await.unwrap()[0].memory.id, idw);
    assert_eq!(s.search(&in_session(memhouse_core::access::NOBODY)).await.unwrap().len(), 2);
    assert_eq!(s.search(&SearchQuery { valid_at: Utc::now() + Duration::hours(1), ..dense(axis(2, 0.0)) }).await.unwrap().len(), 2, "expired by then");
    assert_eq!(s.search(&SearchQuery { valid_at: Utc::now() - Duration::days(1), ..dense(axis(2, 0.0)) }).await.unwrap().len(), 0, "not yet valid then");
    let many = s.search_many(&[dense(axis(0, 0.0)), kw("chain"), dense(axis(2, 0.0))]).await.unwrap();
    assert_eq!((many[0][0].memory.id, ids(&many[1]), many[2][0].memory.id), (ida, vec![idb], idw));
    // The weights and k of the fusion are the query's.
    let fused = s.search(&SearchQuery { keyword_weight: 2.0, vector_weight: 0.5, rrf_k: 10.0, ..query(S, "chain", Some(axis(1, 0.0))) }).await.unwrap();
    assert!((fused[0].score - (2.0 / 11.0 + 0.5 / 11.0)).abs() < 1e-6, "{}", fused[0].score);

    // Gate lookups: same kind, committed, exactly the same scope.
    assert_eq!(s.nearest(T, S, MemoryKind::Semantic, &axis(0, 0.0)).await.unwrap().map(|n| n.0), Some(ida));
    assert!(s.nearest(T, S, MemoryKind::Procedural, &axis(0, 0.0)).await.unwrap().is_none());
    assert!(s.nearest_many(T, S, MemoryKind::Semantic, &axis(0, 0.0), 5, &Scope::default()).await.unwrap().is_empty(), "the record is scoped");
    assert_eq!(s.nearest_many(T, S, MemoryKind::Semantic, &axis(0, 0.0), 5, &a.scope).await.unwrap().len(), 1);
    assert_eq!(s.nearest_many(T, S, MemoryKind::Commitment, &axis(1, 0.0), 5, &Scope::default()).await.unwrap()[0].0, idb);

    // Structured records and code references.
    let (st, refs) = s.representations(T, ida).await.unwrap();
    assert_eq!((st.map(|x| x.record_type), refs.len()), (Some("vehicle".into()), 1));
    assert_eq!(s.representations("other", ida).await.unwrap().1.len(), 0);
    assert_eq!(s.structured_query(T, S, "vehicle", &json!({ "wheels": 2, "kept": { "in": "shed" } })).await.unwrap().len(), 1);
    assert!(s.structured_query(T, S, "vehicle", &json!({ "wheels": 3 })).await.unwrap().is_empty());
    let q = query(S, "", None);
    assert_eq!(s.structured_lookup(&q, Some("vehicle"), None, &[]).await.unwrap()[0].score, 1.0);
    assert_eq!(s.structured_lookup(&q, None, Some(&json!({ "type": "Bicycle" })), &["BICYCLE".into()]).await.unwrap().len(), 1);
    assert_eq!(s.structured_lookup(&q, None, None, &["2".into()]).await.unwrap().len(), 1);
    assert!(s.structured_lookup(&q, Some("pet"), None, &[]).await.unwrap().is_empty());
    assert!(s.structured_lookup(&q, None, None, &["car".into()]).await.unwrap().is_empty());
    assert!(s.structured_lookup(&SearchQuery { denied_labels: vec!["private".into()], ..q.clone() }, None, None, &[]).await.unwrap().is_empty());
    assert_eq!(s.stale_code_refs(T, S, "src/shed.rs", "h2").await.unwrap(), vec![ida]);
    assert!(s.stale_code_refs(T, S, "src/shed.rs", "h1").await.unwrap().is_empty());

    // Status changes follow the lifecycle; labels are replaced; sessions extend; records expire.
    assert!(!s.set_status(T, ida, MemoryStatus::Rejected).await.unwrap(), "committed never becomes rejected");
    assert!(s.set_status(T, ida, MemoryStatus::Quarantined).await.unwrap());
    assert_eq!(s.set_status_many(T, &[ida, idb], MemoryStatus::Committed).await.unwrap(), 1);
    assert!(s.set_labels(T, ida, &["public".into()]).await.unwrap());
    assert_eq!(s.get(T, ida).await.unwrap().unwrap().labels, vec!["public".to_string()]);
    assert!(!s.set_labels(T, Uuid::now_v7(), &[]).await.unwrap());
    let until = Utc::now() + Duration::hours(2);
    assert_eq!(s.session_extend(T, S, "sess-1", until).await.unwrap(), 1);
    assert_eq!(s.session_extend(T, S, "sess-1", until).await.unwrap(), 0, "only when later");
    assert_eq!(s.get(T, idw).await.unwrap().unwrap().expires_at.map(|t| t.timestamp_micros()), Some(until.timestamp_micros()));
    assert_eq!(s.expire_due(T).await.unwrap(), 0);

    // Supersession ends the old version's validity where the new one starts.
    let mut newer = memory(S, "Ada keeps her bicycle in the garage now.");
    newer.scope = a.scope.clone();
    newer.supersedes = Some(ida);
    newer.valid_from = Utc::now();
    let idn = newer.id;
    let then = Utc::now() - Duration::milliseconds(500);
    s.insert(&[new(newer.clone(), Some(axis(0, 0.05)))]).await.unwrap();
    assert!(s.set_superseded(T, ida, idn).await.unwrap());
    assert!(!s.set_superseded(T, ida, idn).await.unwrap(), "already superseded");
    let old = s.get(T, ida).await.unwrap().unwrap();
    assert_eq!((old.status, old.valid_to.map(|t| t.timestamp_micros())), (MemoryStatus::Superseded, Some(newer.valid_from.timestamp_micros())));
    assert_eq!(s.find_by_hash(T, S, &memhouse_core::engine::content_hash(&a.content)).await.unwrap(), None);
    assert_eq!(s.search(&dense(axis(0, 0.0))).await.unwrap()[0].memory.id, idn);
    // As-of recall sees the version that was true then, and only that one.
    let as_of = s.search(&SearchQuery { as_of: Some(then), valid_at: then, ..dense(axis(0, 0.0)) }).await.unwrap();
    assert!(ids(&as_of).contains(&ida) && !ids(&as_of).contains(&idn));
    // Unfiltered: every state, for the explanation.
    let unfiltered = s.search_unfiltered(&SearchQuery { denied_labels: vec!["public".into()], ..dense(axis(0, 0.0)) }).await.unwrap();
    assert!(ids(&unfiltered).contains(&ida) && ids(&unfiltered).contains(&idn));

    let stats = s.stats(T).await.unwrap();
    assert_eq!((stats.memories, stats.committed, stats.superseded, stats.subjects), (4, 3, 1, 1));
    assert_eq!(s.subjects(T, 10).await.unwrap(), vec![(S.to_string(), 3)]);
    assert_eq!(s.forget_matches(T, ForgetScope::User, "ada", 10).await.unwrap().len(), 2);
    assert_eq!(s.forget_matches(T, ForgetScope::Agent, "agent-1", 1).await.unwrap().len(), 1);
    assert_eq!(s.forget_count(T, ForgetScope::Source, "test").await.unwrap(), 4);
    assert_eq!(s.forget_count(T, ForgetScope::Subject, S).await.unwrap(), 4);
    assert_eq!(s.forget_count(T, ForgetScope::Tenant, T).await.unwrap(), 4);
    assert!(s.forget_matches(T, ForgetScope::Subject, S, 1).await.is_err());
}

#[tokio::test]
async fn deletion_cascades() {
    let (dir, s) = store().await;
    let prefix_hash = |text: &str| memhouse_core::engine::content_hash(&format!("passage: {text}"));
    let round = memory(S, "user: We moved the office to Lisbon in May.");
    let mut fact = memory(S, "The office moved to Lisbon in May.");
    fact.metadata = json!({ "derived": true, "source_ids": [round.id.to_string()] });
    let mut promoted = memory(S, "Office location: Lisbon.");
    promoted.metadata = json!({ "promoted_from": [fact.id.to_string()], "promoted_from_kinds": ["semantic"] });
    let mut again = memory("team:ops", "Lisbon is the office.");
    again.metadata = json!({ "promoted_from": [promoted.id.to_string()] });
    let other = memory(S, "An unrelated record that stays.");
    let (idr, idf, idp, ida, ido) = (round.id, fact.id, promoted.id, again.id, other.id);
    let mut nr = new(round.clone(), Some(axis(0, 0.0)));
    nr.alt = Some(("alt-of-round".into(), axis(1, 0.0)));
    s.insert(&[nr, new(fact.clone(), Some(axis(2, 0.0))), new(promoted, None), new(again, None), new(other.clone(), None)]).await.unwrap();
    s.embed_cache_put("test:model", &[(prefix_hash(&round.content), axis(0, 0.0)), ("alt-of-round".into(), axis(1, 0.0)), (prefix_hash(&fact.content), axis(2, 0.0))])
        .await
        .unwrap();
    s.embed_cache_put("test:model", &[(prefix_hash(&other.content), axis(3, 0.0))]).await.unwrap();
    let job = s.enrich_enqueue(T, S, "sess", &[idr]).await.unwrap();
    s.llm_cache_put("extraction-1", "llm", "{}").await.unwrap();
    s.llm_cache_put("extraction-2", "llm", "{}").await.unwrap();
    s.enrich_finish(job, Some("extraction-1"), &EnrichOutcome::default()).await.unwrap();
    s.link_put(&Link {
        tenant: T.into(),
        subject: S.into(),
        linked_subject: "team:ops".into(),
        link_type: "member".into(),
        memory_id: Some(idr),
        created_by: "test".into(),
        created_at: Utc::now(),
    })
    .await
    .unwrap();
    // A promotion of the round that is still queued goes with it; another proposal stays.
    let mut queued = memory(S, "Queued promotion of the round.");
    queued.metadata = json!({ "promoted_from": [idr.to_string()] });
    let (queued, stays) = (proposal(vec![queued]), proposal(vec![memory(S, "A queued write that stays.")]));
    s.enqueue(&queued).await.unwrap();
    s.enqueue(&stays).await.unwrap();
    // A promotion whose source is gone is not queued at all.
    let mut orphan = memory(S, "Promotion of nothing.");
    orphan.metadata = json!({ "promoted_from": [Uuid::now_v7().to_string()] });
    assert!(s.enqueue(&proposal(vec![orphan])).await.is_err());

    assert!(s.delete(T, idr, "tester").await.unwrap());
    assert!(!s.delete(T, idr, "tester").await.unwrap());
    for gone in [idr, idf, idp, ida] {
        assert!(s.get(T, gone).await.unwrap().is_none(), "{gone} should have gone with the round");
    }
    assert!(s.get(T, ido).await.unwrap().is_some());
    let cached = s.embed_cache_get("test:model", &[prefix_hash(&round.content), "alt-of-round".into(), prefix_hash(&fact.content), prefix_hash(&other.content)]).await.unwrap();
    assert_eq!(cached.len(), 1, "only the unrelated record's vector stays cached");
    assert_eq!(s.enrich_status(T, Some(S)).await.unwrap().done, 0);
    assert!(s.llm_cache_get("extraction-1").await.unwrap().is_none() && s.llm_cache_get("extraction-2").await.unwrap().is_some());
    assert!(s.links(T, S).await.unwrap().is_empty(), "the link's record was deleted");
    assert!(!s.unfinished(queued.id).await.unwrap() && s.unfinished(stays.id).await.unwrap());
    assert!(s.search(&SearchQuery { mode: RetrievalMode::Keyword, ..query(S, "Lisbon office", None) }).await.unwrap().is_empty());

    // Retention: old rounds go with their facts; what was promoted from them stays.
    let mut old = memory(S, "user: An old round about the Porto office.");
    old.kind = MemoryKind::Episodic;
    old.created_at = Utc::now() - Duration::days(40);
    let mut old_fact = memory(S, "There was a Porto office.");
    old_fact.metadata = json!({ "source_ids": [old.id.to_string()] });
    let mut kept = memory(S, "Promoted: Porto office existed.");
    kept.metadata = json!({ "promoted_from": [old.id.to_string()] });
    let mut recent = memory(S, "user: A recent round.");
    recent.kind = MemoryKind::Episodic;
    let (idk, idrecent) = (kept.id, recent.id);
    let old_id = old.id;
    s.insert(&[new(old, None), new(old_fact, None), new(kept, None), new(recent, None)]).await.unwrap();
    s.enrich_enqueue(T, S, "old-session", &[old_id]).await.unwrap();
    assert_eq!(s.purge_older_than(T, MemoryKind::Episodic, 30).await.unwrap(), 2);
    assert!(s.get(T, idk).await.unwrap().is_some() && s.get(T, idrecent).await.unwrap().is_some());
    assert_eq!(s.enrich_status(T, Some(S)).await.unwrap().pending, 0);
    assert_eq!(s.purge_older_than(T, MemoryKind::Episodic, 30).await.unwrap(), 0);

    // Erasing the subject: records, queued writes, jobs, remembered responses, explanations.
    s.request_put(T, "key-1", S, "remember", "h", &json!({ "ok": true })).await.unwrap();
    s.enrich_enqueue(T, S, "sess-2", &[idrecent]).await.unwrap();
    s.insert(&[new(memory("user:bob", "Bob's record stays."), None)]).await.unwrap();
    assert_eq!(s.delete_subject(T, S, "tester", true).await.unwrap(), 3);
    assert_eq!(count(&s, S).await, 0);
    assert!(!s.subject_unfinished(T, S).await.unwrap());
    assert!(s.request_get(T, "key-1").await.unwrap().is_none());
    let jobs = s.enrich_status(T, Some(S)).await.unwrap();
    assert_eq!(jobs.pending + jobs.running + jobs.done + jobs.failed, 0);
    assert_eq!(count(&s, "user:bob").await, 1);
    assert!(s.embed_cache_get("test:model", &[prefix_hash(&other.content)]).await.unwrap().is_empty());

    // Erasing the tenant takes the rest; another tenant is untouched.
    let mut theirs = memory("user:eve", "Another tenant's record.");
    theirs.tenant = "other".into();
    s.insert(&[new(theirs, None)]).await.unwrap();
    assert_eq!(s.delete_tenant(T, "tester").await.unwrap(), 1);
    assert_eq!(s.stats(T).await.unwrap().memories, 0);
    assert_eq!(s.stats("other").await.unwrap().memories, 1);

    // The keyword index followed every deletion, and the file is in WAL mode.
    let raw = rusqlite::Connection::open(dir.path().join("memhouse.db")).unwrap();
    raw.execute("INSERT INTO mh_memory_fts (mh_memory_fts, rank) VALUES ('integrity-check', 1)", []).unwrap();
    let (indexed, stored): (i64, i64) = raw.query_row("SELECT (SELECT count(*) FROM mh_memory_fts), (SELECT count(*) FROM mh_memory)", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!((indexed, stored), (1, 1));
    let mode: String = raw.query_row("PRAGMA journal_mode", [], |r| r.get(0)).unwrap();
    assert_eq!(mode, "wal");
    let ledger: Vec<String> = raw.prepare("SELECT scope FROM mh_deletion_ledger ORDER BY id").unwrap().query_map([], |r| r.get(0)).unwrap().collect::<Result<_, _>>().unwrap();
    assert_eq!(ledger, ["memory", "retention", "subject", "subject", "tenant"]);
    let orphans: i64 =
        raw.query_row("SELECT (SELECT count(*) FROM mh_source_ref) + (SELECT count(*) FROM mh_structured) + (SELECT count(*) FROM mh_code_ref)", [], |r| r.get(0)).unwrap();
    assert_eq!(orphans, 0);
}

#[tokio::test]
async fn write_stage_and_queues() {
    let (_dir, s) = store().await;
    let old = memory(S, "The renewal date is 1 March.");
    let mut plan = memory(S, "Ada plans to visit Japan in May.");
    plan.status = MemoryStatus::Candidate;
    plan.metadata = json!({ "held": "plan" });
    plan.expires_at = Some(Utc::now() + Duration::days(30));
    let mut signal = memory(S, "Ada seems to prefer morning meetings.");
    signal.status = MemoryStatus::Candidate;
    signal.kind = MemoryKind::Preference;
    signal.metadata = json!({ "held": "signal" });
    let (ido, idp, ids_) = (old.id, plan.id, signal.id);
    s.insert(&[new(old, Some(axis(0, 0.0))), new(plan, Some(axis(1, 0.0))), new(signal, Some(axis(2, 0.0)))]).await.unwrap();
    let held = |reason: &'static str, kind: Option<MemoryKind>| {
        let s = s.clone();
        async move { s.nearest_held(T, S, &axis(1, 0.2), 5, &Held { reason, kind, scope: &Scope::default(), counted: None, labels: &[] }).await.unwrap() }
    };
    assert_eq!(held("plan", None).await.iter().map(|h| h.0).collect::<Vec<_>>(), vec![idp]);
    assert_eq!(held("signal", Some(MemoryKind::Preference)).await.len(), 1);
    assert!(held("signal", Some(MemoryKind::Semantic)).await.is_empty());

    // One proposal: a correction that supersedes, confirms the plan and repeats the signal.
    let mut new_fact = memory(S, "The renewal date is 1 April.");
    new_fact.supersedes = Some(ido);
    let p = proposal(vec![new_fact.clone()]);
    s.enqueue(&p).await.unwrap();
    let job = s.claim(1, 60, Some((T, S))).await.unwrap().remove(0);
    assert_eq!(s.pending_proposal(T, new_fact.id).await.unwrap(), Some(p.id));
    let write = IntakeWrite {
        proposal: Some(p.id),
        tenant: T.into(),
        records: vec![new(job.proposal.records[0].memory.clone(), Some(axis(0, 0.1)))],
        supersede: vec![(ido, new_fact.id)],
        confirm: vec![(idp, new_fact.id)],
        signals: vec![(ids_, new_fact.id, false)],
        requires: vec![],
        audit: vec![audit("memory.write"), audit("memory.supersede")],
        enrich: Some((S.into(), "sess".into(), vec![new_fact.id])),
        outcome: json!({ "stored": 1 }),
        dead: None,
    };
    assert!(s.apply_intake(&write).await.unwrap());
    assert!(!s.apply_intake(&write).await.unwrap(), "exactly once: the second attempt writes nothing");
    assert_eq!(count(&s, S).await, 4);
    assert_eq!(s.audit_log(T, 10).await.unwrap().len(), 2);
    assert_eq!(s.enrich_status(T, None).await.unwrap().pending, 1);
    assert_eq!((s.unfinished(p.id).await.unwrap(), s.outcome(p.id).await.unwrap()), (false, Some(json!({ "stored": 1 }))));
    assert_eq!(s.get(T, ido).await.unwrap().unwrap().status, MemoryStatus::Superseded);
    let confirmed = s.get(T, idp).await.unwrap().unwrap();
    assert_eq!((confirmed.status, confirmed.expires_at, confirmed.metadata), (MemoryStatus::Committed, None, json!({ "confirmed_by": new_fact.id.to_string() })));
    let seen = s.get(T, ids_).await.unwrap().unwrap();
    assert_eq!((seen.status, seen.metadata["signals"].clone(), seen.metadata["held"].clone()), (MemoryStatus::Candidate, json!(2), json!("signal")));
    // The signal again, this time committing it.
    let repeat = IntakeWrite { tenant: T.into(), signals: vec![(ids_, new_fact.id, true)], outcome: json!({}), ..Default::default() };
    assert!(s.apply_intake(&repeat).await.unwrap());
    let seen = s.get(T, ids_).await.unwrap().unwrap();
    assert_eq!((seen.status, seen.metadata["signals"].clone(), seen.metadata.get("held")), (MemoryStatus::Committed, json!(3), None));
    // Nothing is written when a precondition no longer holds: the whole transaction rolls back.
    let stale = IntakeWrite {
        tenant: T.into(),
        records: vec![new(memory(S, "Should never be stored."), None)],
        supersede: vec![(ido, new_fact.id)],
        audit: vec![audit("memory.write")],
        outcome: json!({}),
        ..Default::default()
    };
    assert!(s.apply_intake(&stale).await.is_err());
    let gone_source = IntakeWrite {
        tenant: T.into(),
        records: vec![new(memory(S, "Promotion of a deleted record."), None)],
        requires: vec![Uuid::now_v7()],
        outcome: json!({}),
        ..Default::default()
    };
    assert!(s.apply_intake(&gone_source).await.is_err());
    assert_eq!((count(&s, S).await, s.audit_log(T, 10).await.unwrap().len()), (4, 2));
    // A proposal erased meanwhile writes nothing; a poison one is set aside with its error.
    let erased = proposal(vec![memory(S, "Erased before it was written.")]);
    s.enqueue(&erased).await.unwrap();
    assert_eq!(s.discard(T, ForgetScope::Record, &erased.id.to_string()).await.unwrap(), 1);
    assert!(!s
        .apply_intake(&IntakeWrite {
            proposal: Some(erased.id),
            tenant: T.into(),
            records: vec![new(erased.records[0].memory.clone(), None)],
            outcome: json!({}),
            ..Default::default()
        })
        .await
        .unwrap());
    let poison = proposal(vec![memory(S, "Poison.")]);
    s.enqueue(&poison).await.unwrap();
    assert!(s
        .apply_intake(&IntakeWrite { proposal: Some(poison.id), tenant: T.into(), dead: Some("it failed".into()), outcome: json!({ "dead": true }), ..Default::default() })
        .await
        .unwrap());
    assert_eq!(s.status(Some(T)).await.unwrap().dead, 1);

    // Forgetting one record of a two-record proposal leaves the other queued.
    let two = proposal(vec![memory(S, "First of two."), memory(S, "Second of two.")]);
    let (first, second) = (two.records[0].memory.id, two.records[1].memory.id);
    s.enqueue(&two).await.unwrap();
    assert_eq!(s.discard(T, ForgetScope::Record, &second.to_string()).await.unwrap(), 1);
    assert!(s.pending(T, second).await.unwrap().is_none() && s.pending(T, first).await.unwrap().is_some());
    let left = s.claim(5, 60, Some((T, S))).await.unwrap();
    assert_eq!(left[0].proposal.records.len(), 1);
    assert_eq!(s.discard(T, ForgetScope::User, "ada").await.unwrap(), 1);
    assert_eq!(s.discard(T, ForgetScope::Agent, "agent-1").await.unwrap(), 0);

    // A claim without a subject never takes a scratch tenant's proposal or job.
    let scratch = format!("{T}{}abc", memhouse_core::eval::SCRATCH_MARK);
    let mut sm = memory(S, "A replayed write.");
    sm.tenant = scratch.clone();
    let mut sp = proposal(vec![sm]);
    sp.tenant = scratch.clone();
    s.enqueue(&sp).await.unwrap();
    assert!(s.claim(10, 60, None).await.unwrap().is_empty());
    assert_eq!(s.claim(10, 60, Some((&scratch, S))).await.unwrap().len(), 1);
    s.enrich_enqueue(&scratch, S, "replay", &[]).await.unwrap();
    s.enrich_enqueue(T, S, "second", &[]).await.unwrap();
    let claimed = s.enrich_claim(10, 60).await.unwrap();
    assert_eq!(claimed.len(), 1, "one job of a subject at a time, none of the scratch tenant");
    assert_eq!((claimed[0].tenant.as_str(), claimed[0].session_id.as_str(), claimed[0].attempts, claimed[0].round_ids.clone()), (T, "sess", 1, vec![new_fact.id]));
    assert!(s.enrich_claim_for(T, S, 10, 60).await.unwrap().is_empty(), "the first is still leased");
    assert_eq!(s.enrich_claim_for(&scratch, S, 10, 60).await.unwrap().len(), 1);
    // A failed job waits out its backoff; after the last attempt it is failed for good.
    s.enrich_fail(claimed[0].id, "model unavailable", 3).await.unwrap();
    assert!(s.enrich_claim_for(T, S, 10, 60).await.unwrap().is_empty(), "backing off, and still ahead of the second job");
    s.enrich_fail(claimed[0].id, "model unavailable", 1).await.unwrap();
    let st = s.enrich_status(T, Some(S)).await.unwrap();
    assert_eq!((st.failed, st.pending, st.oldest_pending_secs.is_some()), (1, 1, true));
    let next = s.enrich_claim_for(T, S, 10, 60).await.unwrap();
    assert_eq!(next[0].session_id, "second");
    s.enrich_finish(next[0].id, None, &EnrichOutcome { facts: 2, model: "m".into(), ..Default::default() }).await.unwrap();
    let outcomes = s.enrich_outcomes(T, S).await.unwrap();
    assert_eq!((outcomes.len(), outcomes[0].facts), (1, 2));
    assert!(outcomes[0].lag_ms >= 0.0);
    assert!(s.audit_verify().await.unwrap().1.is_none());
}

#[tokio::test]
async fn audit_chain_detects_tampering() {
    let (dir, s) = store().await;
    for i in 0..3 {
        s.audit("tester", "memory.write", T, Some(S), Some(Uuid::now_v7()), json!({ "n": i })).await.unwrap();
    }
    assert_eq!(s.audit_verify().await.unwrap(), (3, None));
    let log = s.audit_log(T, 2).await.unwrap();
    assert_eq!((log.len(), log[0].detail.clone(), log[0].prev_hash.clone()), (2, json!({ "n": 2 }), log[1].hash.clone()));
    let raw = rusqlite::Connection::open(dir.path().join("memhouse.db")).unwrap();
    raw.execute("UPDATE mh_audit SET actor = 'someone-else' WHERE id = 2", []).unwrap();
    assert_eq!(s.audit_verify().await.unwrap(), (2, Some(2)));
}

#[tokio::test]
async fn policies_identities_grants_and_evaluations() {
    let (_dir, s) = store().await;
    let now = Utc::now();
    // Compiled policies: the first write of a version wins.
    let line = |v: &str, n: i64| memhouse_core::format::PolicyLine { version: v.into(), body: json!({ "n": n }), created_at: now };
    s.policy_put(&line("p1", 1)).await.unwrap();
    s.policy_put(&line("p1", 2)).await.unwrap();
    assert_eq!(s.policy_body("p1").await.unwrap(), Some(json!({ "n": 1 })));
    assert_eq!((s.policy_body("p2").await.unwrap(), s.export_policies().await.unwrap().len()), (None, 1));

    // Policy specs: numbered per tenant; only an approved one can be activated.
    let v1 = s.policy_propose(T, "strict", &json!({ "rules": [] }), "h1", "ada", Some("first")).await.unwrap();
    let v2 = s.policy_propose(T, "loose", &json!({ "rules": [1] }), "h2", "ada", None).await.unwrap();
    assert_eq!((v1.version, v2.version, v1.status, v1.note.as_deref()), (1, 2, memhouse_core::policy::SpecStatus::Proposed, Some("first")));
    assert_eq!(s.policy_propose("other", "x", &json!({}), "h", "eve", None).await.unwrap().version, 1);
    let refused = s.policy_activate(T, Some(2), "c2", "rollback", "ada").await.unwrap_err().to_string();
    assert!(refused.contains("only approved policies execute"), "{refused}");
    assert!(s.policy_activate(T, Some(9), "c9", "rollback", "ada").await.is_err(), "no such version");
    assert!(s.policy_active(T).await.unwrap().is_none());
    assert!(s.policy_approve(T, 1, "bob", "c1").await.unwrap());
    assert!(!s.policy_approve(T, 1, "bob", "c1").await.unwrap());
    let active = s.policy_active(T).await.unwrap().unwrap();
    assert_eq!((active.version, active.approved_by.as_deref(), active.approved_at.is_some()), (1, Some("bob"), true));
    s.policy_activate(T, None, "default", "rollback", "ada").await.unwrap();
    assert!(s.policy_active(T).await.unwrap().is_none(), "the default policy is active");
    s.policy_activate(T, Some(1), "c1", "rollback", "ada").await.unwrap();
    let history = s.policy_history(T, 10).await.unwrap();
    assert_eq!(history.iter().map(|h| (h.version, h.action.as_str())).collect::<Vec<_>>(), vec![(Some(1), "rollback"), (None, "rollback"), (Some(1), "approve")]);
    assert_eq!((s.policy_specs(T).await.unwrap().len(), s.policy_spec(T, 2).await.unwrap().map(|p| p.name)), (2, Some("loose".into())));

    // Principals, their keys and the signing key.
    use memhouse_core::identity::{ApiKey, Principal, PrincipalKind};
    let mut p = Principal {
        id: "agent-1".into(),
        tenant: T.into(),
        kind: PrincipalKind::Agent,
        name: Some("Agent One".into()),
        subjects: vec!["user:*".into()],
        kinds: vec![MemoryKind::Semantic],
        denied_labels: vec!["secret".into()],
        org: Some("org".into()),
        team: None,
        can_commit: true,
        act_as: false,
        disabled_at: None,
        created_at: now,
        created_by: "admin".into(),
    };
    s.principal_put(&p).await.unwrap();
    p.name = Some("Renamed".into());
    p.disabled_at = Some(now);
    s.principal_put(&p).await.unwrap();
    let got = s.principal_get("agent-1").await.unwrap().unwrap();
    assert_eq!(
        (got.name.as_deref(), got.kinds.clone(), got.subjects.clone(), got.can_commit, got.disabled_at.is_some()),
        (Some("Renamed"), vec![MemoryKind::Semantic], vec!["user:*".to_string()], true, true)
    );
    // A put under another tenant changes nothing: a principal keeps its tenant.
    s.principal_put(&Principal { tenant: "other".into(), name: Some("Hijacked".into()), ..p.clone() }).await.unwrap();
    assert_eq!(s.principal_get("agent-1").await.unwrap().unwrap().tenant, T);
    assert_eq!((s.principals(Some(T)).await.unwrap().len(), s.principals(Some("other")).await.unwrap().len(), s.principals(None).await.unwrap().len()), (1, 0, 1));
    let key = ApiKey {
        id: "k1".into(),
        principal_id: "agent-1".into(),
        hash: "sha".into(),
        scopes: vec!["read".into(), "write".into()],
        expires_at: None,
        revoked_at: None,
        created_at: now,
        created_by: "admin".into(),
    };
    s.api_key_put(&key).await.unwrap();
    assert!(s.api_key_put(&ApiKey { id: "k2".into(), principal_id: "nobody".into(), ..key.clone() }).await.is_err(), "a key needs its principal");
    let grace = now + Duration::hours(1);
    assert!(s.api_key_end("k1", Some(grace)).await.unwrap());
    assert!(s.api_key_end("k1", Some(grace + Duration::hours(5))).await.unwrap());
    assert_eq!(s.api_key_get("k1").await.unwrap().unwrap().expires_at.map(|t| t.timestamp_micros()), Some(grace.timestamp_micros()), "an end never moves later");
    assert!(s.api_key_end("k1", None).await.unwrap());
    assert!(!s.api_key_end("k1", None).await.unwrap());
    assert_eq!((s.api_keys(Some("agent-1")).await.unwrap()[0].scopes.len(), s.api_keys(None).await.unwrap().len(), s.api_key_get("k9").await.unwrap().is_none()), (2, 1, true));
    let (kid, secret) = s.signing_key_current().await.unwrap();
    assert_eq!(s.signing_key_current().await.unwrap(), (kid.clone(), secret.clone()));
    assert_eq!((s.signing_key(&kid).await.unwrap(), s.signing_key("nope").await.unwrap()), (Some(secret), None));

    // Grants: never active unaudited; revoked once.
    let grant = Grant {
        id: Uuid::now_v7(),
        tenant: T.into(),
        grantor: "agent-1".into(),
        grantee: "agent-2".into(),
        subjects: "user:*".into(),
        kinds: vec![MemoryKind::Semantic],
        created_by: "admin".into(),
        created_at: now,
        expires_at: None,
        revoked_at: None,
    };
    s.grant_put(&grant, &audit("grant.create")).await.unwrap();
    let expired = Grant { id: Uuid::now_v7(), expires_at: Some(now - Duration::hours(1)), created_at: now + Duration::milliseconds(1), ..grant.clone() };
    s.grant_put(&expired, &audit("grant.create")).await.unwrap();
    assert!(s.grant_put(&Grant { id: Uuid::now_v7(), grantee: "agent-1".into(), ..grant.clone() }, &audit("grant.create")).await.is_err(), "no grant to oneself");
    assert_eq!(s.audit_log(T, 10).await.unwrap().len(), 2, "the refused grant wrote no event");
    assert_eq!((s.grants(T, Some("agent-2")).await.unwrap().len(), s.grants(T, None).await.unwrap()[0].id, s.grants(T, Some("agent-3")).await.unwrap().len()), (1, expired.id, 0));
    assert!(s.grant_revoke(T, grant.id, &audit("grant.revoke")).await.unwrap());
    assert!(!s.grant_revoke(T, grant.id, &audit("grant.revoke")).await.unwrap());
    assert_eq!((s.grants(T, Some("agent-2")).await.unwrap().len(), s.audit_log(T, 10).await.unwrap().len()), (0, 3));

    // Promotions merge their sources into the existing promoted record.
    let (src1, src2) = (memory(S, "Source one."), memory(S, "Source two."));
    let mut promoted = memory(S, "Promoted.");
    promoted.labels = vec!["b".into()];
    promoted.metadata = json!({ "promoted_from": [src1.id.to_string()], "promoted_from_kinds": ["semantic"] });
    let (id1, id2, idp) = (src1.id, src2.id, promoted.id);
    s.insert(&[new(src1, None), new(src2, None), new(promoted, None)]).await.unwrap();
    assert!(!s.promotion_merge(T, id1, &[id2], &["episodic".into()], &[], &audit("memory.promote")).await.unwrap(), "not a promotion");
    assert!(s.promotion_merge(T, idp, &[id2, id1], &["episodic".into(), "semantic".into()], &["a".into(), "b".into()], &audit("memory.promote")).await.unwrap());
    assert!(s.promotion_merge(T, idp, &[Uuid::now_v7()], &[], &[], &audit("memory.promote")).await.is_err(), "the source is gone");
    let merged = s.get(T, idp).await.unwrap().unwrap();
    assert_eq!(merged.metadata, json!({ "promoted_from": [id1.to_string(), id2.to_string()], "promoted_from_kinds": ["semantic", "episodic"] }));
    assert_eq!(merged.labels, vec!["a".to_string(), "b".to_string()]);
    // The merged link is followed by a deletion of the added source.
    assert!(s.delete(T, id2, "tester").await.unwrap());
    assert!(s.get(T, idp).await.unwrap().is_none());

    // Evaluation suites and runs.
    use memhouse_core::eval::{EvalRun, EvalTrigger, StoredSuite};
    let suite = |hash: &str| StoredSuite {
        tenant: T.into(),
        name: "smoke".into(),
        hash: hash.into(),
        suite: serde_json::from_value(json!({ "name": "smoke", "conversations": [] })).unwrap(),
        created_by: "ada".into(),
        created_at: now,
    };
    s.eval_suite_put(&suite("h1")).await.unwrap();
    s.eval_suite_put(&suite("h2")).await.unwrap();
    assert_eq!(s.eval_suites(T).await.unwrap().iter().map(|x| x.hash.as_str()).collect::<Vec<_>>(), vec!["h2"]);
    let run = |hash: &str, age: i64, gate: Option<bool>| EvalRun {
        id: Uuid::now_v7(),
        tenant: T.into(),
        suite: "smoke".into(),
        suite_hash: hash.into(),
        policy_version: "p1".into(),
        fingerprint: Default::default(),
        trigger: EvalTrigger::Manual,
        counts: Default::default(),
        metrics: Default::default(),
        per_conversation: vec![],
        outcomes: vec![],
        took_ms: 1.0,
        created_at: now - Duration::minutes(age),
        gate_passed: gate,
    };
    let (oldest, passed, failed, other) = (run("h2", 30, None), run("h2", 20, Some(true)), run("h2", 10, Some(false)), run("h1", 5, None));
    for r in [&oldest, &passed, &failed, &other] {
        s.eval_run_put(r).await.unwrap();
    }
    assert_eq!(s.eval_reference(T, "smoke", "h2").await.unwrap().map(|r| r.id), Some(passed.id), "the newest that did not fail a gate");
    assert_eq!(s.eval_reference(T, "smoke", "h9").await.unwrap(), None);
    assert_eq!(s.eval_runs(T, Some("smoke"), 2).await.unwrap().iter().map(|r| r.id).collect::<Vec<_>>(), vec![other.id, failed.id]);
    assert_eq!((s.eval_runs(T, None, 10).await.unwrap().len(), s.eval_runs(T, Some("nope"), 10).await.unwrap().len()), (4, 0));
    assert!(s.eval_suite_delete(T, "smoke").await.unwrap() && !s.eval_suite_delete(T, "smoke").await.unwrap());

    // Recall explanations.
    let recall = |user: Option<&str>, at: DateTime<Utc>| -> RecallRecord {
        serde_json::from_value(json!({
            "recall_id": Uuid::now_v7(), "at": at, "tenant": T, "subject": S, "principal": "agent-1", "user": user, "policy_version": "p1",
            "authorizer": "scope", "query": "q", "k": 5, "denied_labels": [], "valid_at": at, "mode": "hybrid", "reranked": false, "returned": [],
            "stages": RecallStages::default(),
        }))
        .unwrap()
    };
    let (r1, r2, r3) = (recall(Some("ada"), now), recall(Some("bob"), now), recall(None, now - Duration::days(10)));
    for r in [&r1, &r2, &r3] {
        s.recall_put(r).await.unwrap();
    }
    s.recall_put(&r1).await.unwrap();
    assert_eq!(s.recall_get(T, r1.recall_id).await.unwrap().map(|r| r.query), Some("q".into()));
    assert!(s.recall_get("other", r1.recall_id).await.unwrap().is_none());
    assert_eq!(s.recalls_delete(T, Some("ada"), None).await.unwrap(), 1);
    assert_eq!(s.recalls_delete(T, None, Some(5)).await.unwrap(), 1);
    assert_eq!(s.recalls_delete(T, None, None).await.unwrap(), 1);
    // An explanation written after its subject was erased, of a recall made before the
    // erasure, is not stored (the write is scheduled and may arrive late); one of a recall made
    // well after it is. Another subject's is not affected.
    let erased = "user:erased";
    let late = RecallRecord { subject: erased.into(), ..recall(Some("ada"), Utc::now()) };
    s.delete_subject(T, erased, "t", true).await.unwrap();
    s.recall_put(&late).await.unwrap();
    assert!(s.recall_get(T, late.recall_id).await.unwrap().is_none(), "an explanation written after the erasure of its subject");
    let after = RecallRecord { subject: erased.into(), ..recall(Some("ada"), Utc::now() + Duration::seconds(30)) };
    let other = RecallRecord { subject: "user:kept".into(), ..recall(Some("ada"), Utc::now()) };
    s.recall_put(&after).await.unwrap();
    s.recall_put(&other).await.unwrap();
    assert!(s.recall_get(T, after.recall_id).await.unwrap().is_some() && s.recall_get(T, other.recall_id).await.unwrap().is_some());
    // A dotted key and a value that JSON escapes are found in the audit log as they were written.
    s.audit("t", "test.find", T, None, None, json!({ "a.b": "a\"b\nc" })).await.unwrap();
    assert!(s.audit_find(T, "test.find", "a.b", "a\"b\nc").await.unwrap());
    assert!(!s.audit_find(T, "test.find", "a.b", "a").await.unwrap() && !s.audit_find(T, "test.find", "a", "a\"b\nc").await.unwrap());

    // Links and idempotency keys: the first write wins.
    let link =
        Link { tenant: T.into(), subject: S.into(), linked_subject: "team:ops".into(), link_type: "member".into(), memory_id: None, created_by: "ada".into(), created_at: now };
    s.link_put(&link).await.unwrap();
    s.link_put(&Link { created_by: "eve".into(), ..link.clone() }).await.unwrap();
    assert_eq!(s.links(T, S).await.unwrap().iter().map(|l| l.created_by.as_str()).collect::<Vec<_>>(), vec!["ada"]);
    assert_eq!((s.export_links(T, None).await.unwrap().len(), s.export_links(T, Some("team:ops")).await.unwrap().len()), (1, 0));
    s.request_put(T, "k", S, "remember", "h1", &json!(1)).await.unwrap();
    s.request_put(T, "k", S, "remember", "h2", &json!(2)).await.unwrap();
    assert_eq!(s.request_get(T, "k").await.unwrap(), Some(("h1".into(), json!(1))));
    assert!(s.audit_verify().await.unwrap().1.is_none());
}

#[tokio::test]
async fn export_import_and_reembedding() {
    let (_dir, s) = store().await;
    let mut a = memory(S, "Exported with everything.");
    a.labels = vec!["l".into()];
    a.metadata = json!({ "source_ids": [Uuid::now_v7().to_string()] });
    let mut na = new(a.clone(), Some(axis(0, 0.0)));
    na.alt = Some(("alt-a".into(), axis(1, 0.0)));
    na.structured = Some(Structured { record_type: "thing".into(), attrs: json!({ "k": "v" }) });
    na.code_refs = vec![CodeRef::new("b.rs", "2"), CodeRef::new("a.rs", "1")];
    let b = memory("user:bob", "Bob's record, without a vector.");
    s.insert(&[na, new(b.clone(), None)]).await.unwrap();
    let lines = s.export_records(T, None, None, 10).await.unwrap();
    assert_eq!(lines.iter().map(|l| l.id).collect::<Vec<_>>(), vec![a.id, b.id], "in id order");
    assert_eq!(
        (lines[0].alt_hash.as_deref(), lines[0].code_refs[0].path.as_str(), lines[0].structured.as_ref().map(|x| x.attrs.clone())),
        (Some("alt-a"), "a.rs", Some(json!({ "k": "v" })))
    );
    assert_eq!(lines[0].content_hash, memhouse_core::engine::content_hash(&a.content));
    assert_eq!(s.export_records(T, Some("user:bob"), None, 10).await.unwrap().len(), 1);
    assert_eq!(s.export_records(T, None, Some(a.id), 10).await.unwrap().iter().map(|l| l.id).collect::<Vec<_>>(), vec![b.id]);
    assert_eq!(s.export_records(T, None, None, 1).await.unwrap().len(), 1);

    // Into a second store: ids already present are skipped, everything else is as exported.
    let (_dir2, s2) = store().await;
    let import: Vec<ImportRow> = lines
        .iter()
        .map(|l| ImportRow { record: l.clone(), embedding: (l.id == a.id).then(|| axis(0, 0.0)), alt: (l.id == a.id).then(|| ("alt-a".to_string(), axis(1, 0.0))) })
        .collect();
    assert_eq!(s2.import_records(&import).await.unwrap(), 2);
    assert_eq!(s2.import_records(&import).await.unwrap(), 0);
    let again = s2.export_records(T, None, None, 10).await.unwrap();
    assert_eq!(serde_json::to_value(&again).unwrap(), serde_json::to_value(&lines).unwrap());
    assert_eq!(s2.search(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(axis(1, 0.0))) }).await.unwrap()[0].memory.id, a.id);

    // Re-embedding to another model in place.
    let (current, target) = s.embedding_identity().await.unwrap();
    assert_eq!((current.as_ref().map(|i| (i.embedder.as_str(), i.dim, i.passage_prefix.as_str())), target), (Some(("test:model", DIM, "passage: ")), None));
    let to = EmbeddingIdentity { embedder: "test:bigger".into(), dim: 12, passage_prefix: String::new() };
    let estimate = s.reembed_estimate().await.unwrap();
    assert_eq!((estimate.records, estimate.second_vectors, estimate.characters, estimate.done), (1, 1, a.content.chars().count() as u64, 0));
    assert!(s.reembed_cutover(&to).await.is_err(), "nothing in progress");
    s.reembed_begin(&to).await.unwrap();
    s.reembed_begin(&to).await.unwrap();
    assert!(s.reembed_begin(&EmbeddingIdentity { embedder: "test:third".into(), ..to.clone() }).await.is_err());
    assert_eq!(s.embedding_identity().await.unwrap().1, Some(to.clone()));
    let pending = s.reembed_pending(None, 10).await.unwrap();
    assert_eq!((pending.len(), pending[0].id, pending[0].alt_hash.as_deref()), (1, a.id, Some("alt-a")));
    assert_eq!(s.reembed_cutover(&to).await.unwrap(), Some(1), "one record still to do");
    let big = |i: usize| (0..12).map(|j| if i == j { 1.0 } else { 0.0 }).collect::<Vec<f32>>();
    assert!(s.reembed_write(&to, &[ReembedVectors { id: a.id, embedding: axis(0, 0.0), alt: None }]).await.is_err(), "the wrong size");
    s.reembed_write(&to, &[ReembedVectors { id: a.id, embedding: big(5), alt: Some(("alt-new".into(), big(7))) }]).await.unwrap();
    assert_eq!((s.reembed_pending(None, 10).await.unwrap().len(), s.reembed_estimate().await.unwrap().done), (0, 1));
    // Until the switch, recall still runs on the current vectors; an abort leaves them untouched.
    assert!(s.reembed_abort().await.unwrap() && !s.reembed_abort().await.unwrap());
    assert_eq!(s.search(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(axis(0, 0.0))) }).await.unwrap().len(), 1);
    s.reembed_begin(&to).await.unwrap();
    assert_eq!(s.reembed_pending(None, 10).await.unwrap().len(), 1, "the aborted run's vectors are gone");
    s.reembed_write(&to, &[ReembedVectors { id: a.id, embedding: big(5), alt: Some(("alt-new".into(), big(7))) }]).await.unwrap();
    s.embed_cache_put("test:model", &[("old".into(), axis(0, 0.0))]).await.unwrap();
    assert_eq!(s.reembed_cutover(&to).await.unwrap(), None);
    assert_eq!(s.embedding_identity().await.unwrap(), (Some(to.clone()), None));
    assert!(s.embed_cache_get("test:model", &["old".into()]).await.unwrap().is_empty());
    // This process is still on the old model: its recalls and its writes are refused.
    let refused = s.search(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(axis(0, 0.0))) }).await.unwrap_err();
    assert_eq!(memhouse_core::error::code_of(&refused), memhouse_core::error::ErrorCode::Conflict, "{refused}");
    let refused = s.insert(&[new(memory(S, "Written with the old model."), Some(axis(0, 0.0)))]).await.unwrap_err().to_string();
    assert!(refused.contains("now embedded with test:bigger, not test:model"), "{refused}");
    assert!(s.enqueue(&proposal(vec![memory(S, "Queued by the old model.")])).await.is_err());
    assert!(s.migrate(DIM, "test:model").await.is_err());
    // A process started with the new configuration reads the new vectors.
    let restarted = SqliteStore::open(&_dir.path().join("memhouse.db"), "").unwrap();
    restarted.migrate(12, "test:bigger").await.unwrap();
    let hits = restarted.search(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(big(7))) }).await.unwrap();
    assert_eq!((hits[0].memory.id, hits[0].similarity.map(|x| x > 0.99)), (a.id, Some(true)));
    assert_eq!(restarted.export_records(T, Some(S), None, 1).await.unwrap()[0].alt_hash.as_deref(), Some("alt-new"));
}

/// MEM-05 and TR-WF-01: a record that names its source in another spelling of the id goes with
/// the source, and both of its cached vectors go with it.
#[tokio::test]
async fn a_dependent_goes_with_its_source_however_the_id_is_spelled() {
    let (_dir, s) = store().await;
    let prefix_hash = |text: &str| memhouse_core::engine::content_hash(&format!("passage: {text}"));
    let source = memory(S, "user: The alarm code is 4471.");
    let mut fact = memory(S, "The alarm code is 4471.");
    fact.metadata = json!({ "derived": true, "source_ids": [source.id.to_string().to_uppercase()] });
    let mut promoted = memory(S, "Alarm code: 4471.");
    promoted.metadata = json!({ "promoted_from": [fact.id.to_string().to_uppercase()] });
    let (ids, idf, idp) = (source.id, fact.id, promoted.id);
    let mut nf = new(fact.clone(), Some(axis(0, 0.0)));
    nf.alt = Some(("alt-of-fact".into(), axis(1, 0.0)));
    s.insert(&[new(source, None), nf, new(promoted, None)]).await.unwrap();
    s.embed_cache_put("test:model", &[(prefix_hash(&fact.content), axis(0, 0.0)), ("alt-of-fact".into(), axis(1, 0.0))]).await.unwrap();

    assert!(s.delete(T, ids, "tester").await.unwrap());
    for gone in [idf, idp] {
        assert!(s.get(T, gone).await.unwrap().is_none(), "{gone} should have gone with its source");
    }
    assert!(s.embed_cache_get("test:model", &[prefix_hash(&fact.content), "alt-of-fact".into()]).await.unwrap().is_empty(), "a cached vector of the fact is left");
}

/// TR-MS-04: the staging columns and the switch belong to the recorded target, the whole of it;
/// and a process on the identity of before a switch is refused, also when only the dimension
/// changed.
#[tokio::test]
async fn re_embedding_checks_the_whole_identity() {
    let (dir, s) = store().await;
    let a = memory(S, "Embedded twice.");
    s.insert(&[new(a.clone(), Some(axis(0, 0.0)))]).await.unwrap();
    let wide = |n: usize, i: usize| (0..n).map(|j| if i == j { 1.0 } else { 0.0 }).collect::<Vec<f32>>();
    let to = EmbeddingIdentity { embedder: "test:model".into(), dim: 12, passage_prefix: "passage: ".into() };
    let other = EmbeddingIdentity { dim: 16, ..to.clone() };
    let vectors = |n: usize| [ReembedVectors { id: a.id, embedding: wide(n, 5), alt: None }];

    // No run: nothing is staged. A run to one target: another target's vectors are not staged.
    assert!(s.reembed_write(&to, &vectors(12)).await.unwrap_err().to_string().contains("no re-embedding"));
    s.reembed_begin(&to).await.unwrap();
    assert!(s.reembed_write(&other, &vectors(16)).await.is_err(), "vectors of a target that is not the run's");
    assert_eq!(s.reembed_estimate().await.unwrap().done, 0);
    s.reembed_write(&to, &vectors(12)).await.unwrap();
    // The switch names the recorded target, dimension included.
    assert!(s.reembed_cutover(&other).await.unwrap_err().to_string().contains("no re-embedding"));
    assert_eq!(s.embedding_identity().await.unwrap().1, Some(to.clone()));
    assert_eq!(s.reembed_cutover(&to).await.unwrap(), None);

    // This process still has 8 dimensions under the same model name: refused, not served.
    let refused = s.search(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(axis(0, 0.0))) }).await.unwrap_err();
    assert_eq!(memhouse_core::error::code_of(&refused), memhouse_core::error::ErrorCode::Conflict, "{refused}");
    assert!(refused.to_string().contains("12 dims") && refused.to_string().contains("8 dims"), "{refused}");
    let refused = s.search_unfiltered(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(axis(0, 0.0))) }).await.unwrap_err();
    assert_eq!(memhouse_core::error::code_of(&refused), memhouse_core::error::ErrorCode::Conflict, "{refused}");
    assert!(s.search_unfiltered(&SearchQuery { mode: RetrievalMode::Keyword, ..query(S, "embedded", None) }).await.is_ok(), "keywords need no model");
    assert!(s.insert(&[new(memory(S, "An 8-dimensional vector beside 12-dimensional ones."), Some(axis(0, 0.0)))]).await.is_err());
    let restarted = SqliteStore::open(&dir.path().join("memhouse.db"), "passage: ").unwrap();
    restarted.migrate(12, "test:model").await.unwrap();
    assert_eq!(restarted.search(&SearchQuery { mode: RetrievalMode::Dense, ..query(S, "", Some(wide(12, 5))) }).await.unwrap().len(), 1);
}

/// A failure reported late, by a worker whose lease ran out, does not reopen a finished job.
#[tokio::test]
async fn a_late_failure_does_not_reopen_a_finished_job() {
    let (_dir, s) = store().await;
    let job = s.enrich_enqueue(T, S, "sess", &[]).await.unwrap();
    assert_eq!(s.enrich_claim_for(T, S, 1, 60).await.unwrap().len(), 1);
    s.enrich_finish(job, None, &EnrichOutcome::default()).await.unwrap();
    s.enrich_fail(job, "the first worker's call timed out", 3).await.unwrap();
    let st = s.enrich_status(T, Some(S)).await.unwrap();
    assert_eq!((st.done, st.pending, st.failed), (1, 0, 0));
}
