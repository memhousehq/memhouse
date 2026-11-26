// SPDX-License-Identifier: Apache-2.0
//! The profile scenario through the SDKs and the framework adapters (roadmap G18): REST as the
//! reference, then the Python and the TypeScript SDK and the adapters for the OpenAI Agents SDK
//! and LangGraph, each driven through its conformance driver (`sdk/*/conformance/driver*`).
//! Every way must meet the scenario's expectations and all must give the same outcome at every
//! step.
//!
//! Ignored by default, since it needs a running deployment, Python, uv and Node:
//! `scripts/sdk-conformance.sh` starts a throwaway deployment and runs it. By hand:
//!
//! ```text
//! MEMHOUSE_URL=http://127.0.0.1:7077 MEMHOUSE_API_KEY=... \
//!   cargo test -p memhouse-conformance --test sdk_profile -- --ignored --nocapture
//! ```
//!
//! - `MEMHOUSE_SDK_PYTHON` / `MEMHOUSE_SDK_NODE`: the interpreters (default `python3`, `node`).
//! - `MEMHOUSE_SDK_ADAPTER_PYTHON`: the Python the adapters run on, a version or an interpreter
//!   (default `3.12`; the frameworks need 3.10 or newer). `uv` builds their environment from
//!   the SDK's lock file with both extras, in `target/sdk-adapters-venv`.
//! - `MEMHOUSE_SDK_EMBEDDED=<directory>`: run the SDKs over their embedded Lite transport
//!   instead, each on a database file of its own in that directory. No server is used, so
//!   there is no REST way: the two SDKs are compared with each other. The interpreters must
//!   have the bindings installed (`memhouse-lite`, `@memhouse/lite`). The adapters are not
//!   part of this run: they are wiring over the SDK's client, whatever its transport.

use memhouse_conformance::profile::{run_profile_suite, Process, Rest, Scenario, Way, BASIC};
use std::path::{Path, PathBuf};

fn var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().expect("the repository root")
}

fn python(root: &Path) -> Process {
    // The SDK has no dependencies: its source directory on the path is an installation.
    let source = root.join("sdk/python/src");
    let path = match var("PYTHONPATH") {
        Some(rest) => format!("{}:{rest}", source.display()),
        None => source.display().to_string(),
    };
    Process::new("python-sdk", var("MEMHOUSE_SDK_PYTHON").unwrap_or_else(|| "python3".into()))
        .arg(root.join("sdk/python/conformance/driver.py").display().to_string())
        .env("PYTHONPATH", path)
}

fn node(root: &Path) -> Process {
    assert!(root.join("sdk/typescript/dist/index.js").is_file(), "the TypeScript SDK is not built: run `pnpm install && pnpm build` in sdk/typescript");
    Process::new("typescript-sdk", var("MEMHOUSE_SDK_NODE").unwrap_or_else(|| "node".into())).arg(root.join("sdk/typescript/conformance/driver.mjs").display().to_string())
}

/// A framework adapter of the Python SDK: `driver_<framework>.py`, run by `uv` in an environment
/// that has the SDK with both framework extras, as its lock file pins them.
fn adapter(root: &Path, name: &str, driver: &str) -> Process {
    let project = root.join("sdk/python");
    let mut way = Process::new(name, "uv").env("UV_PROJECT_ENVIRONMENT", root.join("target/sdk-adapters-venv").display().to_string());
    let python = var("MEMHOUSE_SDK_ADAPTER_PYTHON").unwrap_or_else(|| "3.12".into());
    for arg in ["run", "--project", &project.display().to_string(), "--python", &python, "--extra", "openai-agents", "--extra", "langgraph", "--locked", "python"] {
        way = way.arg(arg);
    }
    // The first call may have to download the frameworks and build the environment.
    way.arg(project.join("conformance").join(driver).display().to_string()).timeout(std::time::Duration::from_secs(600))
}

#[tokio::test]
#[ignore = "needs a running deployment (MEMHOUSE_URL, MEMHOUSE_API_KEY), Python, uv and Node: scripts/sdk-conformance.sh"]
async fn the_profile_scenario_gives_the_same_outcomes_through_rest_the_sdks_and_the_adapters() {
    let root = repository();
    let scenario = Scenario::parse(BASIC).unwrap();
    let report = if let Some(dir) = var("MEMHOUSE_SDK_EMBEDDED") {
        let file = |name: &str| Path::new(&dir).join(name).display().to_string();
        // The engine opens its models when the first call arrives: allow for a cold start.
        let slow = std::time::Duration::from_secs(300);
        let (py, js) = (python(&root).env("MEMHOUSE_EMBEDDED", file("python.db")).timeout(slow), node(&root).env("MEMHOUSE_EMBEDDED", file("typescript.db")).timeout(slow));
        let ways: [&dyn Way; 2] = [&py, &js];
        run_profile_suite(&scenario, &ways).await
    } else {
        let url = var("MEMHOUSE_URL").expect("MEMHOUSE_URL: the deployment to test");
        let key = var("MEMHOUSE_API_KEY").expect("MEMHOUSE_API_KEY: a key of that deployment");
        // The drivers read the same two variables from the environment they inherit.
        let (rest, py, js) = (Rest::new(&url, &key), python(&root), node(&root));
        let (agents, langgraph) = (adapter(&root, "openai-agents-adapter", "driver_openai_agents.py"), adapter(&root, "langgraph-adapter", "driver_langgraph.py"));
        let ways: [&dyn Way; 5] = [&rest, &py, &js, &agents, &langgraph];
        run_profile_suite(&scenario, &ways).await
    };
    for way in &report.ways {
        println!("{}: {} steps, {} unmet expectation(s)", way.way, way.transcript.len(), way.failures.len());
        for (i, line) in way.transcript.iter().enumerate() {
            println!("  {:>2}. {line}", i + 1);
        }
    }
    println!("{}", report.summary());
    assert!(report.passed(), "{}", report.failure_text());
}
