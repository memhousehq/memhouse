// SPDX-License-Identifier: Apache-2.0
//! Governance checks for the conformance kits (roadmap G15):
//!
//! - `adapter_conformance`: the Postgres profile's adapters pass their kits (store, intake
//!   queue, embedder, reranker when one is configured, authorizer, and the chat-model kit with a
//!   stand-in model), and a store that drops one cascade (facts extracted from a deleted round
//!   stay) fails the store kit with a message that says so.

use crate::governance::{check, Check, Scratch};
use memhouse_conformance as kit;
use memhouse_core::traits::Store;
use memhouse_core::Engine;
use std::sync::Arc;

type Outcome = anyhow::Result<(bool, String, String)>;

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    let titles = [(
        "adapter_conformance",
        "TR-CORE-02 / DEP-02 (G15)",
        "Every adapter of the Postgres profile passes its conformance kit; a store that drops one deletion cascade fails the store kit with a message that names it",
    )];
    let results: Vec<Outcome> = vec![adapters(engine).await];
    titles
        .iter()
        .zip(results)
        .map(|((id, req, title), r)| match r {
            Ok((passed, value, detail)) => check(id, req, title, passed, value, "all", detail),
            Err(e) => check(id, req, title, false, "error".into(), "all", format!("{e:#}")),
        })
        .collect()
}

async fn postgres(url: &str) -> anyhow::Result<Arc<memhouse_store_postgres::PgStore>> {
    Ok(Arc::new(memhouse_store_postgres::PgStore::connect(url, 4, "").await?.with_identity_recheck(std::time::Duration::ZERO)))
}

async fn adapters(base: &Engine) -> Outcome {
    let mut problems = vec![];
    let mut reports = vec![];
    // The store and its queue, on an empty database.
    let scratch = Scratch::create(base, "kit1").await?;
    let ran = async {
        let store = postgres(&scratch.url).await?;
        reports.push(kit::run_store_kit(store.clone()).await);
        let queue = store.intake_queue().ok_or_else(|| anyhow::anyhow!("the Postgres store has no intake queue"))?;
        reports.push(kit::run_intake_queue_kit(queue).await);
        anyhow::Ok(())
    }
    .await;
    scratch.drop().await?;
    ran?;
    reports.push(kit::run_embedder_kit(base.embedder.as_ref()).await);
    if let Some(r) = &base.reranker {
        reports.push(kit::run_reranker_kit(r.as_ref()).await);
    }
    reports.push(kit::run_authorizer_kit(&memhouse_core::access::ScopeAuthorizer::new(&base.cfg)).await);
    // No model is called in this suite: the chat kit runs with the stand-in extractor, which
    // shows the kit itself works. A real model is checked with `memhouse conformance chat`.
    reports.push(kit::run_chat_kit(&kit::fakes::EchoExtractor).await);
    for r in &reports {
        if !r.passed() {
            problems.push(if r.checks.is_empty() { format!("{}: no check ran", r.kit) } else { r.failure_text().replace('\n', "; ") });
        }
    }
    // A store that drops one cascade: the same Postgres store, on a database where deleting a
    // record extracted from a round silently does nothing.
    let scratch = Scratch::create(base, "kit2").await?;
    let faulty = async {
        let store = postgres(&scratch.url).await?;
        store.migrate(kit::STORE_KIT_DIM, &kit::fakes::HashEmbedder::new(kit::STORE_KIT_DIM).id).await?;
        let pool = sqlx::postgres::PgPoolOptions::new().max_connections(1).connect(&scratch.url).await?;
        sqlx::raw_sql(
            "CREATE FUNCTION kit_keep_derived() RETURNS trigger AS $$ BEGIN IF OLD.metadata->>'derived' = 'true' THEN RETURN NULL; END IF; RETURN OLD; END $$ LANGUAGE plpgsql; \
             CREATE TRIGGER kit_keep_derived BEFORE DELETE ON mh_memory FOR EACH ROW EXECUTE FUNCTION kit_keep_derived();",
        )
        .execute(&pool)
        .await?;
        pool.close().await;
        anyhow::Ok(kit::run_store_kit(store).await)
    }
    .await;
    scratch.drop().await?;
    let faulty = faulty?;
    let text = faulty.failure_text();
    let named = faulty.failures().iter().any(|c| c.name == "delete_cascades_to_derived_facts") && text.contains("still stored");
    if faulty.passed() || !named {
        problems.push(format!("a store that keeps the facts of a deleted round was not caught clearly: {}", if faulty.passed() { "the kit passed".to_string() } else { text.replace('\n', "; ") }));
    }
    let value = format!("{}; the faulty store failed {} check(s)", reports.iter().map(|r| r.summary()).collect::<Vec<_>>().join("; "), faulty.failures().len());
    let passed = problems.is_empty();
    Ok((passed, value, if passed { "every kit passed; the dropped cascade was named".into() } else { problems.into_iter().take(6).collect::<Vec<_>>().join("; ") }))
}
