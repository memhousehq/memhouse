<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Simplified memory rollout

The simplified recall path is an opt-in canary. The shipped default remains the
current profile until a human reviews held-out evaluation, PostgreSQL parity,
rollback, cost, and release evidence. Enabling the canary does not migrate or
delete source messages, governed Knowledge, provenance, lifecycle, consent,
audit history, or usage records.

## Before enabling it

1. Back up the PostgreSQL database and blob store at one recovery point.
2. Record the release revision, profile versions, model identities, embedding
   identity, dataset digest, thresholds, and operator-approved spend limit.
3. Install the pinned local Ortex model and tokenizer artifacts, then run the
   deterministic matched experiment and the full external-PostgreSQL gate.
   Require the packaged-pg0 lane to pass in CI. Without those local artifacts,
   the command stops before ingestion rather than substituting vectors.
4. Confirm source-message vectors are current and an authenticated exact and
   semantic source search succeeds in the canary scope.
5. Keep the prior release and configuration available for the whole
   compatibility window.

The deterministic comparison command is:

```bash
mix memhouse.eval.experiment \
  --definition specs/eval/experiments/memory-profile-ablation.json \
  --manifest-output /private/tmp/memhouse-experiment-manifest.json \
  --output /private/tmp/memhouse-comparison.json
```

No live or paid benchmark is implied by these steps. A human must approve its
provider, models, maximum cost, sample, and time limit before it runs.

## Canary configuration

Enable the experimental profile on canary nodes only:

```bash
MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL=true
```

Non-fixed Ask efforts then start from the `minimal` dual-lane-semantic-plus-lexical
profile and use the bounded read-only recall planner. Explicit `fixed` Ask and
explicit current-profile searches retain their existing behavior. Dream
synthesis remains off unless a separate matched evaluation approves it:

```bash
MEMHOUSE_EXPERIMENTAL_DREAM_OPERATION_SPLIT=false
MEMHOUSE_DREAM_SYNTHESIS_ENABLED=false
```

The first flag preserves the legacy single-call hourly/manual path. Evaluate
the split with active governed inputs before canarying it; a configured flag or
zero-work pass is not operation evidence.

Roll out by Account/scope traffic assignment outside MemHouse. Do not mix
current and candidate results under one experiment label, and do not tune
thresholds after reading the candidate results.

## Signals and stop conditions

All signals below contain identifiers, counts, versions, timings, or reason
classes only. They must never contain query, memory, evidence, prompt, or
answer text.

| Signal | Event or surface | Stop condition |
| --- | --- | --- |
| Extraction anchors, logical `batch_requests`, exact `provider_attempts`/`calls`, tokens, admission geometry | `[:memhouse, :operation, :completed]` with `operation: "ingest_batch"` (including the `stale_claims` subset of failed anchors), Ingest status/PipelineRun payload, and Usage ledger | Repairable/terminal rate, repair amplification, queue delay, stale-claim rate, or token/provider-attempt budget exceeds the matched geometry |
| Recall calls, items, query tokens, elapsed time, exhaustion | `[:memhouse, :recall, :planner]` and Ask `recall` diagnostics | Any run exceeds a preregistered bound, or exhaustion rate/latency exceeds the manifest budget |
| Retrieval latency and dropped components | `[:memhouse, :retrieval, :outcomes]`, `:component`, and `:degraded` | p95 or degraded rate exceeds the matched threshold |
| Source-search freshness and availability | `[:memhouse, :retrieval, :source_search]` and source-search status | Sustained `stale`, `unavailable`, or `failed`, or citation targets cannot resolve |
| Projection/index freshness | `[:memhouse, :retrieval, :projection_refresh]` and Operations console | Coverage below the operator threshold after the rebuild allowance |
| Dream work and skips | `[:memhouse, :operation, :completed]` with `operation: "dream"`, operation-specific reasoning aggregates, and `[:memhouse, :pipeline, :dream_gate]` | Queue growth, repeated elapsed-budget skips, or replay durable effects |
| Model calls, tokens, and spend | Usage ledger and `/api/v1/operations/costs` | Preregistered token or spend ceiling reached |
| Citation and answer safety | Eval bundle, Ask abstention/degraded fields, `[:memhouse, :ask, :degraded]` | Any isolation leak or unsupported claim; citation or abstention below its gate |
| Queue health | `/api/ready` and `/console/operations` | Sustained unavailable queue or depth beyond the declared canary budget |

Isolation leaks, authorization failures, unresolvable citations, audit/replay
regressions, and data loss stop the canary immediately. Quality, latency, queue,
or cost regression stops expansion and returns traffic to the current profile.

## Read the states correctly

| State | Meaning | Operator action |
| --- | --- | --- |
| `empty` | The authorized corpus or query match is empty | Verify scope/peer selection; do not rebuild automatically |
| `stale` | Rows exist but their embedding identity does not match | Run the explicit re-embed/rebuild path; lexical recall remains available |
| `degraded` | A bounded component failed or was dropped and partial evidence survived | Inspect its content-free reason class and latency allowance |
| `budget-exhausted` | Planner reports one or more `exhausted` bounds | Treat the answer as bounded; change a reviewed effort preset, not one request ad hoc |
| `unavailable` | A required model/index capability is not configured | Restore the capability or select the compatibility profile |
| `failed` | The component attempted work and returned a classified failure | Correlate trace, usage event, and queue state; stored sources remain durable |

`empty` is not an outage, `stale` is not data loss, and an exhausted planner is
not allowed to silently continue with more calls.

## Rollback rehearsal

1. Set `MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL=false` on canary nodes and restart
   them with the same release.
2. Route canary traffic back only after readiness is green.
3. Exercise an authenticated current-profile search and Ask in the same scope.
4. Verify source-message, Knowledge, audit, and usage counts are unchanged and
   the hash-chain audit verifier still passes.
5. Let existing rebuild jobs finish or cancel only through their supported
   pipeline controls. Never delete job rows or derived state by hand.

This rollback does not reverse migrations because the experiment is additive.
If the release itself must be rolled back, restore the database and blob
snapshot together before starting old code, as described in
[Upgrades](upgrades.md).

Physical removal of a derived component is governed by the repository's
[`specs/eval/component-retirement-manifest.md`](https://github.com/memhousehq/memhouse/blob/main/specs/eval/component-retirement-manifest.md).
No component in this release qualified for physical deletion.
