<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0009: Entity cards are scope-bounded projections

## Status

Accepted.

**Amended by ADR 0011** (`specs/adr/0011-scope-local-entity-card-labels.md`): a card may carry a
scope-local surface form as its label and a recomputed kind, the card threshold is two sources,
and the summary threshold remains three. Amendments are marked in place below.

## Context

Retrieval returns individual governed statements. An agent asking what is known
about one service or person receives a ranked scatter rather than a compact
brief.

Putting a description on `Knowledge.Entity` is unsafe. Entity rows are
account-global and deliberately connect mentions across scopes. A narrative on
that row would aggregate content past the statement scope that supplies all
entity visibility. Account administrators are not an exemption: authenticated
actors still carry explicit authorized scopes.

Entity-card sensitivity also needs an explicit decision. A summary that combines
sources takes the strictest source classification. MemHouse currently uses
sensitivity at Gate B to decide blast radius, then scope policy to authorize
reads. It has no separate reader-clearance axis.

## Decision

Add `entity_card` as a `Knowledge.Projection` kind. One row is keyed by Account,
scope, and resolved entity. `Projection.entity_id` and the entity-bearing cache
key are private coordinates. Neither appears in context output.

The projection builder groups `EntityMention` rows by entity, then dereferences
them to governed statements in the same scope. A card is built only when at
least three distinct source statements are `active` (ADR 0011: two).
`provisional` statements are excluded because an entity card has no subject Peer
whose provisional visibility it could inherit.

The dream reasoner produces one bounded paragraph from the governed statements.
The deterministic local provider instead concatenates the same sources, so an
offline node never presents fake reasoning. A real provider failure fails the
rebuild and leaves the prior clean projection intact for job retry. The card
also contains allowlisted source statements and model provenance; it is a
projection, never a citable knowledge atom.

Each row stores `max(source.sensitivity)` under the order `public < internal <
personal < restricted`, and the context payload returns that classification.
Reads remain scope-gated because no reader-clearance contract exists. If one is
added, its KnowledgeItem field policy and Projection sensitivity policy must
ship together; the stored maximum is the projection-side filter point.

Cards are returned in the additive `entity_cards` member of `get_context` after
scope cards and before individual knowledge in the budget order. Existing
fields and retrieval behavior remain `f7-1`. Dirty marking stays scope-wide.
A rebuild that finds fewer than three active sources leaves any old card dirty
(ADR 0011: fewer than two, and ADR 0011 restates the `f7-1` hold on its own
terms because it changes existing fields).

## Consequences

- Entity rows and their id, canonical-name, and alias fields remain absent from
  every public payload. Summary prose may repeat text from its governed
  statements. ADR 0011 admits one surface form per card as its label, chosen
  from that card's own sources in its own scope.
- Scope authorization and Account isolation remain unchanged.
- Summary cost is bounded by the three-source threshold and one call per
  qualifying scope/entity pair. ADR 0011 keeps this threshold on the summary
  while lowering the threshold for the card itself.
- The context response grows only when a card fits the caller's character
  budget. ADR 0011 adds a per-scope cap, because a lower card threshold would
  otherwise let cheap cards displace ranked statements.
- Embedding cards or admitting them as retrieval candidates remains deferred.
  That change must dereference to governed `source_ids` and pass an evaluation
  ablation before altering any retrieval profile.

## Anchors

- `FR-KN-1`, `FR-KN-16`, `FR-KN-20`, `FR-KN-21`, `FR-KN-23`
- `FR-API-4`, `FR-API-5`, `FR-API-10`
- `AD-DATA-10`, `AD-DATA-11`, `AD-PIPE-7`
- `AINV-5`, `AINV-6`

## Related documents

- `specs/adr/0006-entity-resolution.md`
- `specs/architecture/retrieval-entity-context.md`
- `specs/memory-system-functional-requirements.md`
- `specs/memory-system-architecture-and-nfr.md`
