---
name: AI-ready task
about: Create a small, bounded, testable task that Codex may implement after ai-ready is applied
title: "Task: "
labels: ""
assignees: ""
---

## Goal

<!-- Describe exactly one outcome this issue should achieve. Keep it small enough for one focused PR. -->

## Reference docs

<!-- Link the internal docs that provide the task context reviewers and implementers should read. Include the closest specific document(s), not every possible doc. Delete rows that do not apply. -->

- Modules and tests that define the behavior being changed:
- ADRs: `specs/adr/README.md` or `specs/adr/<adr-file>.md`:
- Architecture notes: `specs/architecture/README.md` or `specs/architecture/<note>.md`:
- Roadmap/process docs: `specs/roadmap/beta-roadmap.md`, `specs/process/`:
- Security/eval docs: `specs/security/README.md`, `specs/eval/README.md`, or a specific note:
- Published user documentation affected: the page(s) under `docs/`:
- Other internal docs:

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

- `ai-ready`: Codex may implement only after the goal, architecture anchors, scope, expected behavior, acceptance criteria, required tests, and risk class are clear.
- `ai-assisted`: AI may help, but a human must closely steer the implementation.
- `ai-review-only`: Codex may review, but must not implement.
- `human-only`: Codex must not implement; reserve for human decisions or implementation.

Risk and routing labels:

- `needs-adr`: Requires an ADR before implementation.
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
