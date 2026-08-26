---
name: AI-ready task
about: Create a small, bounded, testable task that Codex may implement after ai-ready is applied
title: "Task: "
labels: ""
assignees: ""
---

## Goal

<!-- Describe exactly one outcome this issue should achieve. Keep it small enough for one focused PR. -->

## Implementation context

<!-- Link only the context needed to implement and review this task. Delete rows that do not apply. -->

- Originating issue and acceptance criteria:
- Modules and tests that define the behavior being changed:
- Published user documentation affected: the page(s) under `docs/`:
- Prior issue, pull request, or Git history needed for context:

## Product invariants

<!-- Name the invariants from `AGENTS.md` that constrain this work. Do not weaken one in this issue. -->

Relevant invariants:

- Account isolation; Account derived from identity:
- Pipeline-only knowledge writes and governed promotion:
- One codebase, two deployment modes, identical guarantees:
- Other:

## Scope

In scope:

-

Out of scope:

-

## Expected behavior

<!-- Describe the observable behavior after completion. Include user-visible, operator-visible, API-visible, or review-visible behavior as applicable. -->

## Acceptance criteria

<!-- Make each item independently reviewable. -->

- [ ]
- [ ]

## Required tests

<!-- Check every lane required for this change. If a lane is unavailable, explain why in the issue and PR. -->

- [ ] Documentation inspection
- [ ] Unit
- [ ] Packaged pg0 data-layer test
- [ ] External Postgres data-layer test
- [ ] Contract test
- [ ] Property/invariant test
- [ ] Security test
- [ ] Eval scenario

Required evidence notes:

-

## Risk class

<!-- Select exactly one primary risk class. Add the matching labels from the guidance below. -->

- [ ] Low: docs/tests/internal cleanup
- [ ] Medium: normal source change
- [ ] High: tenancy/security/audit/pipeline/release/migration
- [ ] Human-only: architecture/licensing/security model

## Label guidance

Execution-control labels:

- `ai-ready`: Codex may implement only after the goal, architecture constraints, scope, expected behavior, acceptance criteria, required tests, and risk class are clear.
- `ai-assisted`: AI may help, but a human must closely steer the implementation.
- `ai-review-only`: Codex may review, but must not implement.
- `human-only`: Codex must not implement; reserve for human decisions or implementation.

Risk and routing labels:

- `needs-adr`: Requires a human architecture decision with its rationale recorded in the scoped issue before implementation.
- `security-sensitive`: Security review required.
- `tenancy-sensitive`: Tenant isolation or account-boundary review required.
- `audit-sensitive`: Audit, ledger, or immutable-history review required.
- `pipeline-sensitive`: Oban, transactional outbox, ingest, or background-job review required.
- `backend-parity-required`: pg0 and external-Postgres parity evidence required.
- `eval-required`: Eval scenario or workflow evidence required.
- `good-first-agent-task`: Small, low-risk task suitable for Codex.

## Codex instruction

Codex may implement this issue only if the `ai-ready` label is applied.
Codex must not implement this issue if `human-only` is applied, even if another label appears to permit implementation.
Codex must implement only the in-scope acceptance criteria and must not batch unrelated tasks into the PR.
Codex must report real check evidence in the PR and final response; unavailable checks must be called out explicitly.
Do not introduce new dependencies without explanation.
