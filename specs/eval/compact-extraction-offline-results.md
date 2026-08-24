# Compact extraction offline results

Date: 2026-08-17

Revision: `ff72f6320c0be59e9d0b32bf748a75c48cc14d0b`

Status: deterministic contract evidence only; promotion is not approved.

This record compares the then-current `extract-13` contract with the opt-in
`extract-compact-exp-1` contract on the same four anchored observations. The
run used the deterministic provider and the real batch admission, structured
validation, repair, and trusted-cast paths. It did not call a hosted model and
does not measure provider tokens, cost, latency, or semantic quality.

## Result

| Metric | Current | Compact | Change |
| --- | ---: | ---: | ---: |
| Provider calls, four-anchor batch | 1 | 1 | none |
| Admitted anchors | 4 | 4 | none |
| Admitted facts | 4 | 4 | none |
| Empty anchors | 1 | 1 | none |
| Candidate fields | 11 | 6 | -45.5% |
| Batch schema bytes | 2,528 | 1,488 | -41.14% |
| Full request `utf8-bytes-v1` proxy | 5,591 | 4,219 | -24.54% |
| Raw response bytes | 1,727 | 1,340 | -22.41% |
| Raw model-authored policy fields | 7 | 0 | eliminated |

Both variants retained exact raw support spans and source-message IDs through
validation, and both retained the validated source IDs in accepted facts. The
compact raw candidates did not contain kind, subject type, confidence,
sensitivity, target, or valid-time policy fields. Trusted code derived
`fact`, `restricted`, the narrow peer target, and direct confidence `1.0`;
indirect evidence received the existing confidence `0.75`.

The compact contract rejected injected policy fields, unknown subjects,
invented support spans, and cross-anchor provenance. Retry behavior stayed
bounded: one validation or incomplete-response fault recovered on call two;
validation exhaustion stopped after three calls with four terminal anchor
outcomes; incomplete-response exhaustion stopped after three calls; and the
non-retryable invalid-credential case stopped after one call.

The call reduction is a batching result, not a compact-schema result. Four
separate observations required four calls in either mode, while the batch path
required one call in either mode.

## Command and artifact

```bash
MIX_BUILD_PATH=/private/tmp/memhouse-build-285 MIX_ENV=test \
  mix run --no-start /tmp/memhouse_compact_eval.exs
```

The local result artifact was
`/tmp/memhouse_compact_eval_result.json`, with SHA-256
`52902d833e4ae07ee0493ffb6ec557a2aeb62205db1999fe9bc734028fdd15ad`.
The focused schema, extractor, and batch suites passed 15 tests with no
failures.

## Interpretation and promotion gate

This evidence supports keeping the compact contract available as a fail-closed
experiment. It does not support making it the default. In particular:

- the deterministic provider cannot establish semantic non-inferiority or
  actual tokenizer, latency, or cost behavior;
- the exact support span is validation-only and is not stored as durable text
  or offsets; durable provenance stores source IDs plus model and prompt
  identity; and
- exact-span validation cannot by itself prove that a generated statement is
  semantically entailed by that span. The compact path derives direct
  confidence after structural validation, so held-out real-provider evidence
  is required before promotion.

Promotion therefore still requires the preregistered matched evaluation,
privacy and category gates, external-PostgreSQL and packaged-pg0 parity, and
human ADR review. At that revision, `extract-13` remained the default and no
current extraction path was removed.

<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->
