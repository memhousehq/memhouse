// SPDX-License-Identifier: Apache-2.0
//! The conformance kits (DEP-02) on a database file, the exactness of the vector scan
//! (ADR 0003) and the durability of the queue across a restart (TR-LT-05). No Docker, no network.

use chrono::Utc;
use memhouse_core::intake::{Entry, Op, PendingRecord, Proposal};
use memhouse_core::types::*;
use memhouse_core::{IntakeQueue, Store};
use memhouse_store_sqlite::SqliteStore;
use std::sync::Arc;
use uuid::Uuid;

fn memory(tenant: &str, subject: &str, content: &str) -> Memory {
    let now = Utc::now();
    Memory {
        id: Uuid::now_v7(),
        tenant: tenant.into(),
        subject: subject.into(),
        kind: MemoryKind::Semantic,
        status: MemoryStatus::Committed,
        content: content.into(),
        session_id: None,
        turn_ref: None,
        occurred_at: None,
        valid_from: now,
        valid_to: None,
        supersedes: None,
        labels: vec![],
        tags: vec![],
        source: "test".into(),
        confidence: 1.0,
        metadata: serde_json::json!({}),
        created_at: now,
        expires_at: None,
        scope: Scope::default(),
        provenance: Provenance::default(),
        language: None,
        stale_since: None,
    }
}

fn dense(tenant: &str, subject: &str, embedding: Vec<f32>, limit: usize) -> SearchQuery {
    SearchQuery {
        tenant: tenant.into(),
        subject: subject.into(),
        text: String::new(),
        embedding: Some(embedding),
        kinds: None,
        tags: None,
        denied_labels: vec![],
        as_of: None,
        valid_at: Utc::now(),
        mode: RetrievalMode::Dense,
        per_retriever: 100,
        limit,
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

#[tokio::test]
async fn store_kit() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteStore::open(&dir.path().join("memhouse.db"), "").unwrap();
    let report = memhouse_conformance::run_store_kit(Arc::new(store)).await;
    println!("{}", report.summary());
    report.assert_passed();
}

#[tokio::test]
async fn queue_kit() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteStore::open(&dir.path().join("memhouse.db"), "").unwrap();
    store.migrate(memhouse_conformance::STORE_KIT_DIM, "conformance:hash-64").await.unwrap();
    let report = memhouse_conformance::run_intake_queue_kit(store.intake_queue().expect("the store has a queue")).await;
    println!("{}", report.summary());
    report.assert_passed();
}

/// Deterministic pseudo-random unit vectors (xorshift; sums of uniforms are close to normal).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 40) as f32 / (1u64 << 24) as f32 - 0.5
    }

    fn unit(&mut self, dim: usize) -> Vec<f32> {
        let v: Vec<f32> = (0..dim).map(|_| (0..4).map(|_| self.next()).sum()).collect();
        let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        v.iter().map(|x| x / n).collect()
    }
}

/// ADR 0003, decision 4: the half-precision scan returns the top K of a brute-force f32 scan;
/// only scores closer than half precision can tell apart may trade places.
#[tokio::test]
async fn half_precision_scan_is_exact() {
    const DIM: usize = 96;
    const N: usize = 400;
    const K: usize = 10;
    /// Far above the error half precision adds to a cosine of unit vectors, far below the
    /// spacing of unrelated scores.
    const TIE: f32 = 2e-3;
    let store = SqliteStore::in_memory("").unwrap();
    store.migrate(DIM, "test:random").await.unwrap();
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut rows = vec![];
    let mut truth: Vec<(Uuid, Vec<f32>, Option<Vec<f32>>)> = vec![];
    for i in 0..N {
        let mut n = NewMemory::new(memory("t", "s", &format!("memory {i}")), format!("hash-{i}"));
        let v = rng.unit(DIM);
        // Every fifth record has a second vector, as conversation rounds do: the better counts.
        let alt = (i % 5 == 0).then(|| rng.unit(DIM));
        n.embedding = Some(v.clone());
        n.alt = alt.clone().map(|a| (format!("alt-{i}"), a));
        truth.push((n.memory.id, v, alt));
        rows.push(n);
    }
    store.insert(&rows).await.unwrap();
    let dot = |a: &[f32], b: &[f32]| a.iter().zip(b).map(|(x, y)| x * y).sum::<f32>();
    let mut identical = 0;
    for _ in 0..25 {
        let q = rng.unit(DIM);
        let mut exact: Vec<(f32, Uuid)> = truth.iter().map(|(id, v, alt)| (dot(&q, v).max(alt.as_ref().map(|a| dot(&q, a)).unwrap_or(f32::MIN)), *id)).collect();
        exact.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        let hits = store.search(&dense("t", "s", q, K)).await.unwrap();
        assert_eq!(hits.len(), K);
        let (got, want): (Vec<Uuid>, Vec<Uuid>) = (hits.iter().map(|h| h.memory.id).collect(), exact[..K].iter().map(|e| e.1).collect());
        identical += (got == want) as usize;
        for (rank, h) in hits.iter().enumerate() {
            let score = exact.iter().find(|e| e.1 == h.memory.id).unwrap().0;
            assert_eq!(h.vector_rank, Some(rank as i32 + 1));
            assert!((h.similarity.unwrap() - score).abs() < TIE, "similarity {} for an exact {score}", h.similarity.unwrap());
            // The record at this rank scores what brute force has at this rank, give or take a tie.
            assert!((score - exact[rank].0).abs() < TIE, "rank {}: {score} where brute force has {}", rank + 1, exact[rank].0);
        }
    }
    assert!(identical >= 23, "only {identical} of 25 queries had the identical top {K}");
    println!("half-precision scan: identical top {K} for {identical} of 25 queries; any other differs only in ties");

    // The optional binary prefilter rescoring every row is the same exact scan.
    let pre = store.clone().with_bit_prefilter(0, N);
    let q = rng.unit(DIM);
    let ids = |hits: Vec<Hit>| hits.into_iter().map(|h| h.memory.id).collect::<Vec<_>>();
    assert_eq!(ids(pre.search(&dense("t", "s", q.clone(), K)).await.unwrap()), ids(store.search(&dense("t", "s", q, K)).await.unwrap()));
}

/// TR-LT-05: an acknowledged write survives the process. The store is dropped without any
/// shutdown step, the file is opened again, and the proposal is still there to claim.
#[tokio::test]
async fn queued_proposal_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("memhouse.db");
    let mut m = memory("t", "s", "The spare key is with the neighbour.");
    m.status = MemoryStatus::Candidate;
    let proposal = Proposal {
        id: m.id,
        tenant: "t".into(),
        subject: "s".into(),
        actor: "test".into(),
        user: None,
        source: "test".into(),
        op: Op::Remember,
        entry: Entry::Commit,
        records: vec![PendingRecord {
            content_hash: memhouse_core::engine::content_hash(&m.content),
            memory: m,
            redactions: vec![],
            focus: None,
            structured: None,
            code_refs: vec![],
            refs_inherited: false,
        }],
        session_id: None,
        enqueued_at: Utc::now(),
    };
    {
        let store = SqliteStore::open(&path, "").unwrap();
        store.migrate(8, "test:model").await.unwrap();
        store.enqueue(&proposal).await.unwrap();
    }
    let store = SqliteStore::open(&path, "").unwrap();
    store.migrate(8, "test:model").await.unwrap();
    assert_eq!(store.meta("embedder").unwrap().as_deref(), Some("test:model"));
    let status = store.status(Some("t")).await.unwrap();
    assert_eq!((status.pending, status.running), (1, 0));
    assert!(store.unfinished(proposal.id).await.unwrap());
    assert_eq!(store.pending("t", proposal.id).await.unwrap().map(|m| m.content), Some("The spare key is with the neighbour.".to_string()));
    let claimed = store.claim(10, 60, None).await.unwrap();
    assert_eq!(claimed.len(), 1);
    assert_eq!((claimed[0].proposal.id, claimed[0].attempts), (proposal.id, 1));

    // A store written with one embedder refuses another, as Postgres does.
    let other = SqliteStore::open(&path, "").unwrap();
    let refused = other.migrate(8, "test:another-model").await.unwrap_err().to_string();
    assert!(refused.contains("embedded with test:model"), "{refused}");
}
