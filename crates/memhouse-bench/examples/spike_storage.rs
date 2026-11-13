// SPDX-License-Identifier: Apache-2.0
//! Technology spike (roadmap G03, technical document 6.10): vector storage format and the Lite
//! embedded store, measured on real LongMemEval_S rounds.
//!
//! 1. Postgres: `vector` (f32) vs `halfvec` vs `bit` prefilter + `halfvec` rescoring, against the
//!    brute-force f32 top 10 (exactness, latency, bytes per vector).
//! 2. SQLite + FTS5 with in-process scoring (half-precision blobs, binary prefilter), against the
//!    same ground truth; FTS5 keyword recall vs Postgres BM25; latency; file size.
//! 3. Scale: one subject grown to 10,000 memories (PROF-07) for the in-process scorer.
//!
//! Prepare: `memhouse bench run --dataset longmemeval-s --stride 10 --keep --embedding-model bge-small-en-v1.5-onnx-Q`
//! Run:     `cargo run --release -p memhouse-bench --example spike_storage -- <run-id>`
//! Results go to stdout as a markdown report (kept in docs/adr/evidence/).

use half::f16;
use memhouse_bench::datasets;
use memhouse_core::types::*;
use memhouse_core::{Config, EmbedKind};
use sqlx::Row;
use std::collections::{HashMap, HashSet};
use std::time::Instant;

const K: usize = 10;
const MODEL: &str = "bge-small-en-v1.5-onnx-Q";

struct Round {
    id: String,
    session: String,
    content: String,
    emb: Vec<f32>,
    alt: Option<Vec<f32>>,
}

fn parse_vec(s: &str) -> Vec<f32> {
    s.trim_matches(|c| c == '[' || c == ']').split(',').map(|x| x.parse().unwrap()).collect()
}

fn cos(a: &[f32], b: &[f32]) -> f32 {
    let (mut d, mut na, mut nb) = (0f32, 0f32, 0f32);
    for (x, y) in a.iter().zip(b) {
        d += x * y;
        na += x * x;
        nb += y * y;
    }
    d / (na.sqrt() * nb.sqrt())
}

fn cos16(q: &[f32], b: &[f16]) -> f32 {
    let (mut d, mut nb) = (0f32, 0f32);
    for (x, y) in q.iter().zip(b) {
        let y = y.to_f32();
        d += x * y;
        nb += y * y;
    }
    d / nb.sqrt() // q is normalised by the caller
}

fn bits(v: &[f32]) -> Vec<u64> {
    let mut out = vec![0u64; v.len().div_ceil(64)];
    for (i, x) in v.iter().enumerate() {
        if *x > 0.0 {
            out[i / 64] |= 1 << (i % 64);
        }
    }
    out
}

fn hamming(a: &[u64], b: &[u64]) -> u32 {
    a.iter().zip(b).map(|(x, y)| (x ^ y).count_ones()).sum()
}

fn to_half_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| f16::from_f32(*x).to_le_bytes()).collect()
}

fn from_half_blob(b: &[u8]) -> Vec<f16> {
    b.chunks_exact(2).map(|c| f16::from_le_bytes([c[0], c[1]])).collect()
}

fn to_bits_blob(v: &[f32]) -> Vec<u8> {
    bits(v).iter().flat_map(|w| w.to_le_bytes()).collect()
}

fn from_bits_blob(b: &[u8]) -> Vec<u64> {
    b.chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect()
}

fn normalise(v: &[f32]) -> Vec<f32> {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    v.iter().map(|x| x / n).collect()
}

/// Ground truth: brute force, best of the round vector and the user-text vector (as Postgres does).
fn exact_top(q: &[f32], rounds: &[Round]) -> Vec<String> {
    let mut s: Vec<(f32, &str)> = rounds.iter().map(|r| (cos(q, &r.emb).max(r.alt.as_ref().map(|a| cos(q, a)).unwrap_or(-1.0)), r.id.as_str())).collect();
    s.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(b.1)));
    s.into_iter().take(K).map(|(_, id)| id.to_string()).collect()
}

fn overlap(a: &[String], b: &[String]) -> f64 {
    let sa: HashSet<_> = a.iter().collect();
    b.iter().filter(|x| sa.contains(x)).count() as f64 / a.len().max(1) as f64
}

fn pct(xs: &mut [f64], p: f64) -> f64 {
    if xs.is_empty() {
        return 0.0;
    }
    xs.sort_by(|a, b| a.total_cmp(b));
    xs[((xs.len() as f64 - 1.0) * p).round() as usize]
}

#[derive(Default)]
struct Stat {
    overlap: Vec<f64>,
    ms: Vec<f64>,
    same_order: usize,
    n: usize,
}

impl Stat {
    fn add(&mut self, truth: &[String], got: &[String], ms: f64) {
        self.overlap.push(overlap(truth, got));
        self.ms.push(ms);
        self.same_order += (truth == got) as usize;
        self.n += 1;
    }
    fn row(&mut self, name: &str) -> String {
        let mean = self.overlap.iter().sum::<f64>() / self.n.max(1) as f64;
        let min = self.overlap.iter().cloned().fold(1.0, f64::min);
        format!("| {name} | {:.4} | {:.2} | {}/{} | {:.2} | {:.2} |", mean, min, self.same_order, self.n, pct(&mut self.ms, 0.5), pct(&mut self.ms, 0.95))
    }
}

/// FTS5 query: every word ORed, each quoted so punctuation can't form syntax.
fn fts_query(text: &str) -> String {
    let words: Vec<String> = text.split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() > 1).map(|w| format!("\"{}\"", w.to_lowercase())).collect();
    words.join(" OR ")
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let run_id = std::env::args().nth(1).expect("usage: spike_storage <run-id of a --keep run>");
    let prefix = format!("bench:{run_id}:");
    let mut cfg = Config::load(None)?;
    let (_, dim, _) = memhouse_models::local::resolve_embedding(MODEL)?;
    cfg.embedding.model = MODEL.into();
    cfg.embedding.dim = dim;
    let embedder = memhouse_models::build_embedder(&cfg, false)?;
    let base = cfg.database.url.rsplit_once('/').unwrap().0.to_string();
    let pg = sqlx::postgres::PgPoolOptions::new().max_connections(4).connect(&format!("{base}/memhouse_bench_local_bge_small_en_v1_5_onnx_q")).await?;
    let pgv: String = sqlx::query_scalar("SELECT extversion FROM pg_extension WHERE extname = 'vector'").fetch_one(&pg).await?;

    // Questions of the kept run.
    let path = datasets::path_for("longmemeval-s")?;
    let sel = datasets::Selection { limit: None, stride: 10, offset: 0, types: None, abstention_only: false };
    let mut items = vec![];
    datasets::stream("longmemeval-s", &path, &sel, |it| {
        items.push(it);
        Ok(())
    })?;

    // Rounds and vectors per subject, from Postgres.
    let mut data: Vec<(String, Vec<Round>, Vec<datasets::Question>)> = vec![];
    for it in &items {
        let subject = format!("{prefix}{}", it.conv_id);
        let rows = sqlx::query("SELECT id::text, coalesce(session_id, ''), content, embedding::text, embedding_alt::text FROM mh_memory WHERE tenant = 'bench' AND subject = $1 AND status = 'committed' AND embedding IS NOT NULL")
            .bind(&subject)
            .fetch_all(&pg)
            .await?;
        let rounds: Vec<Round> = rows
            .iter()
            .map(|r| Round {
                id: r.get(0),
                session: r.get(1),
                content: r.get(2),
                emb: parse_vec(&r.get::<String, _>(3)),
                alt: r.get::<Option<String>, _>(4).map(|s| parse_vec(&s)),
            })
            .collect();
        if !rounds.is_empty() {
            data.push((subject, rounds, it.questions.clone()));
        }
    }
    let n_rounds: usize = data.iter().map(|d| d.1.len()).sum();
    anyhow::ensure!(n_rounds > 0, "no rows for {prefix}: run the --keep benchmark first");

    // Query embeddings.
    let mut queries: Vec<(usize, datasets::Question, Vec<f32>)> = vec![];
    for (i, (_, _, qs)) in data.iter().enumerate() {
        for q in qs.iter().filter(|q| !q.abstention) {
            let e = embedder.embed(std::slice::from_ref(&q.question), EmbedKind::Query).await?.remove(0);
            queries.push((i, q.clone(), normalise(&e)));
        }
    }

    // ---- 1. Postgres formats ----
    sqlx::raw_sql(
        "DROP TABLE IF EXISTS spike_vec; CREATE TABLE spike_vec AS SELECT id, subject, embedding AS f32, embedding::halfvec(384) AS h, binary_quantize(embedding)::bit(384) AS b, \
         embedding_alt AS f32a, embedding_alt::halfvec(384) AS ha, binary_quantize(embedding_alt)::bit(384) AS ba FROM mh_memory WHERE tenant = 'bench' AND status = 'committed' AND embedding IS NOT NULL; \
         CREATE INDEX ON spike_vec (subject); ANALYZE spike_vec;",
    )
    .execute(&pg)
    .await?;
    let sizes = sqlx::query("SELECT avg(pg_column_size(f32))::float8, avg(pg_column_size(h))::float8, avg(pg_column_size(b))::float8 FROM spike_vec WHERE subject LIKE $1")
        .bind(format!("{prefix}%"))
        .fetch_one(&pg)
        .await?;
    let (sz32, sz16, szb): (f64, f64, f64) = (sizes.get(0), sizes.get(1), sizes.get(2));
    let pg_sql = [
        ("Postgres `vector` f32, exact scan", "SELECT id::text FROM spike_vec WHERE subject = $1 ORDER BY least(f32 <=> $2::vector, coalesce(f32a <=> $2::vector, 2)), id LIMIT 10"),
        ("Postgres `halfvec`, exact scan", "SELECT id::text FROM spike_vec WHERE subject = $1 ORDER BY least(h <=> $2::halfvec, coalesce(ha <=> $2::halfvec, 2)), id LIMIT 10"),
        (
            "Postgres `bit` top 100 → `halfvec` rescoring",
            "SELECT id::text FROM (SELECT id, h, ha FROM spike_vec WHERE subject = $1 ORDER BY least(b <~> binary_quantize($2::vector), coalesce(ba <~> binary_quantize($2::vector), 384)) LIMIT 100) c \
             ORDER BY least(h <=> $2::halfvec, coalesce(ha <=> $2::halfvec, 2)), id LIMIT 10",
        ),
    ];
    let mut pg_stats: Vec<Stat> = pg_sql.iter().map(|_| Stat::default()).collect();
    for (i, _, q) in &queries {
        let (subject, rounds, _) = &data[*i];
        let truth = exact_top(q, rounds);
        let lit = format!("[{}]", q.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","));
        for (j, (_, sql)) in pg_sql.iter().enumerate() {
            let t = Instant::now();
            let got: Vec<String> = sqlx::query_scalar(sqlx::AssertSqlSafe(sql.to_string())).bind(subject).bind(&lit).fetch_all(&pg).await?;
            pg_stats[j].add(&truth, &got, t.elapsed().as_secs_f64() * 1e3);
        }
    }

    // ---- 2. SQLite + FTS5, in-process scoring ----
    // A directory checked to be this user's own and closed to others, emptied of any left-over
    // database files first.
    let dir = memhouse_core::config::home_dir().join("spike");
    private_dir(&dir)?;
    let file = dir.join("memhouse-spike-lite.db");
    for stale in ["", "-wal", "-shm"] {
        let path = dir.join(format!("memhouse-spike-lite.db{stale}"));
        // Whatever is at the path goes, a dangling symlink included (`exists` follows links
        // and would miss one, and SQLite would then create the database at its target).
        if std::fs::symlink_metadata(&path).is_ok() {
            std::fs::remove_file(&path)?;
        }
    }
    let mut db = rusqlite::Connection::open(&file)?;
    db.execute_batch(
        "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;
         CREATE TABLE memory (rid INTEGER PRIMARY KEY, id TEXT NOT NULL, subject TEXT NOT NULL, session TEXT, content TEXT NOT NULL,
                              emb_half BLOB, alt_half BLOB, emb_bits BLOB, alt_bits BLOB);
         CREATE INDEX memory_subject ON memory (subject);
         CREATE VIRTUAL TABLE memory_fts USING fts5(content, content = 'memory', content_rowid = 'rid', tokenize = 'porter unicode61');
         CREATE VIRTUAL TABLE memory_fts2 USING fts5(stok, content, tokenize = 'porter unicode61');",
    )?;
    let t_load = Instant::now();
    {
        let tx = db.transaction()?;
        {
            let mut ins = tx.prepare("INSERT INTO memory (id, subject, session, content, emb_half, alt_half, emb_bits, alt_bits) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)")?;
            for (subject, rounds, _) in &data {
                for r in rounds {
                    ins.execute(rusqlite::params![
                        r.id,
                        subject,
                        r.session,
                        r.content,
                        to_half_blob(&r.emb),
                        r.alt.as_ref().map(|a| to_half_blob(a)),
                        to_bits_blob(&r.emb),
                        r.alt.as_ref().map(|a| to_bits_blob(a))
                    ])?;
                }
            }
        }
        tx.execute("INSERT INTO memory_fts (memory_fts) VALUES ('rebuild')", [])?;
        // Variant: the subject as one indexed token, so MATCH itself is scoped to the subject.
        tx.execute("INSERT INTO memory_fts2 (rowid, stok, content) SELECT rid, 's' || substr(hex(subject), -24), content FROM memory", [])?;
        tx.commit()?;
    }
    let load_ms = t_load.elapsed().as_secs_f64() * 1e3;
    db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")?;
    let file_bytes = std::fs::metadata(&file)?.len();

    struct Blob {
        id: String,
        h: Vec<f16>,
        ha: Option<Vec<f16>>,
        b: Vec<u64>,
        ba: Option<Vec<u64>>,
    }
    let load_subject = |db: &rusqlite::Connection, subject: &str| -> anyhow::Result<Vec<Blob>> {
        let mut st = db.prepare_cached("SELECT id, emb_half, alt_half, emb_bits, alt_bits FROM memory WHERE subject = ?1")?;
        let rows = st.query_map([subject], |r| {
            Ok(Blob {
                id: r.get(0)?,
                h: from_half_blob(&r.get::<_, Vec<u8>>(1)?),
                ha: r.get::<_, Option<Vec<u8>>>(2)?.map(|b| from_half_blob(&b)),
                b: from_bits_blob(&r.get::<_, Vec<u8>>(3)?),
                ba: r.get::<_, Option<Vec<u8>>>(4)?.map(|b| from_bits_blob(&b)),
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    };
    let score16 = |q: &[f32], b: &Blob| cos16(q, &b.h).max(b.ha.as_ref().map(|a| cos16(q, a)).unwrap_or(-1.0));
    let full16 = |q: &[f32], blobs: &[Blob]| -> Vec<String> {
        let mut s: Vec<(f32, &str)> = blobs.iter().map(|b| (score16(q, b), b.id.as_str())).collect();
        s.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(b.1)));
        s.into_iter().take(K).map(|(_, id)| id.to_string()).collect()
    };
    let prefilter = |q: &[f32], blobs: &[Blob], m: usize| -> Vec<String> {
        let qb = bits(q);
        let mut c: Vec<(u32, usize)> = blobs.iter().enumerate().map(|(i, b)| (hamming(&qb, &b.b).min(b.ba.as_ref().map(|a| hamming(&qb, a)).unwrap_or(u32::MAX)), i)).collect();
        c.sort_unstable();
        let mut s: Vec<(f32, &str)> = c.iter().take(m).map(|(_, i)| (score16(q, &blobs[*i]), blobs[*i].id.as_str())).collect();
        s.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(b.1)));
        s.into_iter().take(K).map(|(_, id)| id.to_string()).collect()
    };
    let (mut lite_full, mut lite_pre) = (Stat::default(), Stat::default());
    // Keyword: FTS5 vs Postgres BM25, scored against the gold evidence sessions.
    let (mut fts_ms, mut fts_hit, mut pg_kw_hit, mut kw_overlap, mut n_gold) = (vec![], 0usize, 0usize, vec![], 0usize);
    let (mut fts2_ms, mut fts2_same) = (vec![], 0usize);
    let store = memhouse_store_postgres::PgStore::connect(&format!("{base}/memhouse_bench_local_bge_small_en_v1_5_onnx_q"), 4, "").await?;
    use memhouse_core::Store;
    for (i, qd, q) in &queries {
        let (subject, rounds, _) = &data[*i];
        let truth = exact_top(q, rounds);
        let t = Instant::now();
        let blobs = load_subject(&db, subject)?;
        let got = full16(q, &blobs);
        lite_full.add(&truth, &got, t.elapsed().as_secs_f64() * 1e3);
        let t = Instant::now();
        let blobs = load_subject(&db, subject)?;
        let got = prefilter(q, &blobs, 100);
        lite_pre.add(&truth, &got, t.elapsed().as_secs_f64() * 1e3);

        let t = Instant::now();
        let mut st = db.prepare_cached(
            "SELECT m.id, m.session FROM memory_fts f JOIN memory m ON m.rid = f.rowid WHERE memory_fts MATCH ?1 AND m.subject = ?2 ORDER BY bm25(memory_fts) LIMIT 10",
        )?;
        let fts: Vec<(String, String)> = st.query_map(rusqlite::params![fts_query(&qd.question), subject], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
        fts_ms.push(t.elapsed().as_secs_f64() * 1e3);
        let tok: String = db.query_row("SELECT 's' || substr(hex(?1), -24)", [subject], |r| r.get(0))?;
        let t = Instant::now();
        let mut st2 =
            db.prepare_cached("SELECT m.id FROM memory_fts2 f JOIN memory m ON m.rid = f.rowid WHERE memory_fts2 MATCH ?1 ORDER BY bm25(memory_fts2, 0.0, 1.0) LIMIT 10")?;
        let fts2: Vec<String> = st2.query_map([format!("stok:\"{tok}\" AND ({})", fts_query(&qd.question))], |r| r.get(0))?.collect::<Result<_, _>>()?;
        fts2_ms.push(t.elapsed().as_secs_f64() * 1e3);
        let sq = SearchQuery {
            tenant: "bench".into(),
            subject: subject.clone(),
            text: qd.question.clone(),
            embedding: None,
            kinds: None,
            tags: None,
            denied_labels: vec![],
            as_of: None,
            valid_at: chrono::Utc::now(),
            mode: RetrievalMode::Keyword,
            per_retriever: 100,
            limit: K,
            rrf_k: 60.0,
            keyword_weight: 1.0,
            vector_weight: 1.0,
            windows: vec![],
            scope: Default::default(),
            include_candidates: false,
            shared_agents: vec![],
            with_vectors: false,
        };
        let pgk = store.search(&sq).await?;
        let session_of: HashMap<&str, &str> = rounds.iter().map(|r| (r.id.as_str(), r.session.as_str())).collect();
        let gold: HashSet<&str> = qd.evidence_sessions.iter().map(String::as_str).collect();
        if !gold.is_empty() {
            n_gold += 1;
            fts_hit += fts.iter().any(|(_, s)| gold.contains(s.as_str())) as usize;
            pg_kw_hit += pgk.iter().any(|h| session_of.get(h.memory.id.to_string().as_str()).map(|s| gold.contains(s)).unwrap_or(false)) as usize;
        }
        let a: Vec<String> = pgk.iter().map(|h| h.memory.id.to_string()).collect();
        let b: Vec<String> = fts.iter().map(|(id, _)| id.clone()).collect();
        kw_overlap.push(overlap(&a, &b));
        fts2_same += (overlap(&b, &fts2) >= 0.9) as usize;
    }

    // ---- 3. Scale: one subject grown to 10,000 memories ----
    let (_, big_rounds, _) = data.iter().max_by_key(|d| d.1.len()).unwrap();
    let mut rng_state = 42u64;
    let mut noise = || {
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        (rng_state % 2000) as f32 / 1e5 - 0.01
    };
    let mut big: Vec<Blob> = vec![];
    let mut big32: Vec<Round> = vec![];
    for i in 0..10_000 {
        let r = &big_rounds[i % big_rounds.len()];
        let e: Vec<f32> = r.emb.iter().map(|x| x + noise()).collect();
        let a: Option<Vec<f32>> = r.alt.as_ref().map(|a| a.iter().map(|x| x + noise()).collect());
        big32.push(Round { id: format!("{i}"), session: String::new(), content: String::new(), emb: e.clone(), alt: a.clone() });
        big.push(Blob {
            id: format!("{i}"),
            h: e.iter().map(|x| f16::from_f32(*x)).collect(),
            ha: a.as_ref().map(|a| a.iter().map(|x| f16::from_f32(*x)).collect()),
            b: bits(&e),
            ba: a.as_ref().map(|a| bits(a)),
        });
    }
    let (mut big_full, mut big_pre, mut big_agree) = (vec![], vec![], 0usize);
    let depths = [1000usize, 2000, 4000];
    let mut depth_same = [0usize; 3];
    let mut depth_ms: [Vec<f64>; 3] = [vec![], vec![], vec![]];
    let (mut f16_same_f32, mut f16_overlap) = (0usize, vec![]);
    let n_big = queries.len().min(50);
    for (_, _, q) in queries.iter().take(n_big) {
        let truth = exact_top(q, &big32);
        let t = Instant::now();
        let a = full16(q, &big);
        big_full.push(t.elapsed().as_secs_f64() * 1e3);
        f16_same_f32 += (a == truth) as usize;
        f16_overlap.push(overlap(&truth, &a));
        let t = Instant::now();
        let b = prefilter(q, &big, 1000);
        big_pre.push(t.elapsed().as_secs_f64() * 1e3);
        big_agree += (b == truth) as usize;
        for (j, d) in depths.iter().enumerate() {
            let t = Instant::now();
            let c = prefilter(q, &big, *d);
            depth_ms[j].push(t.elapsed().as_secs_f64() * 1e3);
            depth_same[j] += (c == truth) as usize;
        }
    }
    let rss_kb: u64 = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
        .unwrap_or(0);

    // ---- Report ----
    println!("# Storage spike results\n");
    println!(
        "Run `{run_id}` · {} subjects · {} rounds · {} questions with vectors · pgvector {pgv} · {} · bge-small-en-v1.5 (384 dims)\n",
        data.len(),
        n_rounds,
        queries.len(),
        std::env::consts::ARCH
    );
    println!("Exactness is the overlap of each method's top 10 with the brute-force f32 top 10 (best of round and user-text vector), averaged over questions.\n");
    println!("| Method | top-10 overlap (mean) | worst question | identical order | p50 ms | p95 ms |\n|---|---|---|---|---|---|");
    for (j, (name, _)) in pg_sql.iter().enumerate() {
        println!("{}", pg_stats[j].row(name));
    }
    println!("{}", lite_full.row("SQLite blobs, half precision, full scan (in-process)"));
    println!("{}", lite_pre.row("SQLite blobs, binary top 100 → half-precision rescoring (in-process)"));
    println!("\n**Bytes per vector in Postgres:** vector {sz32:.0}, halfvec {sz16:.0}, bit {szb:.0}.\n");
    let mut fm = fts_ms.clone();
    let mut fm2 = fts2_ms.clone();
    println!("**Keyword, subject-scoped FTS5 (subject as an indexed token in the MATCH):** p50 {:.2} ms, p95 {:.2} ms; same top 10 as the join variant (≥ 90% overlap) for {fts2_same}/{} questions.\n", pct(&mut fm2, 0.5), pct(&mut fm2, 0.95), fts2_ms.len());
    println!("**Keyword:** gold session in the top 10 for {pg_kw_hit}/{n_gold} questions with Postgres BM25 and {fts_hit}/{n_gold} with SQLite FTS5 (porter); mean overlap of the two top-10 lists {:.2}; FTS5 p50 {:.2} ms, p95 {:.2} ms.\n",
        kw_overlap.iter().sum::<f64>() / kw_overlap.len().max(1) as f64, pct(&mut fm, 0.5), pct(&mut fm, 0.95));
    println!(
        "**SQLite file:** {:.1} MB for {n_rounds} rounds ({:.0} bytes per round including text, FTS index and both vectors); load {load_ms:.0} ms.\n",
        file_bytes as f64 / 1e6,
        file_bytes as f64 / n_rounds as f64
    );
    println!(
        "**Scale (PROF-07), one subject of 10,000 memories, in-process, against the f32 brute-force top 10:** full half-precision scan p50 {:.1} ms, p95 {:.1} ms, identical top 10 in {f16_same_f32}/{n_big} queries (mean overlap {:.4}); binary top 1,000 → rescoring p50 {:.1} ms, p95 {:.1} ms, identical in {big_agree}/{n_big}.\n",
        pct(&mut big_full.clone(), 0.5),
        pct(&mut big_full, 0.95),
        f16_overlap.iter().sum::<f64>() / f16_overlap.len().max(1) as f64,
        pct(&mut big_pre.clone(), 0.5),
        pct(&mut big_pre, 0.95)
    );
    println!("| Binary prefilter depth (10,000 memories) | identical top 10 vs f32 | p50 ms | p95 ms |\n|---|---|---|---|");
    for (j, d) in depths.iter().enumerate() {
        println!("| {d} | {}/{n_big} | {:.1} | {:.1} |", depth_same[j], pct(&mut depth_ms[j].clone(), 0.5), pct(&mut depth_ms[j], 0.95));
    }
    println!();
    println!("**Process RSS at the end:** {:.0} MB (includes the embedding model and all {} rounds in memory twice).", rss_kb as f64 / 1024.0, n_rounds);
    sqlx::raw_sql("DROP TABLE spike_vec").execute(&pg).await?;
    Ok(())
}

/// A directory only this user can use: created if missing, then checked to be the user's own
/// and closed to everyone else, so nobody can plant a database or a `-wal` file in it
/// (RUSTSEC-2026-0459, see deny.toml). `MEMHOUSE_HOME` may point anywhere; this does not trust it.
fn private_dir(dir: &std::path::Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let meta = std::fs::symlink_metadata(dir)?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        let me = unsafe { libc::geteuid() };
        anyhow::ensure!(meta.is_dir() && meta.uid() == me, "{} is not a directory owned by this user; the spike won't open a database there", dir.display());
        if meta.mode() & 0o077 != 0 {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    Ok(())
}
