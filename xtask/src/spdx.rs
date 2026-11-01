// SPDX-License-Identifier: Apache-2.0
//! SPDX licence identifiers (RP-03): every source and documentation file names its licence in its
//! first lines, and the licence must match the file's path: `docs/` is CC-BY-4.0, everything else
//! Apache-2.0.

use std::path::Path;

const TAG: &str = "SPDX-License-Identifier:";

/// The licence a path must carry, or `None` for files the rule doesn't cover (data, config,
/// generated reports, licence texts).
pub fn expected(path: &str) -> Option<&'static str> {
    let ext = path.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    let covered = matches!(ext, "rs" | "sh" | "py" | "html" | "md");
    let generated = path.starts_with("bench-results/");
    if !covered || generated {
        return None;
    }
    Some(if path.starts_with("docs/") {
        "CC-BY-4.0"
    } else {
        "Apache-2.0"
    })
}

fn header(path: &str, licence: &str) -> String {
    match path.rsplit_once('.').map(|(_, e)| e).unwrap_or("") {
        "rs" => format!("// {TAG} {licence}"),
        "sh" | "py" => format!("# {TAG} {licence}"),
        _ => format!("<!-- {TAG} {licence} -->"),
    }
}

/// The identifier found in the first five lines, if any.
fn found(text: &str) -> Option<String> {
    text.lines().take(5).find_map(|l| l.split_once(TAG).map(|(_, rest)| rest.trim().trim_end_matches("-->").trim().to_string()))
}

/// Check (or with `fix`, insert) headers. Returns the problems left.
pub fn check(root: &Path, files: &[String], fix: bool) -> Result<Vec<String>, String> {
    let mut problems = vec![];
    for f in files {
        let Some(want) = expected(f) else { continue };
        let p = root.join(f);
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        match found(&text) {
            Some(have) if have == want => {}
            Some(have) => problems.push(format!("{f}: licence is {have}, but files here must be {want}")),
            None if fix => {
                let h = header(f, want);
                // Keep a shebang or doctype on the first line.
                let new = match text.split_once('\n') {
                    Some((first, rest)) if first.starts_with("#!") || first.to_ascii_lowercase().starts_with("<!doctype") => format!("{first}\n{h}\n{rest}"),
                    _ => format!("{h}\n{text}"),
                };
                std::fs::write(&p, new).map_err(|e| format!("{f}: {e}"))?;
            }
            None => problems.push(format!("{f}: no {TAG} line (expected {want}); `cargo xtask spdx --fix` adds it")),
        }
    }
    Ok(problems)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn licence_follows_the_path() {
        assert_eq!(expected("crates/memhouse-core/src/gate.rs"), Some("Apache-2.0"));
        assert_eq!(expected("docs/api.md"), Some("CC-BY-4.0"));
        assert_eq!(expected("Cargo.toml"), None);
        assert_eq!(expected("bench-results/run/report.md"), None);
    }

    #[test]
    fn finds_identifier_in_any_comment_style() {
        assert_eq!(found("<!-- SPDX-License-Identifier: CC-BY-4.0 -->\n# Title").as_deref(), Some("CC-BY-4.0"));
        assert_eq!(found("#!/bin/sh\n# SPDX-License-Identifier: Apache-2.0\n").as_deref(), Some("Apache-2.0"));
        assert_eq!(found("fn main() {}"), None);
    }
}
