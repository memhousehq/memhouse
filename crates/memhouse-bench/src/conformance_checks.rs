// SPDX-License-Identifier: Apache-2.0
//! Governance checks for the conformance kits (roadmap G15):
//!
//! - `adapter_conformance`: the adapters of the profile under test pass their kits (store, intake
//!   queue, embedder, reranker when one is configured, authorizer, and the chat-model kit with a
//!   stand-in model), and a store that drops one cascade (facts extracted from a deleted round
//!   stay) fails the store kit with a message that says so;
//! - `profile_conformance`: the basic scenario gives the same outcomes through REST, MCP and
//!   the command line, each meeting the scenario's expectations (PROF-01: one engine behind
//!   every way in).

use crate::governance::{check, Check, Scratch};
use crate::scratch::{open_store, Profile, Sql};
use memhouse_conformance as kit;
use memhouse_core::Engine;

type Outcome = anyhow::Result<(bool, String, String)>;

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    // The profile under test is named in the title: the kits ran against its store and queue.
    let adapters_title = format!(
        "Every adapter of the {} profile passes its conformance kit; a store that drops one deletion cascade fails the store kit with a message that names it",
        Profile::of(engine).title()
    );
    let titles = [
        ("adapter_conformance", "TR-CORE-02 / DEP-02 (G15)", adapters_title.as_str()),
        (
            "profile_conformance",
            "PROF-01 / TR-CORE-01 (G15)",
            "The profile scenario gives the same outcome at every step through REST, MCP and the command line, and each meets the scenario's expectations",
        ),
    ];
    let results: Vec<Outcome> = vec![adapters(engine).await, profile(engine).await];
    titles
        .iter()
        .zip(results)
        .map(|((id, req, title), r)| match r {
            Ok((passed, value, detail)) => check(id, req, title, passed, value, "all", detail),
            Err(e) => crate::governance::errored(id, req, title, "all", e),
        })
        .collect()
}

async fn adapters(base: &Engine) -> Outcome {
    let mut problems = vec![];
    let mut reports = vec![];
    // The store and its queue, on an empty database.
    let scratch = Scratch::create(base, "kit1").await?;
    let ran = async {
        let store = open_store(&scratch.url, 4, "").await?;
        reports.push(kit::run_store_kit(store.clone()).await);
        let queue = store.intake_queue().ok_or_else(|| anyhow::anyhow!("the {} store has no intake queue", scratch.profile().title()))?;
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
    // shows the kit itself works. A real chat model is checked by calling `run_chat_kit` on it.
    reports.push(kit::run_chat_kit(&kit::fakes::EchoExtractor).await);
    for r in &reports {
        if !r.passed() {
            problems.push(if r.checks.is_empty() { format!("{}: no check ran", r.kit) } else { r.failure_text().replace('\n', "; ") });
        }
    }
    // A store that drops one cascade: the same store, on a database where deleting a record
    // extracted from a round silently does nothing, once.
    let scratch = Scratch::create(base, "kit2").await?;
    let faulty = async {
        let store = open_store(&scratch.url, 4, "").await?;
        store.migrate(kit::STORE_KIT_DIM, &kit::fakes::HashEmbedder::new(kit::STORE_KIT_DIM).id).await?;
        let db = scratch.db().await?;
        // The fault drops one cascade and then heals: the first extracted fact that should be
        // deleted stays. (A store that never deleted one would keep erasure retrying for an hour.)
        // The same fault in each database's own trigger language: in SQLite, RAISE(IGNORE) in a
        // BEFORE DELETE trigger skips that one row and keeps the trigger's own update, which is
        // what RETURN NULL does in Postgres; `derived` is a JSON true, which SQLite reads as 1.
        db.batch(Sql::each(
            "CREATE TABLE kit_fault (left_to_drop int NOT NULL); INSERT INTO kit_fault VALUES (1); \
             CREATE FUNCTION kit_keep_derived() RETURNS trigger AS $$ BEGIN \
               IF OLD.metadata->>'derived' = 'true' THEN \
                 UPDATE kit_fault SET left_to_drop = left_to_drop - 1 WHERE left_to_drop > 0; \
                 IF FOUND THEN RETURN NULL; END IF; \
               END IF; RETURN OLD; END $$ LANGUAGE plpgsql; \
             CREATE TRIGGER kit_keep_derived BEFORE DELETE ON mh_memory FOR EACH ROW EXECUTE FUNCTION kit_keep_derived();",
            "CREATE TABLE kit_fault (left_to_drop int NOT NULL); INSERT INTO kit_fault VALUES (1); \
             CREATE TRIGGER kit_keep_derived BEFORE DELETE ON mh_memory \
             WHEN json_extract(OLD.metadata, '$.derived') = 1 AND (SELECT left_to_drop FROM kit_fault) > 0 BEGIN \
               UPDATE kit_fault SET left_to_drop = left_to_drop - 1; \
               SELECT RAISE(IGNORE); \
             END;",
        ))
        .await?;
        db.close().await;
        anyhow::Ok(kit::run_store_kit(store).await)
    }
    .await;
    scratch.drop().await?;
    let faulty = faulty?;
    let text = faulty.failure_text();
    let named = faulty.failures().iter().any(|c| c.name == "delete_cascades_to_derived_facts") && text.contains("still stored");
    if faulty.passed() || !named {
        problems.push(format!(
            "a store that keeps the facts of a deleted round was not caught clearly: {}",
            if faulty.passed() { "the kit passed".to_string() } else { text.replace('\n', "; ") }
        ));
    }
    let value = format!("{}; the faulty store failed {} check(s)", reports.iter().map(|r| r.summary()).collect::<Vec<_>>().join("; "), faulty.failures().len());
    let passed = problems.is_empty();
    Ok((passed, value, if passed { "every kit passed; the dropped cascade was named".into() } else { problems.into_iter().take(6).collect::<Vec<_>>().join("; ") }))
}

const KEY: &str = "mh_conformance_profile_key_0123456789";

/// The basic scenario through the three ways into one deployment of the profile under test: a
/// server on a scratch database for REST and MCP, and this binary with the same configuration for the CLI.
async fn profile(base: &Engine) -> Outcome {
    use kit::profile::{run_profile_suite, Cli, Mcp, Rest, Scenario, Way, BASIC};
    let scenario = Scenario::parse(BASIC)?;
    let scratch = Scratch::create(base, "prof").await?;
    let dir = std::env::temp_dir().join(format!("memhouse-profile-{}", std::process::id()));
    let ran = async {
        let mut cfg = (*base.cfg).clone();
        cfg.database.url = scratch.url.clone();
        cfg.memory.tenant = "default".into();
        cfg.server.api_keys = vec![KEY.into()];
        cfg.enrich.enabled = false;
        cfg.rerank.enabled = false;
        cfg.governance.audit_reads = false;
        let engine = memhouse_server::build_engine(cfg.clone(), false).await?;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}", listener.local_addr()?);
        // The command line reads the same configuration from a file of its own.
        std::fs::create_dir_all(&dir)?;
        let config = cfg.save(Some(&dir.join("config.toml")))?;
        let (rest, mcp) = (Rest::new(&url, KEY), Mcp::new(&url, KEY));
        let cli = Cli { bin: std::env::current_exe()?, config, env: vec![] };
        // Started after the last step that can fail, so no early return leaves it running.
        let server = tokio::spawn(memhouse_server::serve_listener(listener, engine));
        let ways: [&dyn Way; 3] = [&rest, &mcp, &cli];
        let report = run_profile_suite(&scenario, &ways).await;
        server.abort();
        anyhow::Ok(report)
    }
    .await;
    let _ = std::fs::remove_dir_all(&dir);
    scratch.drop().await?;
    let report = ran?;
    let passed = report.passed();
    Ok((passed, report.summary(), if passed { "the same outcomes through every way in".into() } else { report.failure_text().lines().take(8).collect::<Vec<_>>().join("; ") }))
}
