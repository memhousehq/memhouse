// SPDX-License-Identifier: Apache-2.0
//! Conformance kits (TR-CORE-02, DEP-02): one reusable test suite per adapter type, and the
//! profile conformance suite (PROF-01).
//!
//! An adapter is an implementation of one of the interfaces in [`memhouse_core::traits`] (or
//! [`memhouse_core::access::Authorizer`]). The engine is written against those interfaces
//! alone, so an adapter that passes its kit can replace the default without a change to the
//! engine. Each kit is one function that takes the adapter and returns a [`Report`]:
//!
//! | Adapter | Kit |
//! |---|---|
//! | store | [`run_store_kit`] |
//! | intake queue | [`run_intake_queue_kit`] |
//! | embedder | [`run_embedder_kit`] |
//! | reranker | [`run_reranker_kit`] |
//! | chat model | [`run_chat_kit`] |
//! | authorizer | [`run_authorizer_kit`] |
//!
//! ```ignore
//! let report = memhouse_conformance::run_store_kit(Arc::new(my_store)).await;
//! report.assert_passed(); // panics with every failed check and what it saw
//! ```
//!
//! The profile suite ([`profile`]) runs one scenario file through each way into a deployment
//! (REST, MCP, the command line) and requires the same outcomes from all of them.
//!
//! A kit never panics on a failing adapter: an error or a wrong answer is a failed check with
//! a message that says what was expected and what the adapter did.

mod authorizer;
pub mod fakes;
mod models;
pub mod profile;
mod queue;
mod store;

pub use authorizer::run_authorizer_kit;
pub use models::{run_chat_kit, run_embedder_kit, run_reranker_kit};
pub use queue::run_intake_queue_kit;
pub use store::{run_store_kit, DIM as STORE_KIT_DIM};

use serde::Serialize;

/// One property a kit checked.
#[derive(Debug, Clone, Serialize)]
pub struct Check {
    /// A short stable name, e.g. `delete_cascades_to_derived_facts`.
    pub name: String,
    pub passed: bool,
    /// What the contract asks for, in one sentence.
    pub expects: String,
    /// What the adapter did, when it failed (empty when it passed).
    pub found: String,
}

/// The outcome of one kit for one adapter.
#[derive(Debug, Clone, Serialize)]
pub struct Report {
    /// The adapter type: `store`, `embedder`, ...
    pub kit: String,
    /// The adapter's own name or id.
    pub adapter: String,
    pub checks: Vec<Check>,
}

impl Report {
    pub(crate) fn new(kit: &str, adapter: &str) -> Report {
        Report { kit: kit.into(), adapter: adapter.into(), checks: vec![] }
    }

    /// Record a check: `found` is `None` when it passed, else what the adapter did.
    pub(crate) fn check(&mut self, name: &str, expects: &str, found: Option<String>) {
        self.checks.push(Check { name: name.into(), passed: found.is_none(), expects: expects.into(), found: found.unwrap_or_default() });
    }

    /// Record a check whose evaluation may itself fail: an error is a failed check.
    pub(crate) fn outcome(&mut self, name: &str, expects: &str, r: anyhow::Result<Option<String>>) {
        let found = match r {
            Ok(f) => f,
            Err(e) => Some(format!("the adapter returned an error: {e:#}")),
        };
        self.check(name, expects, found);
    }

    pub fn passed(&self) -> bool {
        !self.checks.is_empty() && self.checks.iter().all(|c| c.passed)
    }

    pub fn failures(&self) -> Vec<&Check> {
        self.checks.iter().filter(|c| !c.passed).collect()
    }

    /// One line per failed check: `store kit, <adapter>: <name>: expected <...>; found <...>`.
    pub fn failure_text(&self) -> String {
        self.failures().iter().map(|c| format!("{} kit, {}: {}: expected: {}; found: {}", self.kit, self.adapter, c.name, c.expects, c.found)).collect::<Vec<_>>().join("\n")
    }

    /// For tests: panic with [`Report::failure_text`] unless every check passed.
    pub fn assert_passed(&self) {
        assert!(self.passed(), "{}", if self.checks.is_empty() { format!("{} kit, {}: no check ran", self.kit, self.adapter) } else { self.failure_text() });
    }

    /// `12 of 12` style summary.
    pub fn summary(&self) -> String {
        format!("{} kit, {}: {} of {} checks passed", self.kit, self.adapter, self.checks.iter().filter(|c| c.passed).count(), self.checks.len())
    }
}

/// `Some(message)` unless `ok`.
pub(crate) fn unless(ok: bool, found: impl FnOnce() -> String) -> Option<String> {
    (!ok).then(found)
}
