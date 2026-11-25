// SPDX-License-Identifier: Apache-2.0
//! Model files from the Hugging Face Hub, without the `hf-hub` crate (its HTTP client bundles the
//! Mozilla CA list under CDLA-Permissive-2.0; we use the operating system's roots instead).
//!
//! The cache keeps the hub's layout (`models--{org}--{name}/snapshots/{commit}/` holding the
//! files), so caches written by earlier versions are reused as they are.
//! `HF_HOME`, `HF_ENDPOINT` and `HF_TOKEN` mean what they mean for the hub's own tools.
//!
//! Tampered model files (threat T19): the models MemHouse names are pinned here to one commit of
//! their repository, with the sha256 of every file they load ([`PINS`]). A file is fetched at
//! that commit and checked before it enters the cache, and a cached file is checked the first
//! time a process loads it. Another model has no pin unless the configuration gives one
//! (`revision`, `sha256`); without, it works as before, with a warning.

use anyhow::Context;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// A model pinned in the binary: one commit of its repository and the sha256 of its files there.
pub struct Pin {
    pub repo: &'static str,
    pub revision: &'static str,
    pub files: &'static [(&'static str, &'static str)],
}

/// Every hash was checked against the hub's own record for the commit (the LFS object id of a
/// large file, the git blob id of a small one) on 21 November 2026.
pub const PINS: &[Pin] = &[
    // The default embedder (`bge-small-en-v1.5`).
    Pin {
        repo: "Xenova/bge-small-en-v1.5",
        revision: "ea104dacec62c0de699686887e3f920caeb4f3e3",
        files: &[
            ("onnx/model.onnx", "828e1496d7fabb79cfa4dcd84fa38625c0d3d21da474a00f08db0f559940cf35"),
            ("tokenizer.json", "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"),
            ("config.json", "fa73f90bf92c8cace1fbcb709626306f2bdbc9ea3e5b5f94b440df9b6aa56350"),
            ("special_tokens_map.json", "b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3"),
            ("tokenizer_config.json", "9261e7d79b44c8195c1cada2b453e55b00aeb81e907a6664974b4d7776172ab3"),
        ],
    },
    // Its quantised form (`bge-small-en-v1.5-onnx-Q`), the benchmark baseline's embedder.
    Pin {
        repo: "Qdrant/bge-small-en-v1.5-onnx-Q",
        revision: "aa8f8b060edb00e03bfdd08813a2949946c8ba55",
        files: &[
            ("model_optimized.onnx", "51f1bd0addd6e859e42c2c8021a5e5461385bb676a649f4b269aa445449f2431"),
            ("tokenizer.json", "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"),
            ("config.json", "13582bcf2effc85b7bf3d3f5532e686bc1c9ce86bb009d10f0ec33cbe92299dd"),
            ("special_tokens_map.json", "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a"),
            ("tokenizer_config.json", "0b29c7bfc889e53b36d9dd3e686dd4300f6525110eaa98c76a5dafceb2029f53"),
        ],
    },
    Pin {
        repo: "Qdrant/all-MiniLM-L6-v2-onnx",
        revision: "d13954661f83248295ba75c1ed411eef3b7b936e",
        files: &[
            ("model.onnx", "bbd7b466f6d58e646fdc2bd5fd67b2f5e93c0b687011bd4548c420f7bd46f0c5"),
            ("tokenizer.json", "851ca67100d372ca3ae031a6abd168f53489eebfd7d89523f35c5c9b4d372c3c"),
            ("config.json", "1b4d8e2a3988377ed8b519a31d8d31025a25f1c5f8606998e8014111438efcd7"),
            ("special_tokens_map.json", "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a"),
            ("tokenizer_config.json", "abda01c8c14c5151ae498aceb30db406d6b91242c394fd88d3b6fd5a63a101e6"),
        ],
    },
    // The multilingual embedder the language warning recommends.
    Pin {
        repo: "intfloat/multilingual-e5-small",
        revision: "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        files: &[
            ("onnx/model.onnx", "ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665"),
            ("tokenizer.json", "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39"),
            ("config.json", "69137736cab8b8903a07fe8afaafdda25aac55415a12a55d1bffa9f581abf959"),
            ("special_tokens_map.json", "d05497f1da52c5e09554c0cd874037a083e1dc1b9cfd48034d1c717f1afc07a7"),
            ("tokenizer_config.json", "a1d6bc8734a6f635dc158508bef000f8e2e5a759c7d92f984b2c86e5ff53425b"),
        ],
    },
    // The default reranker (`jina-reranker-v1-turbo-en`).
    Pin {
        repo: "jinaai/jina-reranker-v1-turbo-en",
        revision: "b8c14f4e723d9e0aab4732a7b7b93741eeeb77c2",
        files: &[
            ("onnx/model.onnx", "c1296c66c119de645fa9cdee536d8637740efe85224cfa270281e50f213aa565"),
            ("tokenizer.json", "0046da43cc8c424b317f56b092b0512aaaa65c4f925d2f16af9d9eeb4d0ef902"),
            ("config.json", "e050ff6a15ae9295e84882fa0e98051bd8754856cd5201395ebf00ce9f2d609b"),
            ("special_tokens_map.json", "06e405a36dfe4b9604f484f6a1e619af1a7f7d09e34a8555eb0b77b66318067f"),
            ("tokenizer_config.json", "d291c6652d96d56ffdbcf1ea19d9bae5ed79003f7648c627e725a619227ce8fa"),
        ],
    },
    Pin {
        repo: "BAAI/bge-reranker-base",
        revision: "2cfc18c9415c912f9d8155881c133215df768a70",
        files: &[
            ("onnx/model.onnx", "15b9a8c3da82eddf263df571281166e00e9308fe19d077084b642ebfcaf06d2b"),
            ("tokenizer.json", "9eb652ac4e40cc093272bbbe0f55d521cf67570060227109b5cdc20945a4489e"),
            ("config.json", "289adf7ada1eb6b4afa7589a48a032d45a076cf2e46dcdb3b4cabc33be14f708"),
            ("special_tokens_map.json", "d5469a60db23249c7f8945013d78df30b44b6bf686c6bb4740f4223f77b1b535"),
            ("tokenizer_config.json", "a1d6bc8734a6f635dc158508bef000f8e2e5a759c7d92f984b2c86e5ff53425b"),
        ],
    },
];

pub fn pin_for(repo: &str) -> Option<&'static Pin> {
    PINS.iter().find(|p| p.repo.eq_ignore_ascii_case(repo))
}

/// What a repository's files are fetched at and checked against.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Expect {
    /// The commit; `None` follows the repository's `main` as it was at the first download.
    pub revision: Option<String>,
    /// Expected sha256 by file name.
    pub sha256: BTreeMap<String, String>,
    /// Whether the configuration replaced or added to the binary's pin.
    pub configured: bool,
}

impl Expect {
    /// The binary's pin for `repo`, with the configuration's revision and hashes over it. The
    /// binary's hashes belong to its revision: another revision keeps only the configured ones.
    pub fn of(repo: &str, revision: Option<&str>, sha256: &BTreeMap<String, String>) -> Expect {
        let pin = pin_for(repo);
        let revision = revision.map(|r| r.trim().to_string()).filter(|r| !r.is_empty()).or_else(|| pin.map(|p| p.revision.to_string()));
        let mut hashes: BTreeMap<String, String> = match pin {
            Some(p) if revision.as_deref() == Some(p.revision) => p.files.iter().map(|(f, h)| (f.to_string(), h.to_string())).collect(),
            _ => BTreeMap::new(),
        };
        hashes.extend(sha256.iter().map(|(f, h)| (f.clone(), h.trim().to_ascii_lowercase())));
        let configured = (revision.is_some() && pin.is_none_or(|p| revision.as_deref() != Some(p.revision))) || !sha256.is_empty();
        Expect { revision, sha256: hashes, configured }
    }

    pub fn pinned(&self) -> bool {
        self.revision.is_some() || !self.sha256.is_empty()
    }

    /// One line for `memhouse doctor`: `Err` when nothing pins the model, or when only a
    /// revision does (the files are then fetched at that commit but compared with nothing).
    pub fn describe(&self, repo: &str) -> Result<String, String> {
        if !self.pinned() {
            return Err(format!("{repo} is not pinned: its files are used as downloaded, unchecked. Set `revision` and `sha256` for it in the configuration"));
        }
        if self.sha256.is_empty() {
            let r = self.revision.as_deref().unwrap_or_default();
            return Err(format!(
                "{repo} is pinned to revision {} without checksums: its files are used as downloaded, unchecked. Set `sha256` for them in the configuration",
                &r[..r.len().min(12)]
            ));
        }
        let by = if self.configured { "by the configuration" } else { "in this build" };
        Ok(match &self.revision {
            Some(r) => format!("{repo} pinned {by} to revision {}, {} file checksums", &r[..r.len().min(12)], self.sha256.len()),
            None => format!("{repo}: {} file checksums {by}, no revision", self.sha256.len()),
        })
    }
}

pub fn sha256_file(path: &Path) -> anyhow::Result<String> {
    let mut file = std::fs::File::open(path).with_context(|| format!("reading {}", path.display()))?;
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(hex::encode(hash.finalize()))
}

/// Whether the file at `path` (the file `name` of `repo`) has the sha256 `expected`. The error
/// names the file and both hashes.
pub fn verify_file(path: &Path, repo: &str, name: &str, expected: &str) -> anyhow::Result<()> {
    let found = sha256_file(path)?;
    anyhow::ensure!(
        found.eq_ignore_ascii_case(expected.trim()),
        "model file {name} of {repo} does not match its pinned checksum: sha256 {found}, expected {}",
        expected.trim().to_ascii_lowercase()
    );
    Ok(())
}

/// Files this process has checked already (path and hash): a model is hashed once per process,
/// not once per session or per command of a server.
static VERIFIED: Mutex<Option<HashSet<(PathBuf, String)>>> = Mutex::new(None);
/// What this process has warned about already.
static WARNED: Mutex<Option<HashSet<String>>> = Mutex::new(None);

fn first_time<T: std::hash::Hash + Eq>(set: &Mutex<Option<HashSet<T>>>, item: T) -> bool {
    set.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashSet::new).insert(item)
}

pub struct Repo {
    dir: PathBuf,
    endpoint: String,
    token: Option<String>,
    model: String,
    show_progress: bool,
    expect: Expect,
}

impl Repo {
    /// The repository `model`, with the binary's pin if it has one.
    pub fn new(model: &str, default_cache_dir: PathBuf, show_progress: bool) -> Repo {
        let cache = std::env::var("HF_HOME").map(PathBuf::from).unwrap_or(default_cache_dir);
        Repo {
            dir: cache.join(format!("models--{}", model.replace('/', "--"))),
            endpoint: std::env::var("HF_ENDPOINT").unwrap_or_else(|_| "https://huggingface.co".into()).trim_end_matches('/').to_string(),
            token: std::env::var("HF_TOKEN").ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()),
            model: model.to_string(),
            show_progress,
            expect: Expect::of(model, None, &BTreeMap::new()),
        }
    }

    /// The configuration's revision and checksums over the binary's pin (see [`Expect::of`]).
    pub fn with_pin(mut self, revision: Option<&str>, sha256: &BTreeMap<String, String>) -> Repo {
        self.expect = Expect::of(&self.model, revision, sha256);
        self
    }

    /// Local paths of `files`, downloading the missing ones; every file with an expected
    /// checksum has been checked against it. Blocking; safe to call on a runtime thread (the
    /// HTTP client runs on a thread of its own).
    pub fn get(&self, files: &[&str]) -> anyhow::Result<Vec<PathBuf>> {
        self.warn_unpinned(files);
        // A pinned model never follows `refs/main`: a cache of another commit is not its files.
        let rev = match &self.expect.revision {
            Some(r) => Some(r.clone()),
            None => std::fs::read_to_string(self.dir.join("refs/main")).ok().map(|r| r.trim().to_string()).filter(|r| !r.is_empty()),
        };
        if let Some(rev) = &rev {
            let paths: Vec<PathBuf> = files.iter().map(|f| self.dir.join("snapshots").join(rev).join(f)).collect();
            if paths.iter().all(|p| p.exists()) {
                for (f, p) in files.iter().zip(&paths) {
                    self.check_cached(f, p)?;
                }
                return Ok(paths);
            }
        }
        std::thread::scope(|s| s.spawn(|| self.fetch(rev, files)).join().map_err(|_| anyhow::anyhow!("model download thread panicked"))?)
    }

    fn warn_unpinned(&self, files: &[&str]) {
        if !self.expect.pinned() {
            if first_time(&WARNED, self.model.clone()) {
                tracing::warn!(
                    "model {} is not pinned: its files are used as downloaded from the hub, without a checksum. Set `revision` and `sha256` for it in the configuration to pin it",
                    self.model
                );
            }
            return;
        }
        for f in files.iter().filter(|f| !self.expect.sha256.contains_key(**f)) {
            if first_time(&WARNED, format!("{}/{f}", self.model)) {
                tracing::warn!("model {}: no checksum for {f}, which is used unchecked. Add it to `sha256` in the configuration", self.model);
            }
        }
    }

    /// A cached file against its checksum, the first time this process uses it. What is hashed
    /// is the file at rest; the loader reads it again right after.
    fn check_cached(&self, name: &str, path: &Path) -> anyhow::Result<()> {
        let Some(expected) = self.expect.sha256.get(name) else { return Ok(()) };
        let key = (path.to_path_buf(), expected.clone());
        if VERIFIED.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|v| v.contains(&key)) {
            return Ok(());
        }
        verify_file(path, &self.model, name, expected)
            .with_context(|| format!("the cached file {} was changed after it was downloaded, or belongs to another revision; delete it to download it again", path.display()))?;
        first_time(&VERIFIED, key);
        Ok(())
    }

    fn fetch(&self, rev: Option<String>, files: &[&str]) -> anyhow::Result<Vec<PathBuf>> {
        let http = reqwest::blocking::Client::builder().connect_timeout(std::time::Duration::from_secs(30)).build()?;
        let rev = match rev {
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
            if path.exists() {
                self.check_cached(f, &path)?;
            } else {
                let url = format!("{}/{}/resolve/{rev}/{f}", self.endpoint, self.model);
                self.download(&http, &url, f, &path).with_context(|| format!("downloading {} {f}", self.model))?;
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

    /// Download to a temporary name, check it, then rename: an interrupted download never looks
    /// complete, and a file that is not the pinned one never has the name the loader reads.
    fn download(&self, http: &reqwest::blocking::Client, url: &str, name: &str, path: &Path) -> anyhow::Result<()> {
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
        drop(file);
        let checked = copied.and_then(|_| match self.expect.sha256.get(name) {
            Some(expected) => verify_file(&part, &self.model, name, expected).context("the download was discarded; nothing was added to the cache"),
            None => Ok(()),
        });
        if let Err(e) = checked {
            let _ = std::fs::remove_file(&part);
            return Err(e);
        }
        std::fs::rename(&part, path)?;
        if let Some(expected) = self.expect.sha256.get(name) {
            first_time(&VERIFIED, (path.to_path_buf(), expected.clone()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;

    fn sha(bytes: &[u8]) -> String {
        hex::encode(Sha256::digest(bytes))
    }

    fn temp(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("mh-hub-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    /// A repository under `root` that fetches from `endpoint`, with the pin given.
    fn repo(root: &Path, endpoint: &str, revision: Option<&str>, files: &[(&str, String)]) -> Repo {
        Repo {
            dir: root.join("models--org--m"),
            endpoint: endpoint.into(),
            token: None,
            model: "org/m".into(),
            show_progress: false,
            expect: Expect::of("org/m", revision, &files.iter().map(|(f, h)| (f.to_string(), h.clone())).collect()),
        }
    }

    /// Nothing listens here: any fetch fails.
    const NOWHERE: &str = "http://127.0.0.1:9";

    /// A hub that serves `files` (path, body) at the commit `rev` of `org/m`.
    fn hub(rev: &str, files: &[(&str, &[u8])]) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let served: Vec<(String, Vec<u8>)> = files.iter().map(|(f, b)| (format!("/org/m/resolve/{rev}/{f}"), b.to_vec())).collect();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut lines = std::io::BufReader::new(stream.try_clone().unwrap()).lines();
                let request = lines.next().and_then(|l| l.ok()).unwrap_or_default();
                while lines.next().and_then(|l| l.ok()).is_some_and(|l| !l.is_empty()) {}
                let path = request.split(' ').nth(1).unwrap_or("");
                let reply = match served.iter().find(|(p, _)| p == path) {
                    Some((_, body)) => [format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes(), body.clone()].concat(),
                    None => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
                };
                let _ = stream.write_all(&reply);
            }
        });
        url
    }

    fn files_under(dir: &Path) -> Vec<PathBuf> {
        let mut found = vec![];
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            if e.path().is_dir() {
                found.extend(files_under(&e.path()));
            } else {
                found.push(e.path());
            }
        }
        found
    }

    #[test]
    fn reads_an_existing_hub_cache_without_network() {
        let root = temp("unpinned");
        let dir = root.join("models--org--m");
        std::fs::create_dir_all(dir.join("refs")).unwrap();
        std::fs::create_dir_all(dir.join("snapshots/abc/onnx")).unwrap();
        std::fs::write(dir.join("refs/main"), "abc\n").unwrap();
        std::fs::write(dir.join("snapshots/abc/onnx/model.onnx"), b"x").unwrap();
        std::fs::write(dir.join("snapshots/abc/tokenizer.json"), b"{}").unwrap();
        let mut repo = Repo::new("org/m", root.clone(), false);
        repo.dir = dir.clone();
        repo.endpoint = NOWHERE.into();
        // A model the binary does not name has no pin, and works as it did.
        assert!(!repo.expect.pinned());
        let got = repo.get(&["onnx/model.onnx", "tokenizer.json"]).unwrap();
        assert_eq!(got[0], dir.join("snapshots/abc/onnx/model.onnx"));
        assert!(repo.get(&["missing.json"]).is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn verification_accepts_the_file_and_rejects_a_tampered_one_by_name() {
        let root = temp("verify");
        let path = root.join("model.onnx");
        std::fs::write(&path, b"the model").unwrap();
        let expected = sha(b"the model");
        verify_file(&path, "org/m", "onnx/model.onnx", &expected).unwrap();
        verify_file(&path, "org/m", "onnx/model.onnx", &expected.to_ascii_uppercase()).unwrap();
        std::fs::write(&path, b"the mode1").unwrap();
        let e = verify_file(&path, "org/m", "onnx/model.onnx", &expected).unwrap_err().to_string();
        assert!(e.contains("onnx/model.onnx") && e.contains("org/m"), "{e}");
        assert!(e.contains(&format!("sha256 {}", sha(b"the mode1"))) && e.contains(&format!("expected {expected}")), "{e}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_cached_file_is_checked_when_first_loaded() {
        let root = temp("cached");
        let snapshot = root.join("models--org--m/snapshots/rev1");
        std::fs::create_dir_all(&snapshot).unwrap();
        std::fs::write(snapshot.join("model.onnx"), b"the model").unwrap();
        std::fs::write(snapshot.join("config.json"), b"{}").unwrap();
        // `refs/main` naming another commit is not followed by a pinned model.
        std::fs::create_dir_all(root.join("models--org--m/refs")).unwrap();
        std::fs::write(root.join("models--org--m/refs/main"), "other").unwrap();
        let pinned = [("model.onnx", sha(b"the model")), ("config.json", sha(b"{}"))];
        let good = repo(&root, NOWHERE, Some("rev1"), &pinned);
        assert_eq!(good.get(&["model.onnx", "config.json"]).unwrap(), [snapshot.join("model.onnx"), snapshot.join("config.json")]);

        // Checked once per process: the same file is not hashed again by the next session or command.
        assert!(VERIFIED.lock().unwrap().as_ref().unwrap().contains(&(snapshot.join("model.onnx"), sha(b"the model"))));

        // A file changed in the cache is refused when it is first loaded, by name, with both hashes.
        let changed = root.join("models--org--m/snapshots/rev2");
        std::fs::create_dir_all(&changed).unwrap();
        std::fs::write(changed.join("model.onnx"), b"the model").unwrap();
        std::fs::write(changed.join("config.json"), b"{ }").unwrap();
        let e = format!("{:#}", repo(&root, NOWHERE, Some("rev2"), &pinned).get(&["model.onnx", "config.json"]).unwrap_err());
        assert!(e.contains("model file config.json of org/m") && e.contains(&sha(b"{ }")) && e.contains(&sha(b"{}")), "{e}");
        assert!(e.contains("delete it to download it again"), "{e}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_download_is_checked_before_it_enters_the_cache() {
        let root = temp("download");
        let url = hub("rev1", &[("onnx/model.onnx", b"the model"), ("config.json", b"{}")]);
        let snapshot = root.join("models--org--m/snapshots/rev1");

        // What the hub serves is not what is pinned: an error naming the file and both hashes, and nothing kept.
        let wrong = repo(&root, &url, Some("rev1"), &[("onnx/model.onnx", sha(b"another model")), ("config.json", sha(b"{}"))]);
        let e = format!("{:#}", wrong.get(&["config.json", "onnx/model.onnx"]).unwrap_err());
        assert!(e.contains("model file onnx/model.onnx of org/m") && e.contains(&sha(b"the model")) && e.contains(&sha(b"another model")), "{e}");
        assert_eq!(files_under(&snapshot), [snapshot.join("config.json")], "only the file that matched is in the cache");

        // The pinned files are fetched at the pinned commit and kept.
        let right = repo(&root, &url, Some("rev1"), &[("onnx/model.onnx", sha(b"the model")), ("config.json", sha(b"{}"))]);
        let got = right.get(&["onnx/model.onnx", "config.json"]).unwrap();
        assert_eq!(std::fs::read(&got[0]).unwrap(), b"the model");
        // Another commit is another address: the hub above does not have it.
        assert!(repo(&root, &url, Some("rev2"), &[]).get(&["config.json"]).is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn pins_are_well_formed() {
        let hex_of = |s: &str, n: usize| s.len() == n && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        for p in PINS {
            assert!(hex_of(p.revision, 40), "{}: revision {}", p.repo, p.revision);
            for needed in ["tokenizer.json", "config.json", "special_tokens_map.json", "tokenizer_config.json"] {
                assert!(p.files.iter().any(|(f, _)| *f == needed), "{}: no checksum for {needed}", p.repo);
            }
            assert!(p.files.iter().all(|(_, h)| hex_of(h, 64)), "{}", p.repo);
            assert_eq!(PINS.iter().filter(|q| q.repo == p.repo).count(), 1, "{} is pinned twice", p.repo);
        }
    }

    #[test]
    fn the_configuration_pins_another_model_or_moves_a_pinned_one() {
        let none = BTreeMap::new();
        let pin = &PINS[0];
        let built_in = Expect::of(pin.repo, None, &none);
        assert_eq!((built_in.revision.as_deref(), built_in.sha256.len(), built_in.configured), (Some(pin.revision), pin.files.len(), false));
        assert!(built_in.describe(pin.repo).unwrap().contains("in this build"));
        // Another revision of a pinned model: the binary's checksums are not that revision's.
        let moved = Expect::of(pin.repo, Some("0123456789abcdef0123456789abcdef01234567"), &BTreeMap::from([("config.json".to_string(), "AB".repeat(32))]));
        assert_eq!(moved.sha256, BTreeMap::from([("config.json".to_string(), "ab".repeat(32))]));
        assert!(moved.configured && moved.describe(pin.repo).unwrap().contains("by the configuration"));
        // A revision alone fetches that commit but checks nothing: not reported as verified.
        let unchecked = Expect::of(pin.repo, Some("0123456789abcdef0123456789abcdef01234567"), &none);
        assert!(unchecked.pinned() && unchecked.describe(pin.repo).unwrap_err().contains("without checksums"));
        // A model the binary does not name: unpinned, then pinned by the configuration.
        let unknown = Expect::of("org/other", None, &none);
        assert!(!unknown.pinned() && unknown.describe("org/other").unwrap_err().contains("not pinned"));
        assert!(Expect::of("org/other", Some("abc"), &none).pinned());
    }

    /// Fetches two small files of the default embedder at its pinned commit from the real hub
    /// (network, a few kilobytes) and checks them. Run with `--ignored`.
    #[test]
    #[ignore]
    fn the_hub_serves_the_pinned_files() {
        let root = temp("real");
        let repo = Repo { dir: root.join("models--Xenova--bge-small-en-v1.5"), ..Repo::new(PINS[0].repo, root.clone(), false) };
        let got = repo.get(&["config.json", "tokenizer_config.json"]).unwrap();
        assert!(got.iter().all(|p| p.starts_with(root.join("models--Xenova--bge-small-en-v1.5/snapshots").join(PINS[0].revision))));
        let _ = std::fs::remove_dir_all(root);
    }
}
