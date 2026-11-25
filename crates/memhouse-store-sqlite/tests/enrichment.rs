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
}

#[async_trait::async_trait]
impl ChatModel for DeletesDuringTheCall {
    fn id(&self) -> String {
        "test:deletes-during-the-call".into()
    }
    async fn chat(&self, system: &str, user: &str) -> anyhow::Result<(String, LlmUsage)> {
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
    let chat = Arc::new(DeletesDuringTheCall { store: store.clone(), delete: Mutex::new(vec![]) });
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

    // The round is deleted while the model reads it: its fact is not written afterwards.
    let erased = ingest("s2", "My bank card PIN is 4471.").await;
    *chat.delete.lock().unwrap() = erased.ids.clone();
    assert!(e.enrich_once_for(T, S, &spend).await.unwrap());
    for id in &erased.ids {
        assert!(store.get(T, *id).await.unwrap().is_none());
    }
    let left = derived().await;
    assert!(left.iter().all(|m| !m.content.contains("4471")), "a fact of the deleted round was stored: {:?}", left.iter().map(|m| &m.content).collect::<Vec<_>>());
    // Nothing is left to retry: the job went with its round.
    let st = store.enrich_status(T, Some(S)).await.unwrap();
    assert_eq!(st.pending + st.running, 0);
}
