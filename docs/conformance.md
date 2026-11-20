<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Conformance kits

MemHouse's engine talks to the outside through a few interfaces: a store, an intake queue, an
embedder, a reranker, a chat model and an authorizer. An **adapter** is an implementation of one
of them. A **conformance kit** is a reusable test suite for one adapter type: an adapter that
passes its kit can replace the default one without a change to the engine (requirements
TR-CORE-02 and DEP-02). The **profile suite** checks the other direction: that every way into a
deployment (REST, MCP, the command line) gives the same outcomes, because one engine answers
behind each (PROF-01, TR-CORE-01).

The kits are the crate `memhouse-conformance`. The Postgres profile runs all of them in the
governance suite, in CI.

## The kits

Each kit is one function that takes the adapter and returns a report. It never panics on a
faulty adapter: an error or a wrong answer is a failed check that says what was expected and
what the adapter did.

| Adapter | Interface | Kit | What it checks |
|---|---|---|---|
| Store | `memhouse_core::Store` | `run_store_kit(store)` | migration is repeatable; a write reads back; an exact duplicate is not stored twice; keyword and vector search; subjects and tenants are isolated; a revision keeps the old version, superseded and linked; held candidates are hidden; denied labels are filtered inside the store; **deleting a round deletes the facts extracted from it**; erasing a subject removes its records, derived facts and queued extraction jobs; the audit chain verifies; the embedding cache and idempotency keys round-trip |
| Intake queue | `memhouse_core::traits::IntakeQueue` | `run_intake_queue_kit(queue)` | a queued record reads back as a candidate, in its tenant only; a subject's proposals are handed out one at a time and in order; leased work is not handed out twice, and other subjects are not blocked; a failed attempt is retried; a finished proposal keeps its outcome; an expired lease is taken over, and the stale worker's report changes nothing; a poison proposal is set aside; erasure drops queued writes; pruning removes only finished proposals |
| Embedder | `memhouse_core::Embedder` | `run_embedder_kit(&embedder)` | vectors of the declared size, finite and not zero; one per text, in order; the same text gives the same vector, alone or in a batch; a paraphrase is closer than an unrelated text; a question is closer to the passage that answers it; no text gives no vectors |
| Reranker | `memhouse_core::Reranker` | `run_reranker_kit(&reranker)` | one finite score per document, following the documents' order; the document that answers the query scores highest; the same input gives the same scores; no documents give no scores |
| Chat model | `memhouse_core::ChatModel` | `run_chat_kit(&model)` | a stable id; an answer to a plain instruction, in the JSON format asked for; consistent usage (a cost is never negative) |
| Authorizer | `memhouse_core::access::Authorizer` | `run_authorizer_kit(&authorizer)` | fail closed: a request with no operation, a credential with no permission, another tenant, a subject outside the principal's, and a write with a denied label are all refused; a read-only credential cannot write; a decision always runs in the principal's own tenant; denied labels reach the decision; a request cannot widen the caller's scope; the same request gets the same decision; a denial says why |

```rust
use std::sync::Arc;

#[tokio::test]
async fn my_store_conforms() {
    let store = Arc::new(MyStore::connect_to_an_empty_test_database().await.unwrap());
    memhouse_conformance::run_store_kit(store).await.assert_passed();
}
```

`assert_passed` panics with one line per failed check:

```text
store kit, store under test: delete_cascades_to_derived_facts: expected: deleting a conversation
round also deletes the facts extracted from it; found: after the round was deleted, 1 fact(s)
extracted from it are still stored (["We adopted a kitten called Marzipan last weekend."]) and a
recall returns 1 hit(s)
```

Notes for adapter authors:

- **Give the store kit a fresh, empty store** (a test database). It migrates the store for a
  64-dimension stand-in embedder and writes into tenants of its own; the intake-queue kit
  prunes finished proposals of every tenant. Neither is for a production database.
- Most of the store kit drives the real engine over your store, with a deterministic embedder
  and fact extractor (`memhouse_conformance::fakes`), so it tests the store the way it is
  used. A store without an intake queue, or without a claim of one subject's extraction jobs
  (`Store::enrich_claim_for`), fails the checks that need them.
- The model kits call the model: the embedder and reranker kits a handful of times, the chat
  kit once. With a paid model that is a paid call.
- The authorizer kit builds its own principals in the tenant `kit-tenant`, allowed the subjects
  `kit:*`. An authorizer that decides from stored relationships must allow those for the agent
  `agent:kit` and the user `user:kit-ana` before the kit runs.

## The profile suite

A **scenario** is a YAML file of steps. Each step is one of five operations that every way in
offers (`remember`, `recall`, `revise`, `forget`, `ingest`), with the outcome it must have:

```yaml
name: basic
steps:
  - remember: {content: "The warehouse in Tallinn has four loading docks."}
    save: docks
    expect: {status: committed, deduplicated: false}
  - remember: {content: "We plan to open a second warehouse in Riga next year."}
    save: plan
    expect: {status: candidate}
  - recall: {query: "How many loading docks does the Tallinn warehouse have?"}
    expect: {first: docks, excludes: [plan]}
  - revise: {id: docks, content: "The warehouse in Tallinn has six loading docks."}
    save: docks2
    expect: {status: committed, superseded: docks}
```

`save` names the record a step stores; later steps refer to it by that name. `expect` may give
`status`, `deduplicated`, `superseded`, a recall's `first` hit, hits it `contains` or
`excludes`, a `contains_text`, the rounds an ingest `stored`, and how many records a forget
`deleted`. The built-in scenario is
[`crates/memhouse-conformance/scenarios/basic.yaml`](../crates/memhouse-conformance/scenarios/basic.yaml):
a write, its exact duplicate, a preference, a held plan, a revision, an injection attempt that
must be quarantined and never recalled, an ingested conversation, and a deletion.

`run_profile_suite(&scenario, &ways)` runs the scenario through each **way**, each on a subject
of its own, and requires two things: every way meets every expectation, and all ways give the
same outcome at every step (ids replaced by their saved names). Three ways are built in:

| Way | How it calls |
|---|---|
| `Rest` | `POST {base}/v1/{operation}` with a bearer key |
| `Mcp` | `tools/call` at `{base}/mcp` with a bearer key, reading the tool's structured result |
| `Cli` | the `memhouse` binary with a configuration file (`remember`, `recall --json`, `revise --json`, `forget --json`, `ingest --json`) |

An SDK adds its own way by implementing the `Way` trait (one method: carry out an operation
with a JSON request and return the JSON response). The Lite profile (G16) and the SDKs (G17)
are run through the same scenario.

## Where they run

`memhouse bench run --suite governance` runs two checks with the kits:

- `adapter_conformance`: the Postgres store and its intake queue on an empty database, the
  configured embedder (and reranker, when one is enabled), the default authorizer, and the
  chat kit with a stand-in model (no external chat model is called; the embedder kit does call the
  configured embedder, which is a paid call when that is a paid API). Then the same store on a
  database where deleting an extracted fact silently does nothing: the store kit must fail and
  name the dropped cascade.
- `profile_conformance`: the basic scenario through REST, MCP and the command line against one
  Postgres deployment.

Hosted CI runs the governance suite on every pull request, so both run there.
