// SPDX-License-Identifier: Apache-2.0
//! Technology spike (roadmap G03, technical document 6.10): the Lite candidate against PROF-06 and
//! PROF-07 on laptop hardware, in one process with no external service (PROF-04 shape):
//! SQLite file + FTS5 + half-precision blobs + an in-process job queue and worker + the local
//! embedding model.
//!
//! - 100,000 memories in one store, 10,000 per subject (PROF-07 sizes)
//! - recall p95 ≤ 50 ms including local query embedding (no remote model calls)
//! - write acknowledgement p95 ≤ 20 ms after a durable write to the job queue (TR-LT-05)
//! - a written memory recallable within 2 s
//! - resident memory ≤ 256 MB with 100,000 memories (PROF-06)
//!
//! Run (needs the embedding model in the local cache, no network), each step a fresh process:
//! `cargo run --release -p memhouse-bench --features spike --example spike_lite_profile -- build`
//! `… -- run` (local embedding model) and `… -- run --no-model` (store only)

use half::f16;
use memhouse_core::{Config, EmbedKind};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MODEL: &str = "bge-small-en-v1.5-onnx-Q";
const SUBJECTS: usize = 10;
const PER_SUBJECT: usize = 10_000;

const NAMES: &[&str] = &["Ana", "Ben", "Chen", "Dara", "Eli", "Fatima", "Goran", "Hana", "Ivo", "Juno", "Kofi", "Lena"];
const THINGS: &[&str] = &[
    "invoice",
    "SSO certificate",
    "renewal",
    "dog",
    "flight",
    "dentist appointment",
    "API key rotation",
    "kitchen tiles",
    "piano lesson",
    "migration plan",
    "tax return",
    "garden",
];
const VERBS: &[&str] = &["moved", "was cancelled", "got approved", "failed", "was booked", "needs a follow-up", "was paid", "broke", "was rescheduled", "went well"];
const CITIES: &[&str] = &["Lisbon", "Osaka", "Quito", "Riga", "Hanoi", "Accra", "Hobart", "Tbilisi"];
const DAYS: &[&str] = &["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

fn sentence(rng: &mut StdRng) -> String {
    format!(
        "{} said the {} {} on {} in {}, ref {}",
        NAMES[rng.gen_range(0..NAMES.len())],
        THINGS[rng.gen_range(0..THINGS.len())],
        VERBS[rng.gen_range(0..VERBS.len())],
        DAYS[rng.gen_range(0..DAYS.len())],
        CITIES[rng.gen_range(0..CITIES.len())],
        rng.gen_range(1000..99999)
    )
}

fn question(rng: &mut StdRng) -> String {
    format!("what happened with the {} in {}?", THINGS[rng.gen_range(0..THINGS.len())], CITIES[rng.gen_range(0..CITIES.len())])
}

fn half_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| f16::from_f32(*x).to_le_bytes()).collect()
}

fn bits_blob(v: &[f32]) -> Vec<u8> {
    let mut b = vec![0u8; v.len().div_ceil(8)];
    for (i, x) in v.iter().enumerate() {
        if *x > 0.0 {
            b[i / 8] |= 1 << (i % 8);
        }
    }
    b
}

fn pct(xs: &mut [f64], p: f64) -> f64 {
    xs.sort_by(|a, b| a.total_cmp(b));
    xs[((xs.len() as f64 - 1.0) * p).round() as usize]
}

/// Peak resident set size of this process in MB (getrusage; bytes on macOS, KB on Linux).
fn rss_mb() -> f64 {
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) } != 0 {
        return f64::NAN;
    }
    let raw = u.ru_maxrss as f64;
    if cfg!(target_os = "macos") {
        raw / 1048576.0
    } else {
        raw / 1024.0
    }
}

fn open(path: &std::path::Path, durable: bool) -> anyhow::Result<rusqlite::Connection> {
    let db = rusqlite::Connection::open(path)?;
    db.execute_batch(if durable {
        // Power-loss durable on macOS: fsync the WAL with F_FULLFSYNC on every commit.
        "PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA busy_timeout = 5000;"
    } else {
        // Durable across a process crash (WAL, synchronous = NORMAL).
        "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;"
    })?;
    Ok(db)
}

/// Recall in one subject: vector full scan (half precision) + subject-scoped FTS5, fused by RRF.
fn recall(db: &rusqlite::Connection, subject: usize, q: &[f32], text: &str) -> anyhow::Result<(Vec<i64>, f64, f64)> {
    let t = Instant::now();
    let mut st = db.prepare_cached("SELECT rid, emb FROM memory WHERE subject = ?1")?;
    let mut scored: Vec<(f32, i64)> = st
        .query_map([subject as i64], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?)))?
        .map(|r| {
            let (rid, b) = r.unwrap();
            let (mut d, mut n) = (0f32, 0f32);
            for (i, c) in b.chunks_exact(2).enumerate() {
                let y = f16::from_le_bytes([c[0], c[1]]).to_f32();
                d += q[i] * y;
                n += y * y;
            }
            (d / n.sqrt(), rid)
        })
        .collect();
    scored.sort_by(|a, b| b.0.total_cmp(&a.0));
    let vec_ms = t.elapsed().as_secs_f64() * 1e3;
    let t = Instant::now();
    let words: Vec<String> = text.split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() > 2).map(|w| format!("\"{}\"", w.to_lowercase())).collect();
    let mut st = db.prepare_cached("SELECT rowid FROM memory_fts WHERE memory_fts MATCH ?1 ORDER BY bm25(memory_fts, 0.0, 1.0) LIMIT 100")?;
    let kw: Vec<i64> = st.query_map([format!("stok:s{subject} AND ({})", words.join(" OR "))], |r| r.get(0))?.collect::<Result<_, _>>()?;
    let fts_ms = t.elapsed().as_secs_f64() * 1e3;
    let mut fused: std::collections::HashMap<i64, f32> = Default::default();
    for (rank, (_, rid)) in scored.iter().take(100).enumerate() {
        *fused.entry(*rid).or_default() += 1.0 / (61.0 + rank as f32);
    }
    for (rank, rid) in kw.iter().enumerate() {
        *fused.entry(*rid).or_default() += 1.0 / (61.0 + rank as f32);
    }
    let mut top: Vec<(i64, f32)> = fused.into_iter().collect();
    top.sort_by(|a, b| b.1.total_cmp(&a.1));
    Ok((top.into_iter().take(10).map(|(r, _)| r).collect(), vec_ms, fts_ms))
}

fn vec_of_half(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(2).map(|c| f16::from_le_bytes([c[0], c[1]]).to_f32()).collect()
}

fn store_path() -> std::path::PathBuf {
    std::env::temp_dir().join("memhouse-spike-lite-profile").join("memhouse.db")
}

fn config() -> anyhow::Result<Config> {
    let mut cfg = Config::load(None)?;
    let (_, dim, _) = memhouse_models::local::resolve_embedding(MODEL)?;
    cfg.embedding.model = MODEL.into();
    cfg.embedding.dim = dim;
    cfg.embedding.batch_size = 64;
    cfg.embedding.max_length = 64;
    // Parallel model sessions (each holds a copy of the model); 0 = the default (half the cores, at most 4).
    cfg.embedding.sessions = std::env::var("SPIKE_SESSIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    Ok(cfg)
}

/// `build`: create the 100,000-memory store, plus pools of query and write vectors so the store-only
/// run needs no model. A separate process from `run`, so the build's memory doesn't count.
async fn build() -> anyhow::Result<()> {
    let embedder = memhouse_models::build_embedder(&config()?, false)?;
    let path = store_path();
    let _ = std::fs::remove_dir_all(path.parent().unwrap());
    std::fs::create_dir_all(path.parent().unwrap())?;
    let mut rng = StdRng::seed_from_u64(7);
    let db = open(&path, false)?;
    db.execute_batch(
        "CREATE TABLE memory (rid INTEGER PRIMARY KEY, subject INTEGER NOT NULL, stok TEXT NOT NULL, content TEXT NOT NULL, emb BLOB NOT NULL, bits BLOB NOT NULL, created_at REAL NOT NULL);
         CREATE INDEX memory_subject ON memory (subject);
         CREATE VIRTUAL TABLE memory_fts USING fts5(stok, content, content = 'memory', content_rowid = 'rid', tokenize = 'porter unicode61');
         CREATE TABLE job (id INTEGER PRIMARY KEY, subject INTEGER NOT NULL, content TEXT NOT NULL, emb BLOB, enqueued REAL NOT NULL);
         CREATE TABLE pool (kind TEXT NOT NULL, text TEXT NOT NULL, emb BLOB NOT NULL);",
    )?;
    let t_build = Instant::now();
    for s in 0..SUBJECTS {
        let texts: Vec<String> = (0..PER_SUBJECT).map(|_| sentence(&mut rng)).collect();
        let vecs = embedder.embed(&texts, EmbedKind::Passage).await?;
        let tx = db.unchecked_transaction()?;
        {
            let mut ins = tx.prepare("INSERT INTO memory (subject, stok, content, emb, bits, created_at) VALUES (?1, ?2, ?3, ?4, ?5, 0)")?;
            for (t, v) in texts.iter().zip(&vecs) {
                ins.execute(rusqlite::params![s as i64, format!("s{s}"), t, half_blob(v), bits_blob(v)])?;
            }
        }
        tx.commit()?;
    }
    for (kind, texts) in [("query", (0..300).map(|_| question(&mut rng)).collect::<Vec<_>>()), ("write", (0..400).map(|_| sentence(&mut rng)).collect())] {
        let ek = if kind == "query" { EmbedKind::Query } else { EmbedKind::Passage };
        let vecs = embedder.embed(&texts, ek).await?;
        for (t, v) in texts.iter().zip(&vecs) {
            db.execute("INSERT INTO pool (kind, text, emb) VALUES (?1, ?2, ?3)", rusqlite::params![kind, t, half_blob(v)])?;
        }
    }
    db.execute_batch("INSERT INTO memory_fts (memory_fts) VALUES ('rebuild'); PRAGMA wal_checkpoint(TRUNCATE);")?;
    let n: i64 = db.query_row("SELECT count(*) FROM memory", [], |r| r.get(0))?;
    eprintln!("built {n} memories in {:.0} s; {:.0} MB", t_build.elapsed().as_secs_f64(), std::fs::metadata(&path)?.len() as f64 / 1e6);
    Ok(())
}

/// `run [--no-model]`: open the store in a fresh process and measure PROF-06 / PROF-07. With
/// `--no-model`, vectors come from the pools, as when embeddings are computed by a remote endpoint.
async fn run(local_model: bool) -> anyhow::Result<()> {
    let path = store_path();
    anyhow::ensure!(path.exists(), "run `spike_lite_profile build` first");
    let rss_start = rss_mb();
    let embedder = if local_model { Some(memhouse_models::build_embedder(&config()?, false)?) } else { None };
    let rss_model = rss_mb();
    let mut rng = StdRng::seed_from_u64(11);
    let db = open(&path, false)?;
    let n: i64 = db.query_row("SELECT count(*) FROM memory", [], |r| r.get(0))?;
    let file_mb = std::fs::metadata(&path)?.len() as f64 / 1e6;
    let pool = |kind: &str| -> anyhow::Result<Vec<(String, Vec<f32>)>> {
        let mut st = db.prepare("SELECT text, emb FROM pool WHERE kind = ?1")?;
        let rows = st.query_map([kind], |r| Ok((r.get::<_, String>(0)?, vec_of_half(&r.get::<_, Vec<u8>>(1)?))))?;
        Ok(rows.collect::<Result<_, _>>()?)
    };
    let (queries, writes) = (pool("query")?, pool("write")?);

    // Recall, end to end.
    let (mut total, mut emb_ms, mut vec_ms, mut fts_ms) = (vec![], vec![], vec![], vec![]);
    for (i, (q, qv)) in queries.iter().enumerate() {
        let s = i % SUBJECTS;
        let t = Instant::now();
        let e = match &embedder {
            Some(m) => m.embed(std::slice::from_ref(q), EmbedKind::Query).await?.remove(0),
            None => qv.clone(),
        };
        emb_ms.push(t.elapsed().as_secs_f64() * 1e3);
        let (_, v, f) = recall(&db, s, &e, q)?;
        total.push(t.elapsed().as_secs_f64() * 1e3);
        vec_ms.push(v);
        fts_ms.push(f);
    }
    let rss_after_recall = rss_mb();

    // Write acknowledgement: one durable insert into the job queue per write.
    let ack = |durable: bool, rng: &mut StdRng| -> anyhow::Result<Vec<f64>> {
        let db = open(&path, durable)?;
        let mut st = db.prepare("INSERT INTO job (subject, content, enqueued) VALUES (?1, ?2, ?3)")?;
        let mut out = vec![];
        for _ in 0..500 {
            let s = rng.gen_range(0..SUBJECTS) as i64;
            let c = sentence(rng);
            let t = Instant::now();
            st.execute(rusqlite::params![s, c, 0.0])?;
            out.push(t.elapsed().as_secs_f64() * 1e3);
        }
        db.execute("DELETE FROM job", [])?;
        Ok(out)
    };
    let ack_normal = ack(false, &mut rng)?;
    let mut ack_full = ack(true, &mut rng)?;

    // Freshness: 20 writes per second for 15 s; one in-process worker embeds (or takes the pooled
    // vector), indexes and commits. Its own connection on its own thread (connections aren't Send).
    let stop = Arc::new(AtomicBool::new(false));
    let worker = {
        let path = path.clone();
        let stop = stop.clone();
        let embedder = embedder.clone();
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async move {
                let db = open(&path, false).unwrap();
                let mut lags = vec![];
                loop {
                    let job: Option<Job> = db
                        .query_row("SELECT id, subject, content, emb, enqueued FROM job ORDER BY id LIMIT 1", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
                        .ok();
                    match job {
                        Some((id, s, c, pooled, enq)) => {
                            let v = match (&embedder, pooled) {
                                (Some(m), _) => m.embed(std::slice::from_ref(&c), EmbedKind::Passage).await.unwrap().remove(0),
                                (None, Some(b)) => vec_of_half(&b),
                                (None, None) => unreachable!("store-only run enqueues vectors"),
                            };
                            let tx = db.unchecked_transaction().unwrap();
                            tx.execute(
                                "INSERT INTO memory (subject, stok, content, emb, bits, created_at) VALUES (?1, ?2, ?3, ?4, ?5, 0)",
                                rusqlite::params![s, format!("s{s}"), c, half_blob(&v), bits_blob(&v)],
                            )
                            .unwrap();
                            let rid = tx.last_insert_rowid();
                            tx.execute("INSERT INTO memory_fts (rowid, stok, content) VALUES (?1, ?2, ?3)", rusqlite::params![rid, format!("s{s}"), c]).unwrap();
                            tx.execute("DELETE FROM job WHERE id = ?1", [id]).unwrap();
                            tx.commit().unwrap();
                            lags.push(now_s() - enq);
                        }
                        None if stop.load(Ordering::Relaxed) => break,
                        None => tokio::time::sleep(Duration::from_millis(5)).await,
                    }
                }
                lags
            })
        })
    };
    {
        let db = open(&path, false)?;
        let mut st = db.prepare("INSERT INTO job (subject, content, emb, enqueued) VALUES (?1, ?2, ?3, ?4)")?;
        let t0 = Instant::now();
        let mut i = 0usize;
        while t0.elapsed() < Duration::from_secs(15) {
            let (text, v) = &writes[i % writes.len()];
            let pooled = if local_model { None } else { Some(half_blob(v)) };
            st.execute(rusqlite::params![(i % SUBJECTS) as i64, text, pooled, now_s()])?;
            i += 1;
            if let Some(wait) = Duration::from_millis(50 * i as u64).checked_sub(t0.elapsed()) {
                tokio::time::sleep(wait).await;
            }
        }
    }
    stop.store(true, Ordering::Relaxed);
    let mut lags: Vec<f64> = worker.join().expect("worker").into_iter().map(|s| s * 1e3).collect();
    // Undo the writes so repeated runs measure the same store.
    db.execute("DELETE FROM memory WHERE rid > ?1", [n])?;
    let rss_end = rss_mb();

    let sessions = std::env::var("SPIKE_SESSIONS").unwrap_or_else(|_| "default (up to 4)".into());
    let mode = if local_model {
        format!("with the local embedding model (bge-small-en-v1.5 quantised, 384 dims), model sessions: {sessions}")
    } else {
        "store only (vectors supplied, as from a remote embedding endpoint)".to_string()
    };
    println!("## Run {mode}\n");
    println!("{n} memories ({SUBJECTS} subjects × {PER_SUBJECT}) in one {file_mb:.0} MB SQLite file; a fresh process; {}\n", std::env::consts::ARCH);
    println!("| Target | Requirement | Measured | Met |\n|---|---|---|---|");
    let (rp50, rp95) = (pct(&mut total.clone(), 0.5), pct(&mut total, 0.95));
    println!(
        "| Recall p95, 10,000 memories per subject{} | ≤ 50 ms (PROF-07) | p50 {rp50:.1} ms, p95 {rp95:.1} ms (embedding p95 {:.1}, vector scan p95 {:.1}, FTS5 p95 {:.1}) | {} |",
        if local_model { ", local query embedding included" } else { "" },
        pct(&mut emb_ms, 0.95),
        pct(&mut vec_ms, 0.95),
        pct(&mut fts_ms, 0.95),
        if rp95 <= 50.0 { "yes" } else { "no" }
    );
    let (an95, af95) = (pct(&mut ack_normal.clone(), 0.95), pct(&mut ack_full.clone(), 0.95));
    println!(
        "| Write acknowledgement p95, durable insert into the job queue | ≤ 20 ms (PROF-07) | WAL + `synchronous = NORMAL` (crash-safe) p95 {an95:.2} ms; WAL + `synchronous = FULL` + `fullfsync` (power-loss safe) p50 {:.2} ms, p95 {af95:.2} ms | {} |",
        pct(&mut ack_full, 0.5),
        if an95 <= 20.0 && af95 <= 20.0 { "yes" } else { "no" }
    );
    let lp95 = pct(&mut lags.clone(), 0.95);
    println!(
        "| Written memory recallable (enqueue → indexed), 20 writes/s | ≤ 2 s (PROF-07) | p50 {:.0} ms, p95 {lp95:.0} ms over {} writes | {} |",
        pct(&mut lags, 0.5),
        lags.len(),
        if lp95 <= 2000.0 { "yes" } else { "no" }
    );
    println!(
        "| Peak resident memory of the process | ≤ 256 MB (PROF-06) | {rss_end:.0} MB (at start {rss_start:.0} MB; after {} {rss_model:.0} MB; after the recall run {rss_after_recall:.0} MB) | {} |",
        if local_model { "loading the model" } else { "start-up" },
        if rss_end.is_finite() && rss_end > 0.0 && rss_end <= 256.0 { "yes" } else { "no" }
    );
    println!();
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("build") => build().await,
        Some("run") => run(!args.iter().any(|a| a == "--no-model")).await,
        _ => anyhow::bail!("usage: spike_lite_profile build | run [--no-model]"),
    }
}

/// (id, subject, content, pooled vector, enqueued at)
type Job = (i64, i64, String, Option<Vec<u8>>, f64);

fn now_s() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64()
}
