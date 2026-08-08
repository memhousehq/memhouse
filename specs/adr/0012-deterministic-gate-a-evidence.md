# ADR 0012: Deterministic Gate A evidence

## Status

Accepted

## Context

Gate A used the extractor's self-reported confidence as the only input to an
automatic keep. That value is model output. It can change when the same raw
observation is extracted again. It is useful metadata for a reviewer, but it is
not a reproducible automation signal.

The former hearsay discount had the same defect. A model could set `hearsay`,
and a scope subject was treated as hearsay only because it did not equal a peer
key. Neither rule described the source-to-subject relationship reliably.

Sensitivity also selected a matrix row but did not constrain automatic
placement. A permissive row could therefore expose personal or restricted
knowledge without a human decision.

## Decision

The extraction schema derives `evidence_level` from values already verified by
the schema context:

| Relationship | Evidence level | Confidence treatment |
| --- | --- | --- |
| Source Peer is the resolved peer subject | `direct` | unchanged |
| Any other resolved subject | `indirect` | multiply by 0.75 |

`evidence_level` is persisted on `KnowledgeItem`. Gate A automation compares
that value with `GateRule.minimum_evidence_level`, which defaults to `direct`.
`minimum_confidence` remains durable policy metadata for compatibility, but no
longer authorizes automatic keeps.

Gate B may automatically place only `public` or `internal` knowledge. Personal
and restricted knowledge remain held or provisional until a human makes the
placement decision. Subject consent remains an additional requirement; an
automatic consent declaration does not bypass the human sensitivity decision.

The operations console reports content-safe totals for keep, place, hold,
defer, and reject decisions.

## Consequences

Repeated extraction of the same source and resolved subject produces the same
Gate A input. An indirect claim cannot become automatically active because a
model assigns it a high confidence. Existing matrix rows continue to work, but
their confidence floor no longer increases automatic acceptance.

This is intentionally conservative. It does not infer whether a direct
first-person statement is true. Corroboration, consent, sensitivity, and human
review remain independent controls.

## Anchors

- `FR-FORM-15` — source and subject remain independent, with deterministic
  third-party discounting.
- `FR-GOV-1` through `FR-GOV-4` — governed promotion and review.
- `AINV-3` — a wider audience requires more care.
- `AD-GOV-1` through `AD-GOV-5` — Gate A/B governance.

## Related Documents

- `specs/architecture/gate-a-b-governance.md`
- `specs/architecture/model-layer-structured-extraction.md`
- `docs/concepts/governance.md`
