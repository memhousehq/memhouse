<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Glossary

**Account** — the identity-derived isolation boundary for every durable row,
enforced by Phoenix, Ash policies, and PostgreSQL RLS. Community serves one.

**Ask** — cited answer generation over retrieved memory, with abstention.
Defaults to `thorough`.

**Belief time** — when the system learned or holds a claim (`inserted_at`,
`revalidate_after`, `expires_at`). Distinct from valid time.

**Blast radius** — how far a statement can be seen: one peer, a scope, or the
whole Account. Wider radius, higher bar.

**Candidate** — one result from a retrieval strategy, before or after fusion.

**Confidence** — how sure the system is of a statement. Independent of
sensitivity.

**Consent** — a subject's verified, scope-specific permission for personal
knowledge about them to move to a wider scope. No curator can substitute for
it.

**Context** — a budgeted, reasoning-free assembly of governed knowledge, a
session summary, scope cards, and a peer profile, built from projections.

**Contract version** — a version string on a response shape, such as `f7-1`,
independent of the application's semantic version. See
[Contract versions](contract-versions.md).

**Curator** — a human role that may approve, edit, reject, merge, and defer
proposals. Unreachable by machine credentials.

**Deadline** — the hard wall-clock ceiling on retrieval, covering strategies
and reranking. Strategies that miss it are dropped and reported.

**Dream-time** — background consolidation, entity resolution, and revalidation
planning over governed knowledge; throttled first under token pressure.

**Entity** — a canonical referent linking mentions of the same thing. A
rebuildable, pipeline-internal cache exposed through **no** public surface.

**Erasure** — removal of a subject's data. *Proportionate* removes subject
content and scrubs shared provenance; *strict* also removes knowledge sourced
only through that subject. Neither retracts a claim with surviving independent
provenance.

**Fusion** — merging several strategies' *ranks* (not scores) with weighted
reciprocal rank, `k = 60`.

**Gate A** — decides whether a candidate statement is kept, rejected, or
deferred for review.

**Gate B** — decides how widely a kept statement may be seen.

**Gate rule / matrix cell** — the configuration keyed by target level and
sensitivity that both gates consult. A missing rule falls back to human review.

**Held** — a lifecycle state: a scope- or account-level proposal parked at its
source scope and absent from retrieval.

**Idempotency key** — the deterministic key that makes replaying a job merge
provenance rather than duplicate knowledge.

**Ingest** — recording a raw observation. The only write path an agent has.

**Knowledge** — one immutable natural-language statement with confidence,
sensitivity, subject, provenance, lifecycle state, and timestamps.

**Lifecycle state** — the governance position of a statement: `proposed`,
`provisional`, `active`, `held`, `needs_revalidation`, `contested`,
`superseded`, `expired`, `stale`, `rejected`, `redacted`, `retracted`.
Retrieval filters on it.

**Model role** — one of exactly five Account-level roles: `embedder`,
`reranker`, `ingest_extractor`, `dream_reasoner`, `dialectic_agent`.

**Peer** — one participant: a human, or an agent holding an API key.

**pg0** — the checksum-pinned PostgreSQL distribution the packaged release
supervises for itself.

**Pipeline** — the extraction machinery, and the only writer of knowledge.

**Profile** — a named, versioned retrieval bundle: strategies, weights, rerank
flag, and deadline. `fast`, `balanced`, `thorough`.

**Projection** — rebuildable peer profiles, scope cards, session summaries, and
context payloads derived from knowledge.

**Provenance** — which messages or document versions support a statement, and
how many independent sources it has.

**Provisional** — a lifecycle state: visible only to the peer the statement
came from, while validation is pending.

**Raw observation** — what agents submit: a message, or a document version.

**Reciprocal rank fusion** — the merge algorithm: a candidate at rank `r`
contributes `weight / (k + r)`.

**Rerank** — an optional model-backed reordering of the fused head, used only
by the `thorough` profile.

**Revalidation** — the scheduled recheck of an accepted statement. Once due,
the item stops satisfying skill requirements immediately.

**Scope** — a path in a containment tree. Inheritance is downward and
nearest-wins.

**Search** — ranked retrieval over governed memory, with no answer generation.
Defaults to the `balanced` profile.

**Sensitivity** — how exposed a statement may be. Independent of confidence.

**Session** — a conversation grouping for raw messages, created on demand.

**Skill requirement card** — human-authored, plainly versioned procedural
memory stating what a skill needs before it runs. Not knowledge; does not pass
the gates.

**Strategy** — one independent candidate generator: Semantic, Lexical,
Temporal, SalienceRecency, EntityMatch, RelationExpand.

**Subject** — who or what a statement is *about*. Not the same as its source.

**Supersession** — replacing a statement or a document version with a newer
one, without rewriting history.

**Target level** — how far a proposal is asking to travel: `peer`, `scope`, or
`account`.

**Tombstone** — the marker left when a remote document is deleted, so that
knowledge with surviving provenance is not retracted.

**Usage ledger** — the retained, exact record of every model call
(`UsageEvent`). The ETS counters in front of it are rebuildable.

**Valid time** — when a claim is true in the world (`relevant_from`,
`relevant_until`). Distinct from belief time.
