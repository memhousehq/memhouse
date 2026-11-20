// SPDX-License-Identifier: Apache-2.0
//! The profile conformance suite (PROF-01, TR-CORE-01): one scenario file run through every way
//! into a deployment. Each way must meet the scenario's expectations, and all of them must give
//! the same outcomes step by step, since one engine answers behind each.
//!
//! A [`Way`] carries one of five operations (`remember`, `recall`, `revise`, `forget`,
//! `ingest`) with the request as JSON and returns the response as JSON. Three are built in:
//! [`Rest`], [`Mcp`] (MCP over HTTP) and [`Cli`] (the `memhouse` binary). An SDK adds its own.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

/// The scenario every deployment must pass.
pub const BASIC: &str = include_str!("../scenarios/basic.yaml");

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    pub name: String,
    pub steps: Vec<Step>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Step {
    #[serde(default)]
    pub remember: Option<Remember>,
    #[serde(default)]
    pub recall: Option<Recall>,
    #[serde(default)]
    pub revise: Option<Revise>,
    #[serde(default)]
    pub forget: Option<Forget>,
    #[serde(default)]
    pub ingest: Option<Ingest>,
    /// A name for the record this step stores (for an ingest: its first round).
    #[serde(default)]
    pub save: Option<String>,
    #[serde(default)]
    pub expect: Expect,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Remember {
    pub content: String,
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Recall {
    pub query: String,
    #[serde(default)]
    pub k: Option<usize>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Revise {
    /// The saved name of the record to revise.
    pub id: String,
    pub content: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Forget {
    /// The saved name of the record to forget.
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ingest {
    pub session: String,
    pub messages: Vec<Value>,
}

/// What a step's response must show. Names are those given with `save`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub deduplicated: Option<bool>,
    /// The record a revision replaced.
    #[serde(default)]
    pub superseded: Option<String>,
    /// A recall's first hit.
    #[serde(default)]
    pub first: Option<String>,
    #[serde(default)]
    pub contains: Vec<String>,
    #[serde(default)]
    pub excludes: Vec<String>,
    /// Some hit's content contains this text.
    #[serde(default)]
    pub contains_text: Option<String>,
    /// Rounds an ingest stored.
    #[serde(default)]
    pub stored: Option<u64>,
    #[serde(default)]
    pub deleted: Option<u64>,
}

impl Scenario {
    pub fn parse(yaml: &str) -> anyhow::Result<Scenario> {
        let s: Scenario = serde_yaml_ng::from_str(yaml)?;
        anyhow::ensure!(!s.steps.is_empty(), "scenario {}: no steps", s.name);
        let mut saved: Vec<&str> = vec![];
        for (i, step) in s.steps.iter().enumerate() {
            let n = [step.remember.is_some(), step.recall.is_some(), step.revise.is_some(), step.forget.is_some(), step.ingest.is_some()].iter().filter(|x| **x).count();
            anyhow::ensure!(n == 1, "scenario {}, step {}: exactly one of remember, recall, revise, forget, ingest", s.name, i + 1);
            let used = step.revise.iter().map(|r| &r.id).chain(step.forget.iter().map(|f| &f.id)).chain(&step.expect.contains).chain(&step.expect.excludes).chain(&step.expect.first).chain(&step.expect.superseded);
            for name in used {
                anyhow::ensure!(saved.contains(&name.as_str()), "scenario {}, step {}: \"{name}\" was not saved by an earlier step", s.name, i + 1);
            }
            if let Some(name) = &step.save {
                anyhow::ensure!(step.recall.is_none() && step.forget.is_none(), "scenario {}, step {}: only a step that stores a record can save one", s.name, i + 1);
                saved.push(name);
            }
        }
        Ok(s)
    }
}

/// One way into a deployment.
#[async_trait::async_trait]
pub trait Way: Send + Sync {
    fn name(&self) -> String;
    /// Carry out `op` (`remember`, `recall`, `revise`, `forget` or `ingest`) with the request
    /// `body` (the fields of the REST request) and return the response's JSON.
    async fn call(&self, op: &str, body: Value) -> anyhow::Result<Value>;
}

/// The REST API: `POST {base}/v1/{op}` with a bearer key.
pub struct Rest {
    pub base: String,
    pub key: String,
    http: reqwest::Client,
}

impl Rest {
    pub fn new(base: &str, key: &str) -> Rest {
        Rest { base: base.trim_end_matches('/').into(), key: key.into(), http: reqwest::Client::new() }
    }
}

#[async_trait::async_trait]
impl Way for Rest {
    fn name(&self) -> String {
        "rest".into()
    }
    async fn call(&self, op: &str, body: Value) -> anyhow::Result<Value> {
        let r = self.http.post(format!("{}/v1/{op}", self.base)).bearer_auth(&self.key).json(&body).send().await?;
        let status = r.status();
        let v: Value = r.json().await.unwrap_or(Value::Null);
        anyhow::ensure!(status.is_success(), "REST {op} answered {status}: {v}");
        Ok(v)
    }
}

/// MCP over HTTP: `tools/call` at `{base}/mcp` with a bearer key; the tool's structured result.
pub struct Mcp {
    pub base: String,
    pub key: String,
    http: reqwest::Client,
}

impl Mcp {
    pub fn new(base: &str, key: &str) -> Mcp {
        Mcp { base: base.trim_end_matches('/').into(), key: key.into(), http: reqwest::Client::new() }
    }
}

#[async_trait::async_trait]
impl Way for Mcp {
    fn name(&self) -> String {
        "mcp".into()
    }
    async fn call(&self, op: &str, body: Value) -> anyhow::Result<Value> {
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": op, "arguments": body } });
        let r = self.http.post(format!("{}/mcp", self.base)).bearer_auth(&self.key).json(&request).send().await?;
        let status = r.status();
        let v: Value = r.json().await.unwrap_or(Value::Null);
        anyhow::ensure!(status.is_success() && v.get("error").is_none(), "MCP {op} answered {status}: {v}");
        let result = &v["result"];
        anyhow::ensure!(result["isError"] != true, "MCP {op} returned an error: {}", result["content"][0]["text"]);
        Ok(result["structuredContent"].clone())
    }
}

/// The command line: the `memhouse` binary with a configuration file.
pub struct Cli {
    pub bin: std::path::PathBuf,
    pub config: std::path::PathBuf,
    /// Environment for the binary (for example `MEMHOUSE_HOME`).
    pub env: Vec<(String, String)>,
}

#[async_trait::async_trait]
impl Way for Cli {
    fn name(&self) -> String {
        "cli".into()
    }
    async fn call(&self, op: &str, body: Value) -> anyhow::Result<Value> {
        let text = |k: &str| body[k].as_str().unwrap_or_default().to_string();
        let subject = text("subject");
        let mut file = None;
        let args: Vec<String> = match op {
            "remember" => {
                let mut a = vec!["remember".into(), text("content"), "-s".into(), subject];
                if let Some(k) = body["kind"].as_str() {
                    a.extend(["-k".into(), k.to_string()]);
                }
                a
            }
            "recall" => vec!["recall".into(), text("query"), "-s".into(), subject, "-k".into(), body["k"].as_u64().unwrap_or(10).to_string(), "--json".into()],
            "revise" => vec!["revise".into(), text("id"), text("content"), "--json".into()],
            "forget" => vec!["forget".into(), text("id"), "--json".into()],
            "ingest" => {
                let path = std::env::temp_dir().join(format!("memhouse-profile-{}.json", uuid::Uuid::new_v4().simple()));
                std::fs::write(&path, serde_json::to_vec(&body["messages"])?)?;
                let a = vec!["ingest".into(), path.display().to_string(), "-s".into(), subject, "--session".into(), text("session_id"), "--json".into()];
                file = Some(path);
                a
            }
            other => anyhow::bail!("the command line has no operation {other}"),
        };
        let out = tokio::process::Command::new(&self.bin).arg("--config").arg(&self.config).args(&args).envs(self.env.iter().cloned()).output().await;
        if let Some(f) = file {
            let _ = std::fs::remove_file(f);
        }
        let out = out?;
        anyhow::ensure!(out.status.success(), "memhouse {op} exited with {}: {}", out.status, String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or_default());
        let stdout = String::from_utf8_lossy(&out.stdout);
        let start = stdout.find('{').ok_or_else(|| anyhow::anyhow!("memhouse {op} printed no JSON: {stdout}"))?;
        Ok(serde_json::from_str(&stdout[start..])?)
    }
}

/// What one way did with the scenario.
#[derive(Debug, Clone, serde::Serialize)]
pub struct WayResult {
    pub way: String,
    /// One line per step: the outcome with ids replaced by their saved names.
    pub transcript: Vec<String>,
    /// Expectations not met, and calls that failed.
    pub failures: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ProfileReport {
    pub scenario: String,
    pub ways: Vec<WayResult>,
    /// Steps whose outcome differs between ways.
    pub differences: Vec<String>,
}

impl ProfileReport {
    pub fn passed(&self) -> bool {
        !self.ways.is_empty() && self.differences.is_empty() && self.ways.iter().all(|w| w.failures.is_empty())
    }

    pub fn failure_text(&self) -> String {
        let mut out: Vec<String> = self.ways.iter().flat_map(|w| w.failures.iter().map(move |f| format!("{}: {f}", w.way))).collect();
        out.extend(self.differences.iter().cloned());
        out.join("\n")
    }

    pub fn summary(&self) -> String {
        format!(
            "scenario {}: {} steps through {}; {} unmet expectation(s), {} difference(s) between ways",
            self.scenario,
            self.ways.first().map(|w| w.transcript.len()).unwrap_or(0),
            self.ways.iter().map(|w| w.way.as_str()).collect::<Vec<_>>().join(", "),
            self.ways.iter().map(|w| w.failures.len()).sum::<usize>(),
            self.differences.len()
        )
    }
}

async fn run_way(scenario: &Scenario, way: &dyn Way) -> WayResult {
    let subject = format!("profile:{}:{}:{}", scenario.name, way.name(), uuid::Uuid::new_v4().simple());
    let mut names: BTreeMap<String, String> = BTreeMap::new();
    let mut out = WayResult { way: way.name(), transcript: vec![], failures: vec![] };
    for (i, step) in scenario.steps.iter().enumerate() {
        let n = i + 1;
        let id_of = |name: &str| names.get(name).cloned().unwrap_or_default();
        let name_of = |id: &str| names.iter().find(|(_, v)| v.as_str() == id).map(|(k, _)| k.clone());
        let (op, body) = if let Some(r) = &step.remember {
            let mut b = json!({ "subject": subject, "content": r.content, "wait": true });
            if let Some(k) = &r.kind {
                b["kind"] = json!(k);
            }
            ("remember", b)
        } else if let Some(r) = &step.recall {
            ("recall", json!({ "subject": subject, "query": r.query, "k": r.k.unwrap_or(10) }))
        } else if let Some(r) = &step.revise {
            ("revise", json!({ "id": id_of(&r.id), "content": r.content, "wait": true }))
        } else if let Some(f) = &step.forget {
            ("forget", json!({ "id": id_of(&f.id) }))
        } else if let Some(g) = &step.ingest {
            ("ingest", json!({ "subject": subject, "session_id": g.session, "messages": g.messages, "wait": true }))
        } else {
            continue;
        };
        let v = match way.call(op, body).await {
            Ok(v) => v,
            Err(e) => {
                out.transcript.push(format!("{op}: failed"));
                out.failures.push(format!("step {n} ({op}): {e:#}"));
                continue;
            }
        };
        let ex = &step.expect;
        let mut miss = |what: String| out.failures.push(format!("step {n} ({op}): {what}"));
        let line = match op {
            "remember" | "revise" => {
                let status = v["status"].as_str().unwrap_or("?").to_string();
                let dedup = v["deduplicated"].as_bool().unwrap_or(false);
                let superseded = v["superseded"].as_str().map(|id| name_of(id).unwrap_or_else(|| "an unnamed record".into()));
                if let (Some(name), Some(id)) = (&step.save, v["id"].as_str()) {
                    names.insert(name.clone(), id.to_string());
                }
                if ex.status.as_ref().is_some_and(|s| *s != status) {
                    miss(format!("status {status}, expected {}", ex.status.clone().unwrap_or_default()));
                }
                if ex.deduplicated.is_some_and(|d| d != dedup) {
                    miss(format!("deduplicated {dedup}, expected {}", !dedup));
                }
                if ex.superseded.is_some() && ex.superseded != superseded {
                    miss(format!("superseded {superseded:?}, expected {:?}", ex.superseded));
                }
                format!("{op}: status={status} deduplicated={dedup} superseded={}", superseded.unwrap_or_else(|| "none".into()))
            }
            "recall" => {
                let hits: Vec<(String, String)> = v["hits"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|h| (h["memory"]["id"].as_str().unwrap_or_default().to_string(), h["memory"]["content"].as_str().unwrap_or_default().to_string()))
                    .collect();
                let shown: Vec<String> = hits.iter().map(|(id, content)| name_of(id).unwrap_or_else(|| format!("\"{content}\""))).collect();
                if let Some(first) = &ex.first {
                    if hits.first().map(|(id, _)| id.as_str()) != Some(id_of(first).as_str()) {
                        miss(format!("the first hit is {}, expected {first}", shown.first().cloned().unwrap_or_else(|| "nothing".into())));
                    }
                }
                for name in &ex.contains {
                    if !hits.iter().any(|(id, _)| *id == id_of(name)) {
                        miss(format!("{name} is not among the hits ({})", shown.join(", ")));
                    }
                }
                for name in &ex.excludes {
                    if hits.iter().any(|(id, _)| *id == id_of(name)) {
                        miss(format!("{name} is among the hits, and must not be"));
                    }
                }
                if let Some(text) = &ex.contains_text {
                    if !hits.iter().any(|(_, c)| c.contains(text.as_str())) {
                        miss(format!("no hit contains \"{text}\" ({})", shown.join(", ")));
                    }
                }
                format!("recall: hits=[{}]", shown.join(", "))
            }
            "forget" => {
                let deleted = v["deleted"].as_u64().unwrap_or(0);
                if ex.deleted.is_some_and(|d| d != deleted) {
                    miss(format!("deleted {deleted}, expected {}", ex.deleted.unwrap_or(0)));
                }
                format!("forget: deleted={deleted}")
            }
            _ => {
                let stored = v["stored"].as_u64().unwrap_or(0);
                if let (Some(name), Some(id)) = (&step.save, v["ids"][0].as_str()) {
                    names.insert(name.clone(), id.to_string());
                }
                if ex.stored.is_some_and(|s| s != stored) {
                    miss(format!("stored {stored} rounds, expected {}", ex.stored.unwrap_or(0)));
                }
                format!("ingest: stored={stored} quarantined={} deduplicated={}", v["quarantined"].as_u64().unwrap_or(0), v["deduplicated"].as_u64().unwrap_or(0))
            }
        };
        out.transcript.push(line);
    }
    // The way's subject is erased afterwards where the way can do it; a failure is not scored.
    let _ = way.call("forget", json!({ "subject": subject })).await;
    out
}

/// Run `scenario` through every way, each on a subject of its own, and compare the outcomes.
pub async fn run_profile_suite(scenario: &Scenario, ways: &[&dyn Way]) -> ProfileReport {
    let mut results = vec![];
    for w in ways {
        results.push(run_way(scenario, *w).await);
    }
    let mut differences = vec![];
    if let Some(reference) = results.first() {
        for other in &results[1..] {
            for (i, (a, b)) in reference.transcript.iter().zip(&other.transcript).enumerate() {
                if a != b {
                    differences.push(format!("step {}: {} gave `{a}`, {} gave `{b}`", i + 1, reference.way, other.way));
                }
            }
            if reference.transcript.len() != other.transcript.len() {
                differences.push(format!("{} ran {} steps, {} ran {}", reference.way, reference.transcript.len(), other.way, other.transcript.len()));
            }
        }
    }
    ProfileReport { scenario: scenario.name.clone(), ways: results, differences }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// A way with a tiny memory of its own; `forgetful` drops nothing on forget.
    struct Toy {
        name: &'static str,
        forgetful: bool,
        records: Mutex<Vec<(String, String, String)>>,
    }

    impl Toy {
        fn new(name: &'static str, forgetful: bool) -> Toy {
            Toy { name, forgetful, records: Mutex::new(vec![]) }
        }
    }

    #[async_trait::async_trait]
    impl Way for Toy {
        fn name(&self) -> String {
            self.name.into()
        }
        async fn call(&self, op: &str, body: Value) -> anyhow::Result<Value> {
            let mut recs = self.records.lock().unwrap();
            let text = |k: &str| body[k].as_str().unwrap_or_default().to_string();
            Ok(match op {
                "remember" => {
                    let id = uuid::Uuid::new_v4().to_string();
                    recs.push((id.clone(), text("subject"), text("content")));
                    json!({ "id": id, "status": "committed", "deduplicated": false })
                }
                "recall" => {
                    let word = text("query").split(' ').next().unwrap_or_default().to_lowercase();
                    let hits: Vec<Value> = recs.iter().filter(|r| r.1 == text("subject") && r.2.to_lowercase().contains(&word)).map(|r| json!({ "memory": { "id": r.0, "content": r.2 } })).collect();
                    json!({ "hits": hits })
                }
                "forget" => {
                    let before = recs.len();
                    if !self.forgetful {
                        recs.retain(|r| r.0 != text("id"));
                    }
                    json!({ "deleted": if self.forgetful { 1 } else { before - recs.len() } })
                }
                other => anyhow::bail!("the toy has no {other}"),
            })
        }
    }

    const SMALL: &str = r#"
name: small
steps:
  - remember: {content: "Docks: the warehouse has four."}
    save: docks
    expect: {status: committed}
  - recall: {query: "docks"}
    expect: {first: docks}
  - forget: {id: docks}
    expect: {deleted: 1}
  - recall: {query: "docks"}
    expect: {excludes: [docks]}
"#;

    #[tokio::test]
    async fn ways_that_agree_pass_and_one_that_differs_is_named() {
        let s = Scenario::parse(SMALL).unwrap();
        let (a, b) = (Toy::new("one", false), Toy::new("two", false));
        let ok = run_profile_suite(&s, &[&a, &b]).await;
        assert!(ok.passed(), "{}", ok.failure_text());
        let (a, c) = (Toy::new("one", false), Toy::new("three", true));
        let bad = run_profile_suite(&s, &[&a, &c]).await;
        assert!(!bad.passed());
        let text = bad.failure_text();
        assert!(text.contains("three: step 4 (recall): docks is among the hits, and must not be"), "{text}");
        assert!(text.contains("step 4: one gave `recall: hits=[]`, three gave `recall: hits=[docks]`"), "{text}");
    }

    #[test]
    fn the_basic_scenario_parses_and_a_scenario_must_be_consistent() {
        let s = Scenario::parse(BASIC).unwrap();
        assert!(s.steps.len() >= 10);
        let unknown = "name: x\nsteps:\n  - forget: {id: nobody}\n";
        assert!(Scenario::parse(unknown).unwrap_err().to_string().contains("\"nobody\" was not saved"));
        let two = "name: x\nsteps:\n  - remember: {content: a}\n    recall: {query: a}\n";
        assert!(Scenario::parse(two).unwrap_err().to_string().contains("exactly one of"));
    }
}
