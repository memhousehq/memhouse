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
    e.remember(RememberRequest {
        subject: Some(subject.into()),
        content: content.into(),
        actor: Some("conformance".into()),
        source: Some("conformance".into()),
        wait: true,
        ..Default::default()
    })
    .await
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
    r.check(
        "migrate_is_repeatable",
        "migrating an empty store, and migrating it again, succeeds",
        migrated.as_ref().err().map(|e| format!("the adapter returned an error: {e:#}")),
    );
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
    r.outcome(
        "write_reads_back",
        "a committed write reads back by id with its content, tenant, subject and kind",
        async {
            let m = store.get(t, first.id).await?;
            let ok = m.as_ref().is_some_and(|m| {
                m.content == "The warehouse in Tallinn has four loading docks."
                    && m.tenant == t
                    && m.subject == a
                    && m.kind == MemoryKind::Semantic
                    && m.status == MemoryStatus::Committed
            });
            Ok(unless(ok, || format!("read back: {:?}", m.map(|m| (m.status.as_str().to_string(), m.subject, m.content)))))
        }
        .await,
    );
    r.outcome(
        "exact_duplicate_is_not_stored_twice",
        "writing the same content again for the same subject returns the stored record and adds none",
        async {
            let again = remember(&e, a, "The warehouse in Tallinn has four loading docks.").await?;
            let n = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), include_inactive: true, limit: 100, ..Default::default() }).await?.len();
            Ok(unless(again.id == first.id && again.deduplicated && n == 1, || {
                format!("second write id equal: {}, deduplicated: {}, records: {n}", again.id == first.id, again.deduplicated)
            }))
        }
        .await,
    );
    r.outcome(
        "keyword_search_finds_by_word",
        "a keyword recall finds the record by a word it contains, and nothing for a word it does not",
        async {
            let (hit, miss) = (recall(&e, a, "loading docks", RetrievalMode::Keyword, false).await?, recall(&e, a, "zeppelin", RetrievalMode::Keyword, false).await?);
            Ok(unless(hit.iter().any(|h| h.memory.id == first.id) && miss.is_empty(), || {
                format!("for \"loading docks\": {:?}; for \"zeppelin\": {:?}", contents(&hit), contents(&miss))
            }))
        }
        .await,
    );
    r.outcome(
        "vector_search_ranks_by_similarity",
        "a vector recall returns the closest record first",
        async {
            let other = remember(&e, a, "Priya's favourite tea is a smoky lapsang.").await?;
            let hits = recall(&e, a, "how many loading docks does the Tallinn warehouse have", RetrievalMode::Dense, false).await?;
            Ok(unless(hits.first().map(|h| h.memory.id) == Some(first.id) && hits.iter().any(|h| h.memory.id == other.id), || format!("order: {:?}", contents(&hits))))
        }
        .await,
    );
    r.outcome(
        "subjects_are_isolated",
        "a recall for one subject never returns another subject's record",
        async {
            let hits = recall(&e, b, "loading docks Tallinn warehouse", RetrievalMode::Hybrid, true).await?;
            Ok(unless(hits.is_empty(), || format!("subject B's recall returned {:?}", contents(&hits))))
        }
        .await,
    );
    r.outcome(
        "tenants_are_isolated",
        "another tenant neither reads the record by id nor finds it by recall",
        async {
            let other = format!("{tenant}-other");
            let theirs = e
                .remember(RememberRequest {
                    tenant: Some(other.clone()),
                    subject: Some(a.into()),
                    content: "The other tenant's warehouse has nine loading docks.".into(),
                    actor: Some("conformance".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?;
            let (by_id, cross) = (store.get(t, theirs.id).await?, store.get(&other, first.id).await?);
            let hits = recall(&e, a, "warehouse loading docks", RetrievalMode::Hybrid, true).await?;
            let leaked = hits.iter().any(|h| h.memory.id == theirs.id);
            e.forget_by(ForgetRequest { tenant: Some(other.clone()), all: true, confirm: Some(other), actor: Some("conformance".into()), ..Default::default() }).await?;
            Ok(unless(by_id.is_none() && cross.is_none() && !leaked, || format!("read across tenants by id: {}, {}; found by recall: {leaked}", by_id.is_some(), cross.is_some())))
        }
        .await,
    );
    r.outcome(
        "revision_keeps_the_old_version",
        "a revision becomes the current version; the old one stays, superseded and linked, and is not recalled",
        async {
            let new = e
                .revise(ReviseRequest {
                    id: first.id,
                    content: "The warehouse in Tallinn has six loading docks.".into(),
                    actor: Some("conformance".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?;
            let (old, cur) = (store.get(t, first.id).await?, store.get(t, new.id).await?);
            let hits = recall(&e, a, "loading docks", RetrievalMode::Hybrid, false).await?;
            let ok = old.as_ref().is_some_and(|m| m.status == MemoryStatus::Superseded)
                && cur.as_ref().is_some_and(|m| m.status == MemoryStatus::Committed && m.supersedes == Some(first.id))
                && hits.iter().any(|h| h.memory.id == new.id)
                && !hits.iter().any(|h| h.memory.id == first.id);
            Ok(unless(ok, || {
                format!(
                    "old: {:?}, new: {:?}, recalled: {:?}",
                    old.map(|m| m.status.as_str().to_string()),
                    cur.map(|m| (m.status.as_str().to_string(), m.supersedes)),
                    contents(&hits)
                )
            }))
        }
        .await,
    );
    r.outcome(
        "held_candidates_are_hidden",
        "a held plan is stored as a candidate, left out of a recall, and returned only when candidates are asked for",
        async {
            let plan = remember(&e, a, "I plan to open a second warehouse in Riga next year.").await?;
            let (without, with) =
                (recall(&e, a, "second warehouse Riga", RetrievalMode::Hybrid, false).await?, recall(&e, a, "second warehouse Riga", RetrievalMode::Hybrid, true).await?);
            let ok = plan.status == MemoryStatus::Candidate && !without.iter().any(|h| h.memory.id == plan.id) && with.iter().any(|h| h.memory.id == plan.id);
            Ok(unless(ok, || {
                format!(
                    "status {}, in a plain recall: {}, with candidates: {}",
                    plan.status.as_str(),
                    without.iter().any(|h| h.memory.id == plan.id),
                    with.iter().any(|h| h.memory.id == plan.id)
                )
            }))
        }
        .await,
    );
    r.outcome(
        "denied_labels_are_filtered_in_the_store",
        "a list or a search with denied labels leaves out every record that carries one",
        async {
            let secret = e
                .remember(RememberRequest {
                    subject: Some(a.into()),
                    content: "The vault code rotates every Monday.".into(),
                    labels: vec!["kit-secret".into()],
                    actor: Some("conformance".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?;
            let listed =
                store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), limit: 100, denied_labels: vec!["kit-secret".into()], ..Default::default() }).await?;
            let all = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(a.into()), limit: 100, ..Default::default() }).await?;
            Ok(unless(!listed.iter().any(|m| m.id == secret.id) && all.iter().any(|m| m.id == secret.id), || {
                format!("with the label denied the record was listed: {}; without: {}", listed.iter().any(|m| m.id == secret.id), all.iter().any(|m| m.id == secret.id))
            }))
        }
        .await,
    );

    // Derived data: facts extracted from a round go when the round goes.
    let spend = Spend::default();
    let derived = |subject: &'static str| {
        let (e, tenant) = (e.clone(), tenant.clone());
        async move {
            anyhow::Ok(
                e.list(Some(tenant), Some(subject.to_string()), None, 1000, 0, true)
                    .await?
                    .into_iter()
                    .filter(|m| m.metadata["derived"].as_bool() == Some(true))
                    .collect::<Vec<_>>(),
            )
        }
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
    r.outcome(
        "delete_cascades_to_derived_facts",
        "deleting a conversation round also deletes the facts extracted from it",
        async {
            let ing = ingest(b, "s1", "We adopted a kitten called Marzipan last weekend.").await?;
            for _ in 0..200 {
                let st = store.enrich_status(t, Some(b)).await?;
                if st.pending + st.running == 0 {
                    break;
                }
                e.enrich_once_for(t, b, &spend).await?;
            }
            let before = derived(b).await?;
            anyhow::ensure!(
                before.iter().any(|m| m.content.contains("Marzipan")),
                "the kit could not set up the check: no fact was extracted from the round ({} derived records)",
                before.len()
            );
            for id in &ing.ids {
                e.forget(None, *id, Some("conformance".into())).await?;
            }
            let after = derived(b).await?;
            let hits = recall(&e, b, "kitten Marzipan", RetrievalMode::Hybrid, true).await?;
            Ok(unless(after.is_empty() && hits.is_empty(), || {
                format!(
                    "after the round was deleted, {} fact(s) extracted from it are still stored ({:?}) and a recall returns {} hit(s)",
                    after.len(),
                    after.iter().map(|m| m.content.as_str()).collect::<Vec<_>>(),
                    hits.len()
                )
            }))
        }
        .await,
    );
    r.outcome(
        "erasure_removes_everything",
        "erasing a subject removes its records, derived facts and queued extraction jobs; other subjects are untouched",
        async {
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
        .await,
    );
    r.outcome(
        "audit_chain_is_intact",
        "every change wrote an audit event, and the hash chain verifies",
        async {
            let (n, broken) = store.audit_verify().await?;
            let log = store.audit_log(t, 500).await?;
            let has = |action: &str| log.iter().any(|a| a.action == action);
            Ok(unless(
                broken.is_none()
                    && n > 0
                    && has("memory.write")
                    && has("memory.supersede")
                    && log.iter().any(|a| a.action.starts_with("memory.forget") || a.action.starts_with("memory.delete") || a.action.starts_with("subject.")),
                || {
                    let mut actions: Vec<&str> = log.iter().map(|a| a.action.as_str()).collect();
                    actions.sort();
                    actions.dedup();
                    format!("{n} events, chain broken at {broken:?}, actions recorded: {actions:?}")
                },
            ))
        }
        .await,
    );
    r.outcome(
        "embedding_cache_round_trip",
        "cached vectors come back by model and hash, and not for another model",
        async {
            let key = format!("kit-{}", Uuid::new_v4().simple());
            let v: Vec<f32> = (0..DIM).map(|i| i as f32 / DIM as f32).collect();
            store.embed_cache_put(&embedder.id, &[(key.clone(), v.clone())]).await?;
            let got = store.embed_cache_get(&embedder.id, std::slice::from_ref(&key)).await?;
            let other = store.embed_cache_get("another-model", std::slice::from_ref(&key)).await?;
            let same = got.first().is_some_and(|(k, g)| *k == key && g.len() == DIM && g.iter().zip(&v).all(|(x, y)| (x - y).abs() < 0.01));
            Ok(unless(same && other.is_empty(), || format!("{} vector(s) back for the model, {} for another model", got.len(), other.len())))
        }
        .await,
    );
    r.outcome(
        "idempotency_keys_round_trip",
        "a stored request key gives back its request hash and response, in its tenant only",
        async {
            let key = format!("kit-{}", Uuid::new_v4().simple());
            let response = serde_json::json!({ "id": "kit" });
            store.request_put(t, &key, a, "remember", "hash-1", &response).await?;
            let (mine, theirs) = (store.request_get(t, &key).await?, store.request_get("kit-someone-else", &key).await?);
            Ok(unless(mine.as_ref().is_some_and(|(h, v)| h == "hash-1" && *v == response) && theirs.is_none(), || {
                format!("read back: {mine:?}; another tenant: {}", theirs.is_some())
            }))
        }
        .await,
    );
    // Git-aware staleness (TR-TPL-02): the store applies `staleness::plan` to the references at
    // the observed paths, keeps the record's `stale_since` in step, and filters on it.
    let repo = "repo:kit";
    let linked = |content: &'static str, refs: Vec<CodeRef>| {
        let e = &e;
        async move {
            let written = e
                .remember(RememberRequest {
                    subject: Some(repo.into()),
                    content: content.into(),
                    code_refs: refs,
                    actor: Some("conformance".into()),
                    source: Some("conformance".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?;
            anyhow::ensure!(written.status == MemoryStatus::Committed, "the write was not committed: {}", written.status.as_str());
            Ok::<Uuid, anyhow::Error>(written.id)
        }
    };
    let at = chrono::DateTime::from_timestamp(1_800_000_000, 0).unwrap_or_default();
    let stale_of = |id: Uuid| {
        let store = &store;
        async move { Ok::<_, anyhow::Error>(store.get(t, id).await?.and_then(|m| m.stale_since)) }
    };
    r.outcome(
        "code_refs_observe_marks_staleness",
        "a file seen with another hash, deleted, or renamed with other content makes the references to it stale, and their records with them; the stored hash seen again clears it; a rename moves the reference; nothing else changes",
        async {
            let parser = linked("The parser keeps its token table in a perfect hash.", vec![CodeRef::new("src/parse.rs", "p1"), CodeRef::new("src/lex.rs", "l1")]).await?;
            let lexer = linked("The lexer never allocates on the hot path.", vec![CodeRef::new("src/lex.rs", "l1")]).await?;
            let other = linked("The printer wraps lines at one hundred columns.", vec![CodeRef::new("src/print.rs", "x1")]).await?;
            let flagged = store.code_refs_observe(t, repo, &[FileState::present("src/parse.rs", "p2"), FileState::present("src/lex.rs", "l1")], at).await?;
            let one = flagged.len() == 1 && flagged[0].id == parser && flagged[0].path == "src/parse.rs" && flagged[0].flagged && flagged[0].stale;
            let since = (stale_of(parser).await?, stale_of(lexer).await?, stale_of(other).await?);
            // Another tenant and another subject see nothing of it, and change nothing.
            let elsewhere = store.code_refs_observe("kit-someone-else", repo, &[FileState::present("src/lex.rs", "l9")], at).await?.len()
                + store.code_refs_observe(t, "repo:kit-other", &[FileState::present("src/lex.rs", "l9")], at).await?.len();
            let again = store.code_refs_observe(t, repo, &[FileState::present("src/parse.rs", "p3")], at + chrono::Duration::hours(1)).await?;
            let seen = store.representations(t, parser).await?.1.into_iter().find(|c| c.path == "src/parse.rs");
            let cleared = store.code_refs_observe(t, repo, &[FileState::present("src/parse.rs", "p1")], at).await?;
            let fresh = stale_of(parser).await?.is_none() && cleared.len() == 1 && cleared[0].cleared && !cleared[0].stale;
            // A rename with the same content moves the reference; with other content it is stale
            // too; a deletion is stale with no hash seen.
            let moved = store.code_refs_observe(t, repo, &[FileState::renamed("src/lex.rs", "src/scan.rs", "l1"), FileState::deleted("src/print.rs")], at).await?;
            let paths = |id: Uuid| {
                let store = &store;
                async move { Ok::<_, anyhow::Error>(store.representations(t, id).await?.1.into_iter().map(|c| (c.path, c.stale_since.is_some(), c.seen_hash)).collect::<Vec<_>>()) }
            };
            let (lexer_refs, other_refs) = (paths(lexer).await?, paths(other).await?);
            let renamed = lexer_refs == vec![("src/scan.rs".to_string(), false, None)] && stale_of(lexer).await?.is_none() && moved.iter().filter(|c| c.moved_from.as_deref() == Some("src/lex.rs")).count() == 2;
            let deleted = other_refs == vec![("src/print.rs".to_string(), true, None)] && stale_of(other).await? == Some(at);
            Ok(unless(
                one && since == (Some(at), None, None)
                    && elsewhere == 0
                    && again.is_empty()
                    && seen.as_ref().is_some_and(|c| c.stale_since == Some(at) && c.seen_hash.as_deref() == Some("p3"))
                    && fresh
                    && renamed
                    && deleted,
                || {
                    format!(
                        "first observation {flagged:?}; stale since {since:?}; {elsewhere} change(s) for another tenant or subject; seen again {again:?} → {seen:?}; cleared {cleared:?}; after the rename {lexer_refs:?}; after the deletion {other_refs:?}"
                    )
                },
            ))
        }
        .await,
    );
    r.outcome(
        "stale_records_are_left_out_of_search",
        "a record with a stale reference is left out by search and by the exact lookup unless the query asks for stale records, and is still read by id and listed",
        async {
            let id = linked("The scheduler wakes sleeping tasks through a timer wheel.", vec![CodeRef::new("src/timer.rs", "t1")]).await?;
            let ask = |stale: bool| {
                let e = &e;
                async move {
                    let hits = e
                        .recall(RecallRequest {
                            subject: Some(repo.into()),
                            query: "scheduler timer wheel sleeping tasks".into(),
                            k: Some(10),
                            analyze: Some(false),
                            include_stale: stale,
                            actor: Some("conformance".into()),
                            ..Default::default()
                        })
                        .await?
                        .hits;
                    Ok::<bool, anyhow::Error>(hits.iter().any(|h| h.memory.id == id))
                }
            };
            let before = ask(false).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/timer.rs", "t2")], at).await?;
            let (default, with_stale) = (ask(false).await?, ask(true).await?);
            let by_id = store.get(t, id).await?.is_some_and(|m| m.stale_since == Some(at));
            let listed = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(repo.into()), limit: 100, ..Default::default() }).await?.iter().any(|m| m.id == id);
            Ok(unless(before && !default && with_stale && by_id && listed, || {
                format!("recalled before: {before}; by default when stale: {default}; with include_stale: {with_stale}; read by id with its mark: {by_id}; listed: {listed}")
            }))
        }
        .await,
    );
    r.outcome(
        "code_refs_revalidate_and_travel",
        "revalidation gives a reference its new hash and clears the mark; references are read by path; staleness marks are exported and imported with their record",
        async {
            let id = linked("The router matches paths through a radix tree.", vec![CodeRef::new("src/route.rs", "r1"), CodeRef::new("src/tree.rs", "n1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/route.rs", "r2"), FileState::present("src/tree.rs", "n2")], at).await?;
            let at_path: Vec<(Uuid, CodeRef)> = store.code_refs_at(t, repo, &["src/route.rs".to_string()]).await?;
            let read = at_path.len() == 1 && at_path[0].0 == id && at_path[0].1.seen_hash.as_deref() == Some("r2") && store.code_refs_at("kit-someone-else", repo, &["src/route.rs".to_string()]).await?.is_empty();
            // Exported with its marks, and imported with them under a new id.
            let line = store.export_records(t, Some(repo), None, 1000).await?.into_iter().find(|l| l.id == id);
            let exported = line.as_ref().is_some_and(|l| l.code_refs.len() == 2 && l.code_refs.iter().all(|c| c.stale_since == Some(at) && c.seen_hash.is_some()));
            let mut copy = line.ok_or_else(|| anyhow::anyhow!("the record was not exported"))?;
            copy.id = Uuid::now_v7();
            copy.content = "The router matches paths through a radix tree (imported copy).".into();
            copy.content_hash = memhouse_core::engine::content_hash(&copy.content);
            store.import_records(&[ImportRow { record: copy.clone(), embedding: None, alt: None }]).await?;
            let imported = store.get(t, copy.id).await?.is_some_and(|m| m.stale_since == Some(at)) && store.representations(t, copy.id).await?.1 == copy.code_refs;
            // One reference by a given hash: the record stays stale for the other. Then the rest
            // by the hash last seen.
            let part = store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/route.rs", "r9")])).await?.unwrap_or_default();
            let still = stale_of(id).await?.is_some();
            let all = store.code_refs_revalidate(t, id, None).await?.unwrap_or_default();
            let done = stale_of(id).await?.is_none();
            let hashes = |refs: &[CodeRef]| refs.iter().map(|c| (c.path.clone(), c.blob_hash.clone(), c.stale_since.is_some())).collect::<Vec<_>>();
            let expected_part = vec![("src/route.rs".to_string(), "r9".to_string(), false), ("src/tree.rs".to_string(), "n1".to_string(), true)];
            let expected_all = vec![("src/route.rs".to_string(), "r9".to_string(), false), ("src/tree.rs".to_string(), "n2".to_string(), false)];
            let unknown = store.code_refs_revalidate(t, Uuid::now_v7(), None).await?.is_none() && store.code_refs_revalidate("kit-someone-else", id, None).await?.is_none();
            let foreign = store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/absent.rs", "x")])).await.is_err();
            Ok(unless(read && exported && imported && hashes(&part) == expected_part && still && hashes(&all) == expected_all && done && unknown && foreign, || {
                format!(
                    "read by path: {read}; exported with marks: {exported}; imported with marks: {imported}; after one reference {:?} (still stale: {still}); after the rest {:?} (fresh: {done}); unknown record answered none: {unknown}; a path that is no reference refused: {foreign}",
                    hashes(&part),
                    hashes(&all)
                )
            }))
        }
        .await,
    );
    // Leave the store as it was found, apart from its audit log.
    let _ = e.forget_by(ForgetRequest { tenant: Some(tenant.clone()), all: true, confirm: Some(tenant.clone()), actor: Some("conformance".into()), ..Default::default() }).await;
    r
}
