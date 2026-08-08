# Minimal Benchmark Results

Date: 2026-07-27

This document is the immutable Stage 0 record of the minimal LoCoMo,
LongMemEval, and BEAM benchmark runs
executed against the 0.1.0 benchmark runner. These are not upstream-scale
scores. They prove that the 0.1.0 release could ingest the named benchmark
families, exercise the real `MemHouse.Memory` write/read path, score answers
and citations, and write durable JSON reports in the repository.

All runs used `--no-model`, so extraction and answering used the deterministic
fallback path instead of an external model provider.

All quoted scores use retrieval profile `balanced`, profile version `poc-0`.
The runner used for these runs does not expose benchmark-specific deadline
disable or fixed-clock controls in the report, so the deadline setting is the
normal retrieval path.

The evaluation, CI, and release-readiness work does not relabel these
historical files. Current `f7-1` claims use the `f11-1` report schema and
`specs/eval/release-suite.json`.

## Commands Run

```bash
mix memhouse.eval.benchmark \
  --benchmark locomo \
  --dataset test/fixtures/eval/locomo-minimal.json \
  --profile balanced \
  --account eval-minimal-locomo \
  --run-id minimal-locomo-20260727 \
  --no-model \
  --output specs/eval/results/locomo-minimal-report.json

mix memhouse.eval.benchmark \
  --benchmark longmemeval \
  --dataset test/fixtures/eval/longmemeval-minimal.json \
  --profile balanced \
  --account eval-minimal-longmemeval \
  --run-id minimal-longmemeval-20260727 \
  --no-model \
  --output specs/eval/results/longmemeval-minimal-report.json

mix memhouse.eval.benchmark \
  --benchmark beam \
  --dataset test/fixtures/eval/beam-minimal.json \
  --profile balanced \
  --account eval-minimal-beam \
  --run-id minimal-beam-20260727 \
  --no-model \
  --output specs/eval/results/beam-minimal-report.json
```

## Result Summary

| Benchmark | Source format | Messages | Questions | Accuracy | Citation hit rate | Mean citation recall | Mean token F1 | Mean latency |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| LoCoMo | `locomo10` | 4/4 | 2 | 1.00 | 1.00 | 1.00 | 0.078 | 6.0 ms |
| LongMemEval | `longmemeval-cleaned` | 3/3 | 2 | 0.50 | 0.50 | 0.50 | 0.067 | 8.5 ms |
| BEAM | `beam` | 5/5 | 2 | 1.00 | 1.00 | 1.00 | 0.181 | 6.0 ms |

Raw reports:

- `specs/eval/results/locomo-minimal-report.json`
- `specs/eval/results/longmemeval-minimal-report.json`
- `specs/eval/results/beam-minimal-report.json`

## LoCoMo Minimal Run

The LoCoMo fixture uses the LoCoMo-style `conversation` plus `qa` shape and
evidence refs such as `D1:1` and `D2:2`.

- Messages attempted and ingested: 4/4.
- Questions attempted: 2.
- Overall accuracy: 1.00.
- Citation hit rate: 1.00.
- Mean citation recall: 1.00.
- Category `1`: 1 question, accuracy 1.00, citation hit rate 1.00.
- Category `2`: 1 question, accuracy 1.00, citation hit rate 1.00.

## LongMemEval Minimal Run

The LongMemEval fixture uses the cleaned format with `haystack_sessions`,
`haystack_session_ids`, `answer_session_ids`, and one abstention item.

- Messages attempted and ingested: 3/3.
- Questions attempted: 2.
- Overall accuracy: 0.50.
- Citation hit rate: 0.50.
- Mean citation recall: 0.50.
- `single-session-user`: 1 question, accuracy 1.00, citation hit rate 1.00.
- `abstention`: 1 question, accuracy 0.00, citation hit rate 0.00.

The abstention failure is expected baseline evidence. The fallback answerer
returns a nearby active knowledge item for the unrelated airline question:
`Jordan uses Helix when drafting release notes.` The benchmark scorer marks the
case incorrect because abstention was expected and no evidence references were
expected.

## BEAM Minimal Run

The BEAM fixture uses BEAM-style chats and probing questions across two scale
labels.

- Messages attempted and ingested: 5/5.
- Questions attempted: 2.
- Overall accuracy: 1.00.
- Citation hit rate: 1.00.
- Mean citation recall: 1.00.
- `Instruction Following`: 1 question, accuracy 1.00, citation hit rate 1.00.
- `Knowledge Update`: 1 question, accuracy 1.00, citation hit rate 1.00.

BEAM scale curve:

| Scale | Questions | Accuracy | Citation hit rate | Mean token F1 | Mean latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| `128K` | 1 | 1.00 | 1.00 | 0.286 | 9.0 ms |
| `500K` | 1 | 1.00 | 1.00 | 0.077 | 3.0 ms |

## Interpretation

This is the minimum credible benchmark proof for the 0.1.0 baseline:

- The runner accepts and normalizes LoCoMo, LongMemEval, and BEAM source-shaped
  fixtures.
- Each run writes raw messages, pipeline-created knowledge, lifecycle events,
  retrieval results, answers, citations, and metrics through the local Postgres
  path.
- The checked-in JSON reports preserve per-question and aggregate evidence.
- The LongMemEval abstention miss documents a known retrieval/answering gap
  before release thresholds or upstream judge parity are added.

The evaluation, CI, and release-readiness work subsequently added held-out
tuning discipline, strategy ablations, explicit deadline/report provenance,
deterministic release thresholds, CI gates, ConvoMem support, and
pg0/external-Postgres lanes. Remaining evidence work is
upstream-scale datasets and independent-family live-model judging; smoke-scale
fixtures are not comparative product scores.
