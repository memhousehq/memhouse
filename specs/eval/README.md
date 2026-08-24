# Evaluation Documentation

Evaluation, CI, and release readiness upgrades the original harness into a
versioned deterministic gate and release/nightly matrix. Implementation and
release posture are recorded in
`specs/architecture/evaluation-ci-release-readiness.md`.

The local harness supports MemHouse product-shaped fixtures plus LoCoMo,
LongMemEval, ConvoMem, and BEAM memory paths. It exercises the durable message
write path, pipeline knowledge extraction, scoped retrieval, grounded
answering, and citation validation against Postgres.

For development traces, experiment labels, Langfuse forwarding, and the
measurement checklist that should accompany eval reports, read
`specs/observability/README.md`.

Minimal LoCoMo, LongMemEval, and BEAM benchmark results are checked in at
`specs/eval/minimal-benchmark-results.md`, with raw JSON reports under
`specs/eval/results/`.

Those 2026-07-27 `poc-0` reports are the immutable Stage 0 baseline from before
the retrieval, entity resolution, and context rework; `poc-0` is a historical
profile version tag rather than a phase name. Current public claims must use
the `f11-1` report schema and exact `f7-1` profile evidence; never relabel the
historical files.

Report schema `f11-2` added top-level accounting counts
and an `accounting` block with
available, sampled, attempted, evaluated, skipped, failed, and cancelled counts
plus one private-content-free item id/status record per sampled case. The counts
must balance (attempted means evaluated, failed, or cancelled); `f11-1` remains readable as a historical compatibility format and
the committed reports are not rewritten.

New runner output uses report schema `f11-3`. It adds a content-safe `lifecycle`
block while retaining the `f11-2` accounting contract. It reads all
case scopes with the internal Account actor, so authorization-hidden states are
included. `final_states` contains all public states, including zeroes, while
`absent_final_states` describes the end-of-run snapshot and `exercised_states`
is derived from transition history;
`transitions` counts each `from_state`, `to_state`, and stable reason, and
`audit_transitions` must be exactly the same distribution;
`unexercised_states` identifies states transition history never reached and
`unexercised_reasons` records the contract fixture each such state requires. The validator
requires the transition total, lifecycle-event total, and matching lifecycle
audit total to balance. This is evidence of what the fixture exercised, not a
claim that an ordinary workload must use every state.

The baseline contract also freezes the four tiny input fixtures independently
of volatile database UUIDs and latency values.
`test/fixtures/eval/poc-contract-baseline.json` records each MemHouse, LoCoMo,
LongMemEval, and BEAM fixture's SHA-256 plus its normalized case, message, and
question IDs.

```bash
mix test test/memhouse/eval/fixture_contract_test.exs
```

```bash
mix memhouse.eval.smoke --profile balanced --account eval-poc
```

To write a JSON report:

```bash
mix memhouse.eval.smoke \
  --profile balanced \
  --account eval-poc \
  --output /private/tmp/memhouse-smoke-report.json
```

The built-in fixture is intentionally small. Custom fixtures use this shape:

```json
{
  "benchmark": "local-smoke",
  "messages": [
    {
      "session_id": "s1",
      "scope_path": "/bench/locomo",
      "peer_key": "alice",
      "role": "user",
      "content": "Alice prefers concise status updates."
    }
  ],
  "questions": [
    {
      "id": "q1",
      "scope_path": "/bench/locomo",
      "question": "What does Alice prefer?",
      "expected": "concise status updates",
      "metadata": {"peer_key": "alice"}
    }
  ]
}
```

`questions[].metadata.peer_key` is optional. Set it when the run must evaluate
that already-ingested Peer's governed view or stable identity profile. Without
it, the evaluation harness retains its internal Account reader and does not
guess an identity from message order.

Run a fixture with:

```bash
mix memhouse.eval.smoke --dataset path/to/smoke.json --profile balanced
```

## Deterministic Release Matrix

Run every committed engine/product fixture and the strategy ablations:

```bash
mix memhouse.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/memhouse-f11-release.json

mix memhouse.eval.verify /private/tmp/memhouse-f11-release.json
```

The manifest is `release-suite.json`; deterministic correctness/citation floors
are in `deterministic-thresholds.json`. The manifest uses distinct
`held-out-tuning` and `release-evaluation` names and disables deadlines for
comparable ablations.

Every `f11-1` report records:

- MemHouse semantic version and execution date;
- dataset id, SHA-256, and split;
- profile and exact profile version;
- strategy override and deadline setting;
- provider/model/version/prompt/pipeline identity for all five roles;
- deterministic or model judge identity;
- exact/contains/token-F1, abstention, citation, RAG-triad, latency, token
  efficiency, category, scale, and BEAM degradation measures.

Every `f11-2` question also records `expected_evidence_refs`,
`first_supporting_rank`, `recall_at_k`, and `evidence_absent`. The top-level
`metrics.retrieval` block aggregates these deterministic rank measurements
separately from answerer and judge scores; it uses the full ordered candidate
list, not only answer citations.

`mix memhouse.release.check` requires this evidence for an actual release.
Manual live-model runs add `--judge model`; the configured dream-reasoner must
be a different provider/model family from the dialectic answer role or the run
fails before scoring.

## Matched Profile Experiments

`mix memhouse.eval.experiment` is the controlled-ablation entrypoint. One definition contains one
current and one experimental variant over the same dataset. The command emits a resolved
`memhouse-experiment-manifest-1` artifact and a `memhouse-comparison-1` bundle rather than asking a
maintainer to compare two unrelated runner files by hand.

```bash
mix memhouse.eval.experiment \
  --definition specs/eval/experiments/memory-profile-ablation.json \
  --manifest-output /private/tmp/memhouse-experiment-manifest.json \
  --output /private/tmp/memhouse-comparison.json
```

Execute definitions use a closed component map derived from executable settings: profile,
effective strategies and seed stages, rerank, deadline, extraction batching identity and limits, adaptive recall
effort, source and lineage recall permissions, Knowledge semantic-index refresh, source-message
semantic-index refresh, RecallDocument refresh, idle scheduling gates, explicit dream execution,
the default-off dream-operation split, and durability audit. The map must exactly match the runner
inputs and resolved profile or validation fails. Source-message semantic refresh runs
synchronously in each isolated case scope before questions and records only completion, counts,
and the four-part embedding identity. A variant that declares source recall, lineage recall, or
split reasoning must record an actual completed source-semantic tool, lineage tool, or every
enabled split operation respectively; permission or configuration alone is not execution evidence.
Unknown keys are unsupported rather than
inert labels. Runtime feature switches are restored even when execution raises. Fixture
definitions must keep `components` empty because replaying supplied metrics does not execute a
component. The source revision and dirty/clean state, dataset digest, and explicit
sampling/durability seeds prevent results from two different inputs or implementations being
presented as one ablation.

The committed smoke definition compares the real `balanced` default strategy set and synchronous
fixed recall with the `minimal` dual-lane profile, durable extraction batching, high-effort bounded
recall, explicit source/lineage permissions, idle scheduler switch, and explicit dream pass. Both
variants refresh the isolated Knowledge-derived vector index; only the minimal variant refreshes
the source-message semantic index and rebuilds its non-authoritative RecallDocument projection.
The three refreshes are separately executable and reported rather than one composite maintenance
label.
An offline run therefore requires an Ortex embedder with existing operator-supplied model and
tokenizer artifacts; missing artifacts or a hosted/deterministic stand-in embedder are rejected
before ingestion. `--live-model` is the explicit provider-call boundary and may incur cost. The
harness never stores fake deterministic embeddings.

The measured section stages quality, citation, abstention, unexpected-source isolation, provider
usage, operator-priced cost, wall/recall latency, stored facts, dream-time accounting, database
query count/timing, and new `PipelineRun` work by kind and status. A telemetry handler counts only
the bounded runner interval; the before/after snapshot queries are outside it. It never records
SQL, parameters, results, content, or Account ids. An idle-enabled execute case must supply at
least two active direct-item generations in its exact scope. The harness creates real durable
`PipelineRun` and Oban work through `MemHouse.Pipeline`, verifies schedule and generation order,
executes the stale and latest generations through the production workflow, and replays the latest
generation. It fails closed unless the stale wake is superseded before model work, the latest wake
completes, and replay has zero additional durable effect. A split-operation execute variant also
fails unless its explicit dream pass records every enabled operation.
Gates cover regression, citation and unsupported-answer failures, source-membership leaks,
token/cost and latency budgets, and replay effects. Measured evidence is structurally separate
from inferences and unreproduced first-party claims.
Source-membership accounting normalizes both legacy message provenance and bounded typed
`source_references`. Message identities translate into the fixture's turn/session labels for
citation and rank scoring; a document-version identity cannot belong to the message-only runner
case and is counted only as a content-free isolation leak.

Execute mode uses deterministic local model roles unless the operator explicitly passes
`--live-model`. Fixture mode starts neither the application nor a provider and is not quotable
benchmark evidence. Its committed manifest and bundle under `specs/eval/results/` are exact
reproduction evidence for the comparison contract.

Both production database modes use PostgreSQL. The resolved manifest records `external` or `pg0`;
SQLite is deliberately rejected because the vector, full-text, RLS, and transactional queue
contract has no SQLite implementation.

## Full Benchmark Ingestion And Scoring

MemHouse also includes a full benchmark runner for fixture ingestion and
deterministic scoring:

```bash
mix memhouse.eval.benchmark \
  --benchmark locomo \
  --dataset path/to/locomo10.json \
  --profile balanced \
  --account eval-locomo \
  --output /private/tmp/memhouse-locomo-report.json
```

Supported source formats:

- `--benchmark locomo`: LoCoMo `locomo10.json` samples with `conversation`
  sessions and `qa` evidence refs such as `D1:3`.
- `--benchmark longmemeval`: LongMemEval cleaned JSON files with
  `haystack_sessions`, `haystack_session_ids`, `answer_session_ids`, and
  per-question metadata.
- `--benchmark convomem`: ConvoMem rows with conversation/message history,
  question/answer, category, evidence ids, and abstention metadata.
- `--benchmark beam`: BEAM-style chat/probing-question JSON. The adapter accepts
  common generated-artifact field names such as `messages`, `conversation`,
  `probing_questions`, `questions`, `chat_size`, and `ability`.
- `--benchmark memhouse`: the local JSON shape used by the smoke harness.

Useful options:

```bash
mix memhouse.eval.benchmark \
  --dataset path/to/fixture.json \
  --limit-cases 1 \
  --limit-messages 200 \
  --limit-questions 10 \
  --no-model
```

`--no-model` forces the deterministic extractor and fallback answerer so local
regression runs do not depend on a model provider. Without it, the runner uses
the configured model path for extraction/answering, then scores the outputs
deterministically.

The JSON report includes:

- Per-question answer metrics: exact match, expected-answer containment,
  token-F1, abstention correctness, citation hit, citation recall, latency, and
  contributed retrieval strategies.
- Aggregate metrics overall, by category, and by scale.
- For BEAM, a `beam_degradation_curve` grouped by corpus scale.
- RAG-triad lexical baseline, full-context/token-efficiency, profile/model
  version, deadline, dataset digest/split, date, and run-limit evidence, so a
  published number is reproducible and comparable (see `specs/adr/0004-multi-strategy-retrieval.md`).

The runner uses the real durable write/read path (`MemHouse.Memory`) and
therefore records raw messages, pipeline-created knowledge, lifecycle events,
retrieval, answers, and citations in Postgres. It is still a smoke-scale
harness: it does not claim upstream judge parity or upstream-scale scores from
the committed minimal fixtures. Live/pinned provider runs and larger public
datasets use the same adapter/runner/report contract. The shipped release
matrix provides held-out tuning discipline, named strategy ablations,
deterministic release thresholds, explicit deadline reporting, and
pg0/external-Postgres CI parity.

The surface contract inventory records the intentional integration-surfaces
boundary (still to be implemented; tracked in
`specs/roadmap/beta-roadmap.md`): current Phoenix, MCP, and skill-readiness
helpers are gated; generated OpenAPI and complete SDKs are explicitly marked
`unavailable`.
