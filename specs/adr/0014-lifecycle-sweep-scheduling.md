<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0014: Lifecycle sweep scheduling

## Status

Accepted

## Context

`FR-GOV-17`, `FR-GOV-20`, `AD-PIPE-1`, and `NFR-8` require lifecycle work to
be durable, Account-scoped, and replay-safe. `MemHouse.Governance.Sweeper`
implements expiry and revalidation, but no request creates those runs. A
transactional AshOban trigger cannot start work that is due only because time
passed.

## Decision

Oban Cron starts one `MemHouse.Operations.LifecycleScheduler` job every hour.
It is the only Cron entry. The worker enters the provisioned community Account
and creates dream-time, expiry, and revalidation `PipelineRun` rows through
Ash actions.
Each row is keyed by Account, sweep kind, and the Cron job's `scheduled_at`
timestamp. The row and its AshOban job commit in the Account transaction.

The scheduler never changes knowledge. The existing workers on the
`lifecycle` queue run the sweeps. A late execution or retry keeps the original
slot and reuses completed rows. An installation without a provisioned Account
does no work.

`GET /api/ready` reports the last completed run for each sweep. It reports
`"never"` before a sweep completes. This is operational disclosure, not a
readiness failure.

## Consequences

Expiry and revalidation become reachable in both deployment modes without a
second queue engine or a direct durable write. The maximum normal delay before
a due item becomes durable state is one hour plus queue delay. Read-time
filters still reject due or expired knowledge before that transition.

The application retains Oban job history. A retention policy is separate work;
the scheduler does not add a Pruner.

## Anchors

- `FR-GOV-17`, `FR-GOV-20`
- `AD-PIPE-1`, `AD-SEAM-4.2`, `AD-SEAM-4.3`
- `AINV-6`, `AINV-11`
- `NFR-8`

## Related Documents

- `specs/architecture/transactional-writes-audit-jobs.md`
- `specs/architecture/gate-a-b-governance.md`
- `docs/concepts/governance.md`
