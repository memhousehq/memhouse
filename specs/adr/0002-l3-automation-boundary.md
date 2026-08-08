# ADR 0002: L3 automation boundary

## Status

Accepted

## Context

MemHouse uses L3 automation so Codex can implement well-scoped repository
issues while a human maintainer remains accountable for product and architecture
direction. The L3 flow is deliberately narrow: one issue, one branch, one PR,
real check evidence, and human review before merge.

That boundary matters because MemHouse's core guarantees are not ordinary
implementation details. The ARCH prime directive requires one codebase with two
deployment modes and identical guarantees. Account isolation is absolute.
Deterministic PR gates exist to make automation reviewable, but they do not make
architecture, licensing, security, or data-governance decisions on their own.

ADR 0001 defines the repository automation model. This ADR defines what L3
automation does and does not mean for MemHouse.

## Decision

Codex may implement issues that a human has scoped and marked ready for agent
work. A Codex-executable issue must have a clear goal, scope, architecture
anchors, acceptance criteria, required tests, and risk class. Codex must read
`AGENTS.md`, the relevant blueprint anchors, and applicable docs before editing,
then keep changes focused on that issue.

L3 automation does not authorize source-code auto-merge. Codex may open or
update implementation PRs and provide review support, but a human remains the
merge gate for all source, documentation, configuration, workflow, and policy
changes.

The following areas are human-only decision areas unless a human has already
made the decision explicitly in an issue, ADR, or blueprint update:

- The ARCH prime directive: one codebase, two deployment modes, identical
  guarantees.
- Licensing boundaries between free/core and enterprise features.
- The security model, including authentication, authorization, channel
  assurance, secret handling, and sensitivity policy.
- Data ownership, portability, erasure, audit, and export/import promises.
- Multi-tenancy architecture and any change that affects account isolation.
- Breaking API, SDK, MCP, gateway, or storage behavior.
- Human governance semantics, including who may approve knowledge, consent, or
  scope promotion.
- Required-check policy, branch protection, CODEOWNERS, and GitHub repository
  settings.

Codex may propose an ADR, implementation option, or risk analysis in these
areas, but the decision must be reviewed and accepted by a human before it
becomes binding.

## Consequences

This boundary lets MemHouse use Codex for focused implementation without
delegating product accountability or trust boundaries to automation. It keeps
low-risk work moving while preserving review control over the guarantees that
make the system credible: deployment-mode parity, account isolation, data
ownership, auditability, and deterministic evidence.

The trade-off is deliberate friction. Some issues will require human scoping or
an accepted ADR before implementation can proceed. That is acceptable because
the cost of an extra review step is lower than silently weakening MemHouse's
architecture, security posture, licensing model, or data promises.

Future automation may become more capable, but any expansion of what Codex may
decide or merge must be recorded in a later ADR and backed by deterministic
checks, CODEOWNER review where appropriate, and explicit human approval.

## Anchors

- `AINV-1` - one codebase, two modes, identical guarantees.
- `AINV-6` - account is derived from identity, never from request parameters.
- `AD-EVAL-1` - model provider layer as the determinism seam.
- `AD-EVAL-2` - testing pyramid.
- `AD-EVAL-3` - deterministic PR gate separated from nightly/release evals.
- `AD-SEC-1` - the hard account wall.
- `AD-PORT-1` - logical account export.

## Related Documents

- `AGENTS.md`
- `specs/adr/0001-repo-automation-model.md`
- `specs/roadmap/beta-roadmap.md`
