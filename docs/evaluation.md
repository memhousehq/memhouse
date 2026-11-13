<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Evaluation: suites, metrics and the regression gate

MemHouse can measure its own memory quality on scripted conversations with known ground truth,
and refuse a change that makes it worse. This covers requirements QUAL-03 (the harness), QUAL-04
(your own suites), QUAL-05 (the regression gate), QUAL-10 (reproducibility) and QUAL-11 (the
metrics).

- A **suite** is a list of multi-session conversations. Each turn says what should become of
  it, and each session ends with a checkpoint of questions.
- A **replay** writes a suite through the real write path into a scratch tenant, compares the
  store with the truth at every checkpoint, asks the questions through the real recall path,
  and erases the scratch tenant. Your tenant's memory is never touched, and no model is called
  beyond what your write path is configured to call. The scratch tenant (its name contains
  `~eval~`) runs the policy under evaluation: its queued writes are processed only by the
  engine that replays, never by an intake worker, and no recall explanation is kept for it.
  A write the policy refuses (a type it forbids, a text over its limit) is scored as not
  stored; a store or model failure fails the replay, which is then not scored at all.
- The **gate** replays a tenant's suites under the running policy and under a proposed one, on
  the same items, and refuses the approval if quality falls past the limits.

## The suite format

A suite is a YAML file (JSON also works). The format version is 1.

```yaml
name: support-renewals        # letters, digits, '.', '_' and '-'
description: Renewal conversations with corrections.
k: 5                          # hits a question's answer is looked for in (default 5)
conversations:
  - id: acme
    sessions:
      - at: 2026-01-10T09:00:00Z          # the event time of the session's turns
        turns:
          - say: The customer is on the Team plan.
            expect: commit                # the default
            key: plan
          - say: They plan to upgrade to the Enterprise plan next quarter.
            expect: hold
          - say: Thanks for the quick reply.
            expect: ignore
        ask:
          - q: Which plan is the customer on?
            key: plan
      - at: 2026-03-02T14:00:00Z
        turns:
          - say: The customer is no longer on the Team plan; they are on the Business plan now.
            key: plan
        ask:
          - q: Which plan is the customer on?
            key: plan
```

| Field | Meaning |
|---|---|
| `say` | what is said; written as an agent calling `remember` would write it |
| `expect` | `commit`: a fact, a correction or a preference, which should be stored. `hold`: a plan or a guess, which must not become a fact. `ignore`: small talk, not scored |
| `key` | what a `commit` turn states a value for. A later `commit` turn with the same key replaces it: from then on the earlier turn is **stale** |
| `kind` | the memory type written (`semantic` when absent) |
| `id`, `confirms` | a `hold` turn may have an `id`; a later `commit` turn that carries the plan out names it in `confirms` ("I plan to move to Porto" … "I moved to Porto"). The engine may then commit the plan's own record, rightly: from that turn on the plan is scored neither as held nor as contamination |
| `ask` | the checkpoint after the session: each question names the `key` whose current value answers it |

Instead of `conversations`, a suite can ask for generated ones:

```yaml
name: personal-starter
generate: { profile: personal, seed: 7, conversations: 20 }
```

`memhouse eval add` and `memhouse bench run --suite` report a fault with its place: the line
and column for a syntax error, the conversation, session and turn for a logical one (a question
about a key that no earlier turn commits, an id used twice).

## The synthetic timeline generator

```bash
memhouse bench synth --profile support --seed 7 --conversations 500 --out support-500.yaml
```

A scripted world model holds what is true of a subject at each step and writes the
conversation from it: facts, corrections, plans that are later carried out or dropped, guesses,
and small talk. Every turn carries its ground truth, and every session ends with up to three
questions: first about what changed in the session, then about what was corrected before.

- Profiles: `personal`, `support`, `coding`, `sales`, `success` (one per template).
- The same profile, seed and size give the same suite, byte for byte, on every machine and in
  every release: the generator has its own random numbers.
- Each conversation has its own random stream, so a larger suite starts with the smaller one.

Starter suites of 20 conversations per template are in [`bench/suites/`](../bench/suites).

## The metrics

All are computed at checkpoints and summed over a suite. A record counts as stored when it is
committed and valid at the checkpoint.

| Metric | Definition |
|---|---|
| Storage precision | of the scored records stored, the part that are current facts. The others are stale facts that were not superseded, and plans or guesses that were committed |
| Storage recall | of the current facts, the part that is stored |
| Retrieval precision | of the questions, the part whose first hit is the current fact |
| Retrieval recall | of the questions, the part with the current fact in the top `k` |
| F1 | the harmonic mean of precision and recall, for storage and for retrieval |
| Stale-fact rate | of the questions about a fact that was corrected, the part answered with a stale version in the top `k` |
| Contamination rate | of the plans and guesses, the part committed as facts |

Reports give each with a 95% bootstrap interval over conversations. A metric the suite has
nothing to measure on (no question, no correction, no plan) is left out, not reported as zero.

## Running suites

From files, against the benchmark database (nothing is stored about the run but its report):

```bash
memhouse bench run --suite bench/suites/support          # a file, or every suite in a folder
memhouse bench run --suite my-suite.yaml --repeat 3      # also reports reproducibility
```

A suite is replayed with the engine's own recall settings and is a run of its own: `--mode`,
`--rerank` and `--dataset` are refused together with a suite file.

For a tenant, stored in its database (QUAL-04):

```bash
memhouse eval add my-suite.yaml        # store it, replacing one of the same name (audited)
memhouse eval list
memhouse eval run                      # replay every suite under the running policy
memhouse eval runs                     # stored replays, each with its policy version
memhouse eval gate                     # after an engine or model change; exit status 1 if worse
memhouse eval remove my-suite
```

Every replay is kept in `mh_eval_run` with the suite's hash, the policy version it ran under,
why it ran (`manual`, `policy_change`, `model_change`), whether a gate passed with it, and the
engine's fingerprint (version, embedder, classifier, reranker, and a hash of the `[intake]`
settings, whose thresholds change what is stored without changing the policy).

## The regression gate

**Policy changes.** When a policy version is approved (`memhouse policy approve`,
`POST /v1/policies/{version}/approve`) and the tenant has suites, each suite is replayed under
the running policy and under the proposed one, and the two are compared:

| Metric | Refused if it |
|---|---|
| storage F1, retrieval F1 | falls by more than `max_f1_drop` points (2) |
| stale-fact rate | rises by more than `max_stale_rise` points (1) |
| contamination rate | rises by more than `max_contamination_rise` points (1) |

A refused approval answers `409 conflict` with the report, writes a `policy.refuse` audit event
with the reason `regression_gate` and every finding, and leaves the version `proposed`. A
passed one writes a `policy.gate` event and activates the version. For example, a policy that
stops corrections from superseding what they correct:

```text
policy v2 is not approved: regression gate failed: policy-v2-5d0c… against policy-v1-9a41…
FAIL controlled: stale_rate 0.0 -> 100.0 (+100.0 points, limit 1.0)
```

The running policy's replay is reused when the same items were already replayed under it by an
engine with the same fingerprint. If another version is activated while the gate runs, the
approval answers `409` and asks to be made again, so that the comparison is always with the
policy that is running. A replay takes about two seconds per conversation on a laptop, so size a tenant's
gating suites with the approval in mind. The limits and the switch are in
[`[eval]`](configuration.md#eval).

**Engine and model changes.** `memhouse eval gate` replays every suite now and compares each
with its last stored replay of the same items that did not itself fail a gate (so a failed gate
fails again when it is run again); it exits with status 1 if a limit is passed, so a deployment
script can stop on it. Run it after an upgrade, or after changing the embedder, the
classifier or the reranker. The repository's own engine changes are gated by the benchmark
guard, which replays `bench/suites/personal` against `bench/baselines.json`.

## Reproducibility

With the same models, a replay is deterministic: the rule classifier and the gate call no
model, and a local embedder gives the same vectors. `--repeat 3` replays a suite three times and
reports the share of scored records that ended the same in all three (QUAL-10 asks for 99% or
more; the `eval_reproducible` governance check holds it at 100% on its suite).

## Sizing

The gate's limits are small: to see a 2-point change in F1 reliably, a suite needs about 2,000
scored items (QUAL-05). A 20-conversation starter suite has about 250 questions and is a smoke
test; the 500-conversation reference suite has about 7,000. Results on the reference suite are
in [benchmarks.md](benchmarks.md#synthetic-timeline-suites).
