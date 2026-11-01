//! Embedding throughput probe through MemHouse's own local embedder:
//! `cargo run --release -p memhouse-models --example embed_speed -- <words> <count>`
use memhouse_core::config::EmbeddingConfig;
use memhouse_core::{EmbedKind, Embedder};

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    let words: usize = a.get(1).and_then(|s| s.parse().ok()).unwrap_or(250);
    let count: usize = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(256);
    let mut cfg = EmbeddingConfig { batch_size: a.get(3).and_then(|s| s.parse().ok()).unwrap_or(32), ..Default::default() };
    if let Some(m) = a.get(4) {
        cfg.model = m.clone();
    }
    let e = memhouse_models::local::LocalEmbedder::new(&cfg, true).unwrap();
    let w = ["memory", "agent", "customer", "renewal", "invoice", "travel", "family", "recipe", "upgrade", "plan"];
    let texts: Vec<String> = (0..count).map(|i| (0..(words / 4 + (i * 37) % words)).map(|j| w[(i * 7 + j * 3) % w.len()]).collect::<Vec<_>>().join(" ")).collect();
    e.embed(&texts[..4], EmbedKind::Passage).await.unwrap();
    let t = std::time::Instant::now();
    e.embed(&texts, EmbedKind::Passage).await.unwrap();
    let s = t.elapsed().as_secs_f64();
    println!("{count} texts of up to {words} words: {:.1} texts/s", count as f64 / s);
}
