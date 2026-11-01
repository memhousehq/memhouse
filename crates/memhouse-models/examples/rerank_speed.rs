//! Cross-encoder latency probe: `cargo run --release -p memhouse-models --example rerank_speed -- <docs> <words> [model]`
use memhouse_core::config::RerankConfig;
use memhouse_core::Reranker;

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    let count: usize = a.get(1).and_then(|s| s.parse().ok()).unwrap_or(40);
    let words: usize = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(200);
    let mut cfg = RerankConfig::default();
    if let Some(m) = a.get(3) {
        cfg.model = m.clone();
    }
    let r = memhouse_models::local::LocalReranker::new(&cfg, &None, true).unwrap();
    let w = ["memory", "agent", "customer", "renewal", "invoice", "travel", "family", "recipe", "upgrade", "plan"];
    let docs: Vec<String> = (0..count).map(|i| (0..(words / 4 + (i * 37) % words)).map(|j| w[(i * 7 + j * 3) % w.len()]).collect::<Vec<_>>().join(" ")).collect();
    r.rerank("when is the customer renewal", &docs[..2]).await.unwrap();
    let t = std::time::Instant::now();
    for _ in 0..3 {
        r.rerank("when is the customer renewal", &docs).await.unwrap();
    }
    println!("{} ({count} docs, up to {words} words): {:.0} ms per query", r.id(), t.elapsed().as_secs_f64() * 1000.0 / 3.0);
}
