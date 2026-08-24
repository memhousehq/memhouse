<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Mix tasks

These commands require a source checkout. Packaged-release equivalents are
listed where available.

| Task | Purpose |
| --- | --- |
| `memhouse.identity.bootstrap` | Create the Account and first administrator |
| `memhouse.portability.export` | Write a whole-Account logical archive |
| `memhouse.portability.import` | Load or verify an archive |
| `memhouse.reembed` | Enqueue or inspect an embedding transition |
| `memhouse.model.check` | Probe structured output for every generative role |
| `memhouse.governance.autoshare` | Let one Account keep and place knowledge without a human |
| `memhouse.eval.smoke` | Developer sanity pass over the real write/read path |
| `memhouse.eval.benchmark` | Run one benchmark fixture and score it |
| `memhouse.eval.experiment` | Compare matched current and experimental memory profiles |
| `memhouse.eval.release` | Run the deterministic release matrix |
| `memhouse.eval.verify` | Validate a report's provenance |
| `memhouse.release.check` | Fail unless the tree is releasable |

Packaged standalone releases additionally provide `bin/update --check` and
`bin/update --version MAJOR.MINOR.PATCH`; these are not Mix tasks.

---

## `memhouse.identity.bootstrap`

Provisions the community Account, first password identity, root administrator
grant with downward propagation, and a 12-hour bearer token.

```bash
MEMHOUSE_BOOTSTRAP_PASSWORD='a long password' \
  mix memhouse.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

| Switch | Notes |
| --- | --- |
| `--email`, `-e` | Required. Becomes the sign-in identity and, normalised, the peer key |
| `--name`, `-n` | Display name. Defaults to the email |
| `--password` | Prefer the environment variable — an argument is visible in shell history and the process list |

There is no fallback password. Re-running for an existing email raises. The
whole bootstrap is one transaction, so a failure never leaves a half-created
administrator.

**In a release:** call `MemHouse.Identity.bootstrap_human/1` through
`bin/memhouse rpc` — see the
[Quickstart](../getting-started/quickstart.md#1-bootstrap-an-administrator).

---

## `memhouse.portability.export`

```bash
mix memhouse.portability.export --output /secure/path/memhouse-account.tar.gz
```

Default output is `memhouse-export-YYYY-MM-DD.tar.gz` in the working
directory. Read inside one Account-scoped transaction, so the snapshot is
internally consistent.

**In a release:**
`bin/memhouse rpc 'MemHouse.Release.export!("/secure/path/account.tar.gz")'`

See [Export and import](../operations/portability.md) for what is included.

---

## `memhouse.portability.import`

```bash
mix memhouse.portability.import --input /secure/path/account.tar.gz
mix memhouse.portability.import --input /secure/path/account.tar.gz --validate-only
```

Before writing, import verifies the manifest, every resource and blob hash, and
the complete audit hash chain.

Import requires a **fresh target**: migrated, with no Account holding the
archived id or occupying the community slot. It refuses rather than blending
two histories.

**In a release:** `MemHouse.Release.import!/1` and
`MemHouse.Release.validate_archive!/1` through `bin/memhouse rpc`.

---

## `memhouse.reembed`

```bash
mix memhouse.reembed
mix memhouse.reembed --status PIPELINE_RUN_ID
```

The first command enqueues the configured Account-wide embedding identity. The
task prints the run id and durable progress as JSON. The status form reports
the phase, cursor, processed counts, attempt count, and last error class.

**In a release:**

```bash
bin/memhouse rpc 'MemHouse.Release.reembed!()'
bin/memhouse rpc 'MemHouse.Release.reembed_status!("PIPELINE_RUN_ID")'
```

Knowledge, active document chunks, and entity projections run in resumable
batches. Old-identity rows are absent from semantic retrieval until their
batch commits. Lexical retrieval remains available during the transition.

---

## `memhouse.model.check`

```bash
mix memhouse.model.check
mix memhouse.model.check --json
```

Asks `ingest_extractor`, `dream_reasoner`, and `dialectic_agent` for one tiny
object each and prints status, provider, model, duration, and — for a failure —
a content-free error class. Exits non-zero when a role fails.

Run it after changing a role, a provider key, or an endpoint. A role that
cannot return an object still answers HTTP 200, so extraction thins and answers
degrade with nothing in the logs naming the cause. `checks.model_calls` on
[`GET /api/ready`](../operations/health-and-costs.md) reports failures that have
already happened; this reports whether the next call will work.

A role on the deterministic local fallback is reported as `skipped`. There is no
provider to reach, so the command does not fail on it.

The probe uses the roles from deployment configuration, sends the configured
timeouts and output caps unchanged, and writes no usage row. A per-Account role
override is not covered.

---

## `memhouse.governance.autoshare`

```bash
mix memhouse.governance.autoshare --account-key eval-benchmark
```

| Switch | Notes |
| --- | --- |
| `--account-key`, `-a` | Required. Names the Account to configure. Raises when absent or unknown |

Writes nine Account-wide gate rule cells — `peer`, `scope`, and `account`
target level crossed with `public`, `internal`, and `personal` sensitivity —
and prints the count. An existing Account-wide cell is updated in place. Each
cell gets:

| Field | Value |
| --- | --- |
| `gate_a_mode` | `auto_keep` |
| `gate_b_mode` | `auto_place` |
| `minimum_confidence` | `0.0` |
| `minimum_evidence_level` | `indirect` |
| `minimum_corroboration` | `1` |
| `requires_consent` | `false` |
| `active` | `true` |

`restricted` gets no cell. No cell can place it automatically.

The task does not change consent. Personal knowledge also needs its subject's
agreement, which `requires_consent: false` cannot waive, and only a human
account administrator may declare an Account has no subject to give it. The
task prints a reminder when neither that Account's `consent_mode` is `auto` nor
`MEMHOUSE_GOVERNANCE_UNATTENDED` is true — see
[Governance](../concepts/governance.md#consent-for-personal-knowledge).

!!! danger "It loosens governance for the whole Account"
    Every proposal except `restricted` then bypasses human review, held back
    only by consent. Run it on a benchmark or evaluation Account, never on one
    holding real memory.

---

## `memhouse.eval.smoke`

```bash
mix memhouse.eval.smoke --profile balanced --account eval-poc
```

A developer sanity check, not a graded evaluation: it ingests a few messages,
asks a few questions, and prints what came back. No scores, no thresholds.

!!! danger "It writes real rows"
    There is no dry-run mode and no cleanup. Point it at a scratch database,
    and never reuse an Account key that holds real user data.

---

## `memhouse.eval.benchmark`

```bash
mix memhouse.eval.benchmark --benchmark locomo --dataset data/locomo10.json --dream-time
```

For an issue-160 durability audit, use the same dataset, limits, and seed for
both revisions. A live judge needs a reasoning role configured to a different
provider/model family than `ingest_extractor`.

```bash
mix memhouse.eval.benchmark \
  --benchmark locomo \
  --dataset data/locomo10.json \
  --run-id issue-160-after \
  --durability-audit \
  --durability-judge model \
  --durability-sample 200 \
  --durability-seed issue-160-held-out \
  --output /private/tmp/issue-160-after.json
```

Runs one fixture end to end through the ordinary write and answer paths and
scores it. Recognised shapes: LoCoMo, LongMemEval, ConvoMem, BEAM, and
MemHouse's own `{"messages": [...], "questions": [...]}`.

| Switch | Notes |
| --- | --- |
| `--dataset`, `-d` | Required. Hashed, so the report names the exact data |
| `--benchmark`, `-b` | Inferred from shape when omitted |
| `--profile`, `-p` | Default `balanced` |
| `--account` | Default `eval-benchmark` |
| `--run-id` | Seeds the scope root; give concurrent runs distinct ids |
| `--limit-cases` / `--limit-messages` / `--limit-questions` | Truncate for a fast loop — recorded in the report, because a truncated run is not comparable |
| `--dream-time` | Run and replay the Account dream-time pass after each case ingest. The report records content-safe reasoning counts and rejects a non-zero replay effect. |
| `--durability-audit` | Add a content-safe extraction audit. It records only category and message-yield counts. |
| `--durability-judge` | `deterministic` (default) or `model`. A model judge must differ from the ingest extractor provider/model family. |
| `--durability-sample` / `--durability-seed` | Stable statement sample size and selection seed. Use at least 200 statements for a durability claim. |
| `--no-model` | Deterministic local extractor and answerer |

Unless `--no-model` is given, the run probes every generative role first and
refuses to start if one cannot return an object. Scoring a run whose extractor
never worked publishes a quality number for a corpus that was never extracted.
A role on the deterministic fallback fails this check too: `--no-model` is how
an offline run is requested.

Also writes real rows. Same warning applies.

---

## `memhouse.eval.experiment`

```bash
mix memhouse.eval.experiment \
  --definition specs/eval/experiments/memory-profile-ablation.json \
  --manifest-output /private/tmp/memhouse-experiment-manifest.json \
  --output /private/tmp/memhouse-comparison.json
```

Runs the current and experimental variants over the same dataset, in order, in separate scratch
Accounts. The first output is the environment-resolved run manifest: exact input digest, source
revision and working-tree state, Postgres mode, model and prompt identities, safe generation
parameters, evaluation seeds, and effective retrieval settings. The second is a machine-readable
comparison with stage metrics and gate results.

The stages cover ingest calls/tokens/facts, answer and retrieval quality by category, citations, abstention,
unexpected source membership, total token/cost accounting, latency, and dream-time replay. Cost is
an estimate from the named shipped planning profile or operator override; a provider that returns
no usage object honestly records zero tokens rather than a guess.
`quality.min_category_accuracy` and `quality.max_category_accuracy_regression`
are category-to-fraction maps. A requested category with no measured questions
fails closed. Gates fail the command by default. `--report-only` writes a failed
bundle without changing the exit status.
Execute-mode cost stages record the profile `id` and `kind` beside
`estimated_usd`, so two runs cannot silently compare different rate tables.

Execute definitions use the deterministic providers by default. `--live-model` is the explicit
opt-in for configured hosted providers and may incur cost. It also performs the normal generative
role preflight. Both modes write durable rows to their scratch Accounts.

Execute definitions have a closed `components` contract. Profile, effective strategies and seed
stages, reranking, deadline, extraction batching identity and limits, adaptive recall effort, source/lineage
permissions, separate Knowledge semantic-index, source semantic-index, and RecallDocument refreshes,
idle scheduling gates, explicit
dream execution, the default-off dream-operation split, and durability audit must exactly match
runner behavior. Declared source-semantic and lineage tools and split reasoning operations must
also complete in the report; permission or configuration alone is not execution evidence. An unknown key or a
mismatched value fails validation; the map is not free-form provenance. Runtime feature switches
are restored even on failure. Fixture definitions keep the map empty because fixture replay does
not execute product components.

The committed smoke definition compares the real `balanced` defaults with the opt-in `minimal`
dual-lane, batched, high-effort bounded-recall, idle-scheduler, split-update, and dream-pass
configuration. Offline execution
synchronously refreshes each isolated case Knowledge index and, only for minimal, its source
semantic index and RecallDocument projection before questions. Source refresh reports only its
status, count, scopes, and exact four-part embedding identity. The idle-enabled variant requires
at least two active direct generations per exact case scope, creates real replay-keyed PipelineRun
and Oban jobs, executes stale/latest/replay through the production pipeline, and fails unless the
stale wake is superseded before model work, the latest completes, and replay adds no durable effect.
It requires existing local Ortex model and
tokenizer artifacts. Missing artifacts and hosted or
deterministic stand-in embedders are rejected before ingestion; MemHouse never
substitutes fake vectors.

Each measured stage also reports content-free database query counts/timings and newly-created
maintenance `PipelineRun` counts. Snapshot reads are outside the query interval. SQL, parameters,
results, memory content, and Account ids never enter these measurements.

Fixture definitions are different: they replay content-free stage measurements without starting
MemHouse, Postgres, or a provider. They are test evidence, not benchmark evidence, and the bundle
labels them as fixture mode. Reproduce the committed example with:

```bash
mix memhouse.eval.experiment \
  --definition test/fixtures/eval/profile-experiment-fixture.json \
  --manifest-output /private/tmp/profile-experiment-fixture-manifest.json \
  --output /private/tmp/profile-experiment-fixture-bundle.json
```

MemHouse has one Postgres behavior contract in `external` and packaged `pg0` deployment modes.
SQLite is unsupported and an experiment definition claiming it is rejected rather than presented
as parity evidence. CI runs the same source tests in both supported database modes.

The comparison keeps three categories separate: measured results, explicitly labelled inferences,
and first-party external claims with a source and reproduction flag. An external headline can
therefore never enter a gate as if MemHouse measured it.

---

## `memhouse.eval.release`

```bash
mix memhouse.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/memhouse-release-eval.json
```

Runs `specs/eval/release-suite.json` against floors in
`specs/eval/deterministic-thresholds.json`. Only release guardrails block;
ablations inform. Without `--no-model` it runs the same generative-role probe
as the benchmark task and refuses to start when a role fails it.

---

## `memhouse.eval.verify`

```bash
mix memhouse.eval.verify /tmp/memhouse-eval.json
```

Checks that a report carries enough provenance to be quotable: application
version, timestamp, benchmark, retrieval profile and version, deadline,
strategy override, run limits, dataset id with SHA-256 and split, all five
model-role identities, judge, and metrics.

Provenance only — it re-runs nothing and compares nothing to a floor.

---

## `memhouse.release.check`

```bash
mix memhouse.release.check --eval-report /private/tmp/memhouse-release-eval.json
mix memhouse.release.check --tag v0.4.0 --eval-report /private/tmp/...
```

Fails unless `mix.exs`, changelog, documentation, git tag, and evaluation
evidence describe one release. There is no warning-only outcome.

`--allow-missing-eval` exists for metadata-only lanes; a real release must
supply the report.
