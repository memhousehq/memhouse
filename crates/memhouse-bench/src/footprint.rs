// SPDX-License-Identifier: Apache-2.0
//! The Lite profile's footprint and latency (PROF-06, PROF-07), measured through the real
//! engine: the gate, the intake queue, audit, fusion. A stand-in embedder is used, so the
//! numbers are the engine's and the store's; a local model's memory and time are its own budget
//! (ADR 0002) and are measured by an ordinary benchmark run.

use crate::metrics;
use memhouse_core::config::Config;
use memhouse_core::types::*;
use memhouse_core::{Engine, Store};
use std::fmt::Write as _;
use std::sync::Arc;
use std::time::{Duration, Instant};

const DIM: usize = 384;

/// Deterministic pseudo-words: a vocabulary large enough that the full-text index looks like
/// one of real text (a few thousand distinct stems), not a handful of repeated words.
fn word(n: u64) -> String {
    const SYL: [&str; 24] =
        ["ka", "lo", "mi", "ren", "tu", "sa", "vel", "dor", "an", "pi", "qua", "zen", "bro", "fi", "gul", "hem", "jo", "nar", "os", "ple", "ry", "sto", "ul", "wex"];
    let (a, b, c) = (n % 24, (n / 24) % 24, (n / 576) % 8);
    format!("{}{}{}", SYL[a as usize], SYL[b as usize], SYL[c as usize])
}

pub(crate) fn sentence(seed: u64) -> String {
    let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    let mut next = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let words: Vec<String> = (0..14).map(|_| word(next() % 4608)).collect();
    format!("{} {seed}.", words.join(" "))
}

fn rss_kb() -> Option<u64> {
    let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &std::process::id().to_string()]).output().ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

/// Load `memories` records (`per_subject` in each subject) into a fresh SQLite file and measure.
/// Returns the report as Markdown.
pub async fn run(memories: usize, per_subject: usize, dir: &std::path::Path) -> anyhow::Result<String> {
    // Before anything is opened: with none per subject nothing would be loaded, and the report
    // would measure the probes alone.
    anyhow::ensure!(per_subject > 0, "the number of memories per subject must be at least 1");
    let path = dir.join("footprint.db");
    let mut cfg = Config::default();
    cfg.database.url = format!("sqlite:{}", path.display());
    cfg.memory.tenant = "bench".into();
    cfg.embedding.dim = DIM;
    cfg.governance.audit_reads = false;
    let embedder = Arc::new(memhouse_conformance::fakes::HashEmbedder::new(DIM));
    let store = Arc::new(memhouse_store_sqlite::SqliteStore::open(&path, "")?);
    store.migrate(DIM, &embedder.id).await?;
    let engine = Engine::new(store.clone(), embedder, None, cfg);
    let rss_empty = rss_kb();

    // Load, a session of 50 rounds at a time.
    let subjects = memories.div_ceil(per_subject).max(1);
    let t_load = Instant::now();
    let mut n = 0u64;
    for s in 0..subjects {
        let subject = format!("bench:footprint:{s}");
        let mut left = per_subject.min(memories - s * per_subject);
        let mut session = 0;
        while left > 0 {
            let take = left.min(50);
            let messages = (0..take)
                .map(|_| {
                    n += 1;
                    Message { role: "user".into(), content: sentence(n), timestamp: None, id: Some(format!("m{n}")) }
                })
                .collect();
            engine
                .ingest(IngestRequest {
                    subject: Some(subject.clone()),
                    session_id: Some(format!("s{session}")),
                    messages,
                    per_message: true,
                    actor: Some("bench".into()),
                    wait: true,
                    ..Default::default()
                })
                .await?;
            session += 1;
            left -= take;
        }
    }
    let load_secs = t_load.elapsed().as_secs_f64();
    // The first subject is the largest: the last one holds only what was left over.
    let last = "bench:footprint:0".to_string();

    // Write acknowledgement: the request returns once the write is durable in the queue. One
    // write at a time first (each is through the pipeline before the next is sent), then a
    // burst, where each acknowledgement competes with the pipeline work of the writes before it.
    let mut ack = vec![];
    for i in 0..200u64 {
        let t = Instant::now();
        engine
            .remember(RememberRequest { subject: Some(last.clone()), content: format!("ack {}", sentence(1_000_000_000 + i)), actor: Some("bench".into()), ..Default::default() })
            .await?;
        ack.push(t.elapsed().as_secs_f64() * 1000.0);
        engine.settle_subject(None, &last, Duration::from_secs(120)).await?;
    }
    let mut burst = vec![];
    for i in 0..200u64 {
        let t = Instant::now();
        engine
            .remember(RememberRequest { subject: Some(last.clone()), content: format!("burst {}", sentence(1_500_000_000 + i)), actor: Some("bench".into()), ..Default::default() })
            .await?;
        burst.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    engine.settle_subject(None, &last, Duration::from_secs(120)).await?;

    // Gated and recallable: from the request to the record being returned by a recall.
    let mut fresh = vec![];
    for i in 0..100u64 {
        let content = format!("fresh {}", sentence(2_000_000_000 + i));
        let t = Instant::now();
        let w = engine.remember(RememberRequest { subject: Some(last.clone()), content: content.clone(), actor: Some("bench".into()), wait: true, ..Default::default() }).await?;
        let r = engine.recall(RecallRequest { subject: Some(last.clone()), query: content, k: Some(5), actor: Some("bench".into()), ..Default::default() }).await?;
        anyhow::ensure!(r.hits.iter().any(|h| h.memory.id == w.id), "a record written with wait was not recalled at once");
        fresh.push(t.elapsed().as_secs_f64() * 1000.0);
    }

    // Recall over the largest subject.
    let (mut total, mut search) = (vec![], vec![]);
    for i in 0..300u64 {
        let q = sentence(3 + i * 7919 % n.max(1));
        let r = engine.recall(RecallRequest { subject: Some(last.clone()), query: q, k: Some(10), actor: Some("bench".into()), ..Default::default() }).await?;
        anyhow::ensure!(r.degraded.is_none(), "a recall was degraded: {:?}", r.degraded);
        total.push(r.took_ms);
        search.push(r.search_ms);
    }
    let rss_loaded = rss_kb();
    let stats = engine.store.stats("bench").await?;
    let file = |suffix: &str| std::fs::metadata(format!("{}{suffix}", path.display())).map(|m| m.len()).unwrap_or(0);
    let binary = std::env::current_exe().ok().and_then(|p| std::fs::metadata(p).ok()).map(|m| m.len()).unwrap_or(0);
    let (ack, burst, fresh, total, search) = (metrics::latency(&ack), metrics::latency(&burst), metrics::latency(&fresh), metrics::latency(&total), metrics::latency(&search));
    let mb = |b: u64| b as f64 / 1_048_576.0;
    let verdict = |ok: bool| if ok { "✅" } else { "❌" };

    let mut o = String::new();
    let _ = writeln!(o, "# Lite profile: footprint and latency\n");
    let _ = writeln!(
        o,
        "{} memories in {subjects} subject(s) of up to {per_subject}, one SQLite file, through the engine (gate, intake queue, audit, fusion). A stand-in embedder: a local model's memory and time are not in these numbers.\n",
        stats.committed
    );
    let _ = writeln!(o, "| Requirement | Target | Measured | |\n|---|---|---|---|");
    let _ = writeln!(o, "| PROF-06 binary, without models | ≤ 100 MB | {:.1} MB | {} |", mb(binary), verdict(mb(binary) <= 100.0));
    if let Some(kb) = rss_loaded {
        let _ = writeln!(
            o,
            "| PROF-06 resident memory with the store loaded | ≤ 256 MB | {:.0} MB ({:.0} MB before the load) | {} |",
            kb as f64 / 1024.0,
            rss_empty.unwrap_or(0) as f64 / 1024.0,
            verdict(kb as f64 / 1024.0 <= 256.0)
        );
    }
    let _ = writeln!(
        o,
        "| PROF-07 recall p95 | ≤ 50 ms | {:.1} ms (p50 {:.1}; the store's search alone p95 {:.1}) | {} |",
        total.p95_ms,
        total.p50_ms,
        search.p95_ms,
        verdict(total.p95_ms <= 50.0)
    );
    let _ = writeln!(
        o,
        "| PROF-07 write acknowledgement p95 | ≤ 20 ms | {:.1} ms (p50 {:.1}), one write at a time; {:.1} ms (p50 {:.1}) in a burst of 200 | {} |",
        ack.p95_ms,
        ack.p50_ms,
        burst.p95_ms,
        burst.p50_ms,
        verdict(ack.p95_ms <= 20.0)
    );
    let _ = writeln!(o, "| PROF-07 a gated memory is recallable | ≤ 2 s | {:.0} ms p95 (p50 {:.0}) | {} |", fresh.p95_ms, fresh.p50_ms, verdict(fresh.p95_ms <= 2000.0));
    let _ = writeln!(o, "\n| Other | |\n|---|---|");
    let _ = writeln!(o, "| Load | {:.0} s, {:.0} rounds per second, sessions of 50 rounds |", load_secs, n as f64 / load_secs.max(0.001));
    let _ = writeln!(
        o,
        "| Database file | {:.0} MB ({:.1} KB per memory), write-ahead log {:.0} MB |",
        mb(file("")),
        file("") as f64 / 1024.0 / stats.committed.max(1) as f64,
        mb(file("-wal"))
    );
    Ok(o)
}
