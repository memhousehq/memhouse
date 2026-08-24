<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0022: Executable knowledge lifecycle contract

## Status

Accepted.

## Context

Knowledge has 12 stored lifecycle values. They summarize different operational
conditions: gate progress, current usability, subject action, source support,
and historical disposition. The values were validated only as destinations.
The code did not reject an undocumented source-to-destination edge, and state
lists and meanings were copied across the resource, console, tools, docs, and
evaluation code.

Splitting the column into review, validity, and disposition fields would make
some facts more orthogonal. It would also change stored rows, API filters,
authorization behavior, retrieval predicates, projections, readiness, exports,
and existing lifecycle history at once. There is no measured migration or
compatibility evidence that supports that irreversible public change.

## Decision

Retain all 12 public state names and make their graph and operator metadata one
executable contract in `MemHouse.Knowledge.Lifecycle`.

Each value remains top-level because it selects a distinct action or read rule:

- `proposed`, `provisional`, and `held` identify three different review and
  visibility positions;
- `active`, `needs_revalidation`, `contested`, and `stale` identify four
  different current actions: use, recheck, adjudicate, or do not rely on;
- `rejected`, `expired`, `superseded`, `redacted`, and `retracted` identify five
  different terminal reasons whose visibility, lineage, subject rights, and
  operator explanation differ.

The state is only the current operational summary. `superseded`, `expired`,
`rejected`, and `redacted` are terminal for ordinary lifecycle work, but a
later privacy withdrawal or last-source erasure may still replace their
disposition with `redacted` or `retracted`. Verification, timestamps,
validation rows, consent, provenance, relations, and append-only events retain
the orthogonal facts. The transition action validates both endpoints against
the executable graph. Lifecycle self-edges are retained only where a governed
timer update must preserve its event and audit evidence.

The contract drives resource validation, console filters and meanings, API tool
documentation, projection/readiness state sets, and tests. Evaluation reports
use an internal Account reader and include every final-state count, every
transition/reason count, unexercised states, and balanced lifecycle/audit totals.

## Compatibility and migration

This change needs no data migration. The database column, all 12 values, API
filter values, exports, and existing lifecycle rows remain valid. New writes
that attempt an undocumented edge now fail before the state, event, audit, or
derived refresh can commit.

A future state reduction requires a new ADR and contract version. It must define
a reversible row mapping, backfill lifecycle history without rewriting audit
meaning, support a dual-read compatibility period for API clients and exports,
and show matched evaluation plus external-PostgreSQL and packaged-pg0 evidence.
No state may be renamed or collapsed in place.

## Rejected alternative

Do not split the state column during issue 277. The proposed three-axis model is
useful design input, but applying it without client and data migration evidence
would trade a reasoning problem for silent compatibility and authorization
failures.

## Evidence

- `lib/memhouse/knowledge/lifecycle.ex`
- `test/memhouse/knowledge/lifecycle_contract_test.exs`
- `test/memhouse/f4_real_gate_a_b_governance_test.exs`
- `test/memhouse/f11_evaluation_ci_release_readiness_test.exs`
- `docs/concepts/memory-model.md#lifecycle-state-contract`
