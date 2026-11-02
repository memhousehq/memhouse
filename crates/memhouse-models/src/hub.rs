// SPDX-License-Identifier: Apache-2.0
//! Model files from the Hugging Face Hub, without the `hf-hub` crate (its HTTP client bundles the
//! Mozilla CA list under CDLA-Permissive-2.0; we use the operating system's roots instead).
//!
//! The cache keeps the hub's layout (`models--{org}--{name}/refs/main` naming a snapshot directory
//! that holds the files), so caches written by earlier versions are reused as they are. A missing
//! file is fetched at the cached revision, so all files of a model come from one commit.
//! `HF_HOME`, `HF_ENDPOINT` and `HF_TOKEN` mean what they mean for the hub's own tools.

use anyhow::Context;
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct Repo {
    dir: PathBuf,
    endpoint: String,
    token: Option<String>,
    model: String,
    show_progress: bool,
}

impl Repo {
    pub fn new(model: &str, default_cache_dir: PathBuf, show_progress: bool) -> Repo {
        let cache = std::env::var("HF_HOME").map(PathBuf::from).unwrap_or(default_cache_dir);
        Repo {
            dir: cache.join(format!("models--{}", model.replace('/', "--"))),
            endpoint: std::env::var("HF_ENDPOINT").unwrap_or_else(|_| "https://huggingface.co".into()).trim_end_matches('/').to_string(),
            token: std::env::var("HF_TOKEN").ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()),
            model: model.to_string(),
            show_progress,
        }
    }

    /// Local paths of `files`, downloading the missing ones. Blocking; safe to call on a runtime
    /// thread (the HTTP client runs on a thread of its own).
    pub fn get(&self, files: &[&str]) -> anyhow::Result<Vec<PathBuf>> {
        let snapshot = |rev: &str| self.dir.join("snapshots").join(rev);
        let cached = std::fs::read_to_string(self.dir.join("refs/main")).ok().map(|r| r.trim().to_string()).filter(|r| !r.is_empty());
        if let Some(rev) = &cached {
            let paths: Vec<PathBuf> = files.iter().map(|f| snapshot(rev).join(f)).collect();
            if paths.iter().all(|p| p.exists()) {
                return Ok(paths);
            }
        }
        std::thread::scope(|s| s.spawn(|| self.fetch(cached, files)).join().map_err(|_| anyhow::anyhow!("model download thread panicked"))?)
    }

    fn fetch(&self, cached: Option<String>, files: &[&str]) -> anyhow::Result<Vec<PathBuf>> {
        let http = reqwest::blocking::Client::builder().connect_timeout(std::time::Duration::from_secs(30)).build()?;
        let rev = match cached {
            Some(r) => r,
            None => {
                let url = format!("{}/api/models/{}/revision/main", self.endpoint, self.model);
                let info: serde_json::Value = self.send(&http, &url)?.json().with_context(|| format!("reading {url}"))?;
                let sha = info["sha"].as_str().ok_or_else(|| anyhow::anyhow!("{url} returned no commit"))?.to_string();
                std::fs::create_dir_all(self.dir.join("refs"))?;
                std::fs::write(self.dir.join("refs/main"), &sha)?;
                sha
            }
        };
        let mut out = vec![];
        for f in files {
            let path = self.dir.join("snapshots").join(&rev).join(f);
            if !path.exists() {
                let url = format!("{}/{}/resolve/{rev}/{f}", self.endpoint, self.model);
                self.download(&http, &url, &path).with_context(|| format!("downloading {} {f}", self.model))?;
            }
            out.push(path);
        }
        Ok(out)
    }

    fn send(&self, http: &reqwest::blocking::Client, url: &str) -> anyhow::Result<reqwest::blocking::Response> {
        let mut req = http.get(url);
        if let Some(t) = &self.token {
            req = req.bearer_auth(t);
        }
        let resp = req.send().with_context(|| format!("requesting {url}"))?;
        if !resp.status().is_success() {
            anyhow::bail!("{url} returned {}", resp.status());
        }
        Ok(resp)
    }

    /// Download to a temporary name and rename, so an interrupted download never looks complete.
    fn download(&self, http: &reqwest::blocking::Client, url: &str, path: &Path) -> anyhow::Result<()> {
        let mut resp = self.send(http, url)?;
        if self.show_progress {
            let mb = resp.content_length().map(|n| format!(" ({:.1} MB)", n as f64 / 1e6)).unwrap_or_default();
            eprintln!("downloading {} {}{mb}", self.model, path.file_name().and_then(|n| n.to_str()).unwrap_or(""));
        }
        let dir = path.parent().ok_or_else(|| anyhow::anyhow!("no parent directory for {}", path.display()))?;
        std::fs::create_dir_all(dir)?;
        let part = path.with_extension(format!("part{}", std::process::id()));
        let mut file = std::fs::File::create(&part)?;
        let copied = resp.copy_to(&mut file).map_err(anyhow::Error::from).and_then(|_| file.flush().map_err(anyhow::Error::from));
        if let Err(e) = copied {
            let _ = std::fs::remove_file(&part);
            return Err(e);
        }
        std::fs::rename(&part, path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_existing_hub_cache_without_network() {
        let root = std::env::temp_dir().join(format!("mh-hub-{}", std::process::id()));
        let dir = root.join("models--org--m");
        std::fs::create_dir_all(dir.join("refs")).unwrap();
        std::fs::create_dir_all(dir.join("snapshots/abc/onnx")).unwrap();
        std::fs::write(dir.join("refs/main"), "abc\n").unwrap();
        std::fs::write(dir.join("snapshots/abc/onnx/model.onnx"), b"x").unwrap();
        std::fs::write(dir.join("snapshots/abc/tokenizer.json"), b"{}").unwrap();
        let mut repo = Repo::new("org/m", root.clone(), false);
        repo.dir = dir.clone();
        repo.endpoint = "http://127.0.0.1:9".into(); // nothing listens: any fetch would fail
        let got = repo.get(&["onnx/model.onnx", "tokenizer.json"]).unwrap();
        assert_eq!(got[0], dir.join("snapshots/abc/onnx/model.onnx"));
        assert!(repo.get(&["missing.json"]).is_err());
        let _ = std::fs::remove_dir_all(root);
    }
}
