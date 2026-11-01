// SPDX-License-Identifier: Apache-2.0
//! Secret scanner (docs/security/secrets.md). Looks for credentials in the working tree, in staged
//! changes (pre-commit hook) or in the whole history (before publication). Built in so it runs
//! offline with nothing to install, and can scan the private repositories too (`--repo`).
//!
//! A line that legitimately contains a key-shaped test fixture can be marked with
//! `secret-scan: allow` on the same line. Fake values already in the history are listed by
//! fingerprint in `.secret-scan-allow` at the repository root (one `<fingerprint> <reason>` per
//! line), so the history scan stays clean without rewriting commits for test data.

use regex::Regex;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;

pub struct Finding {
    pub place: String,
    pub rule: &'static str,
    pub preview: String,
    /// sha256 of the matched text (first 16 hex digits), for `.secret-scan-allow`.
    pub fingerprint: String,
}

pub fn fingerprint(matched: &str) -> String {
    hex16(&Sha256::digest(matched.as_bytes()))
}

fn hex16(b: &[u8]) -> String {
    b.iter().take(8).map(|x| format!("{x:02x}")).collect()
}

/// Fingerprints of reviewed fake values (`.secret-scan-allow`).
pub fn allowlist(repo: &Path) -> HashSet<String> {
    std::fs::read_to_string(repo.join(".secret-scan-allow"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_whitespace().next())
        .filter(|f| !f.starts_with('#'))
        .map(String::from)
        .collect()
}

struct Rule {
    name: &'static str,
    re: Regex,
}

fn rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        let r = |name, p: &str| Rule { name, re: Regex::new(p).expect("valid regex") };
        vec![
            r("openrouter key", r"\bsk-or-v1-[0-9a-f]{32,}\b"),
            r("anthropic key", r"\bsk-ant-[A-Za-z0-9_\-]{20,}"),
            r("openai-style key", r"\bsk-(?:proj-|svcacct-|live-|test-)?[A-Za-z0-9_\-]{20,}"),
            r("stripe key", r"\b[rs]k_live_[0-9a-zA-Z]{20,}"),
            r("aws access key", r"\bAKIA[0-9A-Z]{16}\b"),
            r("github token", r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})"),
            r("slack token", r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),
            r("google api key", r"\bAIza[0-9A-Za-z_\-]{35}\b"),
            r("private key", r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----"),
            r("jwt", r"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),
            r("url with password", r#"\b[a-z][a-z0-9+]*://[^:/\s"'@]+:([^@\s"'/]{6,})@"#),
            r("credential assignment", r#"(?i)\b[a-z0-9_]*(?:api_?key|secret|token|passw(?:or)?d)\b["']?\s*[:=]\s*["']([A-Za-z0-9/+_\-.]{16,})["']"#),
        ]
    })
}

/// Values that are obviously placeholders, not credentials.
fn placeholder(v: &str) -> bool {
    let l = v.to_ascii_lowercase();
    let known = ["memhouse", "password", "change-me", "changeme", "secret", "example", "placeholder", "xxxxxx", "your-key", "redacted"];
    v.starts_with('$') || v.starts_with('<') || v.starts_with('{') || v.contains("***") || v.contains("...") || v.contains('…') || known.iter().any(|k| l.contains(k))
        // ENVIRONMENT_VARIABLE_NAMES are references, not values.
        || v.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

fn entropy(s: &str) -> f64 {
    let mut counts = std::collections::HashMap::new();
    for c in s.chars() {
        *counts.entry(c).or_insert(0usize) += 1;
    }
    let n = s.chars().count() as f64;
    counts
        .values()
        .map(|&k| {
            let p = k as f64 / n;
            -p * p.log2()
        })
        .sum()
}

/// Findings on one line of text: (rule, preview, fingerprint).
pub fn scan_line(line: &str) -> Vec<(&'static str, String, String)> {
    if line.contains("secret-scan: allow") {
        return vec![];
    }
    let mut out = vec![];
    for rule in rules() {
        for caps in rule.re.captures_iter(line) {
            let whole = caps.get(0).map(|m| m.as_str()).unwrap_or("");
            // Rules with a captured value: judge the value, not the surrounding text.
            if let Some(v) = caps.get(1).map(|m| m.as_str()) {
                if placeholder(v) || (rule.name == "credential assignment" && entropy(v) < 3.5) {
                    continue;
                }
            }
            out.push((rule.name, preview(whole), fingerprint(whole)));
            break;
        }
    }
    out
}

fn preview(s: &str) -> String {
    let head: String = s.chars().take(8).collect();
    format!("{head}… ({} chars)", s.chars().count())
}

fn git(repo: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git").args(args).current_dir(repo).output().map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(format!("git {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Files that must never be tracked, whatever they contain.
fn forbidden_file(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    (name == ".env" || (name.starts_with(".env.") && name != ".env.example"))
        || name.ends_with(".pem")
        || name.ends_with(".key")
        || name.ends_with(".p12")
        || name.ends_with(".tfstate")
        || name.starts_with("id_rsa")
        || name.starts_with("id_ed25519")
}

/// Scan every tracked and untracked-but-not-ignored file.
pub fn scan_tree(repo: &Path) -> Result<Vec<Finding>, String> {
    let mut out = vec![];
    for f in git(repo, &["ls-files", "-co", "--exclude-standard"])?.lines() {
        if forbidden_file(f) {
            out.push(Finding { place: f.to_string(), rule: "credential file", preview: "must not be committed (ignore it)".into(), fingerprint: fingerprint(f) });
            continue;
        }
        let Ok(text) = std::fs::read_to_string(repo.join(f)) else { continue }; // binary or deleted
        for (i, line) in text.lines().enumerate() {
            for (rule, preview, fingerprint) in scan_line(line) {
                out.push(Finding { place: format!("{f}:{}", i + 1), rule, preview, fingerprint });
            }
        }
    }
    let allowed = allowlist(repo);
    out.retain(|f| !allowed.contains(&f.fingerprint));
    Ok(out)
}

/// Scan added lines of a unified diff (`git diff --cached` or `git log -p`).
fn scan_diff(diff: &str) -> Vec<Finding> {
    let (mut commit, mut file, mut line_no) = (String::new(), String::new(), 0usize);
    let mut out = vec![];
    for l in diff.lines() {
        if let Some(c) = l.strip_prefix("commit ") {
            commit = c.chars().take(10).collect();
        } else if let Some(f) = l.strip_prefix("+++ b/") {
            file = f.to_string();
            if forbidden_file(&file) {
                out.push(Finding { place: place(&commit, &file, 0), rule: "credential file", preview: "must not be committed".into(), fingerprint: fingerprint(&file) });
            }
        } else if l.starts_with("@@") {
            // @@ -a,b +c,d @@
            line_no = l.split('+').nth(1).and_then(|s| s.split([',', ' ']).next()).and_then(|n| n.parse().ok()).unwrap_or(0);
        } else if let Some(added) = l.strip_prefix('+') {
            if !l.starts_with("+++") {
                for (rule, preview, fingerprint) in scan_line(added) {
                    out.push(Finding { place: place(&commit, &file, line_no), rule, preview, fingerprint });
                }
                line_no += 1;
            }
        } else if !l.starts_with('-') {
            line_no += 1;
        }
    }
    out
}

fn place(commit: &str, file: &str, line: usize) -> String {
    let at = if line > 0 { format!("{file}:{line}") } else { file.to_string() };
    if commit.is_empty() {
        at
    } else {
        format!("{commit} {at}")
    }
}

pub fn scan_staged(repo: &Path) -> Result<Vec<Finding>, String> {
    let allowed = allowlist(repo);
    Ok(scan_diff(&git(repo, &["diff", "--cached", "-U0", "--no-color", "--no-ext-diff"])?).into_iter().filter(|f| !allowed.contains(&f.fingerprint)).collect())
}

pub fn scan_history(repo: &Path) -> Result<Vec<Finding>, String> {
    // An empty repository has no history to scan.
    if git(repo, &["rev-parse", "--verify", "-q", "HEAD"]).is_err() {
        return Ok(vec![]);
    }
    let allowed = allowlist(repo);
    Ok(scan_diff(&git(repo, &["log", "--all", "-p", "-U0", "--no-color", "--no-ext-diff", "--format=commit %H"])?)
        .into_iter()
        .filter(|f| !allowed.contains(&f.fingerprint))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Fixtures are assembled at run time so this file never contains a key-shaped literal.
    fn fake(prefix: &str, n: usize) -> String {
        format!("{prefix}{}", "a1B2c3D4e5F6g7H8".repeat(8).chars().take(n).collect::<String>())
    }

    #[test]
    fn finds_provider_keys() {
        assert_eq!(scan_line(&format!("OPENAI_API_KEY={}", fake("sk-or-v1-", 0) + &"0123456789abcdef".repeat(4)))[0].0, "openrouter key");
        assert!(!scan_line(&format!("key = \"{}\"", fake("AKIA", 0) + "ABCDEFGHIJKLMNOP")).is_empty());
        assert!(!scan_line(&fake("ghp_", 40)).is_empty());
    }

    #[test]
    fn finds_urls_with_real_passwords_only() {
        assert!(!scan_line(&format!("postgres://memhouse:{}@db:5432/m", fake("", 12))).is_empty());
        for ok in ["postgres://memhouse:memhouse@127.0.0.1:54329/memhouse", "postgres://mh:${PW}@db/m", "postgres://memhouse:***@127.0.0.1/m", "postgres://mh:change-me@db/m"] {
            assert!(scan_line(ok).is_empty(), "{ok}");
        }
    }

    #[test]
    fn ignores_names_placeholders_and_allowed_lines() {
        assert!(scan_line(r#"api_key_env: Some("OPENAI_API_KEY".into())"#).is_empty());
        assert!(scan_line(r#"token = "your-key-goes-here-please""#).is_empty());
        assert!(scan_line(&format!("let k = \"{}\"; // secret-scan: allow", fake("sk-proj-", 24))).is_empty());
        assert!(!scan_line(&format!("let k = \"{}\";", fake("sk-proj-", 24))).is_empty());
    }

    #[test]
    fn flags_credential_files() {
        assert!(forbidden_file(".env") && forbidden_file("deploy/.env.prod") && forbidden_file("certs/server.key"));
        assert!(!forbidden_file(".env.example") && !forbidden_file("crates/x/src/key.rs"));
    }

    #[test]
    fn diff_scan_reports_added_lines_with_numbers() {
        let diff = format!("commit 0123456789abcdef\n+++ b/a.txt\n@@ -0,0 +3,2 @@\n+fine\n+{}\n", fake("ghp_", 40));
        let f = scan_diff(&diff);
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].place, "0123456789 a.txt:4");
    }
}
