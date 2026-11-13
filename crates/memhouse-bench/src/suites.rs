// SPDX-License-Identifier: Apache-2.0
//! Evaluation suites as files (roadmap G13): YAML (or JSON) in, a scored replay out.
//!
//! A suite file either lists its conversations or asks for them to be generated:
//!
//! ```yaml
//! name: personal-starter
//! generate: { profile: personal, seed: 7, conversations: 40 }
//! ```
//!
//! The format of a written-out suite is [`memhouse_core::eval::Suite`]; `docs/evaluation.md`
//! describes it.

use crate::metrics::Estimate;
use anyhow::Context;
use memhouse_core::eval::{EvalCounts, EvalMetrics, EvalRun, Suite, SuiteConversation, SUITE_FORMAT};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::Path;

/// Conversations to generate instead of listing them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Generate {
    pub profile: String,
    pub seed: u64,
    pub conversations: usize,
}

/// A suite as it may be written in a file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SuiteFile {
    #[serde(default = "format")]
    pub format: u32,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default = "k")]
    pub k: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generate: Option<Generate>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub conversations: Vec<SuiteConversation>,
}

fn format() -> u32 {
    SUITE_FORMAT
}

fn k() -> usize {
    5
}

/// Parse a suite from YAML or JSON text (JSON is YAML), generating its conversations if it asks
/// for that, and validate it. Errors carry the line and column the parser gives.
pub fn parse(text: &str, origin: &str) -> anyhow::Result<Suite> {
    let f: SuiteFile = serde_yaml_ng::from_str(text).with_context(|| format!("{origin} is not a suite"))?;
    let conversations = match (&f.generate, f.conversations.is_empty()) {
        (Some(g), true) => crate::synth::generate(&g.profile, g.seed, g.conversations, Some(&f.name)).with_context(|| format!("{origin}: generate"))?.0.conversations,
        (None, false) => f.conversations,
        (Some(_), false) => anyhow::bail!("{origin}: a suite has either `generate` or `conversations`, not both"),
        (None, true) => anyhow::bail!("{origin}: a suite needs `conversations` or `generate`"),
    };
    let suite = Suite { format: f.format, name: f.name, description: f.description, language: f.language, k: f.k, conversations };
    suite.validate().with_context(|| origin.to_string())?;
    Ok(suite)
}

pub fn load(path: &Path) -> anyhow::Result<Suite> {
    let text = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    parse(&text, &path.display().to_string())
}

/// Every suite file under a directory (`*.yaml`, `*.yml`, `*.json`), or the one file given.
pub fn load_all(path: &Path) -> anyhow::Result<Vec<Suite>> {
    if !path.is_dir() {
        return Ok(vec![load(path)?]);
    }
    let mut files = vec![];
    let mut dirs = vec![path.to_path_buf()];
    while let Some(d) = dirs.pop() {
        for e in std::fs::read_dir(&d).with_context(|| format!("reading {}", d.display()))? {
            let p = e?.path();
            if p.is_dir() {
                dirs.push(p);
            } else if p.extension().and_then(|x| x.to_str()).is_some_and(|x| matches!(x, "yaml" | "yml" | "json")) {
                files.push(p);
            }
        }
    }
    files.sort();
    anyhow::ensure!(!files.is_empty(), "no suite file (*.yaml, *.yml, *.json) under {}", path.display());
    files.iter().map(|f| load(f)).collect()
}

pub fn to_yaml(suite: &Suite) -> anyhow::Result<String> {
    Ok(serde_yaml_ng::to_string(suite)?)
}

/// The metrics of a replay by name, as `(name, value of the counts)`. Rates are also given as
/// their complement (`stale_free`, `clean`), so that every guarded value is one that must not
/// fall.
fn named(m: &EvalMetrics) -> Vec<(&'static str, Option<f64>)> {
    vec![
        ("eval/storage_precision", m.storage_precision),
        ("eval/storage_recall", m.storage_recall),
        ("eval/storage_f1", m.storage_f1),
        ("eval/retrieval_precision", m.retrieval_precision),
        ("eval/retrieval_recall", m.retrieval_recall),
        ("eval/retrieval_f1", m.retrieval_f1),
        ("eval/stale_rate", m.stale_rate),
        ("eval/contamination_rate", m.contamination_rate),
        ("eval/stale_free", m.stale_rate.map(|r| 1.0 - r)),
        ("eval/clean", m.contamination_rate.map(|r| 1.0 - r)),
    ]
}

/// Each metric with a 95% bootstrap interval over conversations (the counts of the resampled
/// conversations are summed, then the ratio is taken, as for the point value). Fixed seed.
pub fn estimates(run: &EvalRun) -> BTreeMap<String, Estimate> {
    let per = &run.per_conversation;
    let point = named(&run.metrics);
    let mut samples: Vec<Vec<f64>> = vec![vec![]; point.len()];
    let mut state = 0x6d65_6d68_6f75_7365u64;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    if per.len() > 1 {
        for _ in 0..400 {
            let mut sum = EvalCounts::default();
            for _ in 0..per.len() {
                sum.add(&per[(next() % per.len() as u64) as usize]);
            }
            for (i, (_, v)) in named(&sum.metrics()).into_iter().enumerate() {
                samples[i].extend(v);
            }
        }
    }
    point
        .into_iter()
        .zip(samples)
        .filter_map(|((name, v), mut s)| {
            let mean = v?;
            s.sort_by(|a, b| a.total_cmp(b));
            let (lo, hi) = if s.is_empty() { (mean, mean) } else { (s[(s.len() as f64 * 0.025) as usize], s[((s.len() as f64 * 0.975) as usize).min(s.len() - 1)]) };
            Some((name.to_string(), Estimate { mean, lo, hi, n: per.len() }))
        })
        .collect()
}

/// Share of scored records that ended the same in every replay (QUAL-10), 0 to 1.
pub fn agreement(runs: &[EvalRun]) -> f64 {
    let Some(first) = runs.first() else { return 1.0 };
    // Over the longest replay: a record one replay has and another lacks is a disagreement.
    let n = runs.iter().map(|r| r.outcomes.len()).max().unwrap_or(0);
    if n == 0 {
        return 1.0;
    }
    let same = (0..n).filter(|i| first.outcomes.get(*i).is_some() && runs.iter().all(|r| r.outcomes.get(*i) == first.outcomes.get(*i))).count();
    same as f64 / n as f64
}

/// The report section of one suite's replay.
pub fn markdown(suite: &Suite, run: &EvalRun, repeats: Option<(usize, f64)>) -> String {
    let est = estimates(run);
    let pct = |k: &str| est.get(k).map(|e| format!("{:.1} [{:.1}–{:.1}]", e.mean * 100.0, e.lo * 100.0, e.hi * 100.0)).unwrap_or_else(|| "–".into());
    let c = &run.counts;
    let mut o = String::new();
    let _ = writeln!(o, "## Evaluation suite `{}`\n", suite.name);
    if !suite.description.is_empty() {
        let _ = writeln!(o, "{}\n", suite.description);
    }
    let _ = writeln!(
        o,
        "{} conversations, {} turns, replayed under policy `{}` in {:.1} s (suite hash `{}`). Percentages with 95% bootstrap intervals over conversations.\n",
        suite.conversations.len(),
        suite.turns(),
        run.policy_version,
        run.took_ms / 1000.0,
        &run.suite_hash[..12]
    );
    let _ = writeln!(o, "| | Precision | Recall | F1 | Scored |\n|---|---|---|---|---|");
    let _ = writeln!(
        o,
        "| Storage | {} | {} | {} | {} facts at checkpoints, {} records |",
        pct("eval/storage_precision"),
        pct("eval/storage_recall"),
        pct("eval/storage_f1"),
        c.truth,
        c.stored
    );
    let _ = writeln!(
        o,
        "| Retrieval | {} | {} | {} | {} questions, top {} |\n",
        pct("eval/retrieval_precision"),
        pct("eval/retrieval_recall"),
        pct("eval/retrieval_f1"),
        c.questions,
        suite.k
    );
    let _ = writeln!(o, "| Rate | Value | Scored |\n|---|---|---|");
    let _ = writeln!(o, "| Stale facts returned | {} | {} of {} questions about a corrected fact |", pct("eval/stale_rate"), c.stale_returned, c.corrected_questions);
    let _ = writeln!(o, "| Contamination | {} | {} of {} plans and guesses committed |\n", pct("eval/contamination_rate"), c.held_committed, c.held);
    let _ = writeln!(
        o,
        "Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top {}.\n",
        suite.k
    );
    if let Some((n, a)) = repeats {
        let _ = writeln!(o, "Reproducibility (QUAL-10): {n} replays, {:.2}% of scored records ended the same in all of them.\n", a * 100.0);
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agreement_counts_a_record_only_some_replays_have() {
        let run = |outcomes: &[&str]| EvalRun {
            id: uuid::Uuid::nil(),
            tenant: String::new(),
            suite: String::new(),
            suite_hash: String::new(),
            policy_version: String::new(),
            fingerprint: Default::default(),
            trigger: memhouse_core::eval::EvalTrigger::Manual,
            counts: Default::default(),
            metrics: Default::default(),
            per_conversation: vec![],
            outcomes: outcomes.iter().map(|s| s.to_string()).collect(),
            took_ms: 0.0,
            created_at: chrono::Utc::now(),
            gate_passed: None,
        };
        assert_eq!(agreement(&[run(&["a", "b"]), run(&["a", "b"])]), 1.0);
        assert_eq!(agreement(&[run(&["a"]), run(&["a", "b"])]), 0.5);
        assert_eq!(agreement(&[run(&["a", "b"]), run(&["a"])]), 0.5);
        assert_eq!(agreement(&[run(&["a", "b"]), run(&["a", "c"])]), 0.5);
        assert_eq!(agreement(&[run(&[]), run(&[])]), 1.0);
    }

    #[test]
    fn yaml_suites_parse_generate_and_report_errors_with_their_place() {
        let written = "name: tiny\nk: 3\nconversations:\n  - id: dana\n    sessions:\n      - at: 2026-01-10T09:00:00Z\n        turns:\n          - say: I live in Lisbon.\n            key: city\n          - say: I might move to Berlin, maybe.\n            expect: hold\n        ask:\n          - q: Where do I live?\n            key: city\n";
        let s = parse(written, "tiny.yaml").unwrap();
        assert_eq!((s.name.as_str(), s.k, s.turns()), ("tiny", 3, 2));
        // A round trip through YAML keeps the suite, and so its hash.
        assert_eq!(parse(&to_yaml(&s).unwrap(), "again").unwrap().hash(), s.hash());
        let generated = parse("name: gen\ngenerate: { profile: support, seed: 11, conversations: 5 }\n", "gen.yaml").unwrap();
        assert_eq!(generated.conversations.len(), 5);
        assert_eq!(generated.hash(), parse("name: gen\ngenerate: { profile: support, seed: 11, conversations: 5 }\n", "x").unwrap().hash());
        let e = format!(
            "{:#}",
            parse("name: bad\nconversations:\n  - id: a\n    sessions:\n      - turns:\n          - say: hello\n            expects: hold\n", "bad.yaml").unwrap_err()
        );
        assert!(e.contains("bad.yaml") && e.contains("line 7"), "{e}");
        assert!(parse("name: none\n", "none.yaml").is_err());
        assert!(format!("{:#}", parse("name: q\nconversations:\n  - id: a\n    sessions:\n      - turns:\n          - say: hi\n            expect: ignore\n        ask:\n          - q: what?\n            key: city\n", "q.yaml").unwrap_err()).contains("no earlier turn commits"));
    }
}
