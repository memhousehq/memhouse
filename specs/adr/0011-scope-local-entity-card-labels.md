<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0011: Entity cards carry a scope-local label and a recomputed kind

## Status

Accepted.

**Amends ADR 0009** (`specs/adr/0009-scope-bounded-entity-cards.md`): a surface form may appear
on a card as its label, the card threshold drops from three sources to two, and the summary
threshold stays at three. ADR 0009's other decisions stand.

## Context

The console graph draws each resolved entity as an anonymous hub labelled `Shared entity 6`. A
reader cannot tell what the referent is, which makes the picture navigable but not informative.

The cost of that anonymity is larger than the console. A wrong entity merge silently degrades
retrieval expansion, and no surface anywhere shows that it happened. Making resolution
observable is the stronger reason for this change; the console readability gain is the smaller
one.

ADR 0009 placed entity ids, canonical names, aliases, and surface forms outside every public
payload. Two of those four must stay outside, and for a reason that is easy to lose:

- `Entity.canonical_name` is account-global. The row deliberately connects mentions across
  scopes, so the name may have been coined in a scope the reader cannot access.
- `Entity.kind` has the same defect and is worse in one way. `infer_kind/1` runs once, in
  `new_draft/5`, against the first spelling ever seen; `write_draft!/3` never revises it. A card
  in a readable scope could report `person` because the entity was first seen as an email address
  somewhere invisible, while every statement in front of the reader implies `org`.

A surface form is different. Restricted to one scope and to the card's own source statements, it
is text the same card already hands the reader.

## Decision

An entity card carries `label` and `kind` in its content.

`label` is chosen from the `EntityMention.surface_form` values belonging to that card's own
sources in its own scope. Selection is by frequency, then shortest form, then lexical order. A
candidate is rejected when it contains `". "`, a newline, a tab, a doubled space, or when the
form is itself a closed-class English word. A card with no surviving candidate carries no label
and renders as an ordinal.

Shortest wins the tie-break, not longest. Surface forms are stored byte-exact, and the mention
spotter joins capitalised words across `\s+`, which crosses sentence boundaries. Longest reliably
selects that artefact. Per-statement deduplication also makes small cards a frequency tie, so the
tie-break decides most labels rather than a few.

The period rule targets `". "` rather than any period. The spotter admits periods inside one
token, so rejecting all of them would discard every email address, and with it every `person`
classification.

`kind` is recomputed by applying `infer_kind/1` to the card's own in-scope forms and resolving by
that function's documented precedence: `person`, then `org`, then `system`, then `concept`. The
stored `Entity.kind` is not read. Recomputation also means **no `Entity` read is added anywhere**,
which is what keeps the builder's phase structure intact: phase two holds no database connection
so that a slow provider call cannot pin one.

`infer_kind/1` becomes public so that one implementation serves both callers.

The card threshold drops to two active sources. The summary threshold stays at three. A
two-source card stores `summary: nil`, `summary_mode: "none"`, and `summary_provenance: nil`.

The summary threshold applies whatever the provider. Under the deterministic provider a summary
is a local concatenation and costs nothing, so a purely economic rule would exempt offline nodes
and give them different content from the same release.

`get_context` caps entity cards per authorized scope, ordered by source count, then best source
confidence, then label. The label enters the sort key because the previous final key was the
cache key, which contains the entity UUID and changes under re-resolution; with a cap in place
that churn would otherwise be visible as cards appearing and disappearing between requests.

The console graph labels a hub only when its cluster resolved to exactly one entity.
`shared_entity_clusters/3` collapses groups with identical membership so the graph never reports
how many entities resolved, and that collapse is preserved. The query now returns `entity_ids`
per group for the caller's own lookups; the loader uses it to find a card and does not put it in
the cluster map.

## Consequences

- `f7-1` does not change. This is a deliberate hold, not an additive change. `summary` and
  `summary_mode` are existing fields, and making a non-null string nullable while adding a third
  mode value is a change to them. ADR 0009's sentence about additive members concerns the
  `entity_cards` member itself and does not cover this. Callers must treat all three summary
  fields as optional; the changelog carries the entry.
- The rendered kind vocabulary is `person`, `org`, `system`, `concept`. `FR-KN-18` names five
  kinds including `artifact`, which no code path produces. The divergence is recorded here rather
  than silently adopted, and the column stays unvalidated free text, so an unrecognised value
  renders as no badge.
- Coverage is partial. A collapsed cluster keeps its ordinal. If collapsed clusters prove common
  in practice, that is the evidence for revisiting the collapse, which is a separate decision.
- Two costs grow with the lower card threshold. Projection rows per scope rise, and
  `retire_stale_entity_cards!/4` reads every entity-card row in the scope and issues one
  sequential update per stale row on each refresh. Neither is bounded by the payload cap, which
  applies at read time.
- Labels are English-only. A deployment whose statements are in another language gets ordinals.
- Labels flicker. A card goes dirty on any lifecycle change in its scope and stays dirty until
  the refresh job runs, so a curator approving statements sees labels fall back to ordinals.
- Offline and online nodes already diverge here. `:entity_resolution` is unrecognised by the
  deterministic provider, so offline runs resolve entities more finely. At two sources that
  divergence becomes visible in the console as different card counts and labels.
- The guarantee is narrow and must be quoted narrowly: a form that *is* a closed-class word is
  rejected. A determiner absorbed into a multiword form survives, because the spotter emits
  `The Helix API` as one form and no token filter removes its leading word.

## Anchors

- `FR-KN-18`, `FR-KN-20`, `FR-KN-21`, `FR-KN-23`
- `FR-API-4`, `FR-API-5`
- `AD-DATA-10`, `AD-DATA-11`, `AD-PIPE-7`
- `AINV-5`, `AINV-6`
- `ADR-0006`, `ADR-0009`

## Related documents

- `specs/adr/0006-entity-resolution.md`
- `specs/adr/0009-scope-bounded-entity-cards.md`
- `specs/architecture/retrieval-entity-context.md`
- `specs/design/2026-08-06-visible-entity-cards-and-projection-oversight-design.md`
