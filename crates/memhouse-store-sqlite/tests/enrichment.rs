// SPDX-License-Identifier: Apache-2.0
//! Enrichment against an erasure (TR-WF-01): a fact extracted from a round is not stored once
//! the round is deleted, also when the deletion runs while the model is being called.

use memhouse_conformance::fakes::{EchoExtractor, HashEmbedder};
use memhouse_core::enrich::Spend;
use memhouse_core::traits::ChatModel;
use memhouse_core::types::*;
use memhouse_core::{Config, Engine, Store};
use memhouse_store_sqlite::SqliteStore;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

const T: &str = "acme";
const S: &str = "user:ada";

/// Extracts as `EchoExtractor` does, after deleting the given records: an erasure that arrives
/// between the job reading its rounds and writing its facts.
struct DeletesDuringTheCall {
    store: SqliteStore,
    delete: Mutex<Vec<Uuid>>,
    prompts: Mutex<Vec<String>>,
}

#[async_trait::async_trait]
impl ChatModel for DeletesDuringTheCall {
    fn id(&self) -> String {
        "test:deletes-during-the-call".into()
    }
    async fn chat(&self, system: &str, user: &str) -> anyhow::Result<(String, LlmUsage)> {
        self.prompts.lock().unwrap().push(user.to_string());
        let ids = std::mem::take(&mut *self.delete.lock().unwrap());
        for id in ids {
            self.store.delete(T, id, "dpo").await?;
        }
        EchoExtractor.chat(system, user).await
    }
}

#[tokio::test]
async fn a_fact_is_not_stored_after_its_round_was_deleted_during_the_model_call() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteStore::open(&dir.path().join("memhouse.db"), "").unwrap();
    let embedder = Arc::new(HashEmbedder::new(8));
    store.migrate(8, &embedder.id).await.unwrap();
    let mut cfg = Config::default();
    cfg.memory.tenant = T.into();
    cfg.embedding.dim = 8;
    cfg.enrich.enabled = true;
    cfg.enrich.min_user_chars = 1;
    cfg.enrich.workers = 0;
    cfg.governance.audit_reads = false;
    let chat = Arc::new(DeletesDuringTheCall { store: store.clone(), delete: Mutex::new(vec![]), prompts: Mutex::new(vec![]) });
    let e = Engine::new(Arc::new(store.clone()), embedder, None, cfg).with_chat(Some(chat.clone()));
    let ingest = |session: &'static str, text: &'static str| {
        let e = e.clone();
        async move {
            e.ingest(IngestRequest {
                subject: Some(S.into()),
                session_id: Some(session.into()),
                messages: vec![Message { role: "user".into(), content: text.into(), timestamp: None, id: Some(format!("{session}-m1")) }],
                actor: Some("test".into()),
                wait: true,
                ..Default::default()
            })
            .await
            .unwrap()
        }
    };
    let derived = || async {
        e.list(Some(T.into()), Some(S.into()), None, 100, 0, true).await.unwrap().into_iter().filter(|m| m.metadata["derived"].as_bool() == Some(true)).collect::<Vec<_>>()
    };
    let spend = Spend::default();

    // Without a deletion the round's fact is stored: the setup extracts something.
    ingest("s1", "We adopted a kitten called Marzipan last weekend.").await;
    assert!(e.enrich_once_for(T, S, &spend).await.unwrap());
    assert!(derived().await.iter().any(|m| m.content.contains("Marzipan")));
    // And its answer is cached.
    let cached = |n: usize| {
        let key = memhouse_core::enrich::cache_key(&chat.id(), &chat.prompts.lock().unwrap()[n]);
        let store = store.clone();
        async move { store.llm_cache_get(&key).await.unwrap() }
    };
    assert!(cached(0).await.is_some());

    // The round is deleted while the model reads it: its fact is not written afterwards.
    let erased = ingest("s2", "My bank card PIN is 4471.").await;
    *chat.delete.lock().unwrap() = erased.ids.clone();
    assert!(e.enrich_once_for(T, S, &spend).await.unwrap());
    for id in &erased.ids {
        assert!(store.get(T, *id).await.unwrap().is_none());
    }
    let left = derived().await;
    assert!(left.iter().all(|m| !m.content.contains("4471")), "a fact of the deleted round was stored: {:?}", left.iter().map(|m| &m.content).collect::<Vec<_>>());
    // Nor is the model's answer, which holds the round's text, kept in the cache.
    assert_eq!(chat.prompts.lock().unwrap().len(), 2);
    assert_eq!(cached(1).await, None, "the extraction of a deleted round stayed in the cache");
    assert!(cached(0).await.is_some());
    // Nothing is left to retry: the job went with its round.
    let st = store.enrich_status(T, Some(S)).await.unwrap();
    assert_eq!(st.pending + st.running, 0);
}

/// A cached answer belongs to its job from the moment it is stored: a deletion of one of the
/// job's rounds at any later time removes it (also before the job has finished, and whichever
/// model gave it), and nothing is cached for a job that is gone.
#[tokio::test]
async fn a_cached_extraction_goes_with_its_job_whenever_a_round_is_deleted() {
    let store = SqliteStore::in_memory("").unwrap();
    let embedder = HashEmbedder::new(8);
    store.migrate(8, &embedder.id).await.unwrap();
    let mut cfg = Config::default();
    cfg.memory.tenant = T.into();
    cfg.embedding.dim = 8;
    cfg.enrich.enabled = true;
    cfg.enrich.workers = 0;
    cfg.governance.audit_reads = false;
    let e = Engine::new(Arc::new(store.clone()), Arc::new(embedder), None, cfg);
    let ingested = e
        .ingest(IngestRequest {
            subject: Some(S.into()),
            session_id: Some("s1".into()),
            messages: vec![Message { role: "user".into(), content: "My bank card PIN is 4471.".into(), timestamp: None, id: Some("m1".into()) }],
            actor: Some("test".into()),
            wait: true,
            ..Default::default()
        })
        .await
        .unwrap();
    let round = ingested.ids[0];
    let job = store.enrich_claim_for(T, S, 1, 300).await.unwrap().pop().expect("the session's job").id;
    // Two models read the session (the small one, then the large one); the job is still running.
    assert!(store.llm_cache_put_for(job, "key-small", "small", "the PIN is 4471").await.unwrap());
    assert!(store.llm_cache_put_for(job, "key-large", "large", "PIN: 4471").await.unwrap());
    assert!(store.llm_cache_put_for(job, "key-small", "small", "the PIN is 4471").await.unwrap());
    assert!(store.llm_cache_get("key-small").await.unwrap().is_some() && store.llm_cache_get("key-large").await.unwrap().is_some());

    assert!(store.delete(T, round, "dpo").await.unwrap());
    assert_eq!((store.llm_cache_get("key-small").await.unwrap(), store.llm_cache_get("key-large").await.unwrap()), (None, None));
    // An answer that comes back after the deletion is not stored.
    assert!(!store.llm_cache_put_for(job, "key-small", "small", "the PIN is 4471").await.unwrap());
    assert_eq!(store.llm_cache_get("key-small").await.unwrap(), None);
}
