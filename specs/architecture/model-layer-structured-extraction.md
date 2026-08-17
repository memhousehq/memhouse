<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Model Layer And Structured Extraction

A provider-neutral, metered model boundary replaces the direct OpenRouter
extractor. It implements `FR-KN-5`, `FR-KN-6`, `FR-KN-10`, `FR-KN-11`, `FR-FORM-13` through
`FR-FORM-16`, `AD-MODEL-1` through `AD-MODEL-6`, `AD-OBS-4`, `AD-EVAL-1`, and
the model-outage portion of `NFR-8`.

## Role and provider boundary

`MemHouse.Model.Config` resolves five Account-level roles:

| Role | Capability | Default |
| --- | --- | --- |
| `embedder` | Pinned vector generation | Local Qwen3-Embedding-0.6B through Ortex/ONNX, 1024 dimensions |
| `reranker` | Query-document precision ranking | Local BAAI/bge-reranker-v2-m3 cross-encoder through Ortex/ONNX |
| `ingest_extractor` | Fast structured observation extraction | ReqLLM generation role |
| `dream_reasoner` | Slow structured reasoning | ReqLLM reasoning role |
| `dialectic_agent` | Grounded structured answers | ReqLLM dialectic role |

An active, versioned `ModelRoleConfig` record wins over runtime defaults.
Per-scope role overrides remain deliberately deferred. Configuration persists
secret references such as `env:OPENROUTER_API_KEY`, never raw credentials; the
Ash actions reject raw secret keys in role options.

Every provider call and repair resolves configuration through
`MemHouse.DataLayer.in_account_transaction/2`. Provider calls hold no
transaction. Without the Account setting, RLS would hide the row and silently
select runtime defaults, producing false provider/model provenance.

Every capability uses `MemHouse.Model.Provider`; `Gateway` alone invokes
callbacks and selects the test, deterministic local, Ortex, or ReqLLM adapter.
ReqLLM supplies OpenRouter, OpenAI-compatible, and self-hosted provider support
without a second engine runtime. There is no in-engine provider cascade:
operators can place an OpenAI-compatible proxy in front of a role when they
need deployment-level fallback.

## Structured extraction and reasoning

`StructuredGenerator` performs non-streaming provider-native structured
generation followed by Ash-backed validation. Invalid output gets at most two
content-safe repair attempts. Exhaustion returns an error to the pipeline so
AshOban can retry; it never turns malformed output into knowledge.

OpenRouter structured calls use its native strict JSON-schema response format,
not a forced synthetic tool call. This avoids models that complete their
reasoning without emitting the forced tool call; ordinary chat retains normal
tool calling.

The extraction JSON schema is derived from `KnowledgeItem` attributes and the
candidate is validated against `create_from_pipeline`. OpenRouter receives it
through its native strict JSON-schema response format. The schema uses
`propertyOrdering` to put the completed natural-language statement before
`confidence_level`. The extractor does not request validation-only reasoning
that no durable output uses. The three anchored
levels map to fixed stored values: `stated_explicitly` to 1.0,
`clearly_implied` to 0.8, and `inferred` to 0.6. Revalidation remains gate-rule
policy, and declining produces no candidate. Gate A receives a deterministic
source-to-subject evidence level after schema validation. Reasoning is not
persisted, metered, or logged.

Statement text is canonicalized — invisible characters removed, whitespace runs
collapsed — before it is hashed, and then measured against the readability rule
in `MemHouse.Knowledge.Statement`: it must carry letters or digits, and above a
24-character floor at least 60% of its non-space characters must be. A decoding
collapse into repeated ellipsis measures below 0.40 where observed prose
measures 0.79 and above. The cast reports the failure so the repair prompt can
act on it, and `create_from_pipeline` validates the same rule so the resource,
not the extractor, is the gate. Repeated real words are not detected.

Each candidate also includes:

- kind, sensitivity, and target level;
- peer or current-scope subject, independently of the source Peer;
- schema-derived direct or indirect source evidence with a confidence discount;
- expiry and valid-time bounds; and
- message source ids from the bounded same-session extraction window. The
  validator rejects ids outside that window; each retained id becomes durable
  provenance for the knowledge item.

Subjects are limited to known Peers or the current scope. New items enter
`proposed` and pass Gate A/B. The reasoning
schema reuses the same candidate shape, requires at least two active contributor
ids for each deduction, and adds typed
`supports`/`contradicts`/`derived_from` relations. The dream lane owns durable
retries, budgets, and per-scope input watermarks. It calls the provider outside
a database transaction, then applies governed proposals and relations,
coalesces derived refreshes, and advances the watermark in one short Account
transaction. Accepted deductions receive provenance and contributor relations;
changed or removed contributors mark them for revalidation. A provider or write
failure leaves the watermark unchanged.
Projection rebuilding remains separate pipeline work.

The dialectic response schema requires answer text, retrieved knowledge IDs,
and an explicit abstention flag. The flag is independent of citation presence:
an inconclusive answer may preserve its qualified text and verified citations
while keeping `abstained` true. `Memory.ask` verifies that every returned
citation was in the retrieved set; when none survive it returns the empty
grounded abstention, and on model error it falls back to the existing grounded
assembler. `get_context` performs no model call.

The `extract-13` and `f5-1` prompt and pipeline versions enforce subject and
source-grounding rules:
agent peers are excluded from the subject allowlist and machine referents are
refused, preserving the verified contract that knowledge is about people and
never about the infrastructure that carried it. Ingest candidates quote an
exact span from a cited message. Validation also rejects an ISO statement date
unless cited text contains that date or a relative-time expression that can
resolve to it. When that exact span is first-person, validation derives the
subject from the cited message's stored speaker key. It ignores the model's
subject reference and fails closed if the cited evidence does not resolve to
one known human peer. The cited speaker also determines direct or indirect
evidence. Validation sends first-person statement prose back for repair because
an opaque peer key cannot safely supply a display name.

## Embeddings

`MemHouse.Model.Embedding.Ortex` implements `AshAi.EmbeddingModel` using local
Tokenizer and ONNX artifacts through Tokenizers and Ortex. It does not download
models or send text to a network. `MemHouse.Model.Embedding.ReqLLM` delegates to
AshAi's ReqLLM adapter for an API-backed role.

Every vector carries provider, model, version, and dimensions. A consumer must
compare the stored identity with the configured identity before reuse.
Mismatch returns an `f5-1` `reembed_all` plan with
`reuse_existing_vectors: false`; the engine never silently substitutes an
incompatible vector space. The version covers the ONNX artifact, tokenizer,
pooling strategy, and dimensions, so changing any of them requires a version
bump. Retrieval, entity resolution, and context now supply the
knowledge/document vector columns, resumable Account-wide re-embedding,
1024-dimensional DiskANN indexes, semantic strategy, and tiny-corpus Nx
baseline. The shipped Qwen3 identity uses `input_ids` plus `attention_mask`,
mask-aware last-token pooling, and a query-only instruction prefix.

## Reranking

`MemHouse.Model.Reranking.Ortex` scores tokenized query-document pairs with a
pinned classifier and returns its unbounded relevance logits. It never downloads
artifacts. Reranking has a dedicated `:reranker` role so slow reasoning does not
consume the retrieval budget. Native hosted rerank endpoints remain supported;
structured generation is available only when retrieval deadlines are disabled.
ADR 0015 records the boundary.

## Provenance, metering, and safety

Knowledge and provenance now store provider, model, model version, prompt
version, pipeline version, and embedding identity fields. Extraction uses
prompt `extract-13` and pipeline `f5-1`. It defines durable claims as stable
facts, preferences, relationships, possessions, skills, commitments, plans,
and lasting events. It drops conversation residue and schema validation rejects
questions, speech-act transcriptions, and peer claims that omit their subject.
Message extraction uses a trailing six-message same-session window, with the
target message as its explicit anchor. Relative dates resolve against the
observation time into `relevant_from` and `relevant_until` only when the source
states or implies the boundary; statement text does not repeat that time unless
a date is part of the claim. Observation time never supplies valid time, and
expiry remains governance policy. Readers render the structured valid-time
fields when they need the date. The prompt requires
`confidence_level` as `stated_explicitly`, `clearly_implied`, or `inferred`;
`Extraction.cast/2` maps these labels to fixed stored numeric fractions.

Adjacent pending anchors in the same Account, scope, and session may share one
`extract-13` provider call. `ExtractionBatch` requires an explicit envelope per
anchor and reuses `Extraction.cast/2` with that anchor's independent validation
context. `utf8-bytes-v1` pre-call admission counts serialized instructions,
schema, evidence windows, reserved output, and safety margin. Supported
experiment targets are 128, 1K, 4K, and 16K; the tokenizer and all budget values
form the admission identity stored on each completed run.

Batch ownership is a temporary `processing` state on the existing per-message
PipelineRun, not a second queue table. Every anchor persists candidates,
governance effects, message completion, and run completion in one short
transaction. Bounded repair may terminally isolate one malformed envelope while
valid siblings progress. Repairable configuration and oversized states, and
terminal source poison, are excluded from automatic reconciliation; explicit
operator requeue is required. Stale `processing` claims return to failed after
the configured lease so a crashed worker cannot strand them.

`MemHouse.Model.Usage` is the one durable emission point. Each provider call,
including every repair attempt and returned provider error, appends one
Account- and optional scope/Peer-attributed `UsageEvent` with operation, role,
provider, model/version, prompt/pipeline versions, input/output/embedding token
counts, duration, status, timestamp, and a content-safe metadata allowlist.
An error that returns no provider usage is marked `unmetered`; its token fields
stay zero for ledger compatibility, but its cost remains explicitly unknown.
OpenTelemetry mirrors safe timings and counts but is not the exact ledger.
Prompts, answers, observations, credentials, and secrets never enter usage
metadata, spans, audit records, or Oban arguments.

Each `UsageEvent` commits in its own short Account transaction. A later caller
failure cannot roll back a call that already happened and was billed.

The gateway classifies total request deadlines as `request_timeout` and other
transport failures as `transport_error`. The classifications contain no
provider message, prompt, or response text.

The ledger reports failures that have happened; it cannot report a role that
has never been called, and a rate cannot show that schema enforcement was lost.
`MemHouse.Model.Probe` covers both: one fixed, content-free structured call per
generative role, resolved from deployment configuration, sending the configured
limits unchanged and writing no usage row. An object that does not carry the
required key is `schema_not_enforced`, and a role on the deterministic adapter
is skipped rather than passed. Graded evaluation refuses to start unless every
generative role passes it, because a scored run cannot distinguish a weak answer
from one that was never generated.

A role naming `openrouter` uses that provider's JSON-schema response path. The
same endpoint reached as `openai-compatible` has no recognised model identity
and would revert to a forced tool call that some models decline, so the role
option `structured_output_mode` sets the mode explicitly there. An unusable
value fails the call rather than degrading to tool calling.

Raw observation, audit, `PipelineRun`, and AshOban enqueue still commit before
any provider call. A provider error leaves the raw message and queued job
durable, keeps extraction incomplete, and is returned for retry. The same
behavior applies when a provider-backed dream step is composed into the
transactional job lane. Context reads remain available during an outage.

The deterministic adapter is explicit configuration for tests and local
development only. Development may select it when no key is present and
`MEMHOUSE_MODEL_LOCAL_FALLBACK=true`; production defaults that flag to false
and never switches to deterministic output after a live provider fails.

## `f5-1` transition

Response shapes, identity-derived tenancy, downward inheritance, pipeline-only
writes, raw durability, Gate A/B, and normalized fixtures remain regression
floors. Extraction provenance and pipeline identity advance from `poc-0` to
`f5-1`, and health now reports
`f5-1`. Retrieval, entity resolution, and context subsequently advance
retrieval/context profile identity to `f7-1` without changing the
message/extractor identity. These are historical contract tags, not roadmap phases.

## Evidence

- Provider, schema, embedding, and usage boundary: `lib/memhouse/model/`
- Pipeline integration: `lib/memhouse/pipeline/extractor.ex` and
  `lib/memhouse/memory.ex`
- Resource migration:
  `priv/repo/migrations/20260727231504_f5_model_layer_structured_extraction.exs`
- Generated resource snapshots: `priv/resource_snapshots/repo/`
- Model layer and structured extraction acceptance suite:
  `test/memhouse/f5_model_layer_structured_extraction_test.exs`
- Deterministic replay adapter and cassette:
  `test/support/model_cassette_provider.ex` and
  `test/fixtures/model/f5-provider-cassette.json`
- Updated baseline contract evidence:
  `test/memhouse/poc_contract_test.exs` and
  `test/memhouse_web/controllers/memory_controller_test.exs`
