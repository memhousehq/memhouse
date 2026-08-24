# MemHouse agent contract

This repository is a single Mix application. Use one scoped GitHub issue, one
branch, and one pull request. Human review is the merge gate.

## Before editing

1. Read this file and the repository-local conventions in `CONTEXT.md` and
   `docs/agents/`.
2. Read the scoped issue and its acceptance criteria.
3. Read the affected modules and tests. They define current behavior.
4. Read the affected user or operator page under `docs/` and any relevant
   retained workflow or security instructions.
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

## Sources of truth

- Source and tests define implemented behavior and release readiness.
- `docs/` defines published user and operator procedures.
- GitHub issues define outstanding scoped work.
- Issue, pull request, and Git history preserve rationale that code cannot show.

Keep non-obvious constraints where they are enforced. Do not make code,
comments, or procedures depend on a retired document for their meaning.

## Delivery

Keep changes focused on the issue. Update tests and user-facing documentation
with behavior changes. Report applicable checks honestly, including unavailable
checks and deliberate limitations. Human review remains required before merge.
