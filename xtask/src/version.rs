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

const SOURCE: &str = r#"(?m)^\[workspace\.package\]\nversion = "([^"]+)""#;

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
    Regex::new(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(alpha|beta|rc)\.(0|[1-9]\d*))?$").unwrap().is_match(version)
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
    let found = Regex::new(SOURCE).unwrap().captures(&text).ok_or("Cargo.toml: no [workspace.package] version")?;
    Ok(found[1].to_string())
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
    let replace = |file: &str, pattern: &str, want: &str| -> Result<(), String> {
        let text = read(root, file)?;
        let re = Regex::new(pattern).unwrap();
        let mut out = String::with_capacity(text.len());
        let mut last = 0;
        for c in re.captures_iter(&text) {
            let m = c.get(1).expect("group 1");
            out.push_str(&text[last..m.start()]);
            out.push_str(want);
            last = m.end();
        }
        out.push_str(&text[last..]);
        if out != text {
            std::fs::write(root.join(file), out).map_err(|e| format!("{file}: {e}"))?;
            eprintln!("  {file}");
        }
        Ok(())
    };
    replace("Cargo.toml", SOURCE, version)?;
    for place in PLACES {
        let want = if place.python { pep440(version) } else { version.to_string() };
        replace(place.file, place.pattern, &want)?;
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
    let base = version.split('-').next().unwrap_or(version);
    let text = read(root, "CHANGELOG.md")?;
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
        for bad in ["2.0", "v2.0.0", "2.0.0-rc1", "2.0.0+build", "02.0.0", "2.0.0-dev.1", ""] {
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
        let next = format!("{base}-rc.7");
        set(&copy, &next).unwrap();
        assert_eq!(current(&copy).unwrap(), next);
        assert_eq!(check(&copy, &next).unwrap(), Vec::<String>::new());
        assert!(read(&copy, "sdk/python/pyproject.toml").unwrap().contains(&format!("version = \"{base}rc7\"")));
        // A place left behind is reported by its file.
        std::fs::copy(root.join("sdk/typescript/package.json"), copy.join("sdk/typescript/package.json")).unwrap();
        let problems = check(&copy, &next).unwrap();
        assert!(problems.len() == 1 && problems[0].starts_with("sdk/typescript/package.json"), "{problems:?}");
        assert!(notes(&copy, &next).unwrap().len() > 100);
        std::fs::remove_dir_all(&copy).unwrap();
    }
}
