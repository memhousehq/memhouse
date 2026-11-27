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
fn ext_of(path: &str) -> &str {
    let name = path.rsplit('/').next().unwrap_or(path);
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
