<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0013: Dream-time knowledge consolidation

Status: Accepted.

## Decision

Dream-time consolidates active knowledge inside one Account and one scope. It:

- merges exact duplicates, and same-subject statements with compatible embedding
  identities and cosine similarity of at least `0.97`;
- retires absorbed rows as `superseded`, retains their source provenance, and
  sets corroboration from distinct source observations; and
- creates a derived aggregate fact for the unambiguous set-membership form
  `subject has a noun named member` when two or more active members exist.

The aggregate is an ordinary governed knowledge row. It records every source
message and provenance row, links to each component with `derived_from`, and
becomes active only because all of its inputs are already active in the same
scope with the same sensitivity and target level. It has no independent claim
or wider visibility.

Consolidation is replay-safe. A repeated run finds the surviving statement or
the same aggregate. A changed set retires the old aggregate and writes its
replacement. Erasure runs consolidation before cache rebuilds, so a removed
source cannot remain in a derived aggregate.

## Consequences

This is a durable knowledge change, not a cache. It uses pipeline-only Ash
actions, lifecycle evidence, content-safe audit events, and normal cache
refresh enqueueing. It does not make ingest slower or let a model bypass Gate A
or Gate B.

The initial aggregate grammar is intentionally narrow. The extractor does not
persist a predicate field, so arbitrary prose cannot be grouped safely. A later
general predicate representation needs its own ADR and blueprint change.

## Anchors

- `FR-KN-1`, `FR-KN-7`, `FR-KN-8`, `FR-KN-9`
- `FR-FORM-14`, `FR-FORM-16`, `FR-FORM-18`, `FR-FORM-23`
- `AINV-2`, `AINV-5`, `AINV-6`, `AINV-11`
- `AD-PIPE-2`, `AD-PIPE-3`, `AD-PIPE-4`, `AD-DATA-1`
