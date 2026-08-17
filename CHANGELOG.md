<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Changelog

All notable MemHouse changes are recorded here. Versions follow Semantic
Versioning. While the public API is pre-1.0, a minor release may intentionally
version an incomplete surface; breaking changes still require an explicit
changelog entry and contract-version transition.

## [Unreleased]

### Changed

- Matched execute experiments now accept only a closed set of component
  bindings derived from the runner's effective profile, strategies, rerank,
  deadline, semantic-index refresh, dream-time, and durability settings.
  Unknown or dishonest labels fail validation, and fixture replays cannot
  claim component execution. The committed comparison now runs the real
  `balanced` versus `minimal` profile defaults; offline semantic runs require
  existing local Ortex artifacts and never substitute fake vectors.

- Dream-time now gates work by a durable timestamp-and-id delta cursor, minimum
  changes, idle/interval windows, hard delta/working-set caps, and a whole-call
  elapsed budget. Update reasoning and multi-source synthesis have separate
  schemas and prompt identities; update remains enabled and synthesis remains
  off until matched evaluation approves it.

- Governed direct-fact activity now schedules a durable per-scope dream wakeup
  after the configured idle window in the same `PipelineRun`/Oban transaction.
  Duplicate and restarted work reuses its replay identity, newer activity
  supersedes older wakeups before model work, and hourly/manual Account sweeps
  remain fallback and operator paths.

- Message extraction now token-batches adjacent pending anchors from the same
  Account, scope, and session through one provider call. Each envelope keeps
  its original replay key and exact source allowlist; governed effects,
  completion, and PipelineRun state commit per anchor. Deterministic pre-call
  admission, repairable/terminal states, stale-claim recovery, and an explicit
  operator requeue replace implicit replay of poison or oversized sources. The
  extraction prompt identity advances to `extract-13`.

- Retrieval now normalizes scores inside each strategy list before weighted
  fusion. A 5% reciprocal-rank term breaks ties, with `rrf_k` set per profile
  and defaulting to 15. Candidates expose `fusion_score`; `rrf_score` remains
  as a deprecated alias for this contract version. Recorded `poc-0` reports
  remain immutable evidence of the previous `k = 60` RRF baseline. See ADR 0020.

### Added

- A default-off `compact-explicit-v1` extractor experiment limits model output
  to atomic durable statements, exact support, subject/source references, and
  exact valid-time evidence. Trusted code derives fail-closed policy defaults
  and reuses the existing validator, batch attribution, provenance, and Gate
  A/B path. `extract-13` remains the default until matched held-out evaluation
  and human review approve `extract-compact-exp-1`.

- The opt-in `minimal` profile now uses a rebuildable, archive-excluded
  `RecallDocument` read model. One query embedding feeds independently capped
  direct and derived semantic top-k lanes; stable interleave records lane rank
  and cosine distance before lexical fusion. Canonical Knowledge remains the
  only writer and is re-joined for Account, scope, reader, lifecycle, expiry,
  deletion, and source-watermark checks before ranking. Refresh is replay-safe,
  lifecycle changes fail closed while it is pending, and hard erasure cascades.

- An opt-in `minimal` dual-lane-semantic-plus-lexical retrieval profile and bounded
  read-only Ask efforts (`low`, `medium`, `high`) add content-free budget
  diagnostics and hard per-tool elapsed enforcement. The planner can read
  governed knowledge, stable-profile knowledge, typed lineage, and authorized
  source messages; it has no write tool. Existing profiles remain the default
  and rollback path.

- `POST /api/v1/source-search` provides Account/scope-authorized exact and
  embedding-identity-matched recall over immutable messages with bounded
  excerpts and stable citation ids. `POST /api/v1/lineage` projects bounded
  typed evidence lineage, and `POST /api/v1/stable-profile` builds a live,
  model-free stable identity projection from governed direct evidence.

- `mix memhouse.eval.experiment` registers one current and one experimental
  variant over the same dataset and emits a revision-, backend-, model-,
  prompt-, profile-, seed-, and component-pinned comparison bundle with
  quality, citation, isolation, cost, latency, and replay gates.

- Operational retention now prunes terminal Oban jobs and expired pipeline, usage, gate-decision,
  and lifecycle rows on configurable horizons. The operations summary separates durable and
  operational bytes and warns when operational storage is larger. Account archives no longer
  carry retained operational history; messages, knowledge, provenance, audit events, and
  reasoning watermarks remain durable.

- `POST /api/v1/ingest` accepts `peer_key` from a machine credential, which
  names the peer that spoke the turn. The Peer is created on first use. See the
  attribution entry under Changed for what the field does and what it does not
  do.

- `POST /api/v1/search`, `POST /api/v1/ask`, `POST /api/v1/context`, and
  `GET /api/v1/knowledge` accept `peer_key`, which names the peer the results
  are read for. See the peer-scoped read entry under Changed.

- `mix memhouse.governance.autoshare --account-key KEY` writes the Account-wide
  gate rule cells that let an Account accept and place knowledge without a
  person. It covers every combination of peer, scope, and account level with
  public, internal, and personal sensitivity, and sets `gate_a_mode`
  `auto_keep`, `gate_b_mode` `auto_place`, `minimum_evidence_level`
  `"indirect"`, and `minimum_corroboration` `1`. The evidence floor is the
  field that decides whether the rest has any effect: it defaults to `direct`,
  a claim is direct only when its subject is the peer who spoke it, and most of
  a relayed conversation is one participant speaking about another. Requiring
  two independent sources would hold a benchmark corpus for the same reason, so
  corroboration drops to one. `restricted` is left alone, because no cell can
  make it automatic. The task does not touch consent: only a human account
  administrator may set `consent_mode`, so it prints a reminder instead. It
  loosens governance for a whole Account. Run it on a benchmark or evaluation
  Account, never on one holding somebody's real memory.

- `mix memhouse.model.check` probes structured output for `ingest_extractor`,
  `dream_reasoner`, and `dialectic_agent`, asking each for one small object and
  printing status, provider, model, duration, and a content-free error class.
  It exits non-zero when a role fails, and reports a role on the deterministic
  local fallback as skipped. The prior-24-hour `checks.model_calls` rate on
  `GET /api/ready` reports failures that already happened and reads as healthy
  on a node that has never called a model; this reports whether the next call
  will work. The probe resolves roles from deployment configuration, sends the
  configured timeouts and output caps unchanged, and writes no usage row, so it
  neither meters itself nor covers a per-Account role override. The readiness
  payload is unchanged and the `f10-1` operator contract still holds.

- `mix memhouse.eval.benchmark` and `mix memhouse.eval.release` run that probe
  before ingest unless `--no-model` is given, and refuse to start when a role
  cannot return an object. A graded run cannot tell a weak answer from one that
  was never generated, so it would otherwise publish a quality number for a
  corpus that was never extracted. A role on the deterministic fallback fails
  the check; `--no-model` is how an offline run is requested.

- Model roles accept a `structured_output_mode` option. A role naming
  `openrouter` already uses that provider's JSON-schema response path; the same
  endpoint reached as `openai-compatible` plus a base URL has no recognised
  model identity and reverts to a forced tool call that some models decline.
  Setting the option to `json_schema` selects the schema-enforced path there.
  An unusable value fails the call instead of degrading to tool calling.

### Security

- `phoenix_live_view` is now 1.2.9, which clears EEF-CVE-2026-64941 (open
  redirect in `Phoenix.LiveView.validate_local_url!/2` via ASCII tab, LF, and
  CR). The `~> 1.1` requirement already allowed it; only the lock moved. Do not
  lower the lock without checking `mix hex.audit`.

- `ash` is now `~> 3.31` (3.31.2), which clears EEF-CVE-2026-69659 (memory
  exhaustion via unbounded deserialization of keyset pagination cursors) and
  EEF-CVE-2026-70395 (predicate injection in `manage_relationship` belongs_to
  lookup disclosing secret lookup keys). Both are fixed from 3.31.1 onward, and
  3.31.1 is retired upstream. `reactor`, `splode`, and `spitfire` moved with it.
  Do not lower the floor without checking `mix hex.audit`.

### Fixed

- Unattended deployments now reject restricted proposals with the audited
  `restricted_unattended_policy` reason instead of leaving them in a curator
  queue that no person can drain. `GET /api/ready` reports pending human reviews
  and the retained count of restricted proposals withheld by this policy.

- Lexical retrieval now uses a linear adjacent-phrase boost over a `2 × limit`
  shortlist instead of a distance-and-direction fan-out over `5 × limit` rows.
  Entity-name lookup uses a normalized GIN expression index instead of
  lowercasing an unnested alias array for every entity row. One strategy can no
  longer consume the full thorough-profile phase budget.

- Entity-index rebuilds no longer create hubs for closed-class words, common
  sentence-start artefacts, or timezone abbreviations. The spotter also stops
  at sentence and line boundaries. Ordinary title-cased names can now produce
  the `person` kind, while calendar names remain concepts. Embedding similarity
  now selects a candidate only; every non-exact entity merge requires explicit
  model confirmation. Rebuild affected scopes to remove old derived rows.

- The packaged pg0 build now uses Rust 1.88. Its resolved ICU dependencies no
  longer compile with the previous Rust 1.86 toolchain.

- Extraction validation now rejects thanks, compliments, greetings, wishes,
  and other conversational-turn transcriptions before they can become
  proposed knowledge. Reporting verbs reject only quoted or reported message
  content, so durable actions such as writing a book remain valid candidates.

- Retrieval strategies no longer return a statement whose `expires_at` has
  passed. Expiry is a timestamp and the sweeper that rewrites `state` to
  `expired` runs as a job, so a row stays `active` with a past expiry until
  that job lands. The active, non-expired predicate now applies consistently
  across `lexical`, both `semantic` branches, `entity_match`,
  `relation_expand`, and `co_mentioned_knowledge`. `temporal` and
  `salience_recency` already applied it. An expired statement is no longer
  retrievable through any visible-knowledge query path.

- `entity_match` now ranks by how much the entities a query names narrow the
  scope, not by how confident the extractor was. Matching was set membership
  with no gradient, so every statement mentioning a matched entity was equally
  matched and ordering fell to `mention.confidence * knowledge.confidence` —
  near `1.0` for anything the extractor was sure was said. In a scope about two
  or three people, nearly every statement names one of them, so the strategy
  returned a confidence-ordered dump of the scope on almost every query.

  Each matched entity is now weighted by inverse frequency over the authorized
  scopes' visible statements, and a statement scores the share of that weight
  its own mentions carry, times its confidence. Scores stay in `0..1`, which
  `min_score` filtering and the `low_score` disagreement hint both rely on.
  Frequency is measured per request rather than cached: entities are
  Account-global while rebuilds are per-scope, so a stored figure would be
  stale for every scope but the last one rebuilt. See
  `specs/adr/0017-entity-match-selectivity.md`.

  Three settings bound it, all with new environment overrides:
  `MEMHOUSE_RETRIEVAL_ENTITY_FREQUENCY_CEILING` (default `0.5`),
  `MEMHOUSE_RETRIEVAL_ENTITY_CEILING_MIN_STATEMENTS` (default `20`), and
  `MEMHOUSE_RETRIEVAL_ENTITY_PER_ENTITY_CAP` (default `25`).

  A query naming only entities above the ceiling now contributes nothing
  instead of contributing the scope. That also repairs
  `disagreement.query_dependent_empty`, which `entity_match` previously held
  `false` on every query that named anyone, asserting the run had understood a
  question it had not. Profile weights are unchanged; `entity_match` stays at
  `0.9` pending held-out fusion tuning.

- Reranking can now actually run, and a run that lost it says so. Three
  independent defects stopped the stage that decides the final order:

  - The strategies spent the whole deadline and the reranker was offered
    whatever was left. A reranking profile now reserves
    `MEMHOUSE_RETRIEVAL_RERANK_RESERVED_MS` (default `120`, clamped to half the
    profile deadline) before the strategies start, and reports the reservation
    as `reserved_rerank_ms`. The strategies are now the stage that degrades
    under time pressure, which is the correct priority: reranking changes which
    candidates a caller sees, expansion mostly changes which ones it does not.
  - `deadline: "disabled"` removed the request deadline but still capped the
    reranker at `MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS`, so an evaluation run
    that asked for no time limit measured fusion order. Such a run is now
    uncapped. This also unblocks the structured-generation rerank fallback,
    which is only permitted on deadline-free runs and could never finish inside
    120 ms.
  - A ranking that did not name every head index exactly once was discarded
    whole. A partial ranking is now applied — the judged indexes lead, in the
    model's order, and the rest follow in fusion order — and reported as a
    completed outcome with reason class `partial_rankings`. Duplicate and
    out-of-range indexes still fail the result as `invalid_result`, because
    they make the intended order unknowable.

  `search` and `ask` also gained `degraded` and `degraded_components`. A dropped
  reranker was previously invisible in the product: the results still arrived
  looking relevance-ordered when they were ordered by reciprocal rank alone.
  Every degraded component now also emits `[:memhouse, :retrieval, :degraded]`
  with a count, Account id, profile, component, and reason class, and logs the
  same at warning level, with no content. The `f7-1` retrieval contract is
  unchanged: the added fields are additive and no existing field changed
  meaning.

- `POST /api/v1/ask` no longer returns a failed model call as an answer. A
  provider error or exhausted structured-output repair reused the same
  top-statement concatenation as the deliberate no-model-configured reply,
  including `abstained: false` and `answer_confidence: 40`, so a caller could
  not tell a failure from an answer; one benchmark run reported zero errors
  while 72.5% of its model calls had failed. A failed call now returns
  `abstained: true`, `answer_confidence: 0`, and a new `answer_degraded` field
  naming the failure class, with the retrieved statements kept in `citations`
  and in a new `supporting_statements` field. Every other reply carries
  `answer_degraded: null`. A new `[:memhouse, :ask, :degraded]` telemetry event
  reports the failure class, Account id, and elapsed time, with no content. The
  no-model-configured reply is unchanged, since that state is a deployment
  choice rather than a failure. The `f7-1` retrieval contract is unchanged.

### Removed

- The four `specs/memory-system-*.md` blueprints, `specs/design/`, and
  `specs/implementation-status.md`, together with the `FR-*`, `AD-*`, `AINV-*`,
  `NFR-*`, and `EV-*` anchor system they defined. The source and its tests are
  the specification of current behavior; those documents restated it and drifted
  from it. `specs/` now holds only what code cannot state: decisions and the
  alternatives they rule out (`specs/adr/`), outstanding work
  (`specs/roadmap/`), module boundaries (`specs/architecture/`), evaluation
  evidence (`specs/eval/`), and release process (`specs/process/`). ADRs 0001
  to 0016 still cite the retired anchors and are kept as dated history.
- The release check no longer requires blueprint-anchor evidence in
  `CHANGELOG.md`, and no longer requires `specs/implementation-status.md` to
  describe the release gate. Both gates enforced the retired anchor system.

### Changed

- Extraction prompt `extract-13` maps first-person claims to the exact speaker
  peer key. For first-person claims, validation ignores the model's
  `subject_ref` and derives the subject from the cited message's stored speaker
  key. Unresolved or ambiguous cited speakers fail closed. The cited speaker
  determines evidence confidence, and first-person stored prose must be repaired
  instead of synthesized from an opaque peer key.

- Extraction prompt `extract-11` requires an exact supporting span from a cited
  source. Schema validation rejects missing cited content, question-only spans,
  and ISO dates that do not occur in the source or resolve from a bounded
  relative expression against the observation time.

- Extraction prompt `extract-10` classifies a claim by its durable meaning.
  Stable facts, preferences, relations, and skills keep those kinds even when
  they were stated or became true at a known time. `event` is only for a claim
  whose durable content is that something occurred. Worked examples pin all
  five kinds. Valid time is independent of kind, and the pipeline no longer
  copies observation time into an event with no known validity window. The
  pipeline contract remains `f5-1`.

- Extraction no longer asks the model to set knowledge expiry. Temporal
  retrieval now ranks dated text matches by distance from the requested time.

- Extraction prompt `extract-10` removes the candidate `reasoning` field. The
  field was required for every candidate but was not stored or used after
  validation. The schema now asks for the statement first and then its anchored
  confidence level, which reduces discarded structured output.

- Extraction prompt `extract-9` removes unused operation and revalidation
  judgements. It orders reasoning and the completed statement before an
  anchored `stated_explicitly`, `clearly_implied`, or `inferred` confidence
  level. These levels map to fixed stored confidence values for deterministic
  downstream ranking. Revalidation stays under governance policy.

- An authenticated caller is no longer always the speaker. A machine
  credential — identity kind `:api_key` or `:system` — that sends `peer_key`
  attributes the turn to that named Peer, created on first use. An agent
  relaying a conversation submits turns it did not speak, and the old rule
  filed all of them against the agent: every personal statement was recorded
  about an infrastructure identity, consent was granted by the wrong party to
  itself, the personal-knowledge hold could never fire, and erasure by subject
  could not reach a human's statements. A password session still always speaks
  as itself and ignores a `peer_key` in the body, so nobody can post under
  another person's name. An internal caller carries no Peer and must supply
  one. The named key is trusted as sent; per-peer authentication is not built
  yet. Authority does not transfer: the actor keeps the calling credential's
  own roles and authorized scopes, so relaying as a peer with wider grants
  cannot widen what the request may write. An existing Peer is resolved rather
  than upserted, so relaying an agent's key cannot rewrite it as human. The
  `message.ingested` audit entry now records the relaying credential as
  `actor_peer_id` and the speaker as metadata `speaker_peer_id`. ADR 0018
  records the decision and the alternative it rules out. Issue:
  https://github.com/memhousehq/memhouse/issues/165

- Retrieval is now performed for a named peer. `search`, `ask`, `get_context`,
  and the knowledge listing accept `peer_key`, trusted on the same terms as
  ingest, naming the peer the results are read for. That peer reads public and
  internal statements, its own statements, statements about the scope rather
  than about a person, and anything promoted to scope or account level;
  promotion is where the subject agreed to the wider audience. A machine
  credential that names no peer reads public statements only, because a caller
  that does not say who it is asking for is asking for nobody. A password
  session with no `peer_key` still reads as itself. Server-side work —
  projection rebuild, dream-time, the evaluation harness — reads the whole
  corpus, and that posture comes from the absence of an authenticated identity,
  never from request input. Shared scope cards and entity cards are now built
  from shareable statements alone, so a personal peer-level statement no longer
  reaches a shared projection. Naming a peer grants none of that peer's
  authority. The `f7-1` retrieval contract is unchanged.

- Extraction prompt `extract-8` is offered the session's participants, minus
  agent-kind peers, as the subjects a statement may be about. It replaces the
  whole-Account peer list, and the speaker is no longer appended to the
  allowlist unconditionally. Document extraction has no session, so it uses the
  Account's non-agent peers. A new deterministic validation floor rejects a
  candidate whose statement names a machine identity — an agent peer key, or
  "the assistant", "the agent", "the ai", "the chatbot", or "the bot". The
  allowlist alone stopped a machine becoming `subject_ref`, but nothing stopped
  one appearing in the prose, and a claim about a person misfiled onto the
  process that carried it is read by governance as a subject consenting to
  itself. The prompt moves from `extract-7` to `extract-8`; the `f5-1` pipeline
  contract is unchanged.

- Gate B may now place personal knowledge automatically when the Account has
  declared that it has no human subject — `consent_mode` `"auto"`, or a
  deployment running with `MEMHOUSE_GOVERNANCE_UNATTENDED=true`. Consent there
  is already settled and written as a real audited row before the gate is
  consulted, so holding the item only parked it forever with nobody to release
  it. `restricted` knowledge is never placed automatically, whatever the
  Account declares: a deployment-wide switch must not reach the one band that
  exists to demand a person. The default posture is unchanged. An Account that
  has not opted in still queues everything for a human.

- `AGENTS.md` and `CONTRIBUTING.md` now direct a contributor to the modules and
  tests first, and to `specs/` only for a decision, unbuilt work, a module
  boundary, or a release gate. A document that restates implemented behavior is
  now explicitly out of scope for `specs/`.
- The pull request and issue templates ask for product invariants and the tests
  that prove them, in place of blueprint anchor citations.
- Extraction prompt `extract-7` records resolved relative dates in
  `relevant_from` and `relevant_until`. Statements state claims without an
  observation-time frame. A statement keeps an ISO date only when the date is
  part of the claim. Ask, projections, and the console render valid time from
  structured fields. It continues to retain durable facts, preferences,
  relationships, possessions, skills, commitments, plans, and lasting events,
  while excluding conversational residue. The `f5-1` pipeline contract is
  unchanged.

- `thorough` retrieval now uses a dedicated `reranker` model role. The default
  is the local, checksum-pinned BAAI/bge-reranker-v2-m3 ONNX cross-encoder with a
  120 ms allowance. Hosted rerank endpoints remain supported; the expensive
  structured-generation fallback cannot run inside a retrieval deadline. ADR
  0015 records the artifact and deadline boundary. The `f7-1` response shape
  and profile identity are unchanged.

- Boot now rejects an embedding width without a matching installed vector
  index. `GET /api/ready` reports the content-safe embedding-index contract
  and returns 503 for that mismatch. This release supports 1024 dimensions.

- Message extraction now uses a bounded six-message same-session window. The
  extractor identifies each retained candidate with the message ids that support
  it, and validation rejects ids outside the supplied window. The durable
  knowledge item and provenance rows retain all cited messages. The prompt is
  now `extract-5`; the `f5-1` pipeline contract is unchanged.

- Lexical question analysis no longer expands a query through a hand-written
  synonym group. The analyzer is now `lexical-question-v2` and retains only
  supplied non-boilerplate terms for plain-text lexical matching. The `f7-1`
  retrieval contract is unchanged.

- The Cartulary product name is now fully migrated to MemHouse. Source and test
  paths, Phoenix modules, Mix task files, release launchers, database defaults,
  telemetry labels, and configuration variables now use `memhouse`,
  `MemHouseWeb`, or the `MEMHOUSE_` prefix. Operators must rename existing
  `CARTULARY_*` environment variables before upgrade. Existing
  `cartulary_` API keys and immutable `f11-1` evidence remain valid; new keys
  and `f11-2` reports use MemHouse names.

- Local semantic retrieval now uses Qwen3-Embedding-0.6B at 1024 dimensions
  and pgvectorscale 0.9.0 StreamingDiskANN indexes. Packaged pg0 builds are
  limited to glibc Linux x86_64/ARM64 and Apple Silicon. Existing installations
  can enqueue the resumable `mix memhouse.reembed` transition; old vectors are
  absent from semantic retrieval until their batches complete.

## [0.4.0] - 2026-08-08

### Fixed

- Entity-card summaries no longer make a scope rebuild wait for the sum of its
  model calls. `MemHouse.Context.Builder` generated one summary per qualifying
  entity cluster with a plain `Enum.flat_map`, so each call ran only after the
  previous one returned, degraded, or hit `MEMHOUSE_MODEL_REQUEST_TIMEOUT_MS`.
  Two comparable scopes in the same run took a few minutes and about 34 minutes,
  the difference being how many of one scope's calls happened to run slow.
  Summary generation now runs with bounded concurrency, so a scope waits closer
  to its slowest call than to their total. The new
  `MEMHOUSE_CONTEXT_SUMMARY_CONCURRENCY` sets how many overlap and defaults
  to `4`; `1` restores the previous serial behavior. Card order, content, and
  the degraded-summary handling are unchanged, and the `f7-1` retrieval and
  context contract is unchanged.
- Gate A no longer automates from a model's self-reported confidence. The
  extractor now derives and persists `direct` or `indirect` source evidence
  from the schema-validated speaker and subject. Matrix rows use that stable
  evidence level for `auto_keep`; `minimum_confidence` remains recorded policy
  metadata only. Hearsay discounting uses the same resolved relationship, not
  the model's label. Gate B also requires a human placement for personal and
  restricted knowledge, and the operations console reports content-safe gate
  outcome totals. ADR 0012 records the `f4-1` governance change.
  Extracted provenance records prompt `extract-4`; the pipeline contract
  remains `f5-1`.

- One flaky entity-card summary call no longer aborts a whole scope rebuild.
  `MemHouse.Context.Builder` raised on any failed summary generation, and that
  raise travelled out of `MemHouse.Retrieval.Rebuild.scope/2`, so a single
  provider timeout reported the rebuild as failed and made the caller re-run
  entity resolution — even though the embeddings and entity rows from the same
  call were already committed. A scope needs one summary call per qualifying
  entity cluster, so a few-hundred-statement scope hit this on nearly every
  attempt. The card now degrades instead: `summary` and `summary_provenance`
  are `null` and `summary_mode` is the new value `"unavailable"`, the same shape
  a two-source card already produces, and the label, sensitivity, and governed
  statements are written as usual. The card stays readable, not dirty, and the
  next refresh retries the summary. `refresh_scope/2` returns
  `entity_card_summaries_unavailable`, and each failure logs the Account, the
  scope, and the error class. `get_context` callers already had to treat the
  three summary fields as optional. The `f7-1` retrieval and context contract is
  unchanged.

- A model generation that collapses into filler no longer becomes knowledge.
  Statement text such as `Melanie told the … …… … statement…… ...` satisfied
  `min_length: 1` and every structural check, so it reached the console looking
  like a fact. `MemHouse.Knowledge.Statement` now states the readability rule:
  a statement must carry letters or digits, and above a short floor at least
  60% of its non-space characters must be. Extraction reports the failure to the
  model, which repairs or fails the observation for retry; the
  `create_from_pipeline` action enforces the same rule so no write path can
  bypass it. Statement text is also canonicalized before hashing — invisible
  padding and whitespace runs are removed — so two observations that differ only
  in padding corroborate one row. The rule does not catch a repetition of real
  words. The `f5-1` extraction and pipeline contract is unchanged.

- `POST /api/v1/ingest` no longer discards an `occurred_at` that carries no UTC
  offset. `2023-07-17T14:31:00` is now read as UTC; previously only the strict
  offset-bearing form parsed, and everything else fell back to the current time,
  so a backfilled transcript was silently stamped with its import instant. An
  unparseable value still falls back to now, which remains documented. The
  offsetless form is the default output of common clients, so this affected most
  backfills.

- A curator edit no longer drops the validity window. The replacement row now
  carries the original's `relevant_from` and `relevant_until`: correcting wording
  is not a claim that the statement has no date. The governed lifecycle contract
  remains `f4-1`.

- Ordinary text retrieval no longer lets query-independent temporal or
  salience-recency lists bury lexical evidence. Temporal now runs only for an
  explicit `as_of` read; salience-recency remains available for blank-query
  context fallback, not as a candidate generator for a text search. A search
  whose query-reading strategies all come back empty now returns an empty
  candidate list instead of a recency page. The named
  profile memberships, weights, response shape, and `f7-1` identity are
  unchanged. ADR 0010 records the applicability rule and deterministic
  micro-ablation evidence.

- Lexical search now normalizes question-shaped queries through the versioned
  `lexical-question-v1` analyzer. It drops a reviewed interrogative set, keeps
  names, dates, negation, and quoted text, expands only the explicit
  `destress`/`stress`/`relax`/`calming`/`therapeutic` group, and adds a bounded
  proximity bonus for terms that fall within eight lexemes of each other in
  either order. The bonus is scored over a base-ranked shortlist so a broad
  query keeps its deadline budget. The content-free retrieval diagnostic records
  the analyzer identity; query text never enters diagnostics or telemetry. The
  retrieval contract remains `f7-1`.
- Extraction now requests `confidence_percentage` through native strict JSON
  Schema as an integer from `1` through `100`, with concise reasoning and the
  candidate statement preceding it. Validation strips non-digits defensively,
  checks the range, then normalizes the percentage to the stored `0.0..1.0`
  confidence fraction. Reasoning is validation-only and never persisted,
  metered, or logged. Bounded repair remains the safety net. Extracted
  provenance records prompt `extract-2`; the pipeline contract remains `f5-1`.

### Changed

- An entity card is now built from two active source statements instead of
  three, but a summary still needs three. On a two-source card `summary` and
  `summary_provenance` are `null` and `summary_mode` is the new value `"none"`,
  so callers of `get_context` must treat all three summary fields as optional.
  The summary threshold applies whatever the provider, including the
  deterministic one where a summary costs nothing, because one release must
  behave the same everywhere. `get_context` also caps entity cards at eight per
  scope, ordered by source count: cards are spent against the character budget
  before individual statements, so a lower card threshold would otherwise let
  cheap cards displace ranked knowledge. The retrieval and context contract
  stays `f7-1` — a deliberate hold, recorded in ADR 0011, not an additive
  change.

- `ask` no longer refuses. The answering prompt now instructs the model to state
  what the retrieved statements make most probable and to carry its uncertainty
  in a new `answer_confidence` percentage rather than replying `not known`. The
  response gains `answer_confidence`, an integer from `0` through `100`, on
  every path: the model's own probability when a model answered, `40` for the
  model-free statement concatenation, and `0` for the empty abstention. A model
  answer below `50` sets `abstained` whatever the model claimed, so a cited,
  abstained, low-confidence answer is now the ordinary shape for a weakly
  supported inference. The one reply that is not an attempt at the question is
  the empty abstention used when no retrieved statement survived grounding; its
  text now reports that state instead of saying `not known`. Citation
  intersection, retrieval, and the `f7-1` identity are unchanged.

- Evaluation reports now carry `answer_confidence` per question and
  `mean_answer_confidence` per group, both `nil` when the answer stated no
  probability, so the abstention threshold can be tuned against measured
  calibration. The metric is reported, not gated: it is deliberately absent from
  the required-metric list. The additions are additive to `f11-2`; committed
  `f11-1` evidence is unchanged.

- Extraction is now told when the observation was made, and an event is
  guaranteed to be datable. The prompt gains an `Observed at` line and two
  rules: resolve every relative date — "last weekend", "yesterday" — against
  that time and write the absolute date into the statement, and label anything
  that happened at a point or over a span as kind `event` with a
  `relevant_from`, plus `relevant_until` when it spans more than an instant.
  `KnowledgeItem.create_from_pipeline` takes an `observed_at` argument, fills a
  missing `relevant_from` on an event from it, and then refuses an event that
  still has none. Document extraction supplies the document version's
  `occurred_at` for the same purpose. Other kinds stay undated. Extracted
  provenance now records prompt `extract-3`; the pipeline contract remains
  `f5-1`.

- Knowledge candidates returned by `POST /api/v1/search` and `/api/v1/ask` now
  carry `relevant_from` and `relevant_until`. Without them a caller could only
  date a statement from its prose, so an unanchored "last weekend" was resolved
  against the reader's own clock. Document-chunk candidates have no validity
  period and omit the pair. The addition is additive; the retrieval contract
  remains `f7-1`.

- The `ask` prompt now shows the answerer each statement's validity window as
  `(true from <date>)` or `(true from <date> until <date>)`, and instructs it to
  date a relative phrase from that window rather than from today. Previously the
  answering prompt carried only `[id] statement`, so a model shown "last
  weekend" had nothing to resolve it against. Dates only; nothing beyond the
  retrieved statements and their windows enters the prompt.

- `/console/graph` is now a scoped explorer rather than a global picture. It
  opens on one scope, keeps that scope and the descendants option in the URL,
  and offers a breadcrumb, a parent control, and chips for the readable scopes
  below it. Ancestors, parents, and children are the scopes the reader may read;
  an unreadable scope in the middle of the tree is skipped rather than named,
  and an unknown or unauthorized `scope` narrows to the shallowest readable
  scope instead of widening to everything. Statements that resolved to the same
  entity are drawn as an anonymous hub labelled by an ordinal: the entity id,
  canonical name, aliases, and surface forms remain unexposed, a group needs two
  readable statements in the drawn scope, and identically-membered groups
  collapse so the number of resolved entities stays private. Statement and hub
  caps are reported, and every view links to the knowledge explorer for the
  complete list.

### Added

- The console graph now joins two named hubs whose entities were mentioned in
  the same statement. Both ends of the line come from one statement the reader
  is already shown, so it discloses nothing beyond what is on the page. It means
  "named together", not "related to": MemHouse records no relations between
  entities and this edge does not create one, so the legend and the console
  guide both say so. Only named hubs take part — joining an unnamed one would
  let a reader count the referents inside a collapsed group by counting the
  lines leaving it, which is what the collapse exists to prevent.

- Entity cards now carry a `label` and a `kind`, and the console graph names a
  shared-entity hub instead of showing only an ordinal. The label is a surface
  form taken from that card's own sources in that card's own scope, so it is
  text the card already returns; `Entity.canonical_name` and `Entity.kind` stay
  unreadable, because both are account-global and the stored kind is frozen at
  the first spelling ever seen. The kind is recomputed from the card's own forms
  and is one of `person`, `org`, `system`, or `concept`. A hub is named only
  when its group resolved to exactly one entity: groups that share identical
  membership are still collapsed and still keep an ordinal, so the number of
  resolved entities stays private. Labels are English-only and either field may
  be `null`. Recorded in ADR 0011, which amends ADR 0009.

- The tool workbench at `/console/tools` now offers account administrators a
  retrieval diagnostic mode. It can look past the ordinary twelve-result window
  up to a clamped cap, isolate internal strategies, disable the latency
  deadline, force reranking on or off, and show only candidates a
  query-dependent strategy voted for. Runs are labelled as not
  production-equivalent, highlight matched query terms through escaped
  server-rendered markup, and export a copyable request carrying scope, query,
  profile, limit, and diagnostic options and no credential, session id, or
  Account identifier. Ordinary `search` and `ask` keep their defaults, and a
  ranked run that filled its window now says deeper candidates may exist. The
  internal seam is reached through a `Retrieval.DiagnosticGrant` struct that
  decoded JSON cannot forge, so no MCP tool or HTTP field is added and the
  `f7-1` contract identity is unchanged.
- GitHub Release publication now builds native Linux x86_64, macOS Apple
  Silicon, macOS Intel, and Windows x86_64 packages and their SHA-256 files are attached to a
  GitHub Release with the evaluation report, while the production container is
  published to the repository's GHCR package. The installation guide explains
  how to choose, download, verify, unpack, and run these artifacts.
- `get_context` now includes scope-bounded `entity_cards` for resolved entities
  with at least three active governed source statements. Each background-built
  card carries a bounded summary, its model provenance, the strictest source
  sensitivity, and its governed statements without exposing entity-cache ids,
  names, aliases, or mention text. The new member is additive; existing
  retrieval behavior and the `f7-1` contract identity are unchanged.


## [0.3.0] - 2026-07-31

### Fixed

- Scope cards and session summaries no longer persist peer-private
  `provisional` statements. Shared projections now contain active knowledge
  only, while a subject-keyed peer profile retains that peer's active and
  provisional knowledge. Context projection keys use a new private audience
  namespace, so clean pre-fix projections are ignored immediately and the
  subject-filtered `fast` fallback covers reads until rebuilt. The public
  `f7-1` payload contract is unchanged; this restores its intended governance
  boundary.
- Lexical retrieval returned nothing for a question. `websearch_to_tsquery`
  joins bare terms with `AND`, so `search` required every content word of the
  query to occur in one governed statement — a bar a single sentence almost
  never clears. The lane that is meant to carry recall when no embedder is
  configured therefore contributed no candidate to any multi-word question,
  and fusion cannot re-rank an empty list. A query that spells a `websearch`
  operator — a quoted phrase, a leading `-`, or `or` — still parses exactly as
  before; any other query now matches statements sharing any of its terms, with
  `ts_rank_cd` ordering by how many terms a statement covers and how densely.
  Document-chunk search changed identically. Matching uses the same lexemes
  `to_tsvector` stored, so the existing GIN indexes still serve both forms and
  no reindex is needed. Retrieval stays inside the `f7-1` contract: no route,
  parameter, response field, or fusion weight changes, and Account, scope, and
  lifecycle filtering is untouched.
- A search response reported a healthy run when every strategy that reads the
  query text had come back empty. `contributed_strategies` was built from every
  strategy that finished, so one that matched nothing was still named a
  contributor, and `disagreement` discarded empty lists before measuring
  anything, so that strategy left no trace in `strategy_count`, `disjoint`, or
  `low_score` either. When only `temporal` and `salience_recency` survived —
  neither of which reads the query — `search` returned the scope in recency
  order, the same page for every question, in a payload whose shape and health
  signals matched a good result. Retrieval now reports three disjoint
  per-strategy outcomes instead of two: `contributed_strategies` (returned
  candidates), the new `empty_strategies` (ran, matched nothing), and
  `dropped_strategies` (disabled, timed out, or failed, unchanged). Each
  strategy declares `query_dependent?/0`, and `disagreement` gains
  `query_dependent_empty`, true when no query-reading strategy contributed.
  It is still computed before fusion (FR-API-29), which is what lets it say
  "nothing was found" while a full ranked list is being returned.
  `strategy_count`, `disjoint`, and `low_score` keep their current meanings and
  values. `search` and `ask` responses carry one new top-level field and one new
  `disagreement` key; a caller counting `contributed_strategies` will now see
  only the strategies that actually voted on the order. The `search` telemetry
  span adds `memhouse.retrieval.empty_strategy_count` and
  `memhouse.retrieval.query_dependent_empty`, and the console retrieval preview
  names empty strategies alongside dropped ones. `ask` does not yet abstain on
  the new signal; that remains the tracked roadmap item, which this change
  supplies the missing input for. No contract identity changes: `f7-1` still
  names retrieval behaviour, and the addition is backward compatible for a
  caller reading fields by name.
- `ask` no longer discards grounded answer text and validated citations when
  the dialectic model marks its conclusion inconclusive. A response may now
  combine `abstained: true` with non-empty `citations`: the cited statements
  support the qualified text but do not establish a conclusion. Responses with
  no surviving retrieved citation still return the empty `not known`
  abstention, so invented citation ids cannot make unsupported prose public.
  This changes the response shape that API and MCP consumers may observe without
  changing its fields or the `f7-1` retrieval/context contract identity.
- Made observation ingest strictly asynchronous. HTTP and MCP now acknowledge
  with the durable message id before any model call, and the removed
  `sync_extract` option can no longer run extraction in the request. HTTP
  callers can poll the Account- and scope-authorised ingest-status route for
  pending, failed, or completed work and visible governed knowledge. Operators
  can enqueue reconciliation independently of ingest. Evaluation and smoke
  commands invoke their direct extraction entrypoint explicitly. Extraction
  failure logs retain only ids, attempt count, and error class. This is the
  intentional pre-1.0 ingest response-contract transition tracked by issue
  #65; the `f5-1` pipeline identity is unchanged because its governed extraction
  semantics did not change.
- A failed extraction reported `:missing_structured_object` no matter why the
  model call produced nothing, which left an operator reading a trace unable to
  tell a transient upstream blip from a failure that will repeat on every
  retry. A hosted aggregator can answer HTTP 200 with a choice whose finish
  reason is `error` — its own upstream failed part-way through generating —
  and `MemHouse.Model.Providers.ReqLLM` saw only that the response carried no
  object. It reported the same name for a response cut off at the output cap
  and for one the endpoint withheld, and that name became the `error.type` on
  the model span and the error class on the usage event. Incomplete responses
  are now classified by how the response ended: `provider_upstream_error`
  (transient; the job retry is the fix), `provider_output_truncated` (repeats
  identically until `CARTULARY_MODEL_MAX_TOKENS` is raised or
  `CARTULARY_MODEL_REASONING_EFFORT` lowered), `provider_content_filtered`
  (repeats until the input or model changes), and the original
  `missing_structured_object` / `missing_text_response` for a call that
  finished normally and simply returned nothing usable. `chat/3` additionally
  treats blank text as no text, which its documented contract already
  promised, rather than returning an empty string as a successful answer.
  Failures remain returned rather than raised and the caller's job remains
  retryable, so no observation is lost. No route, parameter, response field, or
  contract identity changes.
- Nothing ingested through `POST /api/v1/ingest` was ever extracted on a fresh
  install once the database role became one that row-level security actually
  applies to. The request returned `200` and the observation was stored, but the
  extraction job it queued cancelled itself milliseconds later with
  `{:cancel, :trigger_no_longer_applies}`, so no knowledge was proposed and no
  search could find anything. A background job runs with no request behind it,
  so the pooled connection its first query lands on has no Account declared to
  the database, and the row-level security policy on `pipeline_runs` hides every
  row until one is. The job runner reads its own run row back before any
  MemHouse code runs; finding nothing, it concluded its trigger no longer
  applied and cancelled cleanly while the work stayed outstanding. The same gap
  sat on the write side, where an undeclared status update matched no row and
  surfaced as a stale record. This affected all eleven lanes — extraction,
  dream-time, revalidation, expiry, projection refresh, connector sync, import
  rebuild, reconciliation, entity resolution, validation continuation, and
  answer correlation — not extraction alone. Every trigger now reads through the
  new transactional `MemHouse.Operations.PipelineRun.for_trigger` action, and
  `execute` and `mark_failed` declare the run's own Account inside their
  transaction; the lane's own work still runs outside that transaction, so no
  job holds a database connection across its workflow. No route, parameter,
  response field, or contract identity changes.
- Every authenticated API request returned `500 Internal Server Error` once the
  database role became one that row-level security actually applies to.
  `MemHouse.Operations.Metering.record_api/2` writes the edge usage-ledger row
  from `CartularyWeb.Plugs.MeterUsage`'s before-send callback, which runs after
  the request's own transactions have already ended, and it wrote that row with
  no Account declared to the database at all. The ledger's Account policy
  compares each new row against the transaction-local Account setting, so with
  none installed the insert was refused with `42501 insufficient_privilege` and
  the response the controller had already produced was replaced by a `500` —
  `/api/v1/ingest`, `/api/v1/search`, and every other metered route alike. The
  same omission on the read side made `MemHouse.Operations.Metering.summary/1`
  fail silently instead: `GET /api/v1/costs` and the console's overview and
  operations pages reported an Account with real recorded spend as having
  consumed nothing, because the policy filtered the whole ledger away rather
  than raising. Both entry points now open their own
  `MemHouse.DataLayer.in_account_transaction/2`, which is also what keeps the
  ledger row independent of whether the request's own work committed. No route,
  parameter, response field, or contract identity changes; the `f10-1` stamp on
  edge rows is unchanged.
- The two background rebuild lanes left out of the previous fix now follow the
  same rule: `MemHouse.Retrieval.Indexer.rebuild_scope/2` and
  `MemHouse.Retrieval.EntityResolver.rebuild_scope/2` no longer hold an
  Account database transaction across a model call. Both previously opened one
  `MemHouse.DataLayer.with_account_id/3` transaction around the entire scope
  rebuild with provider calls inside it — one batched embedding call for the
  indexer, and for the entity resolver, one embedding call per unmatched
  surface form plus one `dream_reasoner` structured-adjudication call per
  ambiguous surface form, so a scope with any real number of proper nouns
  comfortably exceeded DBConnection's 15 000 ms checkout-ownership timeout and
  lost its connection mid-rebuild, discarding writes for provider calls that
  had already run and already been billed. Each now reads in one short
  transaction, resolves with no transaction open, and writes everything
  durable in one final short transaction; the entity resolver resolves against
  an in-memory working set seeded from that read rather than re-reading the
  Account's entities per surface form, and keeps clearing a scope's stale
  mentions and writing its rebuilt ones in that same final transaction, so a
  failure anywhere still leaves the previous index in place rather than half
  cleared. Fixes a latent bug in `MemHouse.Retrieval.Vector.cosine/2`
  surfaced by the regression tests for this change: it multiplied and divided
  `Nx.Tensor` values with Kernel operators instead of `Nx.multiply/2` and
  `Nx.divide/2`, which always raised once an account actually had more than
  one entity to compare a surface form's embedding against — the entity
  resolver's fuzzy-match tier had never run successfully outside a fresh
  scope's very first surface form. Rebuild ordering, upsert-on-conflict entity
  convergence, mention-visibility inheritance, and the `f7-1` contract
  identity are unchanged.
- No external model call runs inside an Account database transaction any
  more. Extraction previously held one pooled PostgreSQL connection across the
  whole pipeline, including up to three sequential provider calls (one plus
  two bounded repairs) at up to `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` — 120
  seconds — each. DBConnection closes a connection whose checkout exceeds its
  ownership timeout, 15 000 ms by default and not overridden for
  `MemHouse.Repo`, so any extraction whose cumulative provider time crossed
  roughly 15 seconds lost its connection mid-transaction. The write recording
  an already-completed, already-billed call was discarded and the job retried,
  charging the Account a second time; observed at scale as roughly one in 25
  first attempts against a reasoning model. Raising `POOL_SIZE` does not help,
  because the failure is one connection held too long rather than too few
  connections. Three call sites are affected:
  `MemHouse.Memory.extract_message/2` and
  `MemHouse.Memory.extract_message_for_account/2`,
  `MemHouse.Documents.Service.process_version_for_account/2` (whose
  transaction also spanned the blob fetch, the parse, and the embedding call),
  and both provider calls on the `/api/ask` request path — the rerank step in
  `MemHouse.Retrieval.Engine` and grounded answer generation in
  `MemHouse.Memory`, each of which wrapped its call in a transaction that
  existed only to scope the model layer. Each now reads in one short
  transaction, calls the model holding no connection, and writes in a second
  short transaction where it writes at all.
  `MemHouse.Model.Config` and `MemHouse.Model.Usage` scope their own
  Account-scoped reads and writes through the new
  `MemHouse.DataLayer.in_account_transaction/2`, since role resolution and
  usage metering both run during a provider call. A consequence: a usage record
  now commits independently, so a caller whose own write fails afterwards no
  longer rolls back the ledger row for a call that really was billed.
  Extraction ordering, idempotency, advisory locking, gate outcomes, provenance,
  and the `f5-1`, `f7-1`, and `poc-0` contract identities are unchanged.
- PostgreSQL row-level security — the database-enforced half of cross-Account
  isolation described in `AGENTS.md` as "two independent locks on the same
  door" — was inert in every deployment mode and every test lane, because
  PostgreSQL exempts superusers from RLS unconditionally and `FORCE ROW LEVEL
  SECURITY` only removes the table owner's exemption, never the superuser's.
  Every connection MemHouse made was a superuser connection: `postgres` in
  `mix test` and every CI lane, and — the deployment-affecting case — the
  bootstrap role pg0's `initdb` creates in the turnkey single-node install.
  This did not leak tenant data; the Ash actor and tenant filter still ran on
  every query and were the layer actually enforcing isolation. It meant the
  documented backstop for a missed application-layer filter was not there,
  and no test could detect its absence. Every deployment mode now provisions
  and connects as a `NOSUPERUSER NOBYPASSRLS` role
  (`MemHouse.Database.AppRole`), and refuses to boot if that switch did not
  take unless `CARTULARY_ALLOW_UNRESTRICTED_DATABASE_ROLE=true` is set. See
  `specs/adr/0008-restricted-database-role-for-rls-enforcement.md` and
  GitHub issue #55.
- A job that failed once and was scheduled for a delayed retry (state
  `retryable`) stayed in that state permanently instead of running again once
  its backoff elapsed. `config :memhouse, Oban` sets `plugins: false`, and
  `AshOban.config/2` treats any `:plugins` value that is not already a
  non-empty list as "also disable peer leadership entirely" by forcing
  `peer: false`, which Oban resolves to a peer that can never become leader.
  Oban's job stager only promotes delayed `scheduled`/`retryable` jobs back to
  `available` while its node holds leadership, so every node was permanently
  unable to stage its own retries — silently, with no exception raised.
  `MemHouse.Application.oban_config/0` now restores the ordinary
  database-backed peer after `AshOban.config/2` runs, so this node can win
  leadership again; every other consequence of the empty plugin list (no
  Cron, no Pruner) is unchanged.
- Generation roles (`ingest_extractor`, `dream_reasoner`, `dialectic_agent`)
  now default to a bounded reasoning-token spend, an 8192 output-token cap,
  and a 120-second request timeout, overridable with
  `CARTULARY_MODEL_REASONING_EFFORT`, `CARTULARY_MODEL_MAX_TOKENS`, and
  `CARTULARY_MODEL_RECEIVE_TIMEOUT_MS` respectively. Without them, a
  reasoning model such as the default `openai/gpt-oss-120b` could spend an
  uncapped share of its context window on internal reasoning tokens
  regardless of input size — observed in practice as a single-sentence
  ingest extraction with ~600 input/tool tokens requesting roughly 131k
  output tokens and failing once it exceeded the model's whole
  131072-token context window — and, separately, could exceed ReqLLM's
  plain 30-second default request timeout, because ReqLLM only extends its
  timeout for model ids it recognizes as reasoning models (OpenAI's
  o-series, gpt-5, and codex families), which `gpt-oss-120b` does not match.
  `max_tokens` and `receive_timeout` request options already existed in
  `MemHouse.Model.Providers.ReqLLM`; `reasoning_effort` was added to its
  allowlist, and all three now have a default. Role options are always
  string-valued, but req_llm validates `reasoning_effort` against a fixed
  atom enum and rejects a string outright — every extraction call failed
  immediately on this option until `MemHouse.Model.Providers.ReqLLM` started
  converting it to the atom the schema requires.

### Added

- Entity-resolution quality is now observable without making the private
  entity cache public. The account-admin operations page reports entity and
  mention counts, observed-alias buckets, singleton-entity rate, and
  mentions-per-entity p50/p95. Statement detail reports and links only the
  other statements that share an entity and pass the reader's scope,
  lifecycle, soft-delete, and provisional-subject filters. The reviewed
  read-only store returns aggregates or authorized statement ids only; entity
  ids, canonical names, aliases, and surface forms remain pipeline-internal.
  No route or contract identity changed.
- Scope index coverage, so a scope that holds every governed statement and no
  embeddings is finally visible. Embeddings and entity mentions are written by
  the projection refresh alone; a refresh that was cancelled or never enqueued
  left semantic and entity recall permanently empty while full-text search kept
  answering — its index is a generated column no queue failure can lose — and
  nothing anywhere reported the gap. `MemHouse.Retrieval.index_coverage/3`
  returns per-scope statement, embedded, and entity-mention counts plus the
  embedding identities in use, filtered by Account and authorized scopes and
  narrowing provisional statements to their subject like every other retrieval
  query. Mentions are reported as a count, so the entity cache stays internal.
  `/console/scopes` shows the counts and highlights a shortfall, and every
  completed refresh emits `[:memhouse, :retrieval, :projection_refresh]` with
  `indexed`, `statements`, `embedded`, `mentions`, and `coverage` so an
  operator can alert on the ratio. No new table, route, or contract identity.
- Two off-by-default switches let an operator declare an Account or a whole
  deployment has no real human governance participant, and auto-grant the
  subject-consent step `MemHouse.Governance.Engine` otherwise blocks on for
  personal knowledge above peer level: `Account.consent_mode: "auto"`
  (account-admin only, audited) and `CARTULARY_GOVERNANCE_UNATTENDED=true`
  (boot-time, logged, reported on `GET /api/ready`). Intended for benchmark,
  evaluation, and synthetic-data deployments that have no real subject who
  could ever grant consent themselves. Also fixes a structural gap where the
  ordinary (non-promotion) ingestion path could never open a consent request
  at all, for a real subject or a declared-auto one. See
  `specs/adr/0007-unattended-governance-consent.md`.
- A browser console at `/console`, open to every human role. It carries an
  overview dashboard scoped to the reader's grants, a knowledge explorer with
  attribute filters and a side-by-side retrieval preview reporting contributed
  and dropped strategies, a per-statement page showing provenance, extraction
  and embedding identity, lifecycle timeline, gate decisions, relations, and
  the raw observations and document versions behind the claim, a scope
  directory, a deterministic server-rendered SVG graph of scopes and
  statements, a sources page, a skill card library with a self readiness check,
  a personal self-governance page, and an account-admin operations page.
  Curator decisions, promotion requests, and subject verdicts are dispatched to
  the existing operation layer; the console performs no durable write of its
  own and exposes no entity row, vector, chunk, or secret.
  `CartularyWeb.Console.Access` holds its two visibility rules — a
  `provisional` statement is visible only to its subject, and undecided or
  withdrawn states are curator-only except about oneself. New surface entry
  `browser_console` in `specs/eval/surface-contract-inventory.json`, gated by
  `test/cartulary_web/live/console_live_test.exs`,
  `test/cartulary_web/console/access_test.exs`, and
  `test/cartulary_web/console/graph_test.exs`. Design note:
  `specs/architecture/browser-console.md`; guide:
  `docs/guides/web-console.md`. No contract version identity changed.
- A general browser sign-in at `/sign-in` admitting any human password
  identity, plus `/sign-out` and a redirect from the bare origin to
  `/console`. It writes the same session key the curator sign-in uses, so one
  sign-in opens whichever surface the reader's role allows.
- A `docs/`, `README.md`, and `AGENTS.md` obligation binding browser-console
  changes to their documentation: a new row in the `AGENTS.md` change table and
  a "Browser console" discipline section covering the visibility rules,
  operation-layer-only writes, entity non-exposure, and the no-bundler and
  no-inline-script constraints on new controls.

- A published user documentation site built with MkDocs Material from `docs/`
  and deployed to GitHub Pages by `.github/workflows/docs.yml`. The site covers
  installation, a quickstart, how the system works (memory model, ingest
  pipeline, governance gates, retrieval and context, documents and connectors,
  skill readiness, isolation and access control, deployment modes),
  task-oriented guides, operations runbooks, and a reference section (HTTP API,
  configuration, Mix tasks, contract versions, glossary, limitations). Diagrams
  are Mermaid and render natively. The build runs with `strict: true`, so an
  orphaned page or a broken internal link fails CI. Enabling GitHub Pages with
  "GitHub Actions" as its source remains a maintainer-owned repository setting.
- A "Documentation layout" section in `AGENTS.md` and a "Where documentation
  goes" section in `CONTRIBUTING.md` making the two-tree split a contract, with
  a table mapping each kind of change to the document it must update in the
  same patch, plus a matching review question.

### Changed

- A retrieval strategy that could not run is now reported in
  `dropped_strategies` rather than as a contributing strategy that found
  nothing. `search` with a failed embedder previously returned an empty
  `semantic` result, which reads identically to a query with no near
  neighbours; the two call for opposite responses. Strategies may now return
  `{:error, reason}` from `candidates/2`, which the engine reports as
  degradation — matching how it already treats a deadline kill and a reranker
  failure. Response fields are unchanged; `semantic` simply now appears in
  `dropped_strategies` where it previously appeared in
  `contributed_strategies`.
- The curator queue at `/governance` now renders inside the shared console
  frame and takes its appearance from `priv/static/assets/console.css` instead
  of inline styles. Its route, module, events, decisions, and rendered heading
  are unchanged, so the curator-surface and skill-card regression evidence
  still holds. Curators reach it from the console navigation, and individual
  decisions can now also be taken from a statement's own page, where the
  evidence sits beside the controls.
- The browser pipeline now fetches the live flash, so a LiveView that reports a
  refusal while still rendering statically redirects instead of raising.
- Separated the documentation trees. `docs/` now holds only setup, usage, and
  operations documentation for readers of the published site; every
  design-facing document moved to `specs/`: `docs/adr/` → `specs/adr/`,
  `docs/architecture/` → `specs/architecture/`, `docs/roadmap/` →
  `specs/roadmap/`, `docs/eval/` → `specs/eval/`, `docs/security/` →
  `specs/security/`, `docs/observability/` → `specs/observability/`,
  `docs/implementation-status.md` → `specs/implementation-status.md`,
  `docs/superpowers/specs/` → `specs/design/`, and the versioning policy and
  release checklist from `docs/operations/` → `specs/process/`. File names are
  unchanged, so the recorded evaluation reports and every other evidence
  artifact keep their identities. References were updated in
  `MemHouse.ReleaseReadiness`, `mix memhouse.eval.release`, the evaluation
  regression test, `.github/CODEOWNERS`, the issue and pull request templates,
  the workflows README, `AGENTS.md`, `CONTRIBUTING.md`, and `README.md`.
- Replaced `docs/operations/README.md` with the new operations section and the
  getting-started install pages; `backup-restore.md` and `portability.md` stay
  under `docs/operations/` as operator-facing runbooks.
- Rewrote the `README.md` documentation map around the two trees and linked the
  published site from the header, the quick start, the operations section, and
  the observability section.
- Removed the retired `F5`, `F6`, and `F10` phase labels from `.env.example`
  comments.

- Made every first-party source file self-explanatory. Each module now carries
  a real `@moduledoc` stating what it owns, the invariants it guarantees, and
  the mistakes callers must avoid; public functions document their return shape
  and failure modes; comments explain why rather than restating code; and
  configuration, packaging, CI, and script files carry header comments naming
  purpose, inputs, outputs, and assumptions. No behaviour changed.
- Removed every pointer from source comments into `specs/` and `docs/`, and
  every remaining `F0`–`F11` phase label from code prose, replacing each with
  the rule stated in place. The `f`-prefixed contract identity values
  (`poc-0`, `f4-1`, `f5-1`, `f7-1`, `f9-1`, `f10-1`, `f11-1`, `f11-suite-1`,
  `f11-surface-contracts-1`, `memhouse-account-1`) are unchanged, and the test
  filenames that carry regression-evidence identities were deliberately not
  renamed.
- Added a "Coding conventions" section to `AGENTS.md` making the above a
  contract, with matching review questions, a `CONTRIBUTING.md` rewrite, and a
  self-explanatory-code checklist in the pull request template.
- Expanded `README.md` with a core-concepts glossary, an end-to-end walkthrough
  of an ingest request, a repository layout table, and a guided reading order.
- Corrected stale `blueprint/` paths to `specs/` in `CONTRIBUTING.md`,
  `.github/CODEOWNERS`, the pull request template, and the three issue
  templates.
- Replaced the boilerplate `priv/repo/seeds.exs` comment, which advised writing
  through `MemHouse.Repo.insert!/1` and so contradicted the pipeline-only and
  Ash-action-only write rules.
- Updated the official GitHub Actions used by CI, nightly evaluation, and
  release workflows to maintained Node 24 action majors.
- Retired the `F0`–`F11` roadmap phase labels from all documentation in favour
  of literal capability names, and removed proof-of-concept framing now that
  the project is a community beta. The `f`-prefixed contract identities
  (`f4-1`, `f5-1`, `f7-1`, `f9-1`, `f10-1`, `f11-1`, `f11-suite-1`,
  `f11-surface-contracts-1`) and the historical `poc-0` baseline are unchanged;
  they are version tags, not phase labels, and are now documented as such in
  `AGENTS.md` and `docs/architecture/free-core-architecture.md`.
- Renamed each `docs/architecture/fN-*.md` note to its capability name and
  rewrote `README.md` and `AGENTS.md` around the same vocabulary. `CLAUDE.md`
  is now an import of `AGENTS.md` instead of a duplicate copy.
- Changed the `prerequisite` value for the unavailable OpenAPI and generated
  SDK surfaces in `docs/eval/surface-contract-inventory.json` from `F8` to
  `integration-surfaces`, with the matching assertion updated in
  `test/memhouse/f11_evaluation_ci_release_readiness_test.exs`. The
  `f11-surface-contracts-1` schema identity and the `unavailable` statuses are
  unchanged.

### Added

- `docs/roadmap/beta-roadmap.md` as the single roadmap. It merges
  `l3-automation-flow.md`, `main-branch-ruleset.md`, and
  `manual-automation-setup.md`, absorbs the still-open phases of
  `free-core-roadmap.md`, records the verified GitHub configuration as of
  2026-07-28, and tracks every remaining item as a checkbox
  (`AD-EVAL-2`, `AINV-1`).

### Removed

- `docs/roadmap/l3-automation-flow.md`, `docs/roadmap/main-branch-ruleset.md`,
  and `docs/roadmap/manual-automation-setup.md`. Their still-relevant content
  is in `docs/roadmap/beta-roadmap.md`; the steps already completed in GitHub
  are recorded there as verified rather than repeated as instructions.
- `docs/roadmap/free-core-roadmap.md`. Its durable architecture content moved
  to `docs/architecture/free-core-architecture.md`; its completed phases are
  now history in `docs/implementation-status.md` (formerly
  `docs/poc-local-proof.md`).

## [0.2.1] - 2026-07-29

### Fixed

- Ingest extraction no longer fails validation with `confidence must be
  between 0 and 1` when a provider's structured tool-call output round-trips
  the `confidence` field as a JSON string instead of a native number —
  observed identically across unrelated backing models over the OpenRouter
  compat path, which pointed at a type problem rather than a range problem.
  `MemHouse.Model.Schema.Extraction`'s `confidence/1` validator now parses a
  numeric string before range-checking it; the 0–1 range check itself, for
  both numbers and numeric strings, is unchanged. No contract version
  identity changed. Regression evidence:
  `test/memhouse/model/schema_extraction_test.exs`.

## [0.2.0] - 2026-07-28

### Added

- F11 deterministic release guardrails for formatting, warnings-as-errors
  compilation, Ash snapshot drift, tests and properties, Credo, Dialyzer,
  Sobelow, surface privacy, provider cassettes, and evaluation report
  provenance (`AD-EVAL-1` through `AD-EVAL-5`, `AD-DATA-10`).
- Versioned `f11-1` release/nightly evaluation reports for MemHouse product
  scenarios, LoCoMo, LongMemEval, ConvoMem, and BEAM, including deterministic
  RAG-triad signals, abstention/citation measures, token efficiency, latency,
  per-category scores, degradation curves, and strategy ablations
  (`AD-EVAL-3`, `NFR-1`, `NFR-11`).
- External-Postgres and packaged pg0 CI lanes, release and container builds,
  scheduled evals, semantic-version/tag validation, and a fail-closed release
  checklist (`AD-EVAL-2`, `FR-PLAT-2`, `FR-PLAT-4`, `FR-PLAT-5`).

### Changed

- Replaced the obsolete SQLite CI placeholder with the Postgres-only parity
  model selected by ADR-0003.
- Advanced the application version from `0.1.0` to `0.2.0`. Retrieval remains
  profile contract `f7-1`; F11 versions evaluation evidence and release policy,
  not product retrieval behavior.
- Made the governance LiveView bootstrap asset part of the tracked release
  source so clean CI checkouts and packaged builds exercise the same curator
  surface as developer worktrees.

## [0.1.0] - 2026-07-28

### Added

- Initial MemHouse POC and free-core implementation through F10, including the
  F0 contract, F1–F7, F9, and F10 evidence described in the roadmap.
