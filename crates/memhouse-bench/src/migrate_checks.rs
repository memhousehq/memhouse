// SPDX-License-Identifier: Apache-2.0
//! Governance checks for the migration between profiles (roadmap G17):
//!
//! - `migrate_round_trip`: a store filled with every kind of thing an installation holds is
//!   migrated there and back, and ends identical by record hashes (PROF-02, TR-MIG-01). On
//!   Postgres the trips are Lite → Standard → Lite and Standard → Lite → Standard; on SQLite,
//!   where there is no Postgres to go to, Lite → Lite → Lite;
//! - `migrate_erasure_and_audit`: nothing erased comes back (the deletion ledger moves, the
//!   erased text is nowhere in the target), and the audit chain verifies on the target;
//! - `migrate_no_credentials`: a database password appears in no message, in the plan, the
//!   report, the marker or the audit event;
//! - `migrate_failed_verification`: a migration that does not verify names the record and the
//!   field, and leaves the configuration file and the source exactly as they were.

use crate::governance::{check, Check, Scratch};
use crate::scratch::{open_store, Profile, Sql};
use memhouse_conformance::migration::{self as kit, Fingerprint, Seeded};
use memhouse_core::migrate::{Marker, VerificationFailed, AUDIT_ACTION};
use memhouse_core::types::{EmbeddingIdentity, ImportRow};
use memhouse_core::Engine;
use memhouse_server::migrate::{self, Request, Switch};

type Outcome = anyhow::Result<(bool, String, String)>;

pub(crate) async fn run(engine: &Engine) -> Vec<Check> {
    let trips = match Profile::of(engine) {
        Profile::Postgres => "Lite → Standard → Lite and Standard → Lite → Standard",
        Profile::Sqlite => "Lite → Lite → Lite (this run has no Postgres to migrate to)",
    };
    let round_trip = format!("A migration there and back ends identical by record hashes, with every table and the stored vectors: {trips}");
    let titles = [
        ("migrate_round_trip", "PROF-02 / TR-MIG-01 (G17)", round_trip.as_str()),
        (
            "migrate_erasure_and_audit",
            "TR-MIG-01 / TR-WF-03 (G17)",
            "After a migration nothing erased is back (the deletion ledger moved, the erased text is nowhere in the target) and the audit chain verifies on the target",
        ),
        ("migrate_no_credentials", "TR-MIG-01 / AP-10 (G17)", "A database password appears in no message, plan, report, marker or audit event of a migration"),
        (
            "migrate_failed_verification",
            "TR-MIG-01 (G17)",
            "A migration that does not verify names the record and the field, and leaves the configuration file and the source as they were; one that verifies switches the file over and keeps the old one",
        ),
    ];
    let results: Vec<Outcome> = vec![round_trip_check(engine).await, erasure_and_audit(engine).await, no_credentials(engine).await, failed_verification(engine).await];
    titles
        .iter()
        .zip(results)
        .map(|((id, req, title), r)| match r {
            Ok((passed, value, detail)) => check(id, req, title, passed, value, "all", detail),
            Err(e) => crate::governance::errored(id, req, title, "all", e),
        })
        .collect()
}

/// Scratch stores of one check, dropped together whatever the check returned.
struct Places(Vec<Scratch>);

impl Places {
    async fn add(&mut self, profile: Profile, engine: &Engine, suffix: &str) -> anyhow::Result<String> {
        let scratch = Scratch::create_as(profile, engine, suffix).await?;
        let url = scratch.url.clone();
        self.0.push(scratch);
        Ok(url)
    }

    /// Drop every scratch store, whatever the scenario returned, and give its outcome back. A
    /// store that could not be dropped is a problem of the check (a pass must not leave a
    /// database behind); when the scenario itself failed, its error stays the one reported,
    /// with the teardown's beside it.
    async fn drop_all<T>(self, ran: anyhow::Result<(Vec<String>, T)>) -> anyhow::Result<(Vec<String>, T)> {
        let mut left = vec![];
        for s in self.0 {
            let what = memhouse_store_postgres::redact_url(&s.url);
            if let Err(e) = s.drop().await {
                left.push(format!("the scratch store {what} was not removed: {e:#}"));
            }
        }
        match ran {
            Ok((mut problems, value)) => {
                problems.extend(left);
                Ok((problems, value))
            }
            Err(e) if left.is_empty() => Err(e),
            Err(e) => Err(anyhow::anyhow!("{e:#} (and afterwards: {})", left.join("; "))),
        }
    }
}

/// A profile by the name its users know it by.
fn name(p: Profile) -> &'static str {
    match p {
        Profile::Postgres => "Standard",
        Profile::Sqlite => "Lite",
    }
}

/// The profile a migration from the engine's own profile goes to: the other one where there is
/// one, else the same.
fn other(engine: &Engine) -> Profile {
    match Profile::of(engine) {
        Profile::Postgres => Profile::Sqlite,
        Profile::Sqlite => Profile::Sqlite,
    }
}

/// Fill the empty store at `url` with the kit's data; closed again on return.
async fn seed(url: &str) -> anyhow::Result<Seeded> {
    let store = open_store(url, 4, kit::PREFIX).await?;
    store.migrate(kit::DIM, kit::EMBEDDER).await?;
    kit::seed(store.as_ref()).await
}

async fn fingerprint(url: &str) -> anyhow::Result<Fingerprint> {
    let store = open_store(url, 2, kit::PREFIX).await?;
    kit::fingerprint(store.as_ref()).await
}

/// What a migration does not carry (the caches, the idempotency keys), as the source holds it:
/// a migration must leave that alone too. Compared only with the same store at another time.
async fn left_behind(url: &str) -> anyhow::Result<String> {
    let store = open_store(url, 2, kit::PREFIX).await?;
    let counts = store.migration_summary().await?.left_behind;
    let request = store.request_get(kit::TENANT, "req-77").await?;
    let extraction = store.llm_cache_get("cache-key-1").await?;
    let vectors = store.embed_cache_get(kit::EMBEDDER, &[memhouse_core::engine::content_hash("cached text")]).await?;
    Ok(format!("{counts:?} {request:?} {extraction:?} {vectors:?}"))
}

fn request(engine: &Engine, from: &str, to: &str, config: Option<std::path::PathBuf>) -> anyhow::Result<Request> {
    let mut cfg = (*engine.cfg).clone();
    cfg.memory.tenant = kit::TENANT.into();
    Ok(Request { from: migrate::endpoint(from)?, to: migrate::endpoint(to)?, cfg, config_path: config, progress: None })
}

async fn migrate_between(engine: &Engine, from: &str, to: &str) -> anyhow::Result<memhouse_core::migrate::Report> {
    Ok(migrate::run(&request(engine, from, to, None)?).await?.0)
}

async fn round_trip_check(engine: &Engine) -> Outcome {
    let mut places = Places(vec![]);
    let ran = async {
        let mut problems = vec![];
        let mut said = vec![];
        let home = Profile::of(engine);
        // There and back from Lite: on Postgres through Standard, else through another file.
        let through = if home == Profile::Postgres { Profile::Postgres } else { Profile::Sqlite };
        let (a, b, c) = (places.add(Profile::Sqlite, engine, "mig1a").await?, places.add(through, engine, "mig1b").await?, places.add(Profile::Sqlite, engine, "mig1c").await?);
        let seeded = seed(&a).await?;
        let start = fingerprint(&a).await?;
        migrate_between(engine, &a, &b).await?;
        let middle = fingerprint(&b).await?;
        migrate_between(engine, &b, &c).await?;
        let end = fingerprint(&c).await?;
        problems.extend(kit::differences(&start, &middle, 1).into_iter().map(|p| format!("Lite → {}: {p}", name(through))));
        problems.extend(kit::differences(&start, &end, 2).into_iter().map(|p| format!("Lite → {} → Lite: {p}", name(through))));
        if start.records != end.records || start.records.len() != seeded.records {
            problems.push(format!("Lite → {} → Lite is not identical by record hashes ({} records at the start, {} at the end)", name(through), start.records.len(), end.records.len()));
        }
        said.push(format!("Lite → {} → Lite: {} records identical by hash, {} table rows, vectors identical", name(through), end.records.len(), end.tables.values().map(Vec::len).sum::<usize>()));

        if home == Profile::Postgres {
            // The other way round. One record has a vector as Postgres holds them, at single
            // precision: it is rounded to half precision when it lands in the Lite store (the
            // report says so), and travels unchanged from there on.
            let (d, e, f) = (places.add(Profile::Postgres, engine, "mig1d").await?, places.add(Profile::Sqlite, engine, "mig1e").await?, places.add(Profile::Postgres, engine, "mig1f").await?);
            seed(&d).await?;
            let full: Vec<f32> = (0..kit::DIM).map(|i| 0.123_456_79 + i as f32 * 0.071_234_57).collect();
            let extra = {
                let store = open_store(&d, 2, kit::PREFIX).await?;
                store.migrate(kit::DIM, kit::EMBEDDER).await?;
                let mut record = store.export_records(kit::TENANT, None, None, 1).await?.remove(0);
                record.id = uuid::Uuid::now_v7();
                record.content = "A vector at single precision.".into();
                record.content_hash = memhouse_core::engine::content_hash(&record.content);
                (record.alt_hash, record.structured, record.code_refs) = (None, None, vec![]);
                let id = record.id;
                store.import_records(&[ImportRow { record, embedding: Some(full.clone()), alt: None }]).await?;
                id
            };
            let start = fingerprint(&d).await?;
            let there = migrate_between(engine, &d, &e).await?;
            let middle = fingerprint(&e).await?;
            let back = migrate_between(engine, &e, &f).await?;
            let end = fingerprint(&f).await?;
            // Standard → Lite: everything as it was, and that one vector exactly what half
            // precision makes of it (the nearest value, not a neighbour of it).
            let expected = memhouse_store_sqlite::vector::from_half(&memhouse_store_sqlite::vector::to_half(&full));
            let rounded = middle.vectors.get(&extra).and_then(|v| v.embedding.clone()).unwrap_or_default();
            let gap = expected.iter().zip(&full).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max);
            let mut as_lite_holds_it = start.clone();
            if let Some(v) = as_lite_holds_it.vectors.get_mut(&extra) {
                v.embedding = Some(expected.clone());
            }
            problems.extend(kit::differences(&as_lite_holds_it, &middle, 1).into_iter().map(|p| format!("Standard → Lite: {p}")));
            if rounded != expected || expected == full {
                problems.push("a single-precision vector did not land in the Lite store as its exact half-precision rounding".to_string());
            }
            if there.vector_max_gap <= 0.0 {
                problems.push("the migration's report did not say that vectors were rounded".into());
            }
            // Lite → Standard: exact, vectors included.
            problems.extend(kit::differences(&middle, &end, 1).into_iter().map(|p| format!("Standard → Lite → Standard, the way back: {p}")));
            if back.vector_max_gap != 0.0 {
                problems.push(format!("half-precision vectors changed on the way to Postgres (by {})", back.vector_max_gap));
            }
            if start.records != end.records {
                problems.push("Standard → Lite → Standard is not identical by record hashes".into());
            }
            said.push(format!(
                "Standard → Lite → Standard: {} records identical by hash; a single-precision vector was rounded to half precision once (largest change of a component {gap:.6}) and then unchanged",
                end.records.len()
            ));

            // Standard to another Standard database: the same code, both ends on Postgres.
            let i = places.add(Profile::Postgres, engine, "mig1i").await?;
            migrate_between(engine, &d, &i).await?;
            problems.extend(kit::differences(&start, &fingerprint(&i).await?, 1).into_iter().map(|p| format!("Standard → Standard: {p}")));
            said.push("Standard → Standard: identical, vectors at full precision included".into());

            // The one place where a record's export line can change: `jsonb` writes a float
            // with an integral value as an integer (1e16 as 10000000000000000). The value is the
            // same; the migration says so instead of failing, and anything else still fails.
            let (g, h) = (places.add(Profile::Sqlite, engine, "mig1g").await?, places.add(Profile::Postgres, engine, "mig1h").await?);
            {
                let store = open_store(&g, 2, kit::PREFIX).await?;
                store.migrate(kit::DIM, kit::EMBEDDER).await?;
                let mut record = open_store(&a, 2, kit::PREFIX).await?.export_records(kit::TENANT, None, None, 1).await?.remove(0);
                (record.alt_hash, record.structured, record.code_refs) = (None, None, vec![]);
                record.metadata = serde_json::json!({ "huge": 1e16, "tiny": 1e-7, "half": 2.5, "whole": 3.0 });
                store.import_records(&[ImportRow { record, embedding: None, alt: None }]).await?;
            }
            let respelled = migrate_between(engine, &g, &h).await?;
            if respelled.respelled != 1 || respelled.respelled_ids.len() != 1 {
                problems.push(format!("a float that jsonb writes as an integer: {} records reported as equal in value (expected 1)", respelled.respelled));
            }
            said.push("a JSON number Postgres spells differently (1e16) is reported as equal in value, not as a difference".into());
        }
        anyhow::Ok((problems, said))
    }
    .await;
    let (problems, said) = places.drop_all(ran).await?;
    let passed = problems.is_empty();
    Ok((passed, said.join("; "), if passed { "every trip ended where it started".into() } else { problems.into_iter().take(8).collect::<Vec<_>>().join("; ") }))
}

async fn erasure_and_audit(engine: &Engine) -> Outcome {
    let mut places = Places(vec![]);
    let ran = async {
        let mut problems = vec![];
        let (a, b) = (places.add(Profile::of(engine), engine, "mig2a").await?, places.add(other(engine), engine, "mig2b").await?);
        let seeded = seed(&a).await?;
        let before = fingerprint(&a).await?;
        migrate_between(engine, &a, &b).await?;
        let store = open_store(&b, 2, kit::PREFIX).await?;
        if store.get(kit::TENANT, seeded.deleted).await?.is_some() {
            problems.push("a deleted record is in the target".to_string());
        }
        let ledger = store.migration_dump("deletion_ledger", None, 100).await?;
        let scopes: Vec<&str> = ledger.iter().filter_map(|r| r["scope"].as_str()).collect();
        if scopes != ["memory", "subject"] || ledger[0]["memory_id"] != seeded.deleted.to_string() || ledger[1]["subject"] != seeded.erased_subject.as_str() {
            problems.push(format!("the deletion ledger did not move as it was: {ledger:?}"));
        }
        // The erased text, anywhere a record's text is kept.
        let db = places.0[1].db().await?;
        for word in &seeded.gone_words {
            let like = format!("%{word}%");
            let n =
                db.count(Sql::same("SELECT count(*) FROM mh_memory WHERE content LIKE $1 OR subject = $2"), &[like.as_str().into(), seeded.erased_subject.as_str().into()]).await?
                    + db.count(
                        Sql::each("SELECT count(*) FROM mh_intake WHERE payload::text LIKE $1", "SELECT count(*) FROM mh_intake WHERE payload LIKE ?1"),
                        &[like.as_str().into()],
                    )
                    .await?;
            if n > 0 {
                problems.push(format!("erased text ({word}) is in {n} rows of the target"));
            }
        }
        db.close().await;
        // The chain: the source's events with their hashes, then the migration's own.
        let (events, broken) = store.audit_verify().await?;
        if broken.is_some() || events != before.audit.0 + 1 {
            problems.push(format!("the audit chain on the target: {events} events, broken at {broken:?} (the source had {})", before.audit.0));
        }
        let last = store.migration_dump("audit", None, 1000).await?.pop().unwrap_or_default();
        if last["action"] != AUDIT_ACTION {
            problems.push(format!("the last audit event on the target is {}, not the migration's", last["action"]));
        }
        // An event written afterwards continues the chain.
        store.migrate(kit::DIM, kit::EMBEDDER).await?;
        store.audit("bench", "after.migration", kit::TENANT, None, None, serde_json::json!({})).await?;
        let (after, broken) = store.audit_verify().await?;
        if broken.is_some() || after != events + 1 {
            problems.push(format!("an event written after the migration does not continue the chain ({after} events, broken at {broken:?})"));
        }
        anyhow::Ok((problems, format!("{} ledger rows moved, {} erased texts absent, {events} audit events verify", ledger.len(), seeded.gone_words.len())))
    }
    .await;
    let (problems, value) = places.drop_all(ran).await?;
    let passed = problems.is_empty();
    Ok((passed, value, if passed { "nothing erased came back; the chain verifies".into() } else { problems.join("; ") }))
}

/// The passwords a database URL carries, in either form the endpoint accepts: before the host
/// (`scheme://user:password@host/…`) and as a parameter (`?password=…`).
fn passwords_of(url: &str) -> Vec<String> {
    let Some((_, rest)) = url.split_once("://") else { return vec![] };
    let authority = &rest[..rest.find(['/', '?', '#']).unwrap_or(rest.len())];
    let mut found: Vec<String> = authority.rsplit_once('@').and_then(|(userinfo, _)| userinfo.split_once(':')).map(|(_, p)| p.to_string()).into_iter().collect();
    let query = rest.split_once('?').map_or("", |(_, q)| q.split('#').next().unwrap_or(""));
    found.extend(query.split('&').filter_map(|p| p.split_once('=')).filter(|(k, _)| k.to_ascii_lowercase().contains("pass")).map(|(_, v)| v.to_string()));
    found.retain(|p| !p.is_empty());
    found
}

async fn no_credentials(engine: &Engine) -> Outcome {
    let mut places = Places(vec![]);
    let ran = async {
        let mut problems = vec![];
        let mut texts: Vec<(String, String)> = vec![];
        // A database that cannot be reached: the failure must not quote the URL's password.
        const MADE_UP: &str = "hunter2-Zq8-not-a-real-password";
        let unreachable = format!("postgres://someone:{MADE_UP}@127.0.0.1:9/nowhere?password={MADE_UP}y");
        // A secret in a parameter the driver does not know would be written to its log: refused
        // before the driver sees it, by name only.
        match migrate::endpoint(&format!("postgres://someone@127.0.0.1:9/nowhere?sslpassword={MADE_UP}x")) {
            Ok(_) => problems.push("a URL with a secret in a parameter the driver logs was accepted".to_string()),
            Err(e) => texts.push(("the refusal of a parameter the driver would log".into(), format!("{e:#} {e:?}"))),
        }
        let a = places.add(Profile::Sqlite, engine, "mig3a").await?;
        seed(&a).await?;
        let req = request(engine, &a, &unreachable, None)?;
        texts.push(("the endpoint's label".into(), format!("{} {:?}", req.to.label, req.to)));
        match migrate::plan(&req).await {
            Ok(_) => problems.push("a database that does not exist was planned for".to_string()),
            Err(e) => texts.push(("the error of an unreachable target".into(), format!("{e:#} {e:?}"))),
        }
        if let Err(e) = migrate::run(&request(engine, &unreachable, &a, None)?).await {
            texts.push(("the error of an unreachable source".into(), format!("{e:#} {e:?}")));
        }
        let mut secrets = vec![MADE_UP.to_string()];
        // A real migration into the profile under test (on Postgres its URL carries a password).
        let b = places.add(Profile::of(engine), engine, "mig3b").await?;
        secrets.extend(passwords_of(&b));
        let req = request(engine, &a, &b, None)?;
        let plan = migrate::plan(&req).await?;
        texts.push(("the plan".into(), migrate::describe_plan(&req, &plan)));
        texts.push(("the plan as data".into(), serde_json::to_string(&plan)?));
        let (report, switch) = migrate::run(&req).await?;
        texts.push(("the report".into(), migrate::describe_report(&req, &report, &switch)));
        texts.push(("the report as data".into(), serde_json::to_string(&report)?));
        // Closed again before this database becomes a source below.
        let (marker, events) = {
            let store = open_store(&b, 2, kit::PREFIX).await?;
            (store.migration_marker().await?.unwrap_or_default().to_string(), store.migration_dump("audit", None, 1000).await?)
        };
        texts.push(("the marker".into(), marker));
        let event = events.iter().find(|e| e["action"] == AUDIT_ACTION).ok_or_else(|| anyhow::anyhow!("the migration wrote no audit event"))?;
        texts.push(("the audit event".into(), event.to_string()));
        if !event["detail"].as_str().is_some_and(|d| d.contains(&req.from.label) && d.contains("\"records_differing\":0")) {
            // The field by name only: what a faulty event holds is not repeated here.
            problems.push("the audit event's `detail` does not name the source and the verification result".to_string());
        }
        // And one out of it again, so the password is the source's.
        let c = places.add(Profile::Sqlite, engine, "mig3c").await?;
        let req = request(engine, &b, &c, None)?;
        let plan = migrate::plan(&req).await?;
        texts.push(("the plan from it".into(), migrate::describe_plan(&req, &plan)));
        let (report, switch) = migrate::run(&req).await?;
        texts.push(("the report from it".into(), migrate::describe_report(&req, &report, &switch)));
        let store = open_store(&c, 2, kit::PREFIX).await?;
        texts.push(("the marker from it".into(), store.migration_marker().await?.unwrap_or_default().to_string()));
        texts.push(("the audit log from it".into(), serde_json::to_string(&store.migration_dump("audit", None, 1000).await?)?));
        for (what, text) in &texts {
            if secrets.iter().any(|s| text.contains(s.as_str())) {
                problems.push(format!("{what} holds a database password"));
            }
        }
        anyhow::Ok((problems, format!("{} texts searched for {} password(s)", texts.len(), secrets.len())))
    }
    .await;
    let (problems, value) = places.drop_all(ran).await?;
    let passed = problems.is_empty();
    Ok((passed, value, if passed { "no password in any of them".into() } else { problems.join("; ") }))
}

async fn failed_verification(engine: &Engine) -> Outcome {
    let mut places = Places(vec![]);
    let dir = std::env::temp_dir().join(format!("memhouse-gov-mig4-{}", uuid::Uuid::now_v7().simple()));
    let ran = async {
        let mut problems = vec![];
        let (a, b, c) =
            (places.add(Profile::of(engine), engine, "mig4a").await?, places.add(other(engine), engine, "mig4b").await?, places.add(other(engine), engine, "mig4c").await?);
        seed(&a).await?;
        let before = fingerprint(&a).await?;
        let kept_back = left_behind(&a).await?;
        // A configuration file that names the source.
        memhouse_store_sqlite::private_dir(&dir)?;
        let mut cfg = (*engine.cfg).clone();
        cfg.database.url = a.clone();
        cfg.memory.tenant = kit::TENANT.into();
        let config = cfg.save(Some(&dir.join("config.toml")))?;
        let original = std::fs::read(&config)?;

        // The target holds an unfinished run of this migration in which one record is not the source's.
        let from = migrate::endpoint(&a)?;
        let changed = {
            let source = open_store(&a, 2, kit::PREFIX).await?;
            let mut record = source.export_records(kit::TENANT, None, None, 5).await?.remove(2);
            let vectors = source.export_vectors(kit::TENANT, &[record.id]).await?.remove(0);
            record.content = format!("{} And something the source never said.", record.content);
            let id = record.id;
            let target = open_store(&b, 2, kit::PREFIX).await?;
            target.migrate(kit::DIM, kit::EMBEDDER).await?;
            let marker = Marker {
                source: from.label.clone(),
                identity: EmbeddingIdentity { embedder: kit::EMBEDDER.into(), dim: kit::DIM, passage_prefix: kit::PREFIX.into() },
                state: "copying".into(),
                started_at: chrono::Utc::now(),
                completed_at: None,
                verified: None,
            };
            target.set_migration_marker(&serde_json::to_value(&marker)?).await?;
            target.import_records(&[ImportRow { record, embedding: vectors.embedding, alt: None }]).await?;
            id
        };
        let named = match migrate::run(&request(engine, &a, &b, Some(config.clone()))?).await {
            Ok(_) => {
                problems.push("a migration with a changed record verified".to_string());
                false
            }
            Err(e) => match e.downcast_ref::<VerificationFailed>() {
                Some(v) => v.problems.iter().any(|p| p.contains(&changed.to_string()) && p.contains("content")),
                None => {
                    problems.push(format!("the migration failed for another reason: {e:#}"));
                    false
                }
            },
        };
        if !named {
            problems.push("the failure did not name the changed record and its field".to_string());
        }
        if std::fs::read(&config)? != original {
            problems.push("the configuration file changed although the migration did not verify".to_string());
        }
        let beside: Vec<String> = std::fs::read_dir(&dir)?.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n != "config.toml").collect();
        if !beside.is_empty() {
            problems.push(format!("files were written beside the configuration: {beside:?}"));
        }
        problems.extend(kit::differences(&before, &fingerprint(&a).await?, 0).into_iter().map(|p| format!("the source changed: {p}")));
        if left_behind(&a).await? != kept_back {
            problems.push("the source changed: its caches or idempotency keys are not what they were".to_string());
        }
        {
            let target = open_store(&b, 2, kit::PREFIX).await?;
            let marker: Marker = serde_json::from_value(target.migration_marker().await?.unwrap_or_default())?;
            let recorded = target.migration_dump("audit", None, 1000).await?.iter().any(|e| e["action"] == AUDIT_ACTION);
            if marker.state != "copying" || recorded {
                problems.push(format!("the target of a failed migration is marked {} (recorded as complete in its audit log: {recorded})", marker.state));
            }
        }

        // The same migration into an empty target verifies, and only then is the file switched.
        let to = migrate::endpoint(&c)?;
        let (_, switch) = migrate::run(&request(engine, &a, &c, Some(config.clone()))?).await?;
        let now = memhouse_core::Config::load_file(Some(&config))?;
        match &switch {
            Switch::Switched { backup, .. } => {
                if now.database.url != to.url {
                    problems.push("the configuration file does not name the target after a verified migration".to_string());
                }
                if std::fs::read(backup)? != original {
                    problems.push("the configuration as it was is not kept beside the new one".to_string());
                }
            }
            other => problems.push(format!("a verified migration did not switch the configuration over: {other:?}")),
        }
        problems.extend(kit::differences(&before, &fingerprint(&a).await?, 0).into_iter().map(|p| format!("the source changed in the migration that verified: {p}")));
        if left_behind(&a).await? != kept_back {
            problems.push("the source changed in the migration that verified: its caches or idempotency keys are not what they were".to_string());
        }
        anyhow::Ok((problems, format!("record {changed} named; configuration and source unchanged, then switched after a verified run")))
    }
    .await;
    let _ = std::fs::remove_dir_all(&dir);
    let (problems, value) = places.drop_all(ran).await?;
    let passed = problems.is_empty();
    Ok((passed, value, if passed { "the failure changed nothing; the success switched over".into() } else { problems.join("; ") }))
}
