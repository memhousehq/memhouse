// SPDX-License-Identifier: Apache-2.0
//! Link check for the Markdown docs (G09): every relative link points to a file that exists, and
//! every `#anchor` to a heading in it. Offline; external links are listed by `--external`, not
//! fetched, so the check never fails on someone else's outage.

use regex::Regex;
use std::collections::{BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};

/// GitHub's heading anchor: lowercase, punctuation dropped except `-` and `_`, spaces to `-`.
pub fn slug(heading: &str) -> String {
    let text = Regex::new(r"`([^`]*)`").unwrap().replace_all(heading, "$1");
    let text = Regex::new(r"\[([^\]]*)\]\([^)]*\)").unwrap().replace_all(&text, "$1");
    text.trim()
        .to_lowercase()
        .chars()
        .filter_map(|c| match c {
            ' ' => Some('-'),
            c if c.is_alphanumeric() || c == '-' || c == '_' => Some(c),
            _ => None,
        })
        .collect()
}

/// The anchors of a Markdown file (duplicates get `-1`, `-2`, as GitHub does).
fn anchors(text: &str) -> BTreeSet<String> {
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut out = BTreeSet::new();
    let mut fence = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            fence = !fence;
            continue;
        }
        if fence {
            continue;
        }
        if let Some(h) = line.strip_prefix('#') {
            let h = h.trim_start_matches('#');
            if h.starts_with(' ') {
                let s = slug(h);
                let n = seen.entry(s.clone()).or_default();
                out.insert(if *n == 0 { s.clone() } else { format!("{s}-{n}") });
                *n += 1;
            }
        }
    }
    out
}

fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            c => out.push(c),
        }
    }
    out
}

/// Problems found, and the external links seen.
pub fn check(root: &Path, files: &[String]) -> (Vec<String>, BTreeSet<String>) {
    let link = Regex::new(r"\]\(([^)\s]+)(?:\s+\x22[^\x22]*\x22)?\)").unwrap();
    let md: Vec<&String> = files.iter().filter(|f| f.ends_with(".md")).collect();
    let mut cache: HashMap<PathBuf, BTreeSet<String>> = HashMap::new();
    let mut problems = vec![];
    let mut external = BTreeSet::new();
    for f in md {
        let Ok(text) = std::fs::read_to_string(root.join(f)) else { continue };
        let dir = Path::new(f).parent().unwrap_or(Path::new(""));
        let mut fence = false;
        for (i, line) in text.lines().enumerate() {
            if line.trim_start().starts_with("```") {
                fence = !fence;
                continue;
            }
            if fence {
                continue;
            }
            for c in link.captures_iter(line) {
                let target = &c[1];
                if target.starts_with("http://") || target.starts_with("https://") {
                    external.insert(target.to_string());
                    continue;
                }
                if target.starts_with("mailto:") || target.contains("://") {
                    continue;
                }
                let (path, anchor) = target.split_once('#').map(|(p, a)| (p, Some(a))).unwrap_or((target, None));
                let file = if path.is_empty() { PathBuf::from(f) } else { normalize(&dir.join(path)) };
                let full = root.join(&file);
                if !path.is_empty() && !full.exists() {
                    problems.push(format!("{f}:{}: {target}: no such file", i + 1));
                    continue;
                }
                if let Some(a) = anchor.filter(|a| !a.is_empty()) {
                    if !file.to_string_lossy().ends_with(".md") || full.is_dir() {
                        continue;
                    }
                    let set = cache.entry(file.clone()).or_insert_with(|| anchors(&std::fs::read_to_string(&full).unwrap_or_default()));
                    if !set.contains(a) {
                        problems.push(format!("{f}:{}: {target}: no heading #{a}", i + 1));
                    }
                }
            }
        }
    }
    (problems, external)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_slugs() {
        assert_eq!(slug(" G05 — Public API v1 contract ✅"), "g05--public-api-v1-contract-");
        assert_eq!(slug(" `POST /v1/recall`: retrieve memories"), "post-v1recall-retrieve-memories");
        assert_eq!(slug(" 3. The benchmark guard"), "3-the-benchmark-guard");
        let a = anchors("# A\n## A\n```\n# not\n```\n### B c");
        assert!(a.contains("a") && a.contains("a-1") && a.contains("b-c") && !a.contains("not"));
    }
}
