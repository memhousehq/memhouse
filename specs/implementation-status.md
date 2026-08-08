<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Implementation Status

Application version: `0.4.0` (community beta).
Last verified: 2026-07-28.

Current behavior, evidence, and real limitations. Target architecture:
`specs/architecture/free-core-architecture.md`. Outstanding work:
`specs/roadmap/beta-roadmap.md`.

The memory engine, governance, retrieval, documents, packaging, and release
machinery are implemented. Integration surfaces, gateway, and generated SDKs
are not.

## What runs today

### Domain and data boundary

- Ten configured Ash Domains and a 38-Resource durable boundary carry every
  durable write. There is no durable write outside an Ash action.
- Generated AshPostgres migrations and resource snapshots, plus reviewed custom
  DDL for pgcrypto, pgvector, PostgreSQL full-text search, indexes, and
  row-level security.
- Message and document-version content is create-only; knowledge statements can
  only be minted or merged by a pipeline actor; lifecycle, audit, and usage
  records are append-only.
- PostgreSQL RLS on every Account-scoped table, enforced alongside Ash
  actor/tenant policies. Every deployment mode connects as a provisioned
  `NOSUPERUSER NOBYPASSRLS` role (`MemHouse.Database.AppRole`) rather than the
  bootstrap superuser, and a startup guard refuses to serve traffic otherwise
  — see `ADR-0008` (issue #55: this was previously inert everywhere, because
  PostgreSQL exempts superusers from RLS regardless of `FORCE`).

Details: `specs/architecture/ash-domain-backbone.md`.

### Transactional writes, audit, and jobs

- Every message and document ingest commits its raw observation, an immutable
  content-safe hash-chain audit event, a durable idempotency record, and its
  AshOban job in one Postgres transaction. A failure after enqueue rolls the
  whole operation back.
- Eleven AshOban lanes cover extraction, dream-time, revalidation, expiry,
  projection and entity refresh, connector sync, portability rebuild,
  reconciliation, and governance continuations.
- An hourly Oban Cron entry starts the community Account's expiry and
  revalidation runs. Their replay keys use the Cron slot, so retries reuse the
  same durable work. `GET /api/ready` reports each sweep's last completion.
- Ash.Reactor flows own ingest extraction, dream-time reasoning, and transcript
  answer correlation. Legacy validation-continuation jobs remain executable so
  upgrades can drain them, but current gate decisions create validation rows
  inline and do not enqueue that no-op lane.
- Deterministic idempotency keys and Account-local advisory locks make replays
  safe: a replay merges attribution and provenance instead of duplicating
  knowledge.
- Per-Account SHA-256 audit chains, plus an Account-scoped reconciler for raw
  messages, document versions, and due connectors that committed but were not
  processed.
- The raw write and the job commit before any model call, so a provider outage
  delays freshness rather than losing observations.
- HTTP and MCP ingest return an accepted message id without running extraction.
  The HTTP status read reports pending, failed, or completed state through the
  Message's Account and scope policies. Account administrators can enqueue the
  reconciler without creating another observation.

Details: `specs/architecture/transactional-writes-audit-jobs.md`.

### Identity, tenancy, and RBAC

- AshAuthentication password/JWT identities for humans and hashed API-key
  identities for agents, linked to Peers with assurance levels. Only hashes are
  stored.
- Account is derived from the authenticated identity on every surface. Account
  headers and Account fields in request bodies do not select tenancy.
- One authenticated community Account, enforced by a database free-edition
  slot, with an explicit migration path to later enterprise multi-Account
  enablement.
- Inherited allow/deny role grants for `account-admin`, `curator`, `member`,
  and `reader`, resolved deny-wins down the scope tree with per-grant
  propagation. Cross-linked scope reads require access to both endpoints.
- Unknown or foreign identifiers return non-leaking failures, notably for peer
  inline validation ids.

Details: `specs/architecture/identity-tenancy-rbac.md`.

### Gate A/B governance

- A versioned Account/scope gate matrix over derived source evidence, target level, and
  sensitivity decides whether Gate A keeps, rejects, or defers an item and
  whether Gate B may place it at the requested blast radius. Model confidence
  is recorded but cannot auto-keep; personal and restricted knowledge require
  human placement.
- The conservative default is peer-level provisional visibility plus human
  review. Pending scope- and account-level knowledge stays held and never
  reaches retrieval.
- Upward personal attribution additionally requires target-specific, verified
  subject consent; curator approval cannot substitute for it.
- Password-session-only LiveView queue for approve, edit-as-replacement,
  reject, merge, defer, bulk actions, provenance, and conflict bundles.
  Machine credentials and MCP cannot reach any of it.
- Peer self-view, contest/redact, proportionate and strict erasure, affected
  projection and entity recomputation, revalidation timers, confidence decay,
  pending aging, escalation, and stale auto-rejection.
- Governance history and the audit chain store content-safe identifiers and
  hashes; knowledge text is never copied into telemetry or job arguments.

Details: `specs/architecture/gate-a-b-governance.md`.

### Model layer and structured extraction

- One provider-neutral gateway over ReqLLM with four Account-level roles:
  `embedder`, `ingest_extractor`, `dream_reasoner`, and `dialectic_agent`.
  Only secret references are persisted.
- Local Ortex/ONNX `AshAi.EmbeddingModel` by default plus an API embedding
  adapter. Embedding identity is provider, model, version, and dimensions; a
  mismatch takes the explicit re-embed path and never silently substitutes
  vectors.
- Ash-derived structured extraction and reasoning schemas with bounded
  validate-and-repair. Extraction resolves subject independently of source,
  discounts third-party claims, and proposes confidence, sensitivity, target, and temporal
  fields plus an update operation.
- Message extraction reads a trailing six-message window in the same session
  and scope. Candidate source ids are limited to that window and become durable
  provenance rows.
- Complete model provenance — provider, model, version, prompt version,
  pipeline version, embedding model and version — and one durable usage ledger
  for tokens, embeddings, latency, role, Account, and scope.
- Provider failure keeps raw observations durable and jobs retryable.
  `get_context` remains model-free.
- The deterministic adapter is an explicit test/local fallback only; production
  never falls back to it after a provider error.

Details: `specs/architecture/model-layer-structured-extraction.md`.

### Documents, connectors, and sync

- Immutable hash-addressed document versions with content-addressed Local or
  S3-compatible blob storage.
- MDEx for Markdown and ExtractousEx for supported binary formats, then
  TextChunker chunking and `bitcrowd/rag` embedding with pinned embedder
  identity.
- Dual ingest: chunk and embed for retrieval, and extract knowledge through the
  same structured pipeline and Gate A/B governance.
- Incremental connector scheduling with durable cursors that advance only after
  a page is durably handled, hash-based no-op detection, tombstones for remote
  deletion, and provenance-preserving supersession that never overwrites
  history or retracts knowledge with surviving independent provenance.
- Checksum-verified document export/import and erasure that rebuild derived
  chunks instead of treating caches as durable state.

Details: `specs/architecture/documents-connectors-sync.md`.

### Retrieval, entity resolution, and context

- Independent Semantic, Lexical, Temporal, SalienceRecency, and EntityMatch
  seed strategies, followed by hop-one RelationExpand over knowledge relations,
  permission-filtered scope relations, and shared-entity edges.
- Weighted reciprocal-rank fusion over strategy-local ranks, with disagreement
  computed before fusion and optional reranking of the fused head.
- Named versioned profiles that inherit nearest-wins from scope configuration,
  honour deployment strategy constraints, enforce a hard deadline, and report
  contributed, empty, and dropped strategies separately, plus a
  `query_dependent_empty` flag for a run no query-reading strategy answered.
  `search` defaults to `:balanced`; `ask` defaults to `:thorough`.
- Account, authorized scope, lifecycle, provisional subject, and source filters
  are applied before any candidate leaves retrieval internals.
- Knowledge and document chunks use PostgreSQL `vector` values with pinned
  provider/model/version/dimension identity, DiskANN cosine indexes, and PG-FTS
  GIN indexes.
- Entity and EntityMention rows are internal rebuildable caches. The rows are
  never exposed through HTTP, MCP, SDK, LiveView, or retrieval responses. An
  entity card carries one surface form as its label and a kind recomputed from
  the card's own in-scope forms (ADR 0011); no other cache field is readable,
  and nothing reads the entity row itself.
- A failed entity-card summary model call degrades that one card to
  `summary_mode: "unavailable"` instead of failing the scope rebuild. The
  refresh result counts the degraded cards. Retry is the next refresh; nothing
  re-requests the summary sooner.
- Entity-card summary calls run with bounded concurrency inside one refresh
  (`CARTULARY_CONTEXT_SUMMARY_CONCURRENCY`, default 4). Card order is
  unchanged. There is still no per-call duration telemetry, so a scope that is
  slow because of a few slow calls cannot be told from one that is slow because
  it holds many clusters.
- The account-admin operations page exposes content-free resolution health:
  cache counts, observed-alias buckets, singleton rate, and
  mentions-per-entity p50/p95. Statement detail exposes only the count and
  links for co-mentioned statements that the reader can already read; no entity
  identity crosses the retrieval boundary, and no surface form crosses it
  outside an entity card's own scope.
- Per-scope index coverage is readable and reported: statement, embedded, and
  mention counts plus embedding identities, on `/console/scopes` and as a
  telemetry event on every completed projection refresh. Those indexes are
  eventually consistent, so a refresh that never ran leaves a scope with
  statements and no vectors; coverage is what makes that state observable.
  Re-enqueuing a stale scope's refresh is still manual.
- Incremental peer profile, scope card, and session summary projections with
  dirty marking, bounded delta compaction, versioned audience keys, and
  PubSub-backed ETS invalidation. Shared scope/session projections are
  active-only; provisional knowledge appears only in its subject's peer slice.
- `get_context` assembles its budget from clean projections and stays
  reasoning-free; its only live retrieval work is the allowed `:fast` fallback
  after a cache miss.

Details: `specs/architecture/retrieval-entity-context.md`.

### Skill readiness and procedural memory

- Human-authored, plain-versioned skill requirement cards with a validated
  selector language over knowledge metadata, subject, provenance source,
  confidence/corroboration, and freshness.
- Requirement keys inherit down the scope tree with nearest-scope overrides or
  explicit disablement.
- `POST /api/v1/readiness`, the MCP `check_readiness` tool, and the internal
  Skills action all return the same reasoning-free gap report. Required gaps
  block, preferred gaps warn, a missing card blocks, and expired or
  due-for-revalidation knowledge is already stale before the sweeper runs.
- `ask-peer` and `either` gaps produce an elicitation plan; the answer must
  return through ordinary raw `ingest` and governance before readiness is
  rechecked.
- Governance LiveView authoring and review for card versions.

Details: `specs/architecture/skill-readiness-procedural-memory.md`.

### Portability, packaging, and operations

- Linux glibc and Apple Silicon Mix releases with checksum-pinned pg0 and
  ABI-matched pgvectorscale, supervised
  lifecycle, first-run migration, stale-lock recovery, explicit port conflict
  errors, data-directory health checks, and an external-Postgres escape hatch.
- A non-root container image and Compose stack over PostgreSQL with pgvector
  and pgvectorscale, plus an
  optional OpenTelemetry Collector, Jaeger, and Prometheus profile. pg0 is
  never in the container path.
- Runtime configuration validation with clear boot errors.
- Versioned whole-Account logical archives with manifest, resource, and blob
  checksums, complete audit-graph verification before any durable import,
  credential/secret/vector/cache exclusions, private Ash import actions in one
  Account-scoped transaction, and replay-keyed rebuild work.
- Physical backup and restore runbooks for the pg0 directory, external
  Postgres, and blob storage.
- Versioned readiness for the app, database, Oban, queues, and model roles;
  redacted JSON production logs; exact request/token/storage metering;
  dream-time budget admission; and operator-rate self-host cost visibility.

Details: `specs/architecture/portability-packaging-operations.md` and
`docs/operations/`.

### Evaluation, CI, and release readiness

- Reproducible evaluation reports for MemHouse product scenarios, LoCoMo,
  LongMemEval, ConvoMem, and BEAM, carrying dataset hashes and splits, exact
  profile and model-role versions, deadline identity, RAG-triad, token and
  latency measures, per-category scores, degradation curves, and strategy
  ablations.
- Blocking external-Postgres and packaged-pg0 CI lanes, Dialyzer and security
  gates, Mix release and container builds, nightly evaluation, semantic
  version/tag validation, fail-closed release checks, durable GitHub Release
  assets for Linux x86_64/ARM64 and Apple Silicon macOS, and tagged GHCR
  container publication.
- A provider cassette layer for deterministic model tests.
- Held-out tuning discipline: fusion weights may only use held-out data.

Details: `specs/architecture/evaluation-ci-release-readiness.md` and
`specs/memory-system-evaluation-framework.md`.

### HTTP surface

- `GET /api/health`, `GET /api/ready`
- `POST /api/v1/ingest`, `/search`, `/ask`, `/context`, `/readiness`
- `GET /api/v1/ingest/:message_id`
- `GET /api/v1/knowledge`
- `POST /api/auth/password`
- `/api/v1/self/*` peer self-service, human credentials only
- `/api/v1/operations/costs` and `POST /api/v1/operations/reconcile`, including
  replay-safe repair of active scopes with a missing entity-mention index;
  account-admin only
- `/mcp` AshAi MCP endpoint

### Browser surface

- `GET /` redirect, `GET`/`POST /sign-in`, `DELETE /sign-out`
- `/console`, `/console/knowledge`, `/console/knowledge/:id`,
  `/console/scopes`, `/console/graph`, `/console/sources`, `/console/skills`,
  `/console/tools`, `/console/me` — any human password session, every role
- `/console/operations` — account-admin only
- `/governance/sign-in` and `/governance` LiveView — curator or account-admin
  password sessions only

All `/api/v1` routes require a password JWT or an agent API key. The browser
routes take a signed session cookie plus CSRF instead, and admit no machine
credential at all.

## Verification evidence

Recorded on 2026-07-28 for `0.2.0` with pg0, stock external Postgres, and
OpenRouter.

- `mix deps.get`, `mix format --check-formatted`, and
  `mix compile --warnings-as-errors` passed.
- `mix ash.codegen --check` passed with no resource/snapshot drift.
- `mix ecto.migrate` passed, including
  `CREATE EXTENSION IF NOT EXISTS vector`.
- `mix test` passed with 83 tests (81 examples plus two properties).
- `mix credo --strict` passed with no issues.
- `mix dialyzer` passed with 0 errors.
- `mix sobelow --config` passed with no findings after three reviewed
  false-positive skips: local benchmark fixture reads in
  `MemHouse.Eval.Adapter`, the read-only static retrieval data layer in
  `MemHouse.Retrieval.Store`, and the static UUID-only message-to-Account
  bootstrap lookup in `MemHouse.DataLayer`.
- The full suite passed against newly created partitioned test databases,
  exercising the complete migration chain from empty, and separately against
  the stock `pgvector/pgvector:pg18-bookworm` Compose lane through
  `MEMHOUSE_TEST_DATABASE_URL`.
- A packaged Darwin ARM64 release initialized PostgreSQL 18.1.0 plus pgvector,
  applied the full migration chain, returned `f10-1` readiness, recovered and
  reattached the same durable directory, and shut down cleanly.
- The production container built and ran as non-root UID 10001 without Rust or
  pg0 in its runtime layer, and returned `f10-1` readiness.
- A fresh two-database logical archive round trip preserved durable data,
  verified audit continuity, and rebuilt derived caches.
- The deterministic release matrix covered MemHouse, LoCoMo, LongMemEval,
  ConvoMem, and BEAM plus eight ablations, validated report provenance, met
  every committed correctness and citation floor, and passed the semantic
  version and changelog release check for `0.2.0`.
- `mix memhouse.eval.smoke --profile balanced` ingested 3 messages and
  answered all 3 smoke questions with citations against OpenRouter.
- `GET /api/health` returned status `ok` and contract `f5-1`. HTTP ingest and
  ask were verified locally; the ask response returned a cited knowledge item
  extracted by `openai/gpt-oss-120b`.
- The baseline eval fixtures still match the committed hash and normalization
  baseline in `test/fixtures/eval/poc-contract-baseline.json`.

CI repeats the gate against external Postgres and packaged pg0, then builds the
release and container.

## Known limitations

Each limitation is tracked in `specs/roadmap/beta-roadmap.md`.

- **Integration surfaces are partial.** The Phoenix JSON controller, the
  governance LiveView, the MCP tool set, and the transport-neutral readiness
  helpers under `sdk/` exist. Generated AshJsonApi OpenAPI, complete generated
  TypeScript and Python clients, the OpenAI/Anthropic-compatible gateway proxy,
  connector administration, and an Account archive administration UI do not.
  `specs/eval/surface-contract-inventory.json` marks the missing surfaces
  `unavailable`, and the release check fails if they are advertised as shipped.
- **`ask` is not yet the full dialectic loop.** It returns a cited answer over
  retrieved candidates. In-loop citation verification, disagreement input, and
  the complete abstention taxonomy are outstanding.
- **Committed evaluation data is smoke-scale.** The report contract,
  thresholds, ablations, and CI lanes are release-grade, but upstream-scale
  LoCoMo/LongMemEval/ConvoMem/BEAM scores and independent live-model judge
  evidence still need protected credentials and the upstream datasets. Do not
  present the committed fixtures as comparative scores.
- **Model deployment assets are operator-supplied.** The ReqLLM seam and local
  Ortex/ONNX execution ship, but MemHouse does not download or package
  ONNX/tokenizer artefacts, certify every ReqLLM provider, or run an in-engine
  multi-provider cascade.
- **Retrieval tuning is still evidence work.** Versioned profiles, raw internal
  ablations, deadline-disabled evaluation, and complete strategy
  instrumentation exist; changing fusion weights still requires upstream-scale
  held-out evidence.
- **Enterprise identity is out of scope.** SSO/SAML/SCIM, multi-Account
  provisioning, advanced RBAC administration, and channel-linking UX remain
  later licensed work.
- **Dream-time deduction application is partial.** Consolidation merges active
  duplicates and emits bounded set aggregates. Broad applied-deduction and
  projection-build coverage is outstanding.
- **`main` is not fully protected yet.** CI workflows exist and report green,
  but required status checks are not configured on the GitHub ruleset. A
  workflow file is not proof of branch protection.
- **Proof-of-concept naming survives in a few defaults.** The `/poc` default
  scope path, the `poc-0` baseline contract identity, the `poc-baseline`
  retrieval variant label, and the `eval-poc` smoke account are tracked for
  renaming; the migration filenames and recorded `poc-0` evaluation reports are
  immutable historical evidence and stay as they are.

## Local commands

For a downloaded release, one command starts the pinned pg0 instance, migrates,
and serves:

```bash
bin/server
```

For source development, create local configuration and provide the Postgres
server selected by `DATABASE_URL`:

```bash
cp .env.example .env
```

Run setup and the standard gate:

```bash
mix deps.get
mix ecto.migrate
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix sobelow --config
```

Run the deterministic release evaluation and readiness check:

```bash
mix memhouse.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/memhouse-release-eval.json

mix memhouse.release.check \
  --eval-report /private/tmp/memhouse-release-eval.json
```

Run the smoke evaluation:

```bash
mix memhouse.eval.smoke --profile balanced --account eval-poc
```

Run the frozen baseline contract:

```bash
mix test \
  test/memhouse/poc_contract_test.exs \
  test/memhouse_web/controllers/memory_controller_test.exs \
  test/memhouse/eval/fixture_contract_test.exs
```

Start the local API on `http://localhost:4000`:

```bash
mix phx.server
```
