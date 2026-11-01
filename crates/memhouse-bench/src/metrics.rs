// SPDX-License-Identifier: Apache-2.0
//! Retrieval metrics (same definitions as the LongMemEval reference code), bootstrap confidence
//! intervals and latency percentiles.

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// recall_any@k, recall_all@k and nDCG@k for one ranked list with binary relevance.
pub fn eval_ranking(ranked: &[String], relevant: &HashSet<String>, k: usize) -> (f64, f64, f64) {
    if relevant.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let top: HashSet<&String> = ranked.iter().take(k).collect();
    let any = relevant.iter().any(|r| top.contains(r)) as u8 as f64;
    let all = relevant.iter().all(|r| top.contains(r)) as u8 as f64;
    let dcg: f64 = ranked.iter().take(k).enumerate().map(|(i, d)| if relevant.contains(d) { 1.0 / ((i + 2) as f64).log2() } else { 0.0 }).sum();
    let ideal: f64 = (0..relevant.len().min(k)).map(|i| 1.0 / ((i + 2) as f64).log2()).sum();
    (any, all, if ideal > 0.0 { dcg / ideal } else { 0.0 })
}

/// Collapse a ranked list of rounds into a ranked list of unique sessions (first occurrence wins),
/// which is how LongMemEval turns round-level retrieval into session-level metrics.
pub fn unique_in_order(items: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = HashSet::new();
    items.into_iter().filter(|s| seen.insert(s.clone())).collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Estimate {
    pub mean: f64,
    pub lo: f64,
    pub hi: f64,
    pub n: usize,
}

/// Mean with a 95% percentile bootstrap interval (fixed seed, so reports are reproducible).
pub fn bootstrap(values: &[f64], resamples: usize) -> Estimate {
    let n = values.len();
    if n == 0 {
        return Estimate { mean: 0.0, lo: 0.0, hi: 0.0, n };
    }
    let mean = values.iter().sum::<f64>() / n as f64;
    if n == 1 {
        return Estimate { mean, lo: mean, hi: mean, n };
    }
    let mut rng = StdRng::seed_from_u64(0x6d656d686f757365);
    let mut means: Vec<f64> = (0..resamples).map(|_| (0..n).map(|_| values[rng.gen_range(0..n)]).sum::<f64>() / n as f64).collect();
    means.sort_by(|a, b| a.total_cmp(b));
    let lo = means[(resamples as f64 * 0.025) as usize];
    let hi = means[((resamples as f64 * 0.975) as usize).min(resamples - 1)];
    Estimate { mean, lo, hi, n }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Latency {
    pub n: usize,
    pub mean_ms: f64,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub p99_ms: f64,
    pub max_ms: f64,
}

pub fn latency(samples: &[f64]) -> Latency {
    if samples.is_empty() {
        return Latency::default();
    }
    let mut v = samples.to_vec();
    v.sort_by(|a, b| a.total_cmp(b));
    let q = |p: f64| v[((v.len() as f64 - 1.0) * p).round() as usize];
    Latency { n: v.len(), mean_ms: v.iter().sum::<f64>() / v.len() as f64, p50_ms: q(0.50), p95_ms: q(0.95), p99_ms: q(0.99), max_ms: *v.last().unwrap() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn ranking_metrics() {
        let rel: HashSet<String> = s(&["b", "d"]).into_iter().collect();
        let ranked = s(&["a", "b", "c", "d"]);
        let (any, all, ndcg) = eval_ranking(&ranked, &rel, 2);
        assert_eq!((any, all), (1.0, 0.0));
        let ideal = 1.0 + 1.0 / 3f64.log2();
        assert!((ndcg - (1.0 / 3f64.log2()) / ideal).abs() < 1e-9);
        let (_, all4, _) = eval_ranking(&ranked, &rel, 4);
        assert_eq!(all4, 1.0);
    }

    #[test]
    fn bootstrap_bounds() {
        let v: Vec<f64> = (0..200).map(|i| (i % 2) as f64).collect();
        let e = bootstrap(&v, 500);
        assert!((e.mean - 0.5).abs() < 1e-9 && e.lo < 0.5 && e.hi > 0.5);
    }
}
