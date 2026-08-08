<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Visible entity cards and projection oversight

## Status

Draft. Revised after a code-verification pass. Awaiting review.

ADR 0011 must record the contract change before implementation lands. It amends
`specs/adr/0009-scope-bounded-entity-cards.md` in the way ADR 0006 amends
ADR 0004: a note in each Status section, and a mutual entry under Related
documents.

## Problem

The console graph draws entity clusters as anonymous hubs. A hub shows
`Shared entity 6` and a list of member statements. The reader cannot tell what
the referent is.

Two further gaps follow from the same cause:

- A wrong entity merge is invisible. It corrupts retrieval expansion, and no
  surface shows it.
- Projections carry the freshness of every context read. No surface shows
  whether a card is dirty, stale, or still holding a retracted statement.

## Decisions

| Question | Decision |
| --- | --- |
| Entity label | Scope-local surface form. Never `canonical_name` |
| Entity kind | Recomputed scope-locally. Never the stored `Entity.kind` |
| Label and kind in `get_context` | Yes |
| Card threshold | 2 sources for a card, 3 for a summary |
| Cluster collapse | Preserved. Only a single-entity group gets a label |
| Peer profile content | Account-admin only, on `/governance` |
| Console visibility rule | Unchanged. `/console/*` stays subject-only |

## Non-goals

- No reader-clearance axis. Reads stay scope-gated, as ADR 0009 decided.
- No entity permalink. `entity_id` stays a private cache coordinate.
- No card embedding and no card as a retrieval candidate.
- No change to Gate A or Gate B. Cards are projections, never gated artifacts.

## Increment 1: entity cards carry an identity

### Label

The card label is derived from the `EntityMention.surface_form` values that
produced the card, restricted to that card's own scope and its own source
statements. Every character of the label already appears in a statement the
same card supplies. This is what makes it safe, and it is why
`Entity.canonical_name` cannot be used: that column is account-global and can
carry a name coined in a scope the reader cannot see.

Selection is by frequency, then **shortest** form, then lexical order.

Shortest, not longest. Surface forms are stored byte-exact with only outer
trimming (`entity_resolver.ex:128-134`), and the multiword joiner matches `\s+`,
which crosses newlines and sentence boundaries (`entity_resolver.ex:30`).
Longest therefore selects sentence-spanning artefacts. Per-statement dedup means
a two- or three-source card is usually a frequency tie, so the tie-break decides
most labels and must pick the clean form.

A candidate form is rejected when it contains a period, a newline, or a double
space, or when it is a closed-class word.

The closed-class inventory is new code. The repo has no reusable list: the only
word lists are 26 interrogatives for search queries
(`lexical_query_analyzer.ex:14-16`) and a length heuristic in the peer queue.
The inventory is English-only, case-folded for comparison, and that limitation
is stated in the module doc.

The guarantee is exactly: **a form that is itself a closed-class word is
rejected.** It is not "no label contains a determiner". The mention regex joins
adjacent capitalised tokens, so `The Helix API is down.` yields the single form
`The Helix API`, and no token-level filter removes that leading determiner.

A card whose every candidate is rejected carries no label and renders as an
ordinal.

### Kind

The card stores a kind recomputed from its own in-scope surface forms.

The stored `Entity.kind` must not be used. It is set once from the first surface
form that ever created the entity, in whatever scope that was
(`entity_resolver.ex:290`, persisted at `:387`), and `write_draft!/3` never
revises it (`:401-413`). `Entity` has no `scope_id`. Reporting it would leak the
same cross-scope inference the label rules are designed to prevent.

Recomputation applies the existing `infer_kind/1` rule to each distinct in-scope
surface form and resolves by that function's own documented precedence:
`person` beats `org` beats `system` beats `concept`.

`infer_kind/1` becomes public, or moves to the new label module. It must stay
one implementation. Two copies would drift.

Because kind is recomputed, **no `Entity` read is added anywhere**. This is why
`read_scope!/2` keeps its arity and the builder's phase structure is untouched.

The rendered vocabulary is exactly `person`, `org`, `system`, `concept`
(`entity_resolver.ex:531-538`). The column is unvalidated free text
(`knowledge.ex:844`), so an unrecognised value renders as no badge rather than
as an unknown pill. `FR-KN-18` names five kinds including `artifact`, which no
code path produces; ADR 0011 records the divergence rather than silently
adopting it.

### Where the work happens

Label and kind are computed in `build_entity_card_attrs!/5`, which already
receives the scope's mentions and its ranked statements. That function runs in
phase two, which deliberately holds no database connection so a slow provider
call cannot pin one (`builder.ex:10-12`, `:105-106`). Both computations are pure
over data phase one already read, so they respect that constraint.

### Thresholds

`@entity_card_min_sources 3` splits into two constants with distinct reasons:

- card existence: 2 distinct active sources
- summary generation: 3 distinct active sources

The existing comment at `builder.ex:32-34` asserts both halves in one sentence
and must be split, not edited. `retire_stale_entity_cards!/4`'s comment
(`builder.ex:243-247`) states the source threshold as the retirement rule and
follows the card threshold.

The summary threshold applies **uniformly, whatever the provider**. Under the
deterministic provider the summary is a local concatenation and costs nothing
(`builder.ex:265-270`), so a cost argument would exempt offline nodes. Exempting
them would break the prime directive. One release, one behaviour.

A two-source card stores `summary: nil`, `summary_mode: "none"`, and
`summary_provenance: nil`. Today `summary_provenance` is always populated
(`builder.ex:231`).

### Payload budget

Threshold 2 preserves ADR 0009's model-cost bound. It breaks that ADR's other
consequence, that the context response grows only within the caller's budget.

Entity cards are spent before governed knowledge (`context.ex:277-283`), and
`take_values/2` halts at the first value that does not fit (`:293-295`). Each
card carries full statement text. The mention spotter is purely orthographic and
fires on every capitalised token, so halving the threshold multiplies qualifying
entities per scope. Cheap two-source cards would displace ranked statements.

`get_context` therefore caps entity cards per scope, ordered by source count.
The present tie-break is `cache_key`, which is the entity UUID (`context.ex:139`)
and is unstable across re-resolution; the cap makes that instability
user-visible, so the order gains a stable secondary key.

Two costs are also priced in ADR 0011: projection rows per scope, and
`retire_stale_entity_cards!/4`, which reads every entity-card row in the scope
and issues one sequential update per stale row on each refresh
(`builder.ex:248-260`).

### Contract identity

`f7-1` is held deliberately. It is **not** justified as an additive change.

`summary` and `summary_mode` already exist. Making a non-null string nullable
and adding a third value to a two-value mode field is a change to existing
fields. ADR 0009's sentence about additive members concerns the `entity_cards`
member itself and does not cover this. ADR 0011 defends holding `f7-1` on its
own terms, and the changelog carries the entry.

### Console graph

`shared_entity_clusters/3` returns `entity_ids` per group alongside `members`.

The `SELECT DISTINCT members` collapse is preserved. It exists so that two
entities shared by exactly the same statements read as one link rather than
disclosing how many entities resolved (`store.ex:744-746`). A group is therefore
a membership set, not an entity.

A hub is labelled only when its group holds exactly one entity id. A collapsed
group keeps its ordinal. Coverage is partial by design; the alternative spends a
second anonymity property to gain the tightly-coupled hubs.

The loader's cluster map must not gain `entity_id`.
`console_live_test.exs:805` asserts `refute Map.has_key?(cluster, :entity_id)`
against a load-bearing comment, and that assertion survives this change
unmodified. The loader resolves label and kind before building the map and puts
only those in it.

The loader's projection query must filter `kind == "entity_card" and
dirty == false`. `Knowledge.Projection` authorizes reads on `scope_id` alone and
filters neither kind nor peer (`knowledge.ex:684-686`). An unfiltered query in a
drawn scope would return `peer_profile` rows — another peer's provisional
content — to any member with scope access. `MemHouse.Context` avoids this by
filtering kind and keying on `actor.peer_id` (`context.ex:126-128`, `:150-155`).
A negative test pins it.

When `descendants?: true` draws several scopes and a cluster spans them, the
focus scope's card wins. A cluster with no card in the focus scope falls back to
the nearest drawn ancestor that has one.

The cluster panel shows the label, a kind badge, a sensitivity badge, the
summary with its mode, then the member statements. `<.badge family="kind">` is
already deliberately colourless (`console_components.ex:583`), which suits a
heuristic value.

Cards exclude provisional statements; the drawn set includes the viewer's own. A
cluster can hold members its card never read. The panel lists card sources and
cluster members as two groups, so the summary never appears to cover a statement
it did not see.

The console has no existing visual distinction between model-derived and
governed content. The two precedents for "different in kind" are
`.tool-panel.is-write` and `.diagnostic-panel`, both a heavy left border plus an
explicit word. The card summary follows that pattern.

## Increment 2: entity nodes and co-mention edges

Preserving the collapse removes most of this increment's original scope, and the
spec no longer claims it.

Lowering the statement-count guard to 1 does **not** put every entity on the
graph. The guard is `HAVING count(DISTINCT m.knowledge_item_id) >= 2`
(`store.ex:761`), a statement count. At 1, every entity mentioned only in
statement `S` produces `members = [S]`, and `SELECT DISTINCT members` folds them
into one group. The result is one node per statement, not one per entity.
Delivering one node per entity requires removing the collapse, which this design
declines.

What remains, and is worth building:

Co-mention edges between labelled hubs. Two entities named in the same statement
are joined by one join over `entity_mentions`. Both endpoints come from a single
readable statement, which satisfies the rule that expansion requires access to
both relation endpoints. Edges are drawn only between hubs that carry a label,
so the collapse is not circumvented by inference from the edge set.

A co-mention edge means "named together", not "related to". MemHouse has no
entity-relation table, and this edge does not create one. The legend says so.

## Increment 3: projection oversight

A page at `/governance/projections` lists projections for a chosen scope.

This is the first console surface that reads `Knowledge.Projection` directly
rather than through `MemHouse.Context`. That is a new boundary and needs its own
ADR.

### What each role sees

| Kind | Metadata | Content |
| --- | --- | --- |
| `scope_card` | Curator, admin | Curator, admin |
| `session_summary` | Curator, admin | Curator, admin |
| `entity_card` | Curator, admin | Curator, admin |
| `peer_profile` | Curator, admin | Account-admin only |

Metadata is `kind`, `version`, `dirty`, `watermark`, `delta_count`, source
count, and the resolved scope, peer, or session. It carries no statement text.

The `/governance` session admits curators and account-admins, so the route gate
is not sufficient. The page checks for account-admin before rendering
peer-profile content.

### Why peer profiles are the exception

`Knowledge.Projection` authorizes reads on `scope_id` alone. What keeps one
peer's profile away from another today is the access pattern in
`MemHouse.Context`, which builds the peer cache key from `actor.peer_id` and
never from a request parameter. A list that enumerates by scope bypasses that
guard, and peer profiles are the only kind that stores provisional content.

`/console/*` remains subject-only for every role, and
`MemHouseWeb.Console.Access.visible_knowledge?` does not change. Oversight lives
on a separate, role-gated surface.

### Audit

An account-admin who reads another peer's provisional content emits a
content-safe audit record: actor, subject peer id, scope, and time. No statement
text.

A page render is not an operation, and console writes must delegate to the
operation layer, which reauthorizes them (`AGENTS.md:262-263`). Product invariant
11 requires state and audit to commit together. The page therefore calls a named
operation-layer function that loads and audits peer-profile content in one
transaction, rather than reading through the Loader. ADR 0012 names that
function.

`source_ids` on any card can name statements the viewer cannot read. The page
renders counts and links only through the already-authorized loaded set, the rule
`cluster_members/2` already applies.

## Increment 4: scoped entity list

A page listing one scope's entity cards, ordered by source count. It reuses
increment 1's data and increment 3's access rules, and adds no new read path.

It is where systematic merge errors become visible. The graph shows only clusters
among the drawn statement limit.

Members link to `/console/knowledge/:id`. There is no per-entity route, because
the URL cannot carry `entity_id`.

## Contract impact

| Artifact | Change |
| --- | --- |
| ADR 0011 | Amends ADR 0009: a scope-local surface form may appear as a card label; kind is recomputed, not stored; thresholds split; `f7-1` held on its own terms; `FR-KN-18` divergence recorded |
| ADR 0009 | Status gains the reciprocal amendment note |
| `specs/adr/README.md` | Index table gains ADR 0011 |
| ADR 0012 | Console surfaces may read `Knowledge.Projection` directly (increment 3) |
| `AGENTS.md` retrieval section | Surface-form prohibition gains the scope-card exception |
| `AGENTS.md` console rule | "Never expose entities" gains the same exception |
| `docs/reference/http-api.md:251-253` | "mention surface forms are never returned" and the three-source rule |
| `docs/guides/context.md:33-40,52` | Worked example and the three-source rule |
| `docs/concepts/retrieval.md` | Entity anonymity is now scope-bounded |
| `specs/architecture/retrieval-entity-context.md:200,222` | Same two claims |
| `specs/memory-system-architecture-and-nfr.md:171-172` | "No public surface returns them"; three-source rule |
| `specs/implementation-status.md:160-167` | Entity caches "never exposed through … LiveView" |
| `CHANGELOG.md` | Label, kind, nullable summary, per-scope cap, new pages |

## Risks

**Label quality.** Surface forms are raw extracted text with no normalisation.
The tie-break and rejection rules remove the worst artefacts. Some labels will
still read badly. A poor label beats an ordinal.

**Label flicker.** A card goes dirty on any lifecycle change in its scope and
stays dirty until the refresh job runs. A curator approving statements sees
labels fall back to ordinals. The panel shows a refreshing state rather than
failing silently.

**Partial coverage.** Collapsed hubs stay anonymous. If they turn out to be
common, that is the evidence for revisiting the collapse decision.

**Derived content read as governed.** The left-border pattern and the
`summary_mode` badge are the mitigation.

**Deterministic divergence.** `:entity_resolution` is unrecognised by the
deterministic provider (`deterministic.ex:60`), so offline runs resolve entities
more finely and produce different card counts and labels. At threshold 2 this
becomes user-visible in the console. It is pre-existing, and ADR 0011 records it.

## Evidence

| Test | Covers |
| --- | --- |
| `test/memhouse/context/entity_label_test.exs` (new) | Selection order; rejection rules; closed-class list; kind precedence |
| `test/memhouse/context/builder_test.exs` (new) | A label never draws on a statement outside the card's sources; both thresholds; null summary and provenance at two sources |
| `test/memhouse/f7_retrieval_entity_context_test.exs` | Payload members; per-scope cap and its ordering |
| `test/memhouse_web/console/graph_test.exs` | Hub labels; ordinal fallback for collapsed groups |
| `test/memhouse_web/live/console_live_test.exs` | Panel rendering; `:entity_id` absent from the cluster map, unchanged; a `peer_profile` row in a drawn scope never reaches the graph payload |
| `test/memhouse_web/console/access_test.exs` | `/console/*` provisional rule unchanged |

## Delivery

Four pull requests. Increments 3 and 4 depend on 1. Increment 2 is independent of
3 and 4.

Increment 1 ships first on its own. It will show whether surface-form labels are
good enough to justify the surfaces built on them.
