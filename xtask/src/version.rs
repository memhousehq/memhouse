// SPDX-License-Identifier: Apache-2.0
//! One product version, in lockstep (RL-01, roadmap G21): the crates, the SDKs, the embedded
//! bindings and the Helm chart all carry the version of `[workspace.package]` in the root
//! `Cargo.toml`. `cargo xtask version` checks every place that states it, `--set` writes them
//! all, and `--tag` also holds a release tag to it. The API has a version of its own
//! (`info.version` of `api/openapi.json`, docs/api-stability.md), which a release does not move.

use regex::Regex;
use std::path::Path;

/// A file that states the product version: every match of `pattern` holds it in group 1.
struct Place {
    file: &'static str,
    pattern: &'static str,
    /// Matches expected (a place that silently stops matching would no longer be checked).
    count: usize,
    /// Python packaging spells a pre-release its own way (PEP 440: `2.1.0rc1`).
    python: bool,
}

/// Where `text` (the root `Cargo.toml`) states `[workspace.package] version`: the span of the
/// value, wherever in the table the key stands.
fn source_span(text: &str) -> Option<std::ops::Range<usize>> {
    let header = Regex::new(r"(?m)^\[workspace\.package\][ \t]*$").unwrap().find(text)?;
    let rest = &text[header.end()..];
    // The table ends where the next one begins.
    let end = Regex::new(r"(?m)^\[").unwrap().find(rest).map(|m| m.start()).unwrap_or(rest.len());
    let value = Regex::new(r#"(?m)^version[ \t]*=[ \t]*"([^"]+)""#).unwrap().captures(&rest[..end])?.get(1)?;
    Some(header.end() + value.start()..header.end() + value.end())
}

const PLACES: &[Place] = &[
    Place { file: "Cargo.toml", pattern: r#"(?m)^memhouse-[a-z-]+ = \{ path = "[^"]+", version = "([^"]+)" \}"#, count: 7, python: false },
    Place { file: "Cargo.lock", pattern: r#"(?m)^name = "memhouse-[a-z-]+"\nversion = "([^"]+)""#, count: 10, python: false },
    Place { file: "sdk/python/pyproject.toml", pattern: r#"(?m)^name = "memhouse"\nversion = "([^"]+)""#, count: 1, python: true },
    Place { file: "sdk/python/src/memhouse/__init__.py", pattern: r#"(?m)^__version__ = "([^"]+)""#, count: 1, python: true },
    Place { file: "sdk/python/uv.lock", pattern: r#"(?m)^name = "memhouse"\nversion = "([^"]+)""#, count: 1, python: true },
    Place { file: "sdk/typescript/package.json", pattern: r#"(?m)^  "version": "([^"]+)""#, count: 1, python: false },
    Place { file: "bindings/node/package.json", pattern: r#"(?m)^  "version": "([^"]+)""#, count: 1, python: false },
    Place { file: "deploy/helm/memhouse/Chart.yaml", pattern: r#"(?m)^version: (\S+)$"#, count: 1, python: false },
    Place { file: "deploy/helm/memhouse/Chart.yaml", pattern: r#"(?m)^appVersion: "([^"]+)""#, count: 1, python: false },
];

/// `MAJOR.MINOR.PATCH`, optionally with `-alpha.N`, `-beta.N` or `-rc.N`: the forms every
/// registry the release publishes to can state.
pub fn valid(version: &str) -> bool {
    // `[0-9]`, not `\d`: that class also matches digits of other scripts, which no registry reads.
    Regex::new(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$").unwrap().is_match(version)
}

/// The version as Python packaging writes it: `2.1.0-rc.1` is `2.1.0rc1`.
pub fn pep440(version: &str) -> String {
    match version.split_once('-') {
        None => version.to_string(),
        Some((base, pre)) => {
            let (kind, n) = pre.split_once('.').unwrap_or((pre, "0"));
            let kind = match kind {
                "alpha" => "a",
                "beta" => "b",
                other => other,
            };
            format!("{base}{kind}{n}")
        }
    }
}

fn read(root: &Path, file: &str) -> Result<String, String> {
    std::fs::read_to_string(root.join(file)).map_err(|e| format!("{file}: {e}"))
}

/// The product version: `[workspace.package] version`.
pub fn current(root: &Path) -> Result<String, String> {
    let text = read(root, "Cargo.toml")?;
    let span = source_span(&text).ok_or("Cargo.toml: no [workspace.package] version")?;
    Ok(text[span].to_string())
}

/// Every place that does not state `version`, as a line for the report.
pub fn check(root: &Path, version: &str) -> Result<Vec<String>, String> {
    let mut problems = vec![];
    if !valid(version) {
        problems.push(format!("Cargo.toml: version {version} is not MAJOR.MINOR.PATCH with an optional -alpha.N, -beta.N or -rc.N"));
    }
    for place in PLACES {
        let text = read(root, place.file)?;
        let want = if place.python { pep440(version) } else { version.to_string() };
        let found: Vec<String> = Regex::new(place.pattern).unwrap().captures_iter(&text).map(|c| c[1].to_string()).collect();
        if found.len() != place.count {
            problems.push(format!("{}: {} place(s) state a version where {} are expected (xtask/src/version.rs lists them)", place.file, found.len(), place.count));
        }
        for have in found.iter().filter(|have| **have != want) {
            problems.push(format!("{}: states {have}, the product version is {want}", place.file));
        }
    }
    // The changelog has a section for the version; a pre-release is described under its release.
    let base = version.split('-').next().unwrap_or(version);
    let heading = Regex::new(&format!(r"(?m)^## {}( |$)", regex::escape(base))).unwrap();
    if !heading.is_match(&read(root, "CHANGELOG.md")?) {
        problems.push(format!("CHANGELOG.md: no `## {base}` section"));
    }
    Ok(problems)
}

/// Write `version` to every place. The lock files are edited as text: the entries of the
/// workspace's own packages hold no checksum, so nothing else in them depends on the version.
pub fn set(root: &Path, version: &str) -> Result<(), String> {
    if !valid(version) {
        return Err(format!("{version} is not MAJOR.MINOR.PATCH with an optional -alpha.N, -beta.N or -rc.N"));
    }
    // Every file is rewritten in memory first, and nothing is written unless every place was
    // found: a declaration that no longer matches its pattern is an error with no edits, not
    // a checkout left half at the new version.
    let mut texts: Vec<(&str, String, String)> = vec![];
    let text_of = |file: &'static str, texts: &mut Vec<(&str, String, String)>| -> Result<usize, String> {
        if let Some(i) = texts.iter().position(|(f, _, _)| *f == file) {
            return Ok(i);
        }
        let text = read(root, file)?;
        texts.push((file, text.clone(), text));
        Ok(texts.len() - 1)
    };
    let i = text_of("Cargo.toml", &mut texts)?;
    let span = source_span(&texts[i].2).ok_or("Cargo.toml: no [workspace.package] version; nothing was changed")?;
    texts[i].2.replace_range(span, version);
    for place in PLACES {
        let want = if place.python { pep440(version) } else { version.to_string() };
        let i = text_of(place.file, &mut texts)?;
        let text = &texts[i].2;
        let spans: Vec<std::ops::Range<usize>> = Regex::new(place.pattern).unwrap().captures_iter(text).map(|c| c.get(1).expect("group 1").range()).collect();
        if spans.len() != place.count {
            return Err(format!(
                "{}: {} place(s) state a version where {} are expected (xtask/src/version.rs lists them); nothing was changed",
                place.file,
                spans.len(),
                place.count
            ));
        }
        let mut out = text.clone();
        for span in spans.into_iter().rev() {
            out.replace_range(span, &want);
        }
        texts[i].2 = out;
    }
    for (file, before, after) in &texts {
        if before != after {
            std::fs::write(root.join(file), after).map_err(|e| format!("{file}: {e}"))?;
            eprintln!("  {file}");
        }
    }
    Ok(())
}

/// A release tag is `v` and the product version, nothing else.
pub fn check_tag(tag: &str, version: &str) -> Result<(), String> {
    if tag.strip_prefix('v') == Some(version) {
        Ok(())
    } else {
        Err(format!("tag {tag} does not name the product version {version} (expected v{version}); set the version with `cargo xtask version --set`, commit, then tag"))
    }
}

/// The changelog's section for `version` (a pre-release takes its release's section), without
/// the heading: the release notes.
pub fn notes(root: &Path, version: &str) -> Result<String, String> {
    notes_of(&read(root, "CHANGELOG.md")?, version)
}

fn notes_of(text: &str, version: &str) -> Result<String, String> {
    let base = version.split('-').next().unwrap_or(version);
    let mut out = vec![];
    let mut inside = false;
    for line in text.lines() {
        if let Some(h) = line.strip_prefix("## ") {
            if inside {
                break;
            }
            inside = h == base || h.starts_with(&format!("{base} "));
            continue;
        }
        if inside {
            out.push(line);
        }
    }
    if !inside && out.is_empty() {
        return Err(format!("CHANGELOG.md: no `## {base}` section"));
    }
    Ok(out.join("\n").trim().to_string() + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_and_their_python_form() {
        for good in ["2.0.0", "2.1.0-rc.1", "10.20.30-alpha.0", "3.0.0-beta.12"] {
            assert!(valid(good), "{good}");
        }
        for bad in ["2.0", "v2.0.0", "2.0.0-rc1", "2.0.0+build", "02.0.0", "2.0.0-dev.1", "", "2.1.0-rc.1\u{0662}", "\u{0662}.0.0"] {
            assert!(!valid(bad), "{bad}");
        }
        assert_eq!(pep440("2.0.0"), "2.0.0");
        assert_eq!(pep440("2.1.0-rc.1"), "2.1.0rc1");
        assert_eq!(pep440("2.1.0-alpha.3"), "2.1.0a3");
        assert_eq!(pep440("2.1.0-beta.2"), "2.1.0b2");
    }

    #[test]
    fn a_tag_names_the_version_exactly() {
        check_tag("v2.0.0", "2.0.0").unwrap();
        check_tag("v2.0.0-rc.1", "2.0.0-rc.1").unwrap();
        for bad in ["2.0.0", "v2.0.1", "v2.0.0-rc.1", "release-2.0.0"] {
            assert!(check_tag(bad, "2.0.0").is_err(), "{bad}");
        }
    }

    /// The repository itself is in lockstep, and setting another version reaches every place.
    #[test]
    fn every_place_is_set_and_checked() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let version = current(root).unwrap();
        assert_eq!(check(root, &version).unwrap(), Vec::<String>::new());

        let copy = std::env::temp_dir().join(format!("memhouse-version-{}", std::process::id()));
        let mut files: Vec<&str> = PLACES.iter().map(|p| p.file).collect();
        files.push("CHANGELOG.md");
        for f in &files {
            let to = copy.join(f);
            std::fs::create_dir_all(to.parent().unwrap()).unwrap();
            std::fs::copy(root.join(f), to).unwrap();
        }
        let base = version.split('-').next().unwrap();
        // A version the checkout does not have, whatever it has.
        let next = if version == format!("{base}-rc.7") { format!("{base}-rc.8") } else { format!("{base}-rc.7") };
        set(&copy, &next).unwrap();
        assert_eq!(current(&copy).unwrap(), next);
        assert_eq!(check(&copy, &next).unwrap(), Vec::<String>::new());
        assert!(read(&copy, "sdk/python/pyproject.toml").unwrap().contains(&format!("version = \"{}\"", pep440(&next))));
        // A place left behind is reported by its file.
        std::fs::copy(root.join("sdk/typescript/package.json"), copy.join("sdk/typescript/package.json")).unwrap();
        let problems = check(&copy, &next).unwrap();
        assert!(problems.len() == 1 && problems[0].starts_with("sdk/typescript/package.json"), "{problems:?}");
        // A declaration that no longer matches stops `set` before anything is written.
        let manifest = read(&copy, "sdk/typescript/package.json").unwrap();
        std::fs::write(copy.join("sdk/typescript/package.json"), manifest.replace("\n  \"version\"", "\n    \"version\"")).unwrap();
        let before = read(&copy, "Cargo.toml").unwrap();
        let refused = set(&copy, &format!("{base}-rc.9")).unwrap_err();
        assert!(refused.starts_with("sdk/typescript/package.json") && refused.contains("nothing was changed"), "{refused}");
        assert_eq!(read(&copy, "Cargo.toml").unwrap(), before);
        std::fs::remove_dir_all(&copy).unwrap();
    }

    /// The version is read from its table, wherever the key stands in it, and from no other table.
    #[test]
    fn the_version_is_found_by_its_table_not_its_line() {
        let text = "[package]\nversion = \"0.0.1\"\n\n[workspace.package]\nedition = \"2021\"\nversion   =  \"3.4.5\"\n\n[workspace.dependencies]\nversion = \"9.9.9\"\n";
        assert_eq!(&text[source_span(text).unwrap()], "3.4.5");
        assert!(source_span("[workspace.package]\nedition = \"2021\"\n[other]\nversion = \"1.0.0\"\n").is_none());
    }

    /// The release notes are the section of the version, whatever its length.
    #[test]
    fn notes_are_the_versions_section() {
        let log = "# Changelog\n\n## 2.1.0 (unreleased)\n\n- Fix.\n\n## 2.0.0\n\n- First.\n";
        assert_eq!(notes_of(log, "2.1.0").unwrap(), "- Fix.\n");
        assert_eq!(notes_of(log, "2.1.0-rc.1").unwrap(), "- Fix.\n");
        assert_eq!(notes_of(log, "2.0.0").unwrap(), "- First.\n");
        assert!(notes_of(log, "3.0.0").is_err());
    }
}
