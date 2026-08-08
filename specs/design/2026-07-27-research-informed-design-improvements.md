# Research-informed design improvements — design

**Status:** design approved, pending implementation plan
**Date:** 2026-07-27
**Scope:** changes to the MemHouse memory-system design prompted by a review of
the 2026 agent-memory field: entity resolution, evaluation coverage, two NFR
additions, one named architectural principle, and positioning corrections
**Depends on:** FR v1.0, ARCH v1.0, ADR-0002, ADR-0003, ADR-0004, ADR-0005
**Fans out to:** ADR-0006 (entity resolution), append-only anchor additions in
FR and ARCH, and the missing evaluation-framework spec

---

## 1. Context

Three external sources were reviewed against the full MemHouse design set (the
three specs plus ADR-0002 through ADR-0005):

- Vectorize, *Best AI Agent Memory Systems* — a survey of the vendor landscape
  with a critique of what the field measures and what it does not.
- Mem0, *State of AI Agent Memory 2026* — an ecosystem report naming six
  unsolved problems.
- Mem0, research page — published benchmark results and the architectural
  changes behind them.

The review had two useful outcomes. Several MemHouse decisions turn out to
answer problems the field currently lists as open, which is evidence the design
is positioned correctly but understated in the blueprint. Separately, the review
exposed real gaps, one of which is structural.

This document records both, and specifies the changes.

## 2. Where the design already answers the field's open problems

Neither source's list of open problems was written with MemHouse in view, which
is what makes the overlap worth citing.

| Open problem in the field | MemHouse answer | Anchor |
|---|---|---|
| Privacy and consent architecture "left to the application layer" (mem0 #4) | Gate A / Gate B, consent for upward promotion of personal knowledge, blast-radius principle | `FR-GOV-*` |
| Memory staleness — confidently wrong, high-relevance memories (mem0 #6) | Revalidation, Ebbinghaus decay on confidence-at-read, `expires` | `AD-DATA-2`, `FR-KN-17`, `FR-GOV-10` |
| Change treated as replacement rather than evolution (mem0 #2) | Immutable content, supersession chains, append-only ledger | `AD-DATA-1`, `FR-FORM-20`, `AINV-5` |
| "No framework explicitly addresses forgetting or expiration" (vectorize) | Tri-temporal model plus revalidation | `AD-DATA-1` |
| "Multi-agent and shared-memory governance is analyzed by nobody" (vectorize) | The governed recursive scope tree | Blueprint §6, moat 1 |
| Procedural memory "still early-stage in tooling" (both) | Skill requirement cards and pre-flight gap reports | `FR-SK-*`, moat 2 |

Two further points of convergence are worth recording because they are evidence
that independently reached conclusions agree:

- Vectorize's closing recommendation — solve institutional knowledge first,
  because personalization falls out of the same engine — is close to verbatim
  the argument in blueprint §6. The sequencing bet has outside support.
- Mem0 moved to single-pass, ADD-only extraction after finding write-time
  search-then-decide too expensive. That is the same conclusion as
  `AD-PIPE-2`'s cheap-extractor ingest with consolidation deferred to
  dream-time, reached from a different direction.

None of this changes the design. It changes what the blueprint can claim and
how it supports the claim; see §4.5.

## 3. Gaps

Seven gaps were identified, listed here with the ones addressed by this design
marked.

**A. No entity-resolution stage. Addressed in §4.1.** Vectorize describes agent
memory ingestion as Extract → Resolve → Store → Index, with resolution a
distinct stage. Mem0 names entity matching as a third retrieval signal alongside
semantic and lexical, and — the more interesting detail — replaced external
graph databases with graph-style entity linking while keeping the multi-hop
gain. MemHouse has `FR-FORM-14`'s `add` / `merge` / `supersede-candidate` /
`no-op`, none of which canonicalizes referents: "Alice", "our CTO", and
`alice@example.com` are three unrelated strings. Consequences today are that
`merge` is weaker than it appears because it operates on statement similarity
rather than referent identity, that `Lexical` carries proper nouns only when
spelled identically, and that multi-hop questions have no traversal path.

**B. BEAM benchmark absent. Addressed in §4.2.** `AD-EVAL-3`'s replay targets
are LongMemEval, LoCoMo, and ConvoMem, all conversation-scale. BEAM is the only
public benchmark probing 1M–10M-token corpora, which is precisely the axis
`NFR-10`'s honest-ceiling posture commits to reporting.

**C. No token-efficiency target. Addressed in §4.3.** `FR-PLAT-8` meters tokens
by role and `NFR-1` sets latency targets, but nothing bounds context tokens
returned per read. Mem0 leads its research page with roughly 6,900 tokens per
query against roughly 26,000 for full context. That number is at once the cost
lever, a quality proxy, and the comparison the market makes.

**D. `ask` and `search` have no latency band. Addressed in §4.3.** `NFR-1`
leaves both as "tracked" with no figure. ADR-0004 already reasons within a
100–600ms multi-strategy band, and the surveyed systems put LLM synthesis at
800–3000ms. Leaving the cells blank permits unbounded drift.

**E. No task-outcome evaluation. Addressed in §4.2.** Vectorize's sharpest
observation is that LoCoMo and LongMemEval are conversation-QA benchmarks: they
do not measure error reduction across repeated runs, learning from corrections,
task-outcome improvement, or degradation past 100K facts. Skill readiness —
moat 2 — makes exactly those claims and currently has no instrument that would
demonstrate them.

**F. Cross-session identity resolution is thin. Deferred; see §4.5.** Peer being
account-global and symmetric across humans and agents already improves on the
`user_id` / `agent_id` / `run_id` composition the field uses. What is missing is
a peer-merge operation for the anonymous-to-known and multi-device cases.

**G. The read/write cost asymmetry is unnamed. Addressed in §4.4.** The design
consistently trades write cost for read cost but never states this as a
principle, so each instance reads as an independent decision.

A prerequisite blocks B, C, and E: `specs/memory-system-evaluation-framework.md`
is cited throughout the three specs — `EV-REPRO-1`, `EV-GRADE-3`, `EV-MET-24`,
`EV-PROBE-5`, and "EV invariant 1" all appear as live references — and does not
exist on disk. So does `specs/memory-system-build-phasing.md`. The evaluation
spec must be written before the evaluation work can be anchored anywhere.

## 4. Design

### 4.1 Entity resolution

#### Resource shape

A new derived resource, `MemHouse.Knowledge.Entity`:

| Field | Purpose |
|---|---|
| `account_id` | Tenancy, per `AINV-6` |
| `canonical_name` | Preferred surface form |
| `kind` | `:person \| :org \| :system \| :artifact \| :concept` |
| `aliases` | Observed surface forms |
| `alias_embedding` | Vector over canonical name and aliases, for candidate lookup |
| `derived_from` | Ids of the statements the entity was resolved from |

A join resource, `MemHouse.Knowledge.EntityMention`, carries `statement_id`,
`entity_id`, `surface_form`, and `confidence`.

#### Entities are account-global and carry no visibility of their own

This follows the Peer precedent. Mentions inherit scope from the statements they
annotate; retrieval continues to filter statements by scope and policy. The
consequence is the property that makes the rest of the design cheap: **entity
resolution cannot change who can read what.** A resolution error costs accuracy.
It cannot breach the account wall (`AD-SEC-1`) or scope visibility, because
neither is enforced at the entity layer.

Two constraints keep that property true:

1. **Entities are not readable through any public surface.** No API, MCP, SDK,
   or UI endpoint returns entity rows, alias lists, or canonical names. An
   entity resolved from a statement in a restricted scope would otherwise leak
   a referent name past the statement-level filter that is doing all the
   security work. Entities exist only as a retrieval-internal index.
2. **Erasure recomputes entities.** The right-to-be-forgotten flow
   (`FR-GOV-15` / `FR-GOV-16`) must trigger recomputation of every entity whose
   `derived_from` set included an erased statement, pruning entities left with
   no surviving source. Because entities are a derived cache this is
   recomputation rather than deletion, but it is not automatic and must be
   wired explicitly.

#### `FR-KN-2` is preserved

The natural-language-statement-only rule is not weakened. An entity is a
canonical referent, not a triple; statements remain natural-language and
human-validatable, and mentions are annotations over them. No structured
knowledge representation is introduced. This is the distinction that lets entity
resolution proceed while the knowledge-graph layer stays deferred.

#### Placement: dream-time

Three reasons, in order of force:

1. **Gating.** Entities derive only from already-validated statements,
   inheriting the parent statement's gate. This is the same constraint ARCH §18
   places on the deferred graph layer, for the same reason: a human gates one
   statement, not the derived structures downstream of it.
2. **Ingest is reasoning-free.** `AD-PIPE-2` admits extraction and cheap gating
   only. Resolution is reasoning.
3. **Resolution needs corpus context.** Ingest is per-message; resolution needs
   the candidate entity set.

Accepted consequence, stated so it is not discovered later: statements pending a
gate have no entity links, so `EntityMatch` cannot retrieve them. This is
consistent — pending statements are not retrievable as knowledge.

#### Resolution cascade

Cheap first, expensive only where necessary:

1. Exact alias match.
2. Alias-embedding similarity above a configured threshold.
3. Dream-reasoner adjudication, for the ambiguous band between the match
   threshold and the reject threshold only.

Step 3 runs under the dream-time token budget and is shed first under pressure
per `AD-PIPE-3`, so the degradation mode is unresolved mentions rather than a
stalled lane.

#### `AINV-5` compliance

`Entity` and `EntityMention` are derived caches, rebuildable from statements,
never the system of record. They are excluded from the `AD-PORT-1` logical
export because they regenerate on import; the export manifest already records
the embedder model and version, which is what a rebuild needs.

This is what makes entity correction cheap: merges and splits are recomputation,
not history rewriting, so they need no governance gate and leave no ledger
residue.

#### Retrieval: the `EntityMatch` strategy

A new `MemHouse.Retrieval.Strategy` implementation:

- `name/0` — `:entity_match`
- `cost_class/0` — `:cheap`
- `stage/0` — `:seed`
- `applicable?/1` — true when the query contains a mention resolvable against
  the account's entity set
- `candidates/2` — statements mentioning the resolved entities, ranked by
  mention confidence combined with the statement's own score

It fuses through RRF like any other strategy, so a misfiring `applicable?/1`
costs latency rather than correctness — the property ADR-0004 already identifies
as the reason strategies are safe to add.

`RelationExpand` gains a second edge type: hop-1 expansion may now traverse
shared-entity edges alongside `supersedes`, A-MEM upkeep links, and
`ScopeRelation`.

Profile placement: `EntityMatch` joins `:balanced` and `:thorough`. It stays out
of `:fast`, which exists to serve a `get_context` cache miss and must remain
minimal.

#### ADR-0004 stage 4 is retargeted

ADR-0004's staging plan currently ends with "dream-time knowledge graph and the
`Graph` strategy". That stage becomes "entity graph and `EntityMatch`". The full
knowledge-graph layer stays deferred in ARCH §18 and may never be needed: mem0
dropped external graph databases for entity linking and kept the multi-hop
improvement, which is the outcome stage 4 was reaching for.

The `Graph` seam stays reserved. Nothing about this decision forecloses it.

#### Licensing

`EntityMatch` is a retrieval strategy, so ADR-0004's open question — whether any
retrieval strategy may be enterprise-gated — governs it, with the same standing
recommendation of no. Licensing boundaries are an ADR-0002 human-only decision
area; this design inherits the open question rather than answering it.

### 4.2 Evaluation

#### Prerequisite

`specs/memory-system-evaluation-framework.md` must be written first. It is
already referenced by anchor from all three specs, so this is recovering a
document the design assumes exists, not adding one.

#### BEAM as a replay target

Added to `AD-EVAL-3`'s replay set with three conditions:

- **Release tier only.** `AD-EVAL-3` already separates the deterministic PR gate
  from the nightly and release tiers. A 10M-token replay belongs in the latter.
- **Reported as a curve, not a point.** Scores at 100K, 1M, and 10M tokens.
  `NFR-10` commits to an honest, measured ceiling, and a ceiling is a slope.
  Mem0's published 64.1% at 1M falling to 48.6% at 10M is the available
  comparison.
- **Deadlines disabled**, per ADR-0004's existing eval rule, so scores do not
  vary with CI machine load.

#### `EV-TASK`: a task-outcome evaluation class

This is the instrument gap E describes, and the only planned evaluation that
measures the product's claim rather than the retrieval engine's.

Fixture: a task with a known-correct outcome, executed N times against the same
account, with memory accumulating across runs.

Three measures, reported separately:

1. **Error rate across runs 1..N.** Does accumulated memory reduce it? This is
   the claim in its simplest form and nothing currently tests it.
2. **Correction uptake.** Inject a correction at run *k*. Do runs *k+1* onward
   respect it, and after how many turns? Dream-time debounce (`AD-PIPE-5`) sits
   in this path, so the measurement yields a real figure for how long the system
   takes to learn — a number worth knowing independently of the eval.
3. **Elicitation precision and recall.** Skill-readiness gap reports against
   ground-truth missing inputs. Reported as two numbers, never as F1: a false
   gap costs the user a needless question, a missed gap causes a silent failure,
   and the two are not interchangeable.

Scale axis: the same fixture at 1K, 10K, and 100K facts. Vectorize's observation
that nobody measures degradation past 100K facts is an opportunity, not just a
criticism of others.

#### Two named evaluation populations

`AD-EVAL-3` gains an explicit split:

- **Engine benchmarks** — LongMemEval, LoCoMo, ConvoMem, BEAM. Public,
  comparable, measure retrieval.
- **Product evaluations** — `EV-TASK`. In-house, not comparable, measure whether
  the product does what it claims.

ADR-0004's citation discipline — every published score names a profile version
and states whether deadlines were enabled — applies to both.

### 4.3 NFR additions

**`NFR-11` — token efficiency.** Two figures: context tokens returned per
`get_context` at the default budget, and end-to-end tokens per `ask`. Tracked,
not gated. The metering infrastructure exists (`FR-PLAT-8`); what is missing is
a target and a published number.

**`NFR-1` gains its blank cells.**

| Operation | Band | Status |
|---|---|---|
| `search` (`:balanced`) | 100–600ms | tracked |
| `ask` (`:thorough`) | 800–3000ms | tracked |

Neither becomes a gate. ARCH §18 leaves "latency targets as gates" open and this
design does not close it. The bands exist so that `ask` drifting to four seconds
is visible rather than silent.

Both additions depend on §4.2's apparatus to be measurable, which is why the
sequencing in §5 puts evaluation first.

### 4.4 `AD-PIPE-9` — read/write cost asymmetry

A new anchor stating an existing policy:

> Writes may be arbitrarily expensive and arbitrarily late. Reads must be cheap
> and bounded. Where the two conflict, cost moves to the write side.

Existing decisions that become corollaries rather than independent choices:
materialized projections instead of computed ones (`AD-DATA-3`); the `:thorough`
profile running at dream-time to build what `get_context` reads (ADR-0004,
`NFR-2`); entity resolution at dream-time (§4.1).

The general failure mode follows from the principle: staleness, never latency.
Staleness is observable and budget-shed; a blown latency budget is not
recoverable.

Naming it has a forward use. It predicts the answer for future placement
decisions, which is the test of whether a principle is real. §4.1's dream-time
placement looks arbitrary without it and forced with it.

### 4.5 Positioning, one refusal, one deferral

#### Blueprint re-anchoring

Blueprint §6 and §7 gain the §2 table with citations, moving the moat claims
from assertion to third-party evidence. §16's risk entry — that incumbents
advertise sub-200ms retrieval and 90%-plus accuracy — stays, and gains its
counter: those are conversation-benchmark numbers measured on ungoverned,
single-scope corpora. No published number describes governed multi-scope
retrieval because nobody measures one. That is a gap in the field's
instrumentation, and `EV-TASK` is the beginning of an answer.

#### Refusal, recorded as a decision

Mem0 treats agent-generated facts as primary data. MemHouse declines:
`FR-API-12` and FR invariant 2 make agents submitters of observations and the
pipeline the sole writer of knowledge. Agent observations remain a first-class
*source* under `FR-FORM-15`'s subject-versus-source resolution with its hearsay
discount.

This is recorded as an explicit non-goal in FR §12 so that a reader comparing
the two systems sees a choice rather than an omission. The reason is the
governance model: knowledge that entered without passing a gate cannot be
promoted, audited, or consented to on the same terms as knowledge that did, and
a mixed population defeats the guarantee.

#### Deferral, recorded rather than solved

Cross-session identity resolution (gap F). Account-global Peer already covers
more than the field's `user_id` / `agent_id` / `run_id` composition; what is
absent is a peer-merge operation for anonymous-to-known promotion and
multi-device consolidation.

The constraint that shapes any future design: the audit log is an append-only
per-account hash chain (`AD-DATA-8`), so a merge cannot rewrite history. It has
to be a forward-only aliasing record — the merged identity becomes an alias from
a point in time, with prior entries left addressed to the original peer.

This goes to ARCH §18 as an open decision with that constraint attached. It is
not designed now: there is no current design pressure, and it touches the audit
chain, where guessing is worse than waiting.

## 5. Sequencing

ADR-0004's Stage 0 rule settles the order: no strategy work starts before a
baseline exists through the real surface, because otherwise improvement cannot
be attributed. Entity resolution is strategy work. The baseline needs the
evaluation spec, which does not exist.

1. Write `specs/memory-system-evaluation-framework.md`, recovering the `EV-*`
   anchors the three specs already cite.
2. Record the Stage 0 baseline. Add BEAM and `NFR-11` measurement to the release
   tier. Fill in `NFR-1`'s bands.
3. Specify `EV-TASK`. It is independent of entity resolution and measures the
   moat that has no instrument.
4. Blueprint re-anchoring, the `AD-PIPE-9` principle, the FR §12 non-goal, and
   the ARCH §18 deferral. All documentation, all independent of the above, and
   all doable in parallel.
5. ADR-0006 and entity resolution, measured against the step-2 baseline.

## 6. Fan-out

| Change | Lands in |
|---|---|
| Entity resolution, `EntityMatch`, stage-4 retarget | ADR-0006 (new) |
| Entity resource and mention semantics | New `FR-KN-*` anchors |
| Entity as derived cache; export exclusion | `AD-DATA-10` (new) |
| Erasure recomputation of entities | `FR-GOV-15` / `FR-GOV-16` amendment |
| Entity identity as a `merge` signal | `FR-FORM-14` amendment |
| `EntityMatch` in the strategy set and profiles | `AD-SEAM-3` and ADR-0004 amendments |
| BEAM; engine-versus-product split | `AD-EVAL-3` amendment |
| `EV-TASK` | Evaluation-framework spec (to be written) |
| Token efficiency | `NFR-11` (new) |
| `ask` and `search` bands | `NFR-1` amendment |
| Read/write asymmetry | `AD-PIPE-9` (new) |
| Moat citations; incumbent-number counter | Blueprint §6, §7, §16 |
| Agent-writes non-goal | FR §12 |
| Peer merge | ARCH §18 |

Amending accepted ADRs in place follows the convention ADR-0003 and ADR-0004
already established.

## 7. Risks

**Entity resolution merges two distinct referents.** The primary accuracy risk.
Mitigations: a conservative match threshold with the ambiguous band routed to
adjudication; a derived cache, so corrections are recomputation; and the
containment property from §4.1 — a mis-merge cannot cross the account wall or a
scope boundary, because neither is enforced at the entity layer. Bounded blast
radius, which is the same standard the governance model applies elsewhere.

**Entity leakage through a future surface.** The §4.1 constraint that entities
are never publicly readable is a rule, not a mechanism, and rules erode. It
needs a test asserting no public surface returns entity rows, in the
deterministic PR gate rather than the release tier.

**Dream-time cost grows.** Resolution adds a stage to a lane that is already
budget-capped and shed first (`AD-PIPE-3`). The failure mode is unresolved
mentions and staler projections, consistent with `AD-PIPE-9`.

**`EV-TASK` fixtures overfit.** A hand-built repeated-task fixture can be
constructed to show improvement. Mitigation: the same held-out discipline
ADR-0004 applies to fusion weights — a fixture set that never informs
development and is only ever run for publication.

**Benchmark additions expand the release-tier runtime.** BEAM at 10M tokens is
expensive. It is release-tier and curve-reported, so the mitigation is frequency
rather than scope.

## 8. Open questions

- **May `EntityMatch` be enterprise-gated?** Inherits ADR-0004's open question.
  Recommendation unchanged: no. ADR-0002 human-only decision area.
- **Does `kind` stay a closed set?** Started closed at five values. Whether
  deployments may extend it is deferred until a case appears.
- **Where does the alias-embedding threshold live?** `AD-CFG-1` policy config at
  scope grain matches how fusion weights are handled, but resolution quality is
  less obviously a per-scope concern than retrieval weighting. Defaulting to
  runtime config; revisit if a deployment needs otherwise.
- **Peer merge.** Deferred to ARCH §18 with the forward-only-aliasing constraint
  recorded.

## 9. Sources

1. Vectorize. *Best AI Agent Memory Systems.*
   https://vectorize.io/articles/best-ai-agent-memory-systems
2. Mem0. *State of AI Agent Memory 2026.*
   https://mem0.ai/blog/state-of-ai-agent-memory-2026
3. Mem0. *Research.* https://mem0.ai/research

Existing spec references (`[1]`–`[15]` in ARCH §19 and FR §13) are unchanged.
