# ADR 0006: Entity resolution as a dream-time stage

## Status

Accepted. One sub-question is inherited from ADR 0004 and left open for the
maintainer: whether any retrieval strategy may be enterprise-gated (see the Open
question section).

The public-surface boundary was reconsidered in
[#73](https://github.com/memhousehq/memhouse/issues/73) and retained. A
reader-projected entity browser is not an exception to this decision.

This ADR adds two derived resources, one dream-time pipeline stage, and one
retrieval strategy. It adds nothing to the public API surface — the new
resources are deliberately unreadable through every external surface — so this
is not a breaking API change under ADR 0002. It amends ADR 0004's stage 4.

## Context

`FR-FORM-14` chooses `add`, `merge`, `supersede-candidate`, or `no-op` from
statement similarity but does not canonicalize referents. "Alice", "our CTO",
and `alice@example.com` are unrelated strings. As a result, `merge`
(`FR-KN-9`) misses differently phrased statements about one subject, `Lexical`
misses aliases, and `RelationExpand` cannot connect statements about the same
thing.

Industry designs treat resolution as a separate pipeline stage and entity
matching as a retrieval signal. Mem0 reported retaining a +23.1 multi-hop gain
after replacing external graph databases with entity linking, suggesting ADR
0004 stage 4 does not require a full knowledge graph.

`FR-KN-2` requires humans to gate natural-language statements, not derived
triples. Both graphs and entity indexes must therefore derive at dream-time from
validated statements, but the entity index needs only one referent per thing
and one annotation per mention.

## Decision

### Two derived resources

`MemHouse.Knowledge.Entity`:

| Field | Purpose |
|---|---|
| `account_id` | Tenancy (`AINV-6`) |
| `canonical_name` | Preferred surface form |
| `kind` | `:person \| :org \| :system \| :artifact \| :concept` |
| `aliases` | Observed surface forms |
| `alias_embedding` | Vector over canonical name and aliases; candidate lookup |
| `derived_from` | Statement ids the entity was resolved from |

`MemHouse.Knowledge.EntityMention` joins them to knowledge:
`statement_id`, `entity_id`, `surface_form`, `confidence`.

### Entities carry no visibility of their own

Entities are account-global, following the Peer precedent (`AD-SEC-2`).
Mentions inherit scope from the statements they annotate, and retrieval
continues to filter statements by scope and policy exactly as before.

Therefore **entity resolution cannot change who can read what**. Errors affect
accuracy, not the account wall (`AD-SEC-1`, `AINV-6`) or scope authorization.

**Entities are not readable through any public surface.** No REST, MCP, SDK, or
LiveView endpoint returns entity rows, alias lists, or canonical names. An
entity from a restricted statement could otherwise leak its referent. Entities
are retrieval-internal only, enforced by a deterministic PR-gate test
(`AD-EVAL-3`).

### Reader-projected entity browsing is rejected

Recomputing labels and aliases from only the statements a reader may see would
prevent direct disclosure of stored entity fields. It would still disclose the
resolver's clustering: that two otherwise separate statements refer to the
same thing. That relationship is new information, not a restatement of either
authorized statement.

The projection would also require an actor-specific live query over an
account-global cache. It could not be reused between readers, and every change
to scope resolution, policies, or entity resolution would expand the audit
surface. Most importantly, it would replace the structural rule that entity
read actions are pipeline-only with a review-dependent exception.

Public investigation therefore stays statement-shaped. Authorized readers may
search and browse knowledge, then follow visible provenance, supersession, and
knowledge relations. `EntityMatch` may use clustering internally to rank those
statements, but no response groups them by entity or returns a stable or opaque
entity handle. This preserves `FR-KN-21` while serving the curator workflow
through the governed atom.

**Erasure recomputes entities.** `FR-GOV-15` and `FR-GOV-16` recompute every
entity derived from an erased statement and prune entities with no surviving
source. The erasure flow triggers this beside projection recomputation.

### `FR-KN-2` is preserved, not weakened

An entity is a canonical referent, not a triple. Statements remain natural
language; mentions only assert that surface forms denote the same thing. They
do not add graph relationships or new content to govern.

### Placement: dream-time

Three reasons, in order of force:

1. **Gating.** Entities derive only from already-validated statements,
   inheriting the parent statement's gate — the same constraint the deferred
   graph layer carries, for the same reason.
2. **Ingest is reasoning-free.** `AD-PIPE-2` admits extraction and cheap gating
   only. Resolution is reasoning.
3. **Resolution needs corpus context.** Ingest is per-message; resolution needs
   the candidate entity set.

Pending statements have no entity links and `EntityMatch` cannot retrieve them,
consistent with every other knowledge path.

### Resolution cascade

Cheap first; the expensive step runs only where the cheap ones are ambiguous.

1. Exact alias match.
2. Alias-embedding similarity above a configured candidate threshold.
3. Dream-reasoner adjudication (`AD-MODEL-1` capability behaviour) for every
   non-exact candidate. Embedding similarity measures relatedness, not identity,
   and cannot merge entities by itself.

Step 3 uses the dream-time token budget and sheds first under pressure
(`AD-PIPE-3`, `AD-PIPE-4`), leaving unresolved mentions instead of stalling the
lane (`AD-PIPE-9`).

### Derived cache, under `AINV-5`

`Entity` and `EntityMention` are rebuildable from statements and are never the
system of record. They are excluded from the `AD-PORT-1` logical export and
regenerate on import; the export manifest already carries the embedder model and
version, which is what a rebuild needs.

Merges and splits are recomputation, not history changes: they need no gate and
leave no ledger entry.

### The `EntityMatch` retrieval strategy

A new `MemHouse.Retrieval.Strategy` implementation under ADR 0004's seam:

- `name/0` — `:entity_match`
- `cost_class/0` — `:cheap`
- `stage/0` — `:seed`
- `applicable?/1` — true when the query contains a mention resolvable against
  the account's entity set
- `candidates/2` — statements mentioning the resolved entities, ranked by
  mention confidence combined with the statement's own score

It uses RRF, so a false-positive `applicable?/1` adds low-ranked candidates
rather than directly producing an answer.

`RelationExpand` gains a second edge type: hop-1 expansion may traverse
shared-entity edges alongside `supersedes`, upkeep links, and `ScopeRelation`.

Profile placement: `EntityMatch` joins `:balanced` and `:thorough`. It stays out
of `:fast`, which exists to serve a `get_context` cache miss and must stay
minimal.

### ADR 0004 stage 4 is retargeted

ADR 0004's staging ends with "dream-time knowledge graph and the `Graph`
strategy". That stage becomes **entity graph and `EntityMatch`**.

The knowledge graph remains deferred (ARCH §18, FR §12). The `Graph` seam stays
reserved.

## Consequences

- `FR-KN-9` merge decisions can use referent identity instead of embedding
  proximity alone.
- `EntityMatch` adds a cheap seed to `:balanced` and `:thorough`, especially
  for aliases missed by semantic and lexical search.
- Dream-time cost rises; budget shedding leaves unresolved mentions and stale
  coverage rather than a stalled queue.
- Mis-merging referents can mix answers. Conservative thresholds, ambiguous
  band adjudication, and recomputation reduce this accuracy risk. Authorization
  does not depend on entities, so disclosure risk does not expand.
- Public invisibility is enforced by an exhaustive PR-gate test rather than the
  stronger structural defenses used for account isolation.
- Curator investigations use authorized statements and their visible
  provenance and relations; there is no entity-grouped browse view.

## Staging

- **Stage 1:** add resources and dream-time resolution without retrieval;
  measure coverage and precision.
- **Stage 2:** feed referent identity into `FR-FORM-14` merge decisions and
  compare with ADR 0004's Stage 0 baseline.
- **Stage 3:** ablate `EntityMatch` in `:balanced` and `:thorough` before
  changing defaults.
- **Stage 4:** add shared-entity edges to `RelationExpand`.

Stage 1 must not start before ADR 0004's Stage 0 baseline exists, for the reason
ADR 0004 gives: without it there is nothing to attribute improvement to.

## Open question

**May `EntityMatch` be enterprise-gated?** Inherited from ADR 0004's open
question rather than reopened here. The recommendation is unchanged — no; gate
scale, operations, governance, and support, not answer quality. Licensing
boundaries are an ADR 0002 human-only decision area.

## Anchors

- `AINV-5` - system of record vs derived cache; entities are a cache.
- `AINV-6` - account derived from identity; entity tenancy.
- `AINV-8` - domain strategies vs infrastructure ports; `EntityMatch` is domain.
- `AD-SEAM-3` - domain strategies; gains `EntityMatch`.
- `AD-DATA-10` - entities and mentions as a derived, non-exported cache.
- `AD-SEC-1` - the hard account wall; unaffected by entity resolution.
- `AD-SEC-2` - peer identity model; the account-global precedent.
- `AD-MODEL-1` - capability behaviours; the adjudication step.
- `AD-PIPE-2` - ingest is reasoning-free; why resolution is dream-time.
- `AD-PIPE-3` / `AD-PIPE-4` - dream-time budgets; the shed-first cascade step.
- `AD-PIPE-9` - read/write cost asymmetry; why the stage sits on the write side.
- `AD-PORT-1` - logical export; entities are excluded and regenerate.
- `AD-EVAL-3` - PR gate hosts the no-public-entity-surface test.
- `FR-KN-2` - natural-language statements only; preserved, not weakened.
- `FR-KN-9` - dedup and merge; gains referent identity as a signal.
- `FR-KN-18`..`FR-KN-22` - entity resolution requirements.
- `FR-FORM-14` - update-operation resolution; `merge` gains the signal.
- `FR-GOV-15` / `FR-GOV-16` - erasure; must recompute entities.
- `FR-API-25` - multi-strategy retrieval; gains `entity_match`.

## Related Documents

- `specs/adr/0002-l3-automation-boundary.md`
- `specs/adr/0004-multi-strategy-retrieval.md`
