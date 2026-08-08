# ADR 0001: Repository automation model

## Status

Accepted

## Context

MemHouse is intended to be built through the L3 automation flow: one scoped
issue, one branch, one PR, human review, and then the next task. That flow lets
Codex help with implementation while preserving the ARCH prime directive:
one codebase, two deployment modes, identical guarantees.

The blueprint also makes the deterministic PR gate a first-class architecture
concern. `AD-EVAL-1` makes the model provider layer the determinism seam,
`AD-EVAL-2` defines the testing pyramid, and `AD-EVAL-3` splits merge-blocking
deterministic checks from nightly or release evaluation. The repository process
should use those gates to make automation reviewable instead of allowing AI
changes to merge on trust.

At this stage, some repository settings still require manual maintainer setup:
labels, branch protection, required checks, CODEOWNERS, GitHub-side Codex
review, secrets, and external process automation. Until those are configured,
repo-visible changes should remain inert and reviewable.

## Decision

MemHouse will use a controlled repository automation model:

- A human scopes each implementation issue and applies `ai-ready` only when the
  goal, scope, architecture anchors, acceptance criteria, required tests, and
  risk class are clear.
- Codex works only one issue at a time, on a focused branch and PR, and reads
  `AGENTS.md`, relevant blueprint anchors, and applicable docs before editing.
- Codex implementation PRs include real local check evidence. Missing checks
  are reported explicitly when the project has not yet grown the required tool
  or command.
- Deterministic CI is the merge-blocking gate once the corresponding workflows
  exist. Live or model-graded evals are tracked separately unless a later ADR or
  task promotes a specific deterministic guardrail into the PR gate.
- Codex PR review may be used as advisory review support. It does not replace
  deterministic CI, CODEOWNER review, or human approval.
- CODEOWNER review is required for sensitive paths once CODEOWNERS and branch
  protection are configured.
- A human remains the merge gate. The repository does not use AI auto-merge.

## Consequences

This model keeps automation useful but bounded. Codex can make small,
traceable changes quickly, while deterministic checks and human review preserve
the same guarantees expected of human-authored code.

The trade-off is throughput: tasks are intentionally serialized through issues,
PRs, checks, and review. That cost is acceptable because MemHouse's architecture
depends on stable review handles, deployment-mode parity, account isolation, and
honest evidence. Batching unrelated work or allowing AI auto-merge would make
those guarantees harder to audit.

Repository automation changes must stay explicit. New workflows, required
checks, Codex prompts, CODEOWNERS entries, branch rules, or process-channel
integrations should land through their own scoped tasks with test or manual
verification evidence.

## Anchors

- `AINV-1` - one codebase, two modes, identical guarantees.
- `AD-EVAL-1` - model provider layer as the determinism seam.
- `AD-EVAL-2` - testing pyramid.
- `AD-EVAL-3` - deterministic PR gate separated from nightly/release evals.
- `AD-EVAL-4` - deterministic bridge affordances.
- `AD-EVAL-5` - eval framework lives in-repo.

## Related Documents

- `AGENTS.md`
- `specs/roadmap/beta-roadmap.md`
