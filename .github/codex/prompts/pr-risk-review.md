# PR risk review prompt

Use this prompt for advisory GitHub-side Codex review of a pull request. This
review is informational unless a later task makes structured output or required
status checks mandatory. Do not apply patches, approve the PR, request merge, or
perform repository writes.

## Review posture

Focus on serious risks, invariant violations, and missing evidence rather than
style preferences or speculative improvements. Treat the product invariants and
architecture boundaries in `AGENTS.md` as authoritative review inputs,
especially:

- Cross-account isolation is absolute, and identity determines the Account.
- Deterministic release gates stay separate from advisory review.
- One codebase, two deployment modes, identical guarantees.

When evidence is insufficient, say what is missing and why it matters. Avoid
blocking language unless the issue is a concrete violation of a stated invariant,
security boundary, tenancy guarantee, audit requirement, or backend-parity
expectation.

## Review inputs

Review the PR diff, linked issue, local repository instructions, and the tests
covering the changed code before writing findings. If the linked issue or
acceptance criteria are unavailable, call that out as missing context.

## Output format

Return a Markdown review with these sections:

### Risk summary

- State the overall risk level: `low`, `medium`, `high`, or `critical`.
- Summarize the highest-impact risks in a few bullets.
- Distinguish concrete defects from questions or missing evidence.

### Affected invariants

- List each product invariant or architecture boundary the PR touches.
- Explain whether the PR appears to preserve, weaken, or violate each one.
- Pay special attention to cross-account isolation, governed knowledge
  promotion, pipeline-only knowledge writes, durable system-of-record boundaries,
  transactional integrity, and provider/database/deployment-mode neutrality.

### Security, tenancy, and audit concerns

- Identify risks involving account isolation, identity-derived account scoping,
  authorization policy, secrets, user-owned data or keys, audit logs, lifecycle
  ledgers, provenance, or immutable history.
- Call out any request-parameter account trust, cross-account traversal,
  missing policy enforcement, missing audit write, or non-transactional side
  effect that could violate the architecture contract.

### Backend parity and deployment-mode concerns

- Check whether the change preserves supervised-pg0 single-node mode and
  external-Postgres queue-mode behavior as one codebase with identical
  guarantees.
- Flag database-specific logic, queue/Oban behavior, indexing/cache assumptions,
  provider lock-in, cloud lock-in, or enterprise/free boundaries that appear to
  fork behavior without an explicit reviewed seam.

### Missing tests or evidence

- List deterministic tests, documentation inspections, eval coverage, backend
  parity evidence, or manual checks that should exist for the risk class.
- Identify whether required commands were reported and whether failures are real
  defects or documented environment limitations.

### Findings

For each serious issue, include:

- Severity: `critical`, `high`, `medium`, or `low`.
- Location: file and line range when available.
- Problem: the concrete risk or invariant violation.
- Why it matters: the product, security, tenancy, audit, parity, or eval impact.
- Suggested direction: a concise remediation path.

If there are no serious issues, say so explicitly and list any non-blocking
questions separately.
