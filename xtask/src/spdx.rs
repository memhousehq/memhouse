// SPDX-License-Identifier: Apache-2.0
//! SPDX licence identifiers (RP-03): every source and documentation file names its licence in its
//! first lines, and the licence must match the file's path: `docs/` is CC-BY-4.0, everything else
//! Apache-2.0.

use std::path::Path;

const TAG: &str = "SPDX-License-Identifier:";

/// The licence a path must carry, or `None` for files the rule doesn't cover (data, config,
/// generated reports, licence texts).
pub fn expected(path: &str) -> Option<&'static str> {
    let ext = ext_of(path);
    // Packaging (G21): the Dockerfile, the release workflows, the Helm chart (its YAML and its
    // template helpers) and the Homebrew formula template. YAML elsewhere is data (suites,
    // scenarios, lock files) and stays outside the rule.
    let packaging = is_dockerfile(path)
        || (matches!(ext, "yaml" | "yml") && (path.starts_with(".github/workflows/") || path.starts_with("deploy/")))
        || (ext == "tpl" && path.starts_with("deploy/"))
        || (ext == "rb" && path.starts_with("packaging/"));
    let covered = packaging || matches!(ext, "rs" | "sh" | "py" | "ts" | "js" | "mjs" | "html" | "md" | "css");
    let generated = path.starts_with("bench-results/");
    if !covered || generated {
        return None;
    }
    Some(if path.starts_with("docs/") { "CC-BY-4.0" } else { "Apache-2.0" })
}

/// The extension of the file's name (none for `Dockerfile`, or for a dot in a directory's name).
/// A template is the kind of file it is a template of: `memhouse.rb.in` is Ruby.
fn ext_of(path: &str) -> &str {
    let name = path.rsplit('/').next().unwrap_or(path);
    let name = name.strip_suffix(".in").unwrap_or(name);
    name.rsplit_once('.').map(|(_, e)| e).unwrap_or("")
}

fn is_dockerfile(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    name == "Dockerfile" || name.ends_with(".Dockerfile")
}

fn header(path: &str, licence: &str) -> String {
    if is_dockerfile(path) {
        return format!("# {TAG} {licence}");
    }
    match ext_of(path) {
        "rs" | "ts" | "js" | "mjs" => format!("// {TAG} {licence}"),
        "sh" | "py" | "yaml" | "yml" | "rb" => format!("# {TAG} {licence}"),
        "css" => format!("/* {TAG} {licence} */"),
        // A Helm template comment: rendered to nothing.
        "tpl" => format!("{{{{/* {TAG} {licence} */}}}}"),
        _ => format!("<!-- {TAG} {licence} -->"),
    }
}

/// The identifier found in the first five lines, if any.
fn found(text: &str) -> Option<String> {
    text.lines().take(5).find_map(|l| l.split_once(TAG).map(|(_, rest)| rest.trim().trim_end_matches("-->").trim_end_matches("*/}}").trim_end_matches("*/").trim().to_string()))
}

/// `text` with the header line `h` added: first, or after what must stay first.
fn insert(path: &str, text: &str, h: &str) -> String {
    // A Dockerfile's parser directives (`# syntax=`, `# escape=`, `# check=`) count only
    // before any other line, a comment included.
    let keep = if is_dockerfile(path) {
        text.lines()
            .take_while(|l| {
                let Some(l) = l.strip_prefix('#') else { return false };
                let l = l.trim_start().to_ascii_lowercase();
                ["syntax", "escape", "check"].iter().any(|d| l.strip_prefix(d).is_some_and(|rest| rest.trim_start().starts_with('=')))
            })
            .count()
    } else {
        // A shebang or doctype stays on the first line.
        usize::from(text.lines().next().is_some_and(|first| first.starts_with("#!") || first.to_ascii_lowercase().starts_with("<!doctype")))
    };
    let mut lines: Vec<&str> = text.split_inclusive('\n').collect();
    let header = format!("{h}\n");
    lines.insert(keep.min(lines.len()), &header);
    lines.concat()
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
                let new = insert(f, &text, &h);
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
        assert_eq!(expected("sdk/typescript/src/client.ts"), Some("Apache-2.0"));
        assert_eq!(header("sdk/typescript/conformance/driver.mjs", "Apache-2.0"), "// SPDX-License-Identifier: Apache-2.0");
        assert_eq!(expected("Cargo.toml"), None);
        // Packaging files are covered; YAML that is data is not.
        for covered in [
            "Dockerfile",
            ".github/workflows/release.yml",
            "deploy/helm/memhouse/values.yaml",
            "deploy/helm/memhouse/templates/_helpers.tpl",
            "packaging/homebrew/memhouse.rb",
            "packaging/homebrew/memhouse.rb.in",
            "install.sh",
            "xtask/src/site.css",
        ] {
            assert_eq!(expected(covered), Some("Apache-2.0"), "{covered}");
        }
        for data in [
            "bench/suites/coding/suite.yaml",
            "sdk/typescript/pnpm-lock.yaml",
            ".github/dependabot.yml",
            "deploy/helm/memhouse/values.schema.json",
            "deploy/helm/memhouse/templates/NOTES.txt",
        ] {
            assert_eq!(expected(data), None, "{data}");
        }
        assert_eq!(header("Dockerfile", "Apache-2.0"), "# SPDX-License-Identifier: Apache-2.0");
        assert_eq!(header("packaging/homebrew/memhouse.rb.in", "Apache-2.0"), "# SPDX-License-Identifier: Apache-2.0");
        // The header goes first, except after what must stay first.
        let h = "# SPDX-License-Identifier: Apache-2.0";
        assert_eq!(insert("Dockerfile", "FROM scratch\n", h), format!("{h}\nFROM scratch\n"));
        assert_eq!(
            insert("Dockerfile", "# syntax=docker/dockerfile:1\n# escape = `\n# a comment\nFROM scratch\n", h),
            format!("# syntax=docker/dockerfile:1\n# escape = `\n{h}\n# a comment\nFROM scratch\n")
        );
        assert_eq!(insert("install.sh", "#!/bin/sh\nset -eu\n", h), format!("#!/bin/sh\n{h}\nset -eu\n"));
        assert_eq!(insert("a.sh", "set -eu\n", h), format!("{h}\nset -eu\n"));
        assert_eq!(header("deploy/helm/memhouse/templates/_helpers.tpl", "Apache-2.0"), "{{/* SPDX-License-Identifier: Apache-2.0 */}}");
        assert_eq!(found("{{/* SPDX-License-Identifier: Apache-2.0 */}}\n").as_deref(), Some("Apache-2.0"));
        assert_eq!(found("/* SPDX-License-Identifier: Apache-2.0 */\n").as_deref(), Some("Apache-2.0"));
        assert_eq!(expected("bench-results/run/report.md"), None);
    }

    #[test]
    fn finds_identifier_in_any_comment_style() {
        assert_eq!(found("<!-- SPDX-License-Identifier: CC-BY-4.0 -->\n# Title").as_deref(), Some("CC-BY-4.0"));
        assert_eq!(found("#!/bin/sh\n# SPDX-License-Identifier: Apache-2.0\n").as_deref(), Some("Apache-2.0"));
        assert_eq!(found("fn main() {}"), None);
    }
}
