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
        "find_by_hash_prefers_the_live_record",
        "of several records with one content hash, the lookup by hash gives the committed one, else the candidate, whatever order they were written and updated in",
        async {
            let hash = memhouse_core::engine::content_hash(&format!("kit-{}", Uuid::new_v4().simple()));
            let base = store.get(t, first.id).await?.ok_or_else(|| anyhow::anyhow!("the first record is gone"))?;
            let copy = |status: MemoryStatus, n: i64| {
                let mut m = base.clone();
                (m.id, m.status, m.subject) = (Uuid::now_v7(), status, "kit:same-hash".to_string());
                m.content = format!("The same statement, written again ({n}).");
                m.created_at += chrono::Duration::milliseconds(n);
                NewMemory::new(m, hash.clone())
            };
            // A rejected repeat written first, then the candidate it repeats, then a later repeat.
            let (early, held, late) = (copy(MemoryStatus::Rejected, 0), copy(MemoryStatus::Candidate, 1), copy(MemoryStatus::Rejected, 2));
            store.insert(std::slice::from_ref(&early)).await?;
            store.insert(std::slice::from_ref(&held)).await?;
            store.insert(std::slice::from_ref(&late)).await?;
            let mut picks = vec![store.find_by_hash(t, "kit:same-hash", &hash).await?];
            // The candidate's row is rewritten several times (labels), which moves it in a
            // store that appends new row versions; the answer must stay the same.
            for i in 0..5 {
                store.set_labels(t, held.memory.id, &[format!("kit-{i}")]).await?;
                picks.push(store.find_by_hash(t, "kit:same-hash", &hash).await?);
            }
            let committed = copy(MemoryStatus::Committed, 3);
            store.insert(std::slice::from_ref(&committed)).await?;
            let now = store.find_by_hash(t, "kit:same-hash", &hash).await?;
            for id in [early.memory.id, held.memory.id, late.memory.id, committed.memory.id] {
                store.delete(t, id, "conformance").await?;
            }
            Ok(unless(picks.iter().all(|p| *p == Some(held.memory.id)) && now == Some(committed.memory.id), || {
                format!(
                    "with a candidate between two rejected repeats the lookup gave the candidate in {} of {} tries; with a committed record added it gave the committed one: {}",
                    picks.iter().filter(|p| **p == Some(held.memory.id)).count(),
                    picks.len(),
                    now == Some(committed.memory.id)
                )
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
        "a file seen with another hash, deleted, or renamed with other content makes the references to it stale, and their records with them; the stored hash seen again clears it; a rename moves the reference; nothing else changes; a revision is stored with its references judged against its predecessor's as they are then",
        async {
            let parser = linked("The parser keeps its token table in a perfect hash.", vec![CodeRef::new("src/parse.rs", "p1"), CodeRef::new("src/lex.rs", "l1")]).await?;
            let lexer = linked("The lexer never allocates on the hot path.", vec![CodeRef::new("src/lex.rs", "l1")]).await?;
            let other = linked("The printer wraps lines at one hundred columns.", vec![CodeRef::new("src/print.rs", "x1")]).await?;
            let flagged = store.code_refs_observe(t, repo, &[FileState::present("src/parse.rs", "p2"), FileState::present("src/lex.rs", "l1")], at, &memhouse_core::traits::no_audit).await?;
            let one = flagged.len() == 1 && flagged[0].id == parser && flagged[0].path == "src/parse.rs" && flagged[0].flagged && flagged[0].stale;
            let since = (stale_of(parser).await?, stale_of(lexer).await?, stale_of(other).await?);
            // Another tenant and another subject see nothing of it, and change nothing.
            let elsewhere = store.code_refs_observe("kit-someone-else", repo, &[FileState::present("src/lex.rs", "l9")], at, &memhouse_core::traits::no_audit).await?.len()
                + store.code_refs_observe(t, "repo:kit-other", &[FileState::present("src/lex.rs", "l9")], at, &memhouse_core::traits::no_audit).await?.len();
            let again = store.code_refs_observe(t, repo, &[FileState::present("src/parse.rs", "p3")], at + chrono::Duration::hours(1), &memhouse_core::traits::no_audit).await?;
            let seen = store.representations(t, parser).await?.1.into_iter().find(|c| c.path == "src/parse.rs");
            let cleared = store.code_refs_observe(t, repo, &[FileState::present("src/parse.rs", "p1")], at, &memhouse_core::traits::no_audit).await?;
            let fresh = stale_of(parser).await?.is_none() && cleared.len() == 1 && cleared[0].cleared && !cleared[0].stale;
            // A rename with the same content moves the reference; with other content it is stale
            // too; a deletion is stale with no hash seen.
            let moved = store.code_refs_observe(t, repo, &[FileState::renamed("src/lex.rs", "src/scan.rs", "l1"), FileState::deleted("src/print.rs")], at, &memhouse_core::traits::no_audit).await?;
            let paths = |id: Uuid| {
                let store = &store;
                async move { Ok::<_, anyhow::Error>(store.representations(t, id).await?.1.into_iter().map(|c| (c.path, c.stale_since.is_some(), c.seen_hash)).collect::<Vec<_>>()) }
            };
            let (lexer_refs, other_refs) = (paths(lexer).await?, paths(other).await?);
            let renamed = lexer_refs == vec![("src/scan.rs".to_string(), false, None)] && stale_of(lexer).await?.is_none() && moved.iter().filter(|c| c.moved_from.as_deref() == Some("src/lex.rs")).count() == 2;
            let deleted = other_refs == vec![("src/print.rs".to_string(), true, None)] && stale_of(other).await? == Some(at);
            // A record that is stale already is reported as such when another of its files
            // changes: it did not become stale with that observation.
            let two = linked("The cache and the index are rebuilt together.", vec![CodeRef::new("src/cache.rs", "c1"), CodeRef::new("src/index.rs", "i1")]).await?;
            let one_file = store.code_refs_observe(t, repo, &[FileState::present("src/cache.rs", "c2")], at, &memhouse_core::traits::no_audit).await?;
            let other_file = store.code_refs_observe(t, repo, &[FileState::present("src/index.rs", "i2")], at, &memhouse_core::traits::no_audit).await?;
            let transitions = one_file.len() == 1 && one_file[0].id == two && !one_file[0].was_stale && one_file[0].stale && other_file.len() == 1 && other_file[0].flagged && other_file[0].was_stale;
            // Renames that pass through each other's paths in one batch: `b` to `c`, then `a`
            // to `b`, on a record that references both. And the events given for the changes
            // are in the audit log with them.
            let chain = linked("The reader and the writer share one buffer type.", vec![CodeRef::new("src/a.rs", "a1"), CodeRef::new("src/b.rs", "b1")]).await?;
            let event = |changes: &[RefChange]| {
                vec![memhouse_core::intake::AuditEntry {
                    actor: "conformance".into(),
                    action: "kit.observed".into(),
                    subject: Some(repo.to_string()),
                    memory_id: changes.first().map(|c| c.id),
                    detail: serde_json::json!({ "changes": changes.len() }),
                }]
            };
            let renamed_chain =
                store.code_refs_observe(t, repo, &[FileState::renamed("src/b.rs", "src/c.rs", "b1"), FileState::renamed("src/a.rs", "src/b.rs", "a1")], at, &event).await;
            let chain_refs: Vec<(String, String)> = store.representations(t, chain).await?.1.into_iter().map(|c| (c.path, c.blob_hash)).collect();
            let chained = renamed_chain.as_ref().is_ok_and(|c| c.len() == 2) && chain_refs == vec![("src/b.rs".to_string(), "a1".to_string()), ("src/c.rs".to_string(), "b1".to_string())];
            let audited = store.audit_log(t, 50).await?.iter().any(|e| e.action == "kit.observed" && e.memory_id == Some(chain) && e.detail["changes"] == 2);
            // A rename onto a path the record already references drops the old reference. If
            // that one was stale, the record is fresh again, and the change says so.
            let merge = linked("The codec tables are generated at build time.", vec![CodeRef::new("src/m1.rs", "x1"), CodeRef::new("src/m2.rs", "y1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/m1.rs", "x2")], at, &memhouse_core::traits::no_audit).await?;
            let dropped = store.code_refs_observe(t, repo, &[FileState::renamed("src/m1.rs", "src/m2.rs", "y1")], at, &memhouse_core::traits::no_audit).await?;
            let merge_refs: Vec<(String, String)> = store.representations(t, merge).await?.1.into_iter().map(|c| (c.path, c.blob_hash)).collect();
            let merged = dropped.len() == 1
                && dropped[0].cleared
                && dropped[0].was_stale
                && !dropped[0].stale
                && dropped[0].moved_from.as_deref() == Some("src/m1.rs")
                && merge_refs == vec![("src/m2.rs".to_string(), "y1".to_string())]
                && stale_of(merge).await?.is_none();
            // A revision is stored with its references judged against its predecessor's as
            // they are when it is stored, whatever was read when the revision was made: here
            // the files are seen between that read and the insert.
            let revision = |old: Uuid, refs: Vec<CodeRef>, inherited: bool| {
                let store = &store;
                async move {
                    let mut m = store.get(t, old).await?.ok_or_else(|| anyhow::anyhow!("the record to revise is not stored"))?;
                    (m.id, m.supersedes) = (Uuid::now_v7(), Some(old));
                    m.content = format!("{} (revised)", m.content);
                    let mut n = NewMemory::new(m.clone(), memhouse_core::engine::content_hash(&m.content));
                    (n.code_refs, n.refs_inherited) = (refs, inherited);
                    let write = memhouse_core::intake::IntakeWrite { tenant: t.to_string(), records: vec![n], supersede: vec![(old, m.id)], ..Default::default() };
                    anyhow::ensure!(store.apply_intake(&write).await?, "the revision was not written");
                    let refs: Vec<(String, String, bool, Option<String>)> =
                        store.representations(t, m.id).await?.1.into_iter().map(|c| (c.path, c.blob_hash, c.stale_since.is_some(), c.seen_hash)).collect();
                    Ok::<_, anyhow::Error>((refs, stale_of(m.id).await?.is_some()))
                }
            };
            let own = linked("The session store evicts by last use.", vec![CodeRef::new("src/s1.rs", "s1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/s1.rs", "s2")], at, &memhouse_core::traits::no_audit).await?;
            let own_after = revision(own, vec![CodeRef::new("src/s1.rs", "s1")], false).await?;
            let taken = linked("The upload path streams to disk in chunks.", vec![CodeRef::new("src/u1.rs", "u1"), CodeRef::new("src/u2.rs", "v1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/u1.rs", "u2")], at, &memhouse_core::traits::no_audit).await?;
            // Read here by the reviser: `u1.rs` as last seen, `u2.rs`. Then the first is seen
            // restored and the second renamed.
            store.code_refs_observe(t, repo, &[FileState::present("src/u1.rs", "u1"), FileState::renamed("src/u2.rs", "src/u3.rs", "v1")], at, &memhouse_core::traits::no_audit).await?;
            let taken_after = revision(taken, vec![CodeRef::new("src/u1.rs", "u2"), CodeRef::new("src/u2.rs", "v1")], true).await?;
            let vanished = linked("The report generator caches its templates.", vec![CodeRef::new("src/r1.rs", "q1"), CodeRef::new("src/r3.rs", "q3")]).await?;
            // Two files, each renamed and then deleted, the second first. Nothing tells which
            // deleted file was which: each reference stays at the path and with the hash the
            // reviser read for it, stale, and none appears at a path that was not read.
            store
                .code_refs_observe(
                    t,
                    repo,
                    &[
                        FileState::renamed("src/r3.rs", "src/r4.rs", "q3"),
                        FileState::deleted("src/r4.rs"),
                        FileState::renamed("src/r1.rs", "src/r2.rs", "q1"),
                        FileState::deleted("src/r2.rs"),
                    ],
                    at,
                    &memhouse_core::traits::no_audit,
                )
                .await?;
            let vanished_after = revision(vanished, vec![CodeRef::new("src/r1.rs", "q1"), CodeRef::new("src/r3.rs", "q3")], true).await?;
            // A record that takes another's place without revising it (a reviewer's rewording)
            // is stored with that record's references as they are when it is inserted: a
            // report that arrives after the reviewer read them is not lost, and no other
            // record's state is touched.
            let reviewed = linked("The importer reads one batch at a time.", vec![CodeRef::new("src/i1.rs", "i1")]).await?;
            let sibling = linked("The importer's batch size is set in its header.", vec![CodeRef::new("src/i1.rs", "i2")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/i1.rs", "i2")], at, &memhouse_core::traits::no_audit).await?;
            // Read here by the reviewer (stale, seen `i2`). Then the file is seen again, changed.
            store.code_refs_observe(t, repo, &[FileState::present("src/i1.rs", "i3")], at, &memhouse_core::traits::no_audit).await?;
            let marks = |id: Uuid| {
                let store = &store;
                async move {
                    Ok::<_, anyhow::Error>(store.representations(t, id).await?.1.into_iter().map(|c| (c.path, c.blob_hash, c.stale_since.is_some(), c.seen_hash)).collect::<Vec<_>>())
                }
            };
            let sibling_before = marks(sibling).await?;
            let mut m = store.get(t, reviewed).await?.ok_or_else(|| anyhow::anyhow!("the reviewed record is not stored"))?;
            m.id = Uuid::now_v7();
            m.content = "The importer takes its input batch by batch.".into();
            let mut n = NewMemory::new(m.clone(), memhouse_core::engine::content_hash(&m.content));
            n.refs_from = Some(reviewed);
            anyhow::ensure!(store.apply_intake(&memhouse_core::intake::IntakeWrite { tenant: t.to_string(), records: vec![n], ..Default::default() }).await?, "the replacement was not written");
            let seen_i3 = |hash: &str| vec![("src/i1.rs".to_string(), hash.to_string(), true, Some("i3".to_string()))];
            let replaced = marks(m.id).await? == seen_i3("i1")
                && stale_of(m.id).await?.is_some()
                && marks(reviewed).await? == seen_i3("i1")
                && sibling_before == seen_i3("i2")
                && marks(sibling).await? == sibling_before;
            let kept_gone = replaced && vanished_after == (vec![("src/r1.rs".to_string(), "q1".to_string(), true, None), ("src/r3.rs".to_string(), "q3".to_string(), true, None)], true);
            let judged = kept_gone && own_after == (vec![("src/s1.rs".to_string(), "s1".to_string(), true, Some("s2".to_string()))], true)
                // Taken from the predecessor: the renamed file is followed; the one restored
                // since the reviser read it leaves the revision stale (written about `u2`).
                && taken_after == (vec![("src/u1.rs".to_string(), "u2".to_string(), true, Some("u1".to_string())), ("src/u3.rs".to_string(), "v1".to_string(), false, None)], true);
            Ok(unless(
                one && since == (Some(at), None, None)
                    && elsewhere == 0
                    // Another hash on a reference that is stale already: no transition, and
                    // still a change, so that it is audited.
                    && again.len() == 1
                    && again[0].seen_only
                    && again[0].seen_hash.as_deref() == Some("p3")
                    && !again[0].flagged
                    && !again[0].cleared
                    && seen.as_ref().is_some_and(|c| c.stale_since == Some(at) && c.seen_hash.as_deref() == Some("p3"))
                    && fresh
                    && renamed
                    && deleted
                    && transitions
                    && chained
                    && audited
                    && merged
                    && judged,
                || {
                    format!(
                        "first observation {flagged:?}; stale since {since:?}; {elsewhere} change(s) for another tenant or subject; seen again {again:?} → {seen:?}; cleared {cleared:?}; after the rename {lexer_refs:?}; after the deletion {other_refs:?}; a second file of a stale record reported with its state before: {transitions} ({other_file:?}); renames b→c then a→b in one batch: {} → {chain_refs:?}; the observation's audit event written: {audited}; a stale reference merged away by a rename clears its record: {merged} ({dropped:?} → {merge_refs:?}); revisions judged when stored: own {own_after:?}, inherited {taken_after:?}, renamed then deleted {vanished_after:?}",
                        renamed_chain.as_ref().map(|c| c.len().to_string()).unwrap_or_else(|e| format!("{e:#}"))
                    )
                },
            ))
        }
        .await,
    );
    r.outcome(
        "stale_records_are_left_out_of_search",
        "a record with a stale reference is left out by search and by the exact lookup unless the query asks for stale records, and is still read by id and listed (unless the list asks for fresh records only)",
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
            // A structured record about the same file, found by the exact lookup.
            let ticket = e
                .remember(RememberRequest {
                    subject: Some(repo.into()),
                    content: "Ticket KIT-7 tracks the timer wheel rewrite".into(),
                    structured: Some(Structured { record_type: "ticket".into(), attrs: serde_json::json!({ "ticket_id": "KIT-7" }) }),
                    code_refs: vec![CodeRef::new("src/timer.rs", "t1")],
                    actor: Some("conformance".into()),
                    source: Some("conformance".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?
                .id;
            let exact = |stale: bool| {
                let e = &e;
                async move {
                    let hits = e
                        .recall(RecallRequest {
                            subject: Some(repo.into()),
                            query: "the ticket".into(),
                            k: Some(10),
                            analyze: Some(false),
                            exact: Some(ExactQuery { record_type: Some("ticket".into()), attrs: serde_json::json!({ "ticket_id": "KIT-7" }) }),
                            include_stale: stale,
                            actor: Some("conformance".into()),
                            ..Default::default()
                        })
                        .await?
                        .hits;
                    Ok::<bool, anyhow::Error>(hits.iter().any(|h| h.exact && h.memory.id == ticket))
                }
            };
            let before = ask(false).await? && exact(false).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/timer.rs", "t2")], at, &memhouse_core::traits::no_audit).await?;
            let (default, with_stale) = (ask(false).await? || exact(false).await?, ask(true).await? && exact(true).await?);
            // A list shows stale records unless it is asked for fresh ones only, and then the
            // filter is applied before the limit.
            let fresh = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(repo.into()), limit: 1000, fresh_only: true, ..Default::default() }).await?;
            let fresh_only = !fresh.is_empty() && fresh.iter().all(|m| m.stale_since.is_none());
            let by_id = store.get(t, id).await?.is_some_and(|m| m.stale_since == Some(at));
            let listed = store.list(&ListQuery { tenant: tenant.clone(), subject: Some(repo.into()), limit: 100, ..Default::default() }).await?.iter().any(|m| m.id == id);
            Ok(unless(before && !default && with_stale && by_id && listed && fresh_only, || {
                format!(
                    "recalled before, by search and by exact lookup: {before}; by either when stale: {default}; by both with include_stale: {with_stale}; read by id with its mark: {by_id}; listed: {listed}; a list of fresh records only holds none that is stale: {fresh_only}"
                )
            }))
        }
        .await,
    );
    r.outcome(
        "code_refs_revalidate_and_travel",
        "revalidation gives a reference its new hash and clears the mark, unless the file was seen with another hash than the one confirmed; references are read by path; staleness marks are exported and imported with their record",
        async {
            let id = linked("The router matches paths through a radix tree.", vec![CodeRef::new("src/route.rs", "r1"), CodeRef::new("src/tree.rs", "n1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/route.rs", "r2"), FileState::present("src/tree.rs", "n2")], at, &memhouse_core::traits::no_audit).await?;
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
            let part = store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/route.rs", "r2")]), &memhouse_core::traits::no_revalidation_audit).await?.unwrap_or_default();
            let still = stale_of(id).await?.is_some();
            // A confirmation does not hide what was seen after the content it confirms: the
            // file is seen at `r3`, then confirmed at `r2` by a caller that read it before.
            // The reference stays stale, with the hash seen; confirmed at `r3`, it is fresh.
            store.code_refs_observe(t, repo, &[FileState::present("src/route.rs", "r3")], at, &memhouse_core::traits::no_audit).await?;
            let late = store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/route.rs", "r2")]), &memhouse_core::traits::no_revalidation_audit).await?.unwrap_or_default();
            let kept = late.iter().any(|c| c.path == "src/route.rs" && c.blob_hash == "r2" && c.stale_since.is_some() && c.seen_hash.as_deref() == Some("r3"));
            store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/route.rs", "r3")]), &memhouse_core::traits::no_revalidation_audit).await?;
            let all = store.code_refs_revalidate(t, id, None, &memhouse_core::traits::no_revalidation_audit).await?.unwrap_or_default();
            let done = stale_of(id).await?.is_none();
            let hashes = |refs: &[CodeRef]| refs.iter().map(|c| (c.path.clone(), c.blob_hash.clone(), c.stale_since.is_some())).collect::<Vec<_>>();
            let expected_part = vec![("src/route.rs".to_string(), "r2".to_string(), false), ("src/tree.rs".to_string(), "n1".to_string(), true)];
            let expected_all = vec![("src/route.rs".to_string(), "r3".to_string(), false), ("src/tree.rs".to_string(), "n2".to_string(), false)];
            // Seen changed and back again, the reference is not stale: a hash confirmed late
            // for the content in between is a conflict, and writes nothing.
            store.code_refs_observe(t, repo, &[FileState::present("src/tree.rs", "n9")], at, &memhouse_core::traits::no_audit).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/tree.rs", "n2")], at, &memhouse_core::traits::no_audit).await?;
            let ambiguous = store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/tree.rs", "n9")]), &memhouse_core::traits::no_revalidation_audit).await;
            let refused = ambiguous.as_ref().is_err_and(|e| memhouse_core::error::code_of(e) == memhouse_core::error::ErrorCode::Conflict)
                && hashes(&store.representations(t, id).await?.1) == expected_all;
            // A record that is no longer the committed version is not revalidated: checked by
            // the store on the row it writes, whatever the caller read before.
            let old = linked("The mailer retries a failed delivery three times.", vec![CodeRef::new("src/mail.rs", "m1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/mail.rs", "m2")], at, &memhouse_core::traits::no_audit).await?;
            e.revise(ReviseRequest { tenant: Some(tenant.clone()), id: old, content: "The mailer retries a failed delivery five times.".into(), wait: true, ..Default::default() }).await?;
            let superseded = store.code_refs_revalidate(t, old, None, &memhouse_core::traits::no_revalidation_audit).await;
            let not_current = superseded.as_ref().is_err_and(|e| memhouse_core::error::code_of(e) == memhouse_core::error::ErrorCode::Conflict)
                && store.representations(t, old).await?.1.iter().all(|c| c.blob_hash == "m1" && c.stale_since.is_some());
            // Checked by a caller, then reported deleted, then confirmed with the hash checked:
            // the reference takes the hash and stays stale, until the file is seen with it.
            let removed = linked("The exporter writes one file per tenant.", vec![CodeRef::new("src/export.rs", "e1")]).await?;
            store.code_refs_observe(t, repo, &[FileState::present("src/export.rs", "e2")], at, &memhouse_core::traits::no_audit).await?;
            store.code_refs_observe(t, repo, &[FileState::deleted("src/export.rs")], at, &memhouse_core::traits::no_audit).await?;
            let after_deletion = store.code_refs_revalidate(t, removed, Some(&[CodeRef::new("src/export.rs", "e2")]), &memhouse_core::traits::no_revalidation_audit).await?.unwrap_or_default();
            let still_gone = after_deletion.iter().all(|c| c.blob_hash == "e2" && c.stale_since.is_some() && c.seen_hash.is_none()) && stale_of(removed).await?.is_some();
            store.code_refs_observe(t, repo, &[FileState::present("src/export.rs", "e2")], at, &memhouse_core::traits::no_audit).await?;
            let back_again = stale_of(removed).await?.is_none();
            let deleted_kept = still_gone && back_again;
            let unknown = store.code_refs_revalidate(t, Uuid::now_v7(), None, &memhouse_core::traits::no_revalidation_audit).await?.is_none() && store.code_refs_revalidate("kit-someone-else", id, None, &memhouse_core::traits::no_revalidation_audit).await?.is_none();
            let foreign = store.code_refs_revalidate(t, id, Some(&[CodeRef::new("src/absent.rs", "x")]), &memhouse_core::traits::no_revalidation_audit).await.is_err();
            Ok(unless(read && exported && imported && hashes(&part) == expected_part && still && kept && refused && not_current && deleted_kept && hashes(&all) == expected_all && done && unknown && foreign, || {
                format!(
                    "read by path: {read}; exported with marks: {exported}; imported with marks: {imported}; after one reference {:?} (still stale: {still}); a hash seen after the confirmed one kept the reference stale: {kept} ({late:?}); a hash for content seen before the file went back refused: {refused}; a superseded record refused: {not_current}; a hash confirmed after a deletion stays stale until the file is seen again: {deleted_kept} ({after_deletion:?}); after the rest {:?} (fresh: {done}); unknown record answered none: {unknown}; a path that is no reference refused: {foreign}",
                    hashes(&part),
                    hashes(&all)
                )
            }))
        }
        .await,
    );
    // The admin console (G20): sessions kept by the hash of their secret, the review queue,
    // and what the profile advisor measures.
    r.outcome(
        "sessions_review_queue_and_usage",
        "a session is stored, touched, purged and deleted by its id; the review queue lists a tenant's candidates and quarantined records newest first; usage counts what the store holds",
        async {
            let now = chrono::DateTime::from_timestamp_micros(chrono::Utc::now().timestamp_micros()).unwrap_or_default();
            let session = |id: &str| memhouse_core::identity::Session {
                id: format!("{id}-{}", Uuid::new_v4().simple()),
                tenant: t.into(),
                principal_id: "admin:kit".into(),
                key_id: "kit".into(),
                key_check: Some("kid.check".into()),
                created_at: now,
                expires_at: now + chrono::Duration::hours(1),
                last_seen_at: now,
            };
            let (live, mut ended, mut idle) = (session("live"), session("ended"), session("idle"));
            ended.expires_at = now - chrono::Duration::seconds(1);
            idle.last_seen_at = now - chrono::Duration::hours(3);
            for s in [&live, &ended, &idle] {
                store.session_put(s).await?;
            }
            let read = store.session_get(&live.id).await? == Some(live.clone()) && store.session_get("kit-no-such-session").await?.is_none();
            let twice = store.session_put(&live).await.is_err();
            store.session_touch(&live.id, now + chrono::Duration::minutes(2)).await?;
            store.session_touch(&live.id, now).await?;
            let touched = store.session_get(&live.id).await?.is_some_and(|s| s.last_seen_at == now + chrono::Duration::minutes(2));
            let by_end = store.sessions_purge(now, None).await?;
            let by_idle = store.sessions_purge(now, Some(now - chrono::Duration::hours(2))).await?;
            let kept = store.session_get(&live.id).await?.is_some() && store.session_get(&ended.id).await?.is_none() && store.session_get(&idle.id).await?.is_none();
            let deleted = store.session_delete(&live.id).await? && !store.session_delete(&live.id).await?;
            let sessions = read && twice && touched && by_end == 1 && by_idle == 1 && kept && deleted;

            // The queue: records in the asked states, of the tenant, newest first, by keyset.
            let queue = "review:kit";
            let before = store.usage(t).await?;
            let mut made = vec![];
            for (i, status) in [MemoryStatus::Quarantined, MemoryStatus::Candidate, MemoryStatus::Committed, MemoryStatus::Quarantined].into_iter().enumerate() {
                let mut n = NewMemory::new(
                    Memory {
                        id: Uuid::now_v7(),
                        tenant: t.into(),
                        subject: queue.into(),
                        kind: MemoryKind::Semantic,
                        status,
                        content: format!("review queue record {i}"),
                        session_id: None,
                        turn_ref: None,
                        occurred_at: None,
                        valid_from: now,
                        valid_to: None,
                        supersedes: None,
                        labels: vec![],
                        tags: vec![],
                        source: "conformance".into(),
                        confidence: 1.0,
                        metadata: serde_json::json!({}),
                        created_at: now + chrono::Duration::milliseconds(i as i64),
                        expires_at: None,
                        scope: Scope::default(),
                        provenance: Provenance::default(),
                        language: None,
                        stale_since: None,
                    },
                    memhouse_core::engine::content_hash(&format!("review queue record {i}")),
                );
                n.embedding = Some(vec![1.0; DIM]);
                made.push(n.memory.id);
                store.insert(&[n]).await?;
            }
            let both = [MemoryStatus::Candidate, MemoryStatus::Quarantined];
            let ids = |ms: &[Memory]| ms.iter().map(|m| m.id).collect::<Vec<_>>();
            let all = store.review_queue(t, &both, Some(queue), None, 10).await?;
            let first = store.review_queue(t, &both, None, None, 2).await?;
            let rest = match first.last() {
                Some(m) => store.review_queue(t, &both, Some(queue), Some((m.created_at, m.id)), 10).await?,
                None => vec![],
            };
            let quarantined = store.review_queue(t, &[MemoryStatus::Quarantined], Some(queue), None, 10).await?;
            let foreign = store.review_queue("kit-someone-else", &both, None, None, 10).await?;
            let queued = ids(&all) == vec![made[3], made[1], made[0]]
                && ids(&first) == vec![made[3], made[1]]
                && ids(&rest) == vec![made[0]]
                && ids(&quarantined) == vec![made[3], made[0]]
                && foreign.is_empty();
            let after = store.usage(t).await?;
            let counted = after.records == before.records + 4 && after.writes_last_hour >= 4 && after.largest_subject.as_ref().is_some_and(|(_, n)| *n >= 4);
            Ok(unless(sessions && queued && counted, || {
                format!(
                    "session read back: {read}; a second put of its id refused: {twice}; last use moved forward only: {touched}; purged {by_end} past its end and {by_idle} idle (expected 1 and 1); the live one kept: {kept}; deleted once: {deleted}; the queue: {:?}, first page {:?}, rest {:?}, quarantined {:?}, another tenant {} (made {made:?}); usage {before:?} then {after:?}",
                    ids(&all),
                    ids(&first),
                    ids(&rest),
                    ids(&quarantined),
                    foreign.len()
                )
            }))
        }
        .await,
    );
    // Leave the store as it was found, apart from its audit log.
    let _ = e.forget_by(ForgetRequest { tenant: Some(tenant.clone()), all: true, confirm: Some(tenant.clone()), actor: Some("conformance".into()), ..Default::default() }).await;
    r
}
