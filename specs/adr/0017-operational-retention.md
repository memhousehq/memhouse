<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR-0017: Bound operational history

## Status

Accepted.

## Decision

MemHouse retains terminal Oban jobs and Account-scoped operational ledgers for configurable
horizons. A daily, bounded worker deletes only expired `PipelineRun`, `UsageEvent`,
`GateDecision`, and `LifecycleEvent` rows. The Oban Pruner deletes terminal jobs independently.

Messages, document versions, knowledge items, provenance, audit events, and reasoning watermarks
remain durable. Active pipeline runs are never eligible for retention cleanup. The reconciler
settles stranded runs before a later retention pass can delete them.

Account archives exclude retained operational history. Import rebuilds pipeline work from the
durable source rows and starts new local usage and governance-history horizons.

## Consequences

Ordinary use no longer grows queue and bookkeeping tables without bound. Operators choose how
much diagnostic, cost, and governance history to keep. A shorter horizon means older usage totals
and transition details are unavailable, while the audit chain and current knowledge state remain
complete.

This supersedes the append-forever treatment of these four ledgers. It does not change the
`f4-1`, `f10-1`, or `memhouse-account-1` identities because current governance state, the costs
response shape, and durable archive data remain compatible.
