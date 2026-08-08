<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Model Layer And Structured Extraction

A provider-neutral, metered model boundary replaces the direct OpenRouter
extractor. It implements `FR-KN-5`, `FR-KN-6`, `FR-KN-10`, `FR-KN-11`, `FR-FORM-13` through
`FR-FORM-16`, `AD-MODEL-1` through `AD-MODEL-6`, `AD-OBS-4`, `AD-EVAL-1`, and
the model-outage portion of `NFR-8`.

## Role and provider boundary

`MemHouse.Model.Config` resolves exactly four Account-level roles:

| Role | Capability | Default |
| --- | --- | --- |
| `embedder` | Pinned vector generation | Local Qwen3-Embedding-0.6B through Ortex/ONNX, 1024 dimensions |
| `ingest_extractor` | Fast structured observation extraction | ReqLLM generation role |
| `dream_reasoner` | Slow structured reasoning and optional rerank | ReqLLM reasoning role |
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
through its native strict JSON-schema response format. Each candidate starts
with a concise validation-only reasoning string and its natural-language
statement, then an integer `confidence_percentage` from 1 through 100. The
validator strips non-digits from that field, checks the range, and divides by
100 before it passes the resulting confidence to governance. Reasoning is not
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
- `add`, `merge`, `supersede_candidate`, or `no_op`;
- hearsay classification with a confidence discount; and
- expiry, revalidation, and valid-time bounds.

Subjects are limited to known Peers or the current scope. New items enter
`proposed` and pass Gate A/B. The reasoning
schema reuses the same candidate shape and adds typed
`supports`/`contradicts`/`derived_from` relations. The dream lane owns durable
retries and budgets; higher-order result application and projections remain
separate pipeline work.

The dialectic response schema requires answer text, retrieved knowledge IDs,
and an explicit abstention flag. The flag is independent of citation presence:
an inconclusive answer may preserve its qualified text and verified citations
while keeping `abstained` true. `Memory.ask` verifies that every returned
citation was in the retrieved set; when none survive it returns the empty
grounded abstention, and on model error it falls back to the existing grounded
assembler. `get_context` performs no model call.

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

## Provenance, metering, and safety

Knowledge and provenance now store provider, model, model version, prompt
version, pipeline version, and embedding identity fields. Extraction uses
prompt `extract-3` and pipeline `f5-1`. Its prompt explicitly requires
confidence as a JSON fraction from `0.0` through `1.0`; the Ash-derived JSON
schema independently enforces the same numeric bounds.

`MemHouse.Model.Usage` is the one durable emission point. Each provider call,
including every repair attempt and returned provider error, appends one
Account- and optional scope/Peer-attributed `UsageEvent` with operation, role,
provider, model/version, prompt/pipeline versions, input/output/embedding token
counts, duration, status, timestamp, and a content-safe metadata allowlist.
OpenTelemetry mirrors safe timings and counts but is not the exact ledger.
Prompts, answers, observations, credentials, and secrets never enter usage
metadata, spans, audit records, or Oban arguments.

Each `UsageEvent` commits in its own short Account transaction. A later caller
failure cannot roll back a call that already happened and was billed.

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
