# MemHouse agent contract

Applies to the repository unless a nested `AGENTS.md` overrides it. MemHouse
is a `0.4.0` community beta. The old `F0`–`F11` phase names are retired.

## Before editing

The source and its tests are the specification of current behavior. Read them
first, in this order:

1. This file.
2. The modules the task touches, and their tests.
3. The affected page under `docs/` for anything users or operators can see.

Read a document under `specs/` only for what the code cannot tell you:

| Question | Read |
| --- | --- |
| Why was this decided, and what lost? | The closest `specs/adr/` record |
| What is still unbuilt, and in what order? | `specs/roadmap/beta-roadmap.md` |
| Where are the module boundaries? | `specs/architecture/free-core-architecture.md` |
| What blocks a release? | `specs/process/`, `specs/eval/` |

Never treat a document as authoritative over the code it describes. If the two
disagree, the code is right and the document is a bug.

## Writing style

Use ASD-STE100 Simplified Technical English.

Write for a busy reader.

- Lead with the point. Use short sentences and short paragraphs.
- Keep one fact in one place. Link to detail instead of repeating it.
- Delete throat-clearing, recap sections, repeated warnings, and obvious text.
- Use headings for navigation, not as a substitute for clear prose.
- Prefer a small table for repeated mappings; prefer prose for a simple idea.
- Keep examples task-focused. Do not explain every line of an example.
- Define an unfamiliar term once, then use it consistently.
- Preserve necessary precision: commands, units, defaults, failure modes,
  invariants, security boundaries, and contract identities.
- Do not add `TL;DR` sections. Make the page itself easy to scan.

For source comments and docstrings:

- Explain a non-obvious reason, invariant, boundary, or failure mode.
- Never narrate the code or restate a name or type.
- Keep module docs to purpose, ownership, key guarantees, and caller traps.
- Keep public function docs to purpose, non-obvious inputs, return shape, and
  failures. Omit details already clear from the signature.
- Give constants a unit and a brief reason when the value is not self-evident.
- Delete stale, redundant, speculative, and purely historical commentary.
- Do not point to a spec for understanding. State the rule where code enforces
  it. Specs and PRs carry traceability; source stands on its own.

## Prime directive

> One codebase, two deployment modes, identical guarantees.

Single-node and queue mode run the same Mix release and behavior. Runtime
adapters may differ; product semantics may not. The community build must remain
coherent without enterprise code.

## Product invariants

1. Context flows down freely; knowledge flows up only through Gate B.
2. Agents submit raw observations; only the pipeline writes knowledge.
3. Wider visibility requires more confidence, sensitivity care, and consent.
4. Knowledge is the atom; profiles, scope cards, and summaries are projections.
5. Reasoned artifacts pass gates; authored artifacts use plain versioning.
6. Belief-time, valid-time, and salience are independent. Confidence,
   sensitivity, subject, and source are also independent.
7. Scoped values inherit down the containment tree; nearest wins.
8. Account isolation is absolute. Identity determines Account.
9. Users own their data and keys; core must not require a managed service.
10. Raw messages, governed knowledge, and audit logs are durable. Queues,
    projections, indices, HNSW, ETS, and `persistent_term` are rebuildable.
11. One operation commits its state, audit, and enqueue/outbox effects together.
12. Infrastructure adapters change where work runs. Domain strategies change
    behavior and require explicit review.

## Architecture boundaries

- Runtime: Elixir/BEAM, one Mix release, no second engine runtime.
- Domain: Ash Domains, Resources, Actions, policies, and data layers.
- Surfaces: Phoenix HTTP/LiveView/Channels, AshJsonApi, gateway, and `ash_ai`
  MCP where implemented.
- Jobs: AshOban on Postgres in every mode. No Redis, BullMQ, Lite engine, or
  separate worker fleet.
- Storage: AshPostgres, pgvector, and Postgres FTS. Local mode supervises pg0;
  queue mode uses operator-run Postgres.
- Models: provider-neutral roles through ReqLLM. Keep self-hosted,
  OpenAI-compatible, and local Ortex/ONNX options possible.
- Native work: prefer the named Extractous/MDEx, `bitcrowd/rag`, and hnswlib
  integrations over bespoke infrastructure.

## Contract identities

These strings version public contracts, not roadmap phases:

| Identity | Contract |
| --- | --- |
| `poc-0` | Frozen behavior baseline and historical evaluation reports |
| `f4-1` | Governed lifecycle |
| `f5-1` | Extractor and pipeline |
| `f7-1` | Retrieval and context profiles |
| `f9-1` | Skill selectors and gap reports |
| `f10-1` | Readiness payload |
| `f11-1`, `f11-suite-1` | Evaluation report and release bundle |
| `f11-surface-contracts-1` | Surface inventory |
| `memhouse-account-1` | Logical Account archive |

A transition needs a changelog entry, updated evidence, and the closest
architecture note. Never casually rename an identity or historical artifact.

## Change discipline

- Implement only the requested scope. Do not pull in later roadmap work.
- Inspect the worktree first. Preserve unrelated and concurrent changes.
- Keep each behavior change small, with one clear home and focused tests.
- Use Ash actions for durable writes. Keep snapshots and migrations aligned via
  `mix ash.codegen`; review generated migrations and custom DDL.
- Update tests, docs, fixtures, and comments with behavior changes.
- Mark roadmap items complete only when code, evidence, and durable docs exist.
- Write an ADR when a decision closes off an alternative someone would
  otherwise re-propose. Do not write one to record what the code already says.
- Align `mix.exs`, `CHANGELOG.md`, tags, protocol/report versions, and release
  artifacts for releases.

### Documentation locations

| Location | Content |
| --- | --- |
| Source and tests | Current behavior, and the rules the system enforces |
| `docs/` | Published setup, usage, operations, and current behavior |
| `specs/` | Decisions, outstanding work, module boundaries, evaluation evidence, and process |
| `CONTRIBUTING.md` | Development workflow and review rules |
| `README.md` | Project orientation and documentation map |

Do not mix the trees. User procedures must not live only in specs or comments;
design rationale must not appear in `docs/`. Use Mermaid for useful flows. Add
every new docs page to `mkdocs.yml`; use absolute GitHub URLs when a docs page
links outside `docs/`.

`specs/` must not restate implemented behavior. A document that describes what
the code already does is drift waiting to happen: delete it and let the code
answer.

Update these together:

| Change | Required documentation |
| --- | --- |
| Route, parameter, default, response field | `docs/reference/http-api.md` and affected guide |
| Environment variable or config default | `docs/reference/configuration.md`, `.env.example` |
| Mix task or release command | `docs/reference/mix-tasks.md` |
| Install, upgrade, backup, export | Affected operations/getting-started page |
| Governance, retrieval, pipeline, documents, skills | Affected concept and architecture note |
| Contract identity | Contract reference, changelog, architecture note |
| Surface availability | Limitations and surface inventory JSON |
| Browser route, page, control, visibility | Console guide, HTTP route table, console architecture |
| Decision that rules out an alternative | `specs/adr/` only |

### Source documentation

Every first-party module needs a useful `@moduledoc`; every public function
needs `@doc`, except pure DSL or `use`-only modules. `@moduledoc false` requires
an adjacent equivalent comment when generated docs must hide the module.

Document Ash rows, internal-only actions, append/create-only rules,
multitenancy, policies, identities, Oban triggers, and hand-written RLS/index
DDL where they enforce a non-obvious guarantee. Header comments in authored
scripts, workflows, config, containers, and SDK helpers should state only
non-obvious purpose, inputs, outputs, or assumptions. Keep SPDX first.

Do not restyle generated or historical artifacts: `deps/`, generated
migrations, resource snapshots, recorded eval results, or committed JSON
fixtures. Comment new hand-written DDL inside generated migrations.

## Domain guardrails

### Baseline contract

HTTP behavior, Account selection, inheritance, raw persistence, pipeline-only
writes, lifecycle insertion, deterministic fallback, and normalized eval
fixtures must not regress. Evidence:

- `test/memhouse/poc_contract_test.exs`
- `test/memhouse_web/controllers/memory_controller_test.exs`
- `test/memhouse/eval/fixture_contract_test.exs`
- `test/fixtures/eval/poc-contract-baseline.json`

### Ash and transactions

Ten Domains and 38 Resources own durable data. Direct Repo/Ecto SQL is limited
to the documented read-only retrieval store, advisory-lock helper, and
credential bootstrap locator. New exceptions need explicit architecture work.

`MemHouse.Operations.PipelineRun` commits the observation, content-safe audit,
idempotency record, and AshOban enqueue together. Jobs need deterministic replay
keys and reconciliation. Never put content in audit metadata or job arguments.

Evidence: `test/memhouse/f1_ash_domain_backbone_test.exs`,
`test/memhouse/f2_transactional_writes_audit_jobs_test.exs`.

### Identity and governance

`MemHouse.Accounts.ApiKey` derives Account from identity. Store no plaintext
keys. Authenticated scope reads use deny-wins inherited roles through
`MemHouse.Identity.RoleResolver`. Roles are exactly `account-admin`, `curator`,
`member`, and `reader`. A cross-link grants no access.

New knowledge enters `proposed` and passes `MemHouse.Governance.Engine`.
Machine credentials and MCP cannot perform curator actions. Scope/account
proposals stay held until Gate B approval; upward personal knowledge also needs
verified subject consent. Erasure uses `MemHouse.Governance.Erasure`, preserves
content-safe audit evidence, and refreshes affected derived data.

Evidence: `test/memhouse/f3_identity_tenancy_basic_rbac_test.exs`,
`test/memhouse/f4_real_gate_a_b_governance_test.exs`.

### Models and documents

All model calls go through `MemHouse.Model.Gateway`. The four Account roles are
`embedder`, `ingest_extractor`, `dream_reasoner`, and `dialectic_agent`. Persist
secret references, model provenance, and usage through `MemHouse.Model.Usage`.
Structured output uses bounded validation/repair and still passes governance.
`get_context` stays model-free. Embeddings must match provider, model, version,
and dimensions; mismatches take the re-embed path. Deterministic fallback is
test/local only.

Connectors write immutable raw document versions, then use the ordinary
pipeline. Advance cursors only after durable handling. Repeated hashes are
no-ops; changes append and supersede; deletions tombstone. Independent
provenance survives supersession or erasure. Export blobs and metadata, not
chunks or vectors; import rebuilds derived data. Keep document content, cursors,
metadata, and secrets out of audit, telemetry, and job arguments.

Evidence: `test/memhouse/f5_model_layer_structured_extraction_test.exs`,
`test/memhouse/f6_documents_connectors_sync_test.exs`.

### Retrieval and context

`MemHouse.Retrieval.Strategy` owns retrieval;
`MemHouse.Context` owns reasoning-free projection assembly. `search` defaults
to `:balanced`, `ask` to `:thorough`; only `:fast` may run live on a projection
miss. Filter Account, authorized scopes, lifecycle, subject, and source before
candidates leave retrieval internals. Fuse incomparable strategy ranks with
weighted reciprocal-rank fusion under the remaining deadline, and report
contributed/dropped strategies.

Entities and mentions are internal rebuildable caches. Never expose their
names, aliases, ids, vectors, or chunk contents. One surface form may appear as
an entity card's label, and only when it comes from that card's own sources in
that card's own scope; `Entity.canonical_name` and `Entity.kind` are
account-global and stay unreadable. Expansion requires access to both relation
endpoints. Keep vector/FTS indices,
projections, invalidation, and erasure/import rebuilds aligned.

Evidence: `test/memhouse/f7_retrieval_entity_context_test.exs`.

### Browser console

One human password session covers `/console/*`; curator/admin roles also reach
`/governance`. Machines establish neither. `MemHouseWeb.Console.Access` owns
visibility: provisional statements are subject-only even for admins; settled
state and curator visibility follow its narrowing rules. All reads go through
`MemHouseWeb.Console.Loader` inside `DataLayer.with_actor/2`; role-only reads
are pre-gated. Writes delegate to the operation layer, which reauthorizes them.

Never expose entities, vectors, chunks, hashes, or secrets, except an entity
card's scope-local label and recomputed kind. Keep styles in
`console.css`, use no inline script/style, and render deterministic server-side
SVG without randomness or wall clock.

Evidence: `test/memhouse_web/live/console_live_test.exs`,
`test/memhouse_web/console/access_test.exs`,
`test/memhouse_web/console/graph_test.exs`.

### Skills, portability, and operations

Skill cards are authored, plain-versioned procedural memory, not gated
knowledge. Requirements inherit nearest-wins. Only authorized active or the
calling peer's usable provisional knowledge satisfies readiness. Stale or due
items remain gaps. Required gaps block; preferred gaps warn. Elicited answers
return through ingest and governance; helpers never override the server.

The same release runs supervised-pg0 and external Postgres. Pin pg0 version and
checksums; start it before Repo/migrations; never put it in the container path.
Archives use `memhouse-account-1`, stream durable resources, verify blobs and
the audit graph, exclude secrets and derived caches, require a fresh Account,
write through private Ash actions in one transaction, and enqueue replay-safe
rebuilds.

Readiness and logs may expose ids, counts, component status, model/version
identity, timings, tokens, and error classes—never content or secrets. Preserve
incoming W3C trace ids and return `x-trace-id`.

Evidence: `test/memhouse/f9_skill_readiness_procedural_memory_test.exs`,
`test/memhouse/f10_portability_packaging_operations_test.exs`.

### Evaluation and release

Application versions use SemVer; evaluation reports use `f11-1`.
`MemHouse.ReleaseReadiness` is the one fail-closed release-readiness gate, run
by `mix memhouse.release.check`. Deterministic guardrails, both Postgres lanes,
builds, version/changelog checks, provenance, and committed correctness and
citation floors block a release. Public claims need
exact application/profile/model versions, dataset id/hash/split, deadline,
date, judge, strategy override, and run limits. Tune fusion only on held-out
data. Quality, latency, token, and degradation frontiers are not gates without
an explicit threshold change.

Integration surfaces, gateway, and generated SDKs are not implemented. Keep
them unavailable in `specs/eval/surface-contract-inventory.json`.

Evidence: `test/memhouse/f11_evaluation_ci_release_readiness_test.exs`.

## Licensing

- Community/core uses `LICENSE.md` and SPDX
  `MemHouse-Sustainable-Use-1.0` where comments are supported.
- Enterprise uses `LICENSE_EE.md`, lives under `ee` or in `.ee.` files, and uses
  SPDX `MemHouse-Enterprise`.
- Do not move behavior across the boundary or change entitlements without an
  explicit human decision. Core cannot import enterprise modules.
- Gate scale, operations, compliance, and support—not core answer quality.
- Never alter license notices. Vendored code keeps upstream licenses.

## Checks

Run and report applicable checks honestly.

```bash
git status --short
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Run `mix credo --strict`, `mix dialyzer`, and `mix sobelow --config` when the
area warrants them. For evaluation/release work also run:

```bash
mix memhouse.eval.release --no-model --assert-thresholds \
  --output /private/tmp/memhouse-release-eval.json
mix memhouse.release.check \
  --eval-report /private/tmp/memhouse-release-eval.json
```

For `docs/` or `mkdocs.yml` changes:

```bash
pip install -r docs/requirements.txt
mkdocs build
```

The pg0 lane is `scripts/ci-pg0-lane` and requires network access. Database-mode
changes need parity evidence. If a check is unavailable, say so.

## Delivery and review

Use one task, branch, and PR. Start from current `main`; keep humans as the
merge gate. The PR states scope, reason, the tests that prove it, real check
results, and deliberate limitations. Do not claim repository settings from
workflow files alone.

Before delivery, confirm the change preserves Account isolation, inheritance,
governed promotion, pipeline-only writes, durable/cache separation,
transactional effects, deployment parity, provider neutrality, license
boundaries, concise self-contained source documentation, and aligned user docs.

Do not add defensive `try`/`catch` wrappers around imports or aliases; fix the
dependency or configuration. Do not rename historical migrations, snapshots,
pipeline defaults, recorded `poc-0` reports, evidence test paths, or live
defaults as incidental cleanup.
