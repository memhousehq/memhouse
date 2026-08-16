# MemHouse agent contract

This repository is a single Mix application. Use one scoped GitHub issue, one
branch, and one pull request. Human review is the merge gate.

## Before editing

1. Read this file and the repository-local conventions in `CONTEXT.md` and
   `docs/agents/`.
2. Read the modules and tests for the requested change. They define current
   behavior.
3. Read the affected user or operator page under `docs/`.
4. Read the closest architecture or decision document under `specs/` when the
   code does not answer the question.
5. Inspect the worktree and preserve unrelated changes.

## Agent skills

Use these repository-local conventions for planning, triage, wayfinding, and
ticket work:

- `CONTEXT.md` — repository wayfinding.
- `docs/agents/issue-tracker.md` — GitHub issue and pull request workflow.
- `docs/agents/triage-labels.md` — triage, execution-control, and risk labels.
- `docs/agents/domain.md` — domain-document locations.

Use exactly one execution-control label. Agent implementation work uses
`ai-ready` unless a human directly requests the work. Keep the issue scope,
acceptance criteria, tests, and risk class explicit.

## Functional blueprint

The source and tests are authoritative for implemented behavior. These are the
functional references for cross-cutting behavior:

- Product invariants and system boundaries: `specs/architecture/free-core-architecture.md`.
- Governed lifecycle and account isolation: `specs/architecture/gate-a-b-governance.md` and `specs/architecture/identity-tenancy-rbac.md`.
- Pipeline, model, and document behavior: `specs/architecture/transactional-writes-audit-jobs.md`, `specs/architecture/model-layer-structured-extraction.md`, and `specs/architecture/documents-connectors-sync.md`.
- Retrieval, context, and procedural memory: `specs/architecture/retrieval-entity-context.md` and `specs/architecture/skill-readiness-procedural-memory.md`.
- Browser surfaces and portability: `specs/architecture/browser-console.md` and `specs/architecture/portability-packaging-operations.md`.
- Evaluation and release readiness: `specs/architecture/evaluation-ci-release-readiness.md`.
- User and operator behavior: `docs/`.
- Decisions and rejected alternatives: `specs/adr/`.
- Outstanding work: `specs/roadmap/beta-roadmap.md`.

Do not treat a specification as authoritative over code that already exists.
If they disagree, follow the code and update the stale document when the task
requires it.

## Delivery

Keep changes focused on the issue. Update tests and user-facing documentation
with behavior changes. Report applicable checks honestly, including unavailable
checks and deliberate limitations. Human review remains required before merge.
