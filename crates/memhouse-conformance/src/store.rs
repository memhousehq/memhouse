// SPDX-License-Identifier: Apache-2.0
//! The store kit (DEP-02): what the engine relies on a store for. Most checks drive the real
//! engine over the store under test, with a deterministic embedder and extractor, so they
//! test the store the way it is used; a few call the interface directly.

use crate::fakes::{EchoExtractor, HashEmbedder};
use crate::{unless, Report};
use memhouse_core::config::Config;
use memhouse_core::enrich::Spend;
use memhouse_core::traits::Store;
use memhouse_core::types::*;
use memhouse_core::Engine;
use std::sync::Arc;
use uuid::Uuid;

/// Vector size the kit migrates the store to.
pub const DIM: usize = 64;

async fn remember(e: &Engine, subject: &str, content: &str) -> anyhow::Result<RememberResult> {
    e.remember(RememberRequest { subject: Some(subject.into()), content: content.into(), actor: Some("conformance".into()), source: Some("conformance".into()), wait: true, ..Default::default() }).await
}

async fn recall(e: &Engine, subject: &str, query: &str, mode: RetrievalMode, candidates: bool) -> anyhow::Result<Vec<Hit>> {
    let r = e
        .recall(RecallRequest {
            subject: Some(subject.into()),
            query: query.into(),
            k: Some(10),
            mode: Some(mode),
            analyze: Some(false),
            include_candidates: candidates,
            actor: Some("conformance".into()),
            ..Default::default()
        })
        .await?;
    anyhow::ensure!(r.degraded.is_none(), "the recall was degraded: {:?}", r.degraded);
    Ok(r.hits)
}

fn contents(hits: &[Hit]) -> Vec<&str> {
    hits.iter().map(|h| h.memory.content.as_str()).collect()
}

/// The store contract. Give the kit a **fresh, empty store** (a test database): it migrates it
/// for a 64-dimension stand-in embedder and writes into tenants of its own.
pub async fn run_store_kit(store: Arc<dyn Store>) -> Report {
    let embedder = Arc::new(HashEmbedder::new(DIM));
    let mut r = Report::new("store", "store under test");
    let migrated = async {
        store.migrate(DIM, &embedder.id).await?;
        store.migrate(DIM, &embedder.id).await
    }
    .await;
    r.check("migrate_is_repeatable", "migrating an empty store, and migrating it again, succeeds", migrated.as_ref().err().map(|e| format!("the adapter returned an error: {e:#}")));
    if migrated.is_err() {
        return r;
    }
    let tenant = format!("kit-{}", Uuid::new_v4().simple());
    let t = tenant.as_str();
    let mut cfg = Config::default();
    cfg.memory.tenant = tenant.clone();
    cfg.enrich.enabled = true;
    cfg.enrich.min_user_chars = 1;
    cfg.enrich.workers = 0;
    cfg.governance.audit_reads = false;
    let e = Engine::new(store.clone(), embedder.clone(), None, cfg.clone()).with_chat(Some(Arc::new(EchoExtractor)));
    let (a, b) = ("kit:store-a", "kit:store-b");

    let first = match remember(&e, a, "The warehouse in Tallinn has four loading docks.").await {
        Ok(w) => w,
        Err(err) => {
            r.check("write_reads_back", "a write is stored", Some(format!("the write failed: {err:#}")));
            return r;
        }
    };
    r.outcome("write_reads_back", "a committed write reads back by id with its content, tenant, subject and kind", async {
        let m = store.get(t, first.id).await?;
        let ok = m.as_ref().is_some_and(|m| m.content == "The warehouse in Tallinn has four loading docks." && m.tenant == t && m.subject == a && m.kind == MemoryKind::Semantic && m.status == MemoryStatus::Committed);
        Ok(unless(ok, || format!("read back: {:?}", m.map(|m| (m.status.as_str().to_string(), m.subject, m.content)))))
    }
    .await);
    r.outcome("exact_duplicate_is_not_stored_twice", "writing the same content again for the same subject returns the stored record and adds none", async {
        let again = remember(&e, a, "The warehouse in Tallinn has four loading docks.").await?;
        let n = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), include_inactive: true, limit: 100, ..Default::default() }).await?.len();
        Ok(unless(again.id == first.id && again.deduplicated && n == 1, || format!("second write id equal: {}, deduplicated: {}, records: {n}", again.id == first.id, again.deduplicated)))
    }
    .await);
    r.outcome("keyword_search_finds_by_word", "a keyword recall finds the record by a word it contains, and nothing for a word it does not", async {
        let (hit, miss) = (recall(&e, a, "loading docks", RetrievalMode::Keyword, false).await?, recall(&e, a, "zeppelin", RetrievalMode::Keyword, false).await?);
        Ok(unless(hit.iter().any(|h| h.memory.id == first.id) && miss.is_empty(), || format!("for \"loading docks\": {:?}; for \"zeppelin\": {:?}", contents(&hit), contents(&miss))))
    }
    .await);
    r.outcome("vector_search_ranks_by_similarity", "a vector recall returns the closest record first", async {
        let other = remember(&e, a, "Priya's favourite tea is a smoky lapsang.").await?;
        let hits = recall(&e, a, "how many loading docks does the Tallinn warehouse have", RetrievalMode::Dense, false).await?;
        Ok(unless(hits.first().map(|h| h.memory.id) == Some(first.id) && hits.iter().any(|h| h.memory.id == other.id), || format!("order: {:?}", contents(&hits))))
    }
    .await);
    r.outcome("subjects_are_isolated", "a recall for one subject never returns another subject's record", async {
        let hits = recall(&e, b, "loading docks Tallinn warehouse", RetrievalMode::Hybrid, true).await?;
        Ok(unless(hits.is_empty(), || format!("subject B's recall returned {:?}", contents(&hits))))
    }
    .await);
    r.outcome("tenants_are_isolated", "another tenant neither reads the record by id nor finds it by recall", async {
        let other = format!("{tenant}-other");
        let theirs = e
            .remember(RememberRequest { tenant: Some(other.clone()), subject: Some(a.into()), content: "The other tenant's warehouse has nine loading docks.".into(), actor: Some("conformance".into()), wait: true, ..Default::default() })
            .await?;
        let (by_id, cross) = (store.get(t, theirs.id).await?, store.get(&other, first.id).await?);
        let hits = recall(&e, a, "warehouse loading docks", RetrievalMode::Hybrid, true).await?;
        let leaked = hits.iter().any(|h| h.memory.id == theirs.id);
        e.forget_by(ForgetRequest { tenant: Some(other.clone()), all: true, confirm: Some(other), actor: Some("conformance".into()), ..Default::default() }).await?;
        Ok(unless(by_id.is_none() && cross.is_none() && !leaked, || format!("read across tenants by id: {}, {}; found by recall: {leaked}", by_id.is_some(), cross.is_some())))
    }
    .await);
    r.outcome("revision_keeps_the_old_version", "a revision becomes the current version; the old one stays, superseded and linked, and is not recalled", async {
        let new = e.revise(ReviseRequest { id: first.id, content: "The warehouse in Tallinn has six loading docks.".into(), actor: Some("conformance".into()), wait: true, ..Default::default() }).await?;
        let (old, cur) = (store.get(t, first.id).await?, store.get(t, new.id).await?);
        let hits = recall(&e, a, "loading docks", RetrievalMode::Hybrid, false).await?;
        let ok = old.as_ref().is_some_and(|m| m.status == MemoryStatus::Superseded)
            && cur.as_ref().is_some_and(|m| m.status == MemoryStatus::Committed && m.supersedes == Some(first.id))
            && hits.iter().any(|h| h.memory.id == new.id)
            && !hits.iter().any(|h| h.memory.id == first.id);
        Ok(unless(ok, || format!("old: {:?}, new: {:?}, recalled: {:?}", old.map(|m| m.status.as_str().to_string()), cur.map(|m| (m.status.as_str().to_string(), m.supersedes)), contents(&hits))))
    }
    .await);
    r.outcome("held_candidates_are_hidden", "a held plan is stored as a candidate, left out of a recall, and returned only when candidates are asked for", async {
        let plan = remember(&e, a, "I plan to open a second warehouse in Riga next year.").await?;
        let (without, with) = (recall(&e, a, "second warehouse Riga", RetrievalMode::Hybrid, false).await?, recall(&e, a, "second warehouse Riga", RetrievalMode::Hybrid, true).await?);
        let ok = plan.status == MemoryStatus::Candidate && !without.iter().any(|h| h.memory.id == plan.id) && with.iter().any(|h| h.memory.id == plan.id);
        Ok(unless(ok, || format!("status {}, in a plain recall: {}, with candidates: {}", plan.status.as_str(), without.iter().any(|h| h.memory.id == plan.id), with.iter().any(|h| h.memory.id == plan.id))))
    }
    .await);
    r.outcome("denied_labels_are_filtered_in_the_store", "a list or a search with denied labels leaves out every record that carries one", async {
        let secret = e
            .remember(RememberRequest { subject: Some(a.into()), content: "The vault code rotates every Monday.".into(), labels: vec!["kit-secret".into()], actor: Some("conformance".into()), wait: true, ..Default::default() })
            .await?;
        let listed = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), limit: 100, denied_labels: vec!["kit-secret".into()], ..Default::default() }).await?;
        let all = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), limit: 100, ..Default::default() }).await?;
        Ok(unless(!listed.iter().any(|m| m.id == secret.id) && all.iter().any(|m| m.id == secret.id), || {
            format!("with the label denied the record was listed: {}; without: {}", listed.iter().any(|m| m.id == secret.id), all.iter().any(|m| m.id == secret.id))
        }))
    }
    .await);

    // Derived data: facts extracted from a round go when the round goes.
    let spend = Spend::default();
    let derived = |subject: &'static str| {
        let (e, tenant) = (e.clone(), tenant.clone());
        async move { anyhow::Ok(e.list(Some(tenant), Some(subject.to_string()), None, 1000, 0, true).await?.into_iter().filter(|m| m.metadata["derived"].as_bool() == Some(true)).collect::<Vec<_>>()) }
    };
    let ingest = |subject: &'static str, session: &'static str, text: &'static str| {
        let e = e.clone();
        async move {
            e.ingest(IngestRequest {
                subject: Some(subject.into()),
                session_id: Some(session.into()),
                messages: vec![Message { role: "user".into(), content: text.into(), timestamp: None, id: Some(format!("{session}-m1")) }],
                actor: Some("conformance".into()),
                wait: true,
                ..Default::default()
            })
            .await
        }
    };
    r.outcome("delete_cascades_to_derived_facts", "deleting a conversation round also deletes the facts extracted from it", async {
        let ing = ingest(b, "s1", "We adopted a kitten called Marzipan last weekend.").await?;
        for _ in 0..200 {
            let st = store.enrich_status(t, Some(b)).await?;
            if st.pending + st.running == 0 {
                break;
            }
            e.enrich_once(&spend).await?;
        }
        let before = derived(b).await?;
        anyhow::ensure!(before.iter().any(|m| m.content.contains("Marzipan")), "the kit could not set up the check: no fact was extracted from the round ({} derived records)", before.len());
        for id in &ing.ids {
            e.forget(None, *id, Some("conformance".into())).await?;
        }
        let after = derived(b).await?;
        let hits = recall(&e, b, "kitten Marzipan", RetrievalMode::Hybrid, true).await?;
        Ok(unless(after.is_empty() && hits.is_empty(), || {
            format!("after the round was deleted, {} fact(s) extracted from it are still stored ({:?}) and a recall returns {} hit(s)", after.len(), after.iter().map(|m| m.content.as_str()).collect::<Vec<_>>(), hits.len())
        }))
    }
    .await);
    r.outcome("erasure_removes_everything", "erasing a subject removes its records, derived facts and queued extraction jobs; other subjects are untouched", async {
        ingest(b, "s2", "Our second kitten is called Nougat.").await?;
        remember(&e, b, "The cats are fed at seven every morning.").await?;
        e.forget_subject(None, b, Some("conformance".into())).await?;
        let left = e.list(Some(tenant.clone()), Some(b.to_string()), None, 1000, 0, true).await?;
        let jobs = store.enrich_status(t, Some(b)).await?;
        let kept = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), limit: 100, ..Default::default() }).await?.len();
        Ok(unless(left.is_empty() && jobs.pending + jobs.running + jobs.done + jobs.failed == 0 && kept >= 2, || {
            format!("{} records left, {} extraction jobs left, subject A has {kept} records", left.len(), jobs.pending + jobs.running + jobs.done + jobs.failed)
        }))
    }
    .await);
    r.outcome("audit_chain_is_intact", "every change wrote an audit event, and the hash chain verifies", async {
        let (n, broken) = store.audit_verify().await?;
        let log = store.audit_log(t, 500).await?;
        let has = |action: &str| log.iter().any(|a| a.action == action);
        Ok(unless(broken.is_none() && n > 0 && has("memory.write") && has("memory.supersede") && log.iter().any(|a| a.action.starts_with("memory.forget") || a.action.starts_with("memory.delete") || a.action.starts_with("subject.")), || {
            let mut actions: Vec<&str> = log.iter().map(|a| a.action.as_str()).collect();
            actions.sort();
            actions.dedup();
            format!("{n} events, chain broken at {broken:?}, actions recorded: {actions:?}")
        }))
    }
    .await);
    r.outcome("embedding_cache_round_trip", "cached vectors come back by model and hash, and not for another model", async {
        let key = format!("kit-{}", Uuid::new_v4().simple());
        let v: Vec<f32> = (0..DIM).map(|i| i as f32 / DIM as f32).collect();
        store.embed_cache_put(&embedder.id, &[(key.clone(), v.clone())]).await?;
        let got = store.embed_cache_get(&embedder.id, std::slice::from_ref(&key)).await?;
        let other = store.embed_cache_get("another-model", std::slice::from_ref(&key)).await?;
        let same = got.first().is_some_and(|(k, g)| *k == key && g.len() == DIM && g.iter().zip(&v).all(|(x, y)| (x - y).abs() < 0.01));
        Ok(unless(same && other.is_empty(), || format!("{} vector(s) back for the model, {} for another model", got.len(), other.len())))
    }
    .await);
    r.outcome("idempotency_keys_round_trip", "a stored request key gives back its request hash and response, in its tenant only", async {
        let key = format!("kit-{}", Uuid::new_v4().simple());
        let response = serde_json::json!({ "id": "kit" });
        store.request_put(t, &key, a, "remember", "hash-1", &response).await?;
        let (mine, theirs) = (store.request_get(t, &key).await?, store.request_get("kit-someone-else", &key).await?);
        Ok(unless(mine.as_ref().is_some_and(|(h, v)| h == "hash-1" && *v == response) && theirs.is_none(), || format!("read back: {mine:?}; another tenant: {}", theirs.is_some())))
    }
    .await);
    // Leave the store as it was found, apart from its audit log.
    let _ = e.forget_by(ForgetRequest { tenant: Some(tenant.clone()), all: true, confirm: Some(tenant.clone()), actor: Some("conformance".into()), ..Default::default() }).await;
    r
}
