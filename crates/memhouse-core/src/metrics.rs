// SPDX-License-Identifier: Apache-2.0
//! Process metrics in the Prometheus text format (`GET /metrics`). A small registry of counters,
//! gauges and histograms keyed by name and labels: recording is a lock and a map lookup, so the
//! request path pays well under a microsecond per observation. Labels are identifiers and outcomes,
//! never subjects, users or content (bounded cardinality, PR-3).

use std::collections::BTreeMap;
use std::sync::{LazyLock, Mutex};

/// Upper bounds of the latency histograms, in seconds.
pub const BUCKETS: [f64; 14] = [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0];

type Key = (&'static str, Vec<(&'static str, String)>);

#[derive(Default)]
struct Hist {
    counts: [u64; BUCKETS.len()],
    count: u64,
    sum: f64,
}

#[derive(Default)]
struct Registry {
    counters: BTreeMap<Key, f64>,
    gauges: BTreeMap<Key, f64>,
    hists: BTreeMap<Key, Hist>,
}

static REGISTRY: LazyLock<Mutex<Registry>> = LazyLock::new(Default::default);

/// Help text of every metric, so the exposition documents itself.
const HELP: &[(&str, &str, &str)] = &[
    ("memhouse_http_requests_total", "counter", "HTTP requests by route template, method and status"),
    ("memhouse_http_request_duration_seconds", "histogram", "HTTP request latency by route template"),
    ("memhouse_operations_total", "counter", "Memory operations by operation and outcome (ok or an error code)"),
    ("memhouse_operation_duration_seconds", "histogram", "Memory operation latency by operation"),
    ("memhouse_recall_stage_duration_seconds", "histogram", "Recall latency per stage: embed, search, rerank, total"),
    ("memhouse_recall_statements", "histogram", "Database statements on the synchronous recall path (PERF-02: 1)"),
    ("memhouse_writes_total", "counter", "Records written by resulting state (committed, candidate, quarantined, deduplicated)"),
    ("memhouse_refused_total", "counter", "Refused calls: kind auth (401) or access (403), with the reason or rule"),
    ("memhouse_enrich_jobs", "gauge", "Enrichment jobs by state"),
    ("memhouse_enrich_queue_lag_seconds", "gauge", "Age of the oldest pending enrichment job"),
    ("memhouse_enrich_cost_usd_total", "counter", "LLM spend of enrichment, in US dollars"),
    ("memhouse_enrich_tokens_total", "counter", "LLM tokens of enrichment, by type"),
    ("memhouse_build_info", "gauge", "Build and API versions"),
];

fn key(name: &'static str, labels: &[(&'static str, &str)]) -> Key {
    (name, labels.iter().map(|(k, v)| (*k, v.to_string())).collect())
}

pub fn inc(name: &'static str, labels: &[(&'static str, &str)], by: f64) {
    if let Ok(mut r) = REGISTRY.lock() {
        *r.counters.entry(key(name, labels)).or_default() += by;
    }
}

pub fn set(name: &'static str, labels: &[(&'static str, &str)], value: f64) {
    if let Ok(mut r) = REGISTRY.lock() {
        r.gauges.insert(key(name, labels), value);
    }
}

/// Record one observation (seconds for latencies).
pub fn observe(name: &'static str, labels: &[(&'static str, &str)], value: f64) {
    if let Ok(mut r) = REGISTRY.lock() {
        let h = r.hists.entry(key(name, labels)).or_default();
        for (i, b) in BUCKETS.iter().enumerate() {
            if value <= *b {
                h.counts[i] += 1;
            }
        }
        h.count += 1;
        h.sum += value;
    }
}

fn escape(v: &str) -> String {
    v.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n")
}

fn labels(l: &[(&'static str, String)], extra: Option<(&str, String)>) -> String {
    let mut parts: Vec<String> = l.iter().map(|(k, v)| format!("{k}=\"{}\"", escape(v))).collect();
    if let Some((k, v)) = extra {
        parts.push(format!("{k}=\"{v}\""));
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!("{{{}}}", parts.join(","))
    }
}

/// The registry in the Prometheus text exposition format (version 0.0.4).
pub fn render() -> String {
    let r = match REGISTRY.lock() {
        Ok(r) => r,
        Err(p) => p.into_inner(),
    };
    let mut out = String::new();
    for (name, kind, help) in HELP {
        let mut lines = vec![];
        let src = match *kind {
            "counter" => &r.counters,
            "gauge" => &r.gauges,
            _ => &BTreeMap::new(),
        };
        for ((n, l), v) in src.iter().filter(|((n, _), _)| n == name) {
            let _ = n;
            lines.push(format!("{name}{} {v}", labels(l, None)));
        }
        if *kind == "histogram" {
            for ((_, l), h) in r.hists.iter().filter(|((n, _), _)| n == name) {
                for (i, b) in BUCKETS.iter().enumerate() {
                    lines.push(format!("{name}_bucket{} {}", labels(l, Some(("le", b.to_string()))), h.counts[i]));
                }
                lines.push(format!("{name}_bucket{} {}", labels(l, Some(("le", "+Inf".into()))), h.count));
                lines.push(format!("{name}_sum{} {}", labels(l, None), h.sum));
                lines.push(format!("{name}_count{} {}", labels(l, None), h.count));
            }
        }
        if !lines.is_empty() {
            out.push_str(&format!("# HELP {name} {help}\n# TYPE {name} {kind}\n"));
            for line in lines {
                out.push_str(&line);
                out.push('\n');
            }
        }
    }
    out
}

/// The current value of a counter (tests and checks).
pub fn counter(name: &'static str, labels: &[(&'static str, &str)]) -> f64 {
    REGISTRY.lock().map(|r| r.counters.get(&key(name, labels)).copied().unwrap_or(0.0)).unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposition_format() {
        inc("memhouse_refused_total", &[("kind", "access"), ("reason", "label")], 1.0);
        observe("memhouse_recall_stage_duration_seconds", &[("stage", "test-stage")], 0.003);
        set("memhouse_enrich_jobs", &[("state", "pending")], 2.0);
        let text = render();
        assert!(text.contains("# TYPE memhouse_refused_total counter\n"));
        assert!(text.contains("memhouse_refused_total{kind=\"access\",reason=\"label\"} 1"));
        assert!(text.contains("memhouse_recall_stage_duration_seconds_bucket{stage=\"test-stage\",le=\"0.0025\"} 0"));
        assert!(text.contains("memhouse_recall_stage_duration_seconds_bucket{stage=\"test-stage\",le=\"0.005\"} 1"));
        assert!(text.contains("memhouse_recall_stage_duration_seconds_count{stage=\"test-stage\"} 1"));
        assert!(text.contains("memhouse_enrich_jobs{state=\"pending\"} 2"));
        assert_eq!(escape("a\"b"), "a\\\"b");
    }
}
