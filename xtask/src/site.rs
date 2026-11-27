// SPDX-License-Identifier: Apache-2.0
//! The documentation site (roadmap G21): `docs/` rendered to static HTML, one page per Markdown
//! file. No site generator to install: the renderer is a crate pinned in `Cargo.lock`.
//!
//! What a page keeps from its source: the anchors GitHub gives its headings (so the links that
//! `cargo xtask links` checks work here too), links between documents (`.md` becomes `.html`),
//! and links out of `docs/` (to code, the README, the changelog), which point at the repository
//! at the ref the site was built from. Mermaid diagrams stay readable as text; a page that has
//! one loads the renderer for them.

use crate::links::slug;
use pulldown_cmark::{html, CodeBlockKind, CowStr, Event, Options, Parser, Tag, TagEnd};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

/// The diagram renderer, loaded only by pages that hold a diagram. A fixed version from a
/// public CDN; to serve the site without third-party requests, replace this with a vendored copy.
const MERMAID: &str = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs";

const STYLE: &str = include_str!("site.css");

pub struct Site<'a> {
    /// The repository's web address, for links that leave `docs/`.
    pub repository: &'a str,
    /// The branch or tag those links point at.
    pub git_ref: &'a str,
    pub version: &'a str,
}

/// Where a document is written: `README.md` is its directory's `index.html`.
fn page_path(doc: &str) -> String {
    let p = Path::new(doc);
    let name = if p.file_name().and_then(|n| n.to_str()) == Some("README.md") { "index.html".to_string() } else { format!("{}.html", p.file_stem().unwrap().to_string_lossy()) };
    match p.parent().filter(|d| !d.as_os_str().is_empty()) {
        Some(d) => format!("{}/{name}", d.to_string_lossy()),
        None => name,
    }
}

fn normalize(p: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            Component::CurDir => {}
            c => out.push(c),
        }
    }
    Some(out)
}

/// `to` as seen from the directory of the page `from` (both relative to the site root).
fn relative(from: &str, to: &str) -> String {
    let depth = from.matches('/').count();
    format!("{}{to}", "../".repeat(depth))
}

impl Site<'_> {
    /// A link found in `doc` (a path under `docs/`, relative to it), as the page must carry it.
    fn rewrite(&self, doc: &str, target: &str) -> String {
        if target.starts_with('#') || target.contains("://") || target.starts_with("mailto:") {
            return target.to_string();
        }
        let (path, anchor) = target.split_once('#').map(|(p, a)| (p, format!("#{a}"))).unwrap_or((target, String::new()));
        let dir = Path::new("docs").join(doc).parent().map(Path::to_path_buf).unwrap_or_default();
        let Some(full) = normalize(&dir.join(path)) else { return target.to_string() };
        let full = full.to_string_lossy().replace('\\', "/");
        match full.strip_prefix("docs/") {
            Some(inside) if inside.ends_with(".md") => format!("{}{anchor}", relative(doc, &page_path(inside))),
            Some(inside) => format!("{}{anchor}", relative(doc, inside)),
            // Outside the documentation: the file in the repository, at the ref this site is of.
            None => {
                let kind = if path.ends_with('/') || !full.rsplit('/').next().unwrap_or("").contains('.') { "tree" } else { "blob" };
                format!("{}/{kind}/{}/{}{anchor}", self.repository.trim_end_matches('/'), self.git_ref, full.trim_end_matches('/'))
            }
        }
    }

    /// One document as the body of its page, with its title and whether it holds a diagram.
    fn render(&self, doc: &str, text: &str) -> (String, String, bool) {
        let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
        let events: Vec<Event> = Parser::new_ext(text, options).collect();
        // The anchors GitHub gives the headings, in order (a repeated one gets -1, -2, …).
        let mut ids = vec![];
        let mut seen: HashMap<String, usize> = HashMap::new();
        let mut title = String::new();
        let mut heading: Option<String> = None;
        for e in &events {
            match e {
                Event::Start(Tag::Heading { .. }) => heading = Some(String::new()),
                Event::Text(t) | Event::Code(t) => {
                    if let Some(h) = heading.as_mut() {
                        h.push_str(t);
                    }
                }
                Event::End(TagEnd::Heading(_)) => {
                    let h = heading.take().unwrap_or_default();
                    if title.is_empty() {
                        title = h.clone();
                    }
                    let s = slug(&h);
                    let n = seen.entry(s.clone()).or_default();
                    ids.push(if *n == 0 { s.clone() } else { format!("{s}-{n}") });
                    *n += 1;
                }
                _ => {}
            }
        }
        let mut ids = ids.into_iter();
        let mut diagram: Option<String> = None;
        let mut has_diagram = false;
        let mut out = vec![];
        for e in events {
            match e {
                Event::Start(Tag::Heading { level, classes, attrs, .. }) => out.push(Event::Start(Tag::Heading { level, id: ids.next().map(CowStr::from), classes, attrs })),
                Event::Start(Tag::Link { link_type, dest_url, title, id }) => {
                    out.push(Event::Start(Tag::Link { link_type, dest_url: self.rewrite(doc, &dest_url).into(), title, id }))
                }
                Event::Start(Tag::Image { link_type, dest_url, title, id }) => {
                    out.push(Event::Start(Tag::Image { link_type, dest_url: self.rewrite(doc, &dest_url).into(), title, id }))
                }
                Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(lang))) if lang.as_ref() == "mermaid" => diagram = Some(String::new()),
                Event::Text(t) if diagram.is_some() => diagram.as_mut().unwrap().push_str(&t),
                Event::End(TagEnd::CodeBlock) if diagram.is_some() => {
                    has_diagram = true;
                    out.push(Event::Html(format!("<pre class=\"mermaid\">{}</pre>\n", escape(&diagram.take().unwrap())).into()));
                }
                other => out.push(other),
            }
        }
        let mut body = String::new();
        html::push_html(&mut body, out.into_iter());
        (title, body, has_diagram)
    }
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Render the Markdown files of `docs/` (paths relative to the repository) into `out`.
/// Returns the number of pages written.
pub fn build(root: &Path, files: &[String], out: &Path, site: &Site) -> Result<usize, String> {
    let mut docs: Vec<&str> = files.iter().filter_map(|f| f.strip_prefix("docs/")).filter(|f| f.ends_with(".md")).collect();
    // The index first, then the guides, then the directories.
    docs.sort_by_key(|d| (*d != "README.md", d.contains('/'), d.to_string()));
    let mut pages = vec![];
    for doc in &docs {
        let text = std::fs::read_to_string(root.join("docs").join(doc)).map_err(|e| format!("docs/{doc}: {e}"))?;
        let (title, body, diagram) = site.render(doc, &text);
        pages.push((doc.to_string(), page_path(doc), if title.is_empty() { doc.to_string() } else { title }, body, diagram));
    }
    if out.exists() {
        std::fs::remove_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    }
    std::fs::create_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    std::fs::write(out.join("site.css"), STYLE).map_err(|e| e.to_string())?;
    std::fs::write(out.join("diagrams.js"), format!("import mermaid from '{MERMAID}';\nmermaid.initialize({{ startOnLoad: true, securityLevel: 'strict' }});\n"))
        .map_err(|e| e.to_string())?;
    // GitHub Pages would otherwise run the pages through Jekyll.
    std::fs::write(out.join(".nojekyll"), "").map_err(|e| e.to_string())?;
    if let Ok(licence) = std::fs::read(root.join("docs/LICENSE")) {
        std::fs::write(out.join("LICENSE"), licence).map_err(|e| e.to_string())?;
    }
    for (doc, path, title, body, diagram) in &pages {
        let mut nav = String::new();
        let mut group = "";
        for (other, other_path, other_title, _, _) in &pages {
            let dir = other.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
            if dir != group {
                nav.push_str(&format!("<li class=\"group\">{}</li>\n", escape(dir)));
                group = dir;
            }
            let current = if other == doc { " aria-current=\"page\"" } else { "" };
            nav.push_str(&format!("<li><a href=\"{}\"{current}>{}</a></li>\n", relative(path, other_path), escape(other_title)));
        }
        let script = if *diagram { format!("<script type=\"module\" src=\"{}\"></script>\n", relative(path, "diagrams.js")) } else { String::new() };
        let edit = format!("{}/blob/{}/docs/{doc}", site.repository.trim_end_matches('/'), site.git_ref);
        let page = format!(
            "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
             <title>{title} · MemHouse</title>\n<link rel=\"stylesheet\" href=\"{css}\">\n{script}</head>\n<body>\n\
             <header><a class=\"brand\" href=\"{home}\">MemHouse</a> <span class=\"version\">documentation · {version}</span> <a class=\"source\" href=\"{source}\">source</a></header>\n\
             <div class=\"layout\">\n<nav><ul>\n{nav}</ul></nav>\n<main>\n{body}</main>\n</div>\n\
             <footer>MemHouse {version}. Documentation licensed under <a href=\"{licence}\">CC BY 4.0</a>; code under Apache-2.0. <a href=\"{edit}\">This page on GitHub</a>.</footer>\n</body>\n</html>\n",
            title = escape(title),
            css = relative(path, "site.css"),
            home = relative(path, "index.html"),
            version = escape(site.version),
            source = escape(site.repository),
            licence = relative(path, "LICENSE"),
        );
        let to = out.join(path);
        std::fs::create_dir_all(to.parent().expect("page directory")).map_err(|e| e.to_string())?;
        std::fs::write(&to, page).map_err(|e| format!("{}: {e}", to.display()))?;
    }
    // Every link between pages leads to a page that was written.
    let href = regex::Regex::new(r##"href="([^"#:]+)(?:#[^"]*)?""##).unwrap();
    let mut broken = vec![];
    for (_, path, _, _, _) in &pages {
        let text = std::fs::read_to_string(out.join(path)).map_err(|e| e.to_string())?;
        let dir = Path::new(path).parent().unwrap_or(Path::new(""));
        for c in href.captures_iter(&text) {
            match normalize(&dir.join(&c[1])) {
                Some(target) if out.join(&target).exists() => {}
                _ => broken.push(format!("{path}: {} leads nowhere in the site", &c[1])),
            }
        }
    }
    if !broken.is_empty() {
        return Err(broken.join("\n"));
    }
    Ok(pages.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SITE: Site = Site { repository: "https://example.test/org/repo", git_ref: "v9.9.9", version: "9.9.9" };

    #[test]
    fn links_are_rewritten_by_where_they_lead() {
        assert_eq!(SITE.rewrite("api.md", "configuration.md#embedding"), "configuration.html#embedding");
        assert_eq!(SITE.rewrite("api.md", "security/secrets.md"), "security/secrets.html");
        assert_eq!(SITE.rewrite("security/secrets.md", "../README.md"), "../index.html");
        assert_eq!(SITE.rewrite("security/secrets.md", "../../.env.example"), "https://example.test/org/repo/blob/v9.9.9/.env.example");
        assert_eq!(SITE.rewrite("development.md", "../crates/memhouse-core/src/traits.rs"), "https://example.test/org/repo/blob/v9.9.9/crates/memhouse-core/src/traits.rs");
        assert_eq!(SITE.rewrite("install.md", "../deploy/helm/memhouse"), "https://example.test/org/repo/tree/v9.9.9/deploy/helm/memhouse");
        assert_eq!(SITE.rewrite("adr/README.md", "0001-store.md"), "../adr/0001-store.html");
        assert_eq!(SITE.rewrite("api.md", "#errors"), "#errors");
        assert_eq!(SITE.rewrite("api.md", "https://semver.org/"), "https://semver.org/");
        assert_eq!(page_path("adr/README.md"), "adr/index.html");
    }

    #[test]
    fn headings_keep_githubs_anchors_and_diagrams_stay_text() {
        let (title, body, diagram) =
            SITE.render("x.md", "# The `x` guide\n\n## Run it\n\n## Run it\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\n- [x] done\n\n| a | b |\n|---|---|\n| 1 | 2 |\n");
        assert_eq!(title, "The x guide");
        assert!(body.contains("<h1 id=\"the-x-guide\">") && body.contains("<h2 id=\"run-it\">") && body.contains("<h2 id=\"run-it-1\">"), "{body}");
        assert!(diagram && body.contains("<pre class=\"mermaid\">flowchart LR\n  A --&gt; B\n</pre>"), "{body}");
        assert!(body.contains("<table>") && body.contains("type=\"checkbox\""), "{body}");
    }
}
