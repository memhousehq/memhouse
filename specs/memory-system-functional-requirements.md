# MemHouse — Multi-Scope Agent Memory System — Functional Requirements

> **Edition:** **Elixir/Ash edition.** This is the platform-specific rendering of the functional requirements for the Elixir + Ash Framework build. Functional requirements describe **product behavior**, which is platform-independent — so this document is intentionally near-identical to the original. Every `FR-*` anchor id and its requirement meaning is preserved verbatim; only the small number of requirements that name a concrete technology have been updated to the Elixir/Ash stack (Ash data layers, Oban, ReqLLM, Phoenix, Ortex/ONNX, `ash_ai`, Extractous/MDEx, `bitcrowd/rag`). Where a technology reference changed, the FR id and wording pattern are kept and only the named tech is updated (sometimes with a short parenthetical). The companion **ARCH spec** is the authoritative source for how the stack is assembled.
>
> **Status:** v1.0 — final.
> **Product name:** **MemHouse** — a memhouse is the bound register in which an institution kept authenticated copies of its charters: a governed, curated record of what the organisation knows and can prove. *Multi-Scope Agent Memory System* remains the descriptive subtitle.
> **Companions:** `memory-system-architecture-and-nfr.md` (the **ARCH spec** — *how it is built*; `AD-*`/`NFR-*`/`AINV-*` anchors), `memory-system-evaluation-framework.md` (the **EV spec** — *how it is validated*), and `memory-system-product-blueprint.md` (the *why/who/how-it-wins* layer). This document is the technical source of truth for *what the system does*.
> **One-liner:** A self-hostable, model-agnostic memory layer that — like Honcho's peer-centric reasoning memory — distills conversations into evolving representations, and extends that with **collective memory at every level of an organisation** (a recursive scope tree), governed promotion of knowledge, a tri-temporal model, skill-readiness self-evaluation, and an MCP + SDK surface. Licensed fair-code (n8n-style).
>
> **Amendments:** **ADR-0003** — one data layer (AshPostgres + pgvector + PG-FTS everywhere, pg0 as the local launcher); affects `FR-PLAT-2/4/5/6`, `FR-FORM-10`, `FR-API-25`. **ADR-0004** — multi-strategy retrieval: `FR-API-25` becomes N pluggable strategies + reciprocal-rank fusion + optional rerank, selected by named versioned **profiles**, with `FR-API-27/28/29` added below. **ADR-0005** — peer inline validation over MCP: peer self-validation is carved out of `FR-API-13`'s governance-action prohibition and delivered through read-tool results, with `FR-API-30/31` and `FR-GOV-22` added below; affects `FR-GOV-8`, `FR-GOV-10`. **ADR-0006** — entity resolution: canonical referents resolved at dream-time from validated statements, with `FR-KN-18`..`FR-KN-22` added below and an `entity_match` seed strategy added to `FR-API-25`; affects `FR-FORM-14` (referent identity as a `merge` signal) and `FR-GOV-15`/`FR-GOV-16` (erasure recomputes entities); retargets ADR-0004's stage 4 from the knowledge graph to the entity graph (§12). **ADR-0009** — scope-bounded entity cards add `FR-KN-23`; the cards group only active governed statements and never expose entity-cache fields. **ADR-0011** — a card names itself with a surface form drawn from its own sources in its own scope and reports a kind recomputed from those forms, never read from the entity row; the card threshold becomes two sources and the summary threshold stays three; affects `FR-KN-21` and `FR-KN-23`. See `specs/adr/`.
>
> **Changelog v0.1 → v1.0:** added FR-KN-17 (system-derived belief-time), FR-API-23–26 (point-in-time reads, provenance/source filtering, hybrid retrieval, grounding & abstention), FR-GOV-21 (knowledge history/diff view), FR-PLAT-15–16 (CMK, compliance posture) — closing the gaps the ARCH spec and blueprint already referenced; invariant 6 extended to the tri-temporal form; ingest update-operations and incremental projection refresh specified; FR-PLAT-11/13 clarified (portability export is free; SIEM streaming is enterprise); terminology unified on **dream-time** for the slow reasoning lane; §11 deduplicated into the ARCH spec; research grounding added (§13). FR ids are **append-only**: new requirements take the next free number in their area, so v0.1 anchors remain stable even where numbering is no longer positionally sequential.

---

## 1. Overview & Vision

The system stores raw interactions (messages, documents, events) and runs a two-stage background reasoning pipeline that distills them into **knowledge** — the single atomic unit of memory. Knowledge is attributed to one or more **scopes** (a recursive, openly-nested tree representing an organisation and its teams/projects) and/or **peers** (account-global users or agents). Human-readable **profiles**, **scope cards**, and **session summaries** are projections rendered from knowledge. Agents consume memory through an MCP interface and a harness SDK; humans govern it through validation queues and a curator/RBAC model.

In cognitive-architecture terms [1], the layers map cleanly: raw sessions and messages are the **episodic** store, knowledge is the **semantic** store, skill requirement cards and authored policy are the **procedural** store, and the session summary plus the `get_context` bundle play the role of **working memory**. The two-stage pipeline is the system's *sleep-time compute* [5]: reasoning is spent in the background so the serving path stays reasoning-free.

The headline difference from Honcho: Honcho is peer-centric (Workspace → Peer → Session → Message). This system keeps peer memory but adds **collective memory above the peer**, with strict governance over how individual knowledge becomes shared knowledge.

---

## 2. Glossary

- **Account** — the hard tenancy/isolation boundary (one customer). Owns the peer identity registry, billing, SSO, and global config defaults. **Not** a memory level.
- **Scope** — a recursive, openly-nested memory container (org → division → team → project → …). Containment forms a **tree**; cross-cutting associations form a **graph**.
- **Peer** — any persistent entity (user *or* agent), account-global, a member of many scopes.
- **Session** — an interaction thread; opens in one scope but carries a dynamic **set** of scopes.
- **Message** — a timestamped, peer-attributed observation (chat turn, document, or event).
- **Knowledge** — the atomic unit of reasoned memory: a natural-language statement with metadata.
- **Profile / Scope Card / Summary** — projections (curated views) rendered from knowledge.
- **Skill Requirement Card** — an authored contract describing the knowledge a skill needs before it runs.
- **Reasoned artifact** — produced by the pipeline (knowledge, profiles, summaries); subject to validation gates.
- **Authored artifact** — created by humans (skill cards, scope structure, config); subject to plain versioning.
- **Gate A / Gate B** — the two independent validation gates: *keep it?* and *at what level?*.
- **Curator** — a per-scope role that validates scope-level knowledge and confirms emergent sub-scopes.
- **Dream-time** — the slow, periodic, per-scope reasoning lane (deduction, conflict resolution, corroboration leveling, projection refresh); the system's sleep-time compute [5].
- **Belief-time** — *when the system held an item active*: system-derived intervals from the lifecycle ledger, never user-set (FR-KN-17).
- **Valid-time** — *when the statement is true in the world*: the `expires` field (blank = permanent).
- **Salience window** — *when the statement is worth surfacing*: the `relevant-window` field, independent of truth.

---

## 3. Entity & Memory Topology  (`FR-TOP`)

- **FR-TOP-1** The system shall provide an **Account** as the top-level hard isolation boundary; no data, query, or traversal shall ever cross between Accounts.
- **FR-TOP-2** An Account shall own: the peer identity registry, billing/usage, authentication/SSO, and global configuration defaults. The Account shall **not** itself be a memory scope.
- **FR-TOP-3** The system shall represent memory containers as **Scopes** arranged in an openly-nested **tree** of arbitrary depth (e.g., `org → devs → infra → devops → aws-migration`).
- **FR-TOP-4** Parent→child links shall express **containment** (a tree). Cross-cutting **relationship edges** between scopes shall form a separate **graph** (e.g., an `aws-migration` scope under `devops` that *touches* `infra` and `apps`).
- **FR-TOP-5** Every non-leaf scope shall maintain a **child map** plus relationship metadata describing its children and their associations.
- **FR-TOP-6** A **Peer** shall be account-global and may be either a human user or an AI agent (treated symmetrically).
- **FR-TOP-7** A Peer shall be a member of zero or more scopes (many-to-many).
- **FR-TOP-8** Each Peer shall have exactly one **default scope** (e.g., a devops peer defaults to the devops scope).
- **FR-TOP-9** Each Peer shall have **one global profile** (cross-domain facts) and **one profile per scope** in which it is active (domain-specific facts).
- **FR-TOP-10** Documents and knowledge attached to a scope shall be **visible down its subtree** (inherited by descendant scopes) but never to sibling or ancestor scopes by default.
- **FR-TOP-11** The system shall support **emergent scope creation**: the pipeline may *propose* a new child scope when session content fits no existing scope (see `FR-FORM`).

---

## 4. Knowledge & Memory Model  (`FR-KN`)

### 4.1 Knowledge as the atom

- **FR-KN-1** **Knowledge** shall be the single atomic unit of reasoned memory. Profiles, scope cards, and session summaries shall be **projections** rendered from knowledge, never independent stores of truth.
- **FR-KN-2** A knowledge item's content shall be stored as a **natural-language statement only** (human-readable, human-validatable). *(Structured triples / graph form are deferred — see §12.)*
- **FR-KN-3** Each knowledge item shall carry a **kind** (e.g., fact, preference, relation, event, skill).
- **FR-KN-4** Each knowledge item shall carry one or more **attributions**, each `{ target: peer | scope, level }`. The attribution target is the item's **subject** (what it is about).
- **FR-KN-5** Each knowledge item shall carry **provenance** (source messages/documents, extracting model + pipeline version, timestamp). Provenance is the item's **source** (where it came from), distinct from its subject.
- **FR-KN-6** Each knowledge item shall carry a **confidence** score (input to Gate A) and a **sensitivity** classification (input to Gate B).
- **FR-KN-7** Each knowledge item shall carry a **lifecycle state**: `proposed`, `active`, `needs_revalidation`, `superseded`, `expired`, `rejected`.
- **FR-KN-8** Each knowledge item shall support **relations** to other items: `supersedes`, `contradicts`, `supports`, `derived_from`.
- **FR-KN-9** The system shall **deduplicate and merge** equivalent knowledge into a single item with multiple provenance links, rather than storing duplicates.

### 4.2 Temporal model (tri-temporal, operator-simple)

The model is **tri-temporal**: *belief-time* (what the system believed, when — system-derived), *valid-time* (when the statement is true in the world — `expires`), and *salience* (when it is worth surfacing — `relevant-window`) are three independent axes. The first two are the classical bi-temporal transaction-/valid-time split from temporal databases [14], the same model the temporal-knowledge-graph memory line (Zep/Graphiti) converged on for agent memory [3]; the salience axis comes from the retrieval literature [2, 9]. Operators and curators only ever touch the two simple, optional fields below; belief-time costs them nothing.

- **FR-KN-10** Each knowledge item shall expose three **optional** temporal fields, all blank by default:
  - **expires** — when to stop assuming it is true (blank = fundamental/permanent; a date = volatile). *(= valid-time end.)*
  - **revalidate-after** — re-confirm with the peer/source after this interval (blank = never).
  - **relevant-window** — only surface around this date/range (blank = always, when topically relevant). *(= salience.)*
- **FR-KN-11** The extractor shall **propose** values for these fields (e.g., "next week" → short expiry; a birthday → relevant-window), and a human shall be able to override any of them in the validation step.
- **FR-KN-12** "Truth" (expiry) and "salience" (relevant-window) shall be independent: a permanently-true fact (e.g., a birthday) may be relevant only within a window.
- **FR-KN-17** Each knowledge item shall carry **system-derived belief-time**: the interval(s) during which the system held the item `active`, derived exclusively from its lifecycle transition ledger — never set by users, curators, or models. Belief-time is what makes point-in-time reads (FR-API-23) and the history/diff view (FR-GOV-21) possible, and is independent of both valid-time and salience. *(Id appended in v1.0; placed here because it belongs to the temporal model.)*

### 4.3 Projections

- **FR-KN-13** A **peer profile** (global or per-scope) shall be a curated projection of the active knowledge attributed to that peer (and scope), optionally with a synthesized narrative.
- **FR-KN-14** A **scope card** shall be a projection describing the scope: a synthesized summary plus its child map and relationships.
- **FR-KN-15** A **session summary** shall be a projection over the session's messages, maintained incrementally and finalized at session close.
- **FR-KN-16** Projections shall be refreshed when their underlying knowledge changes materially, via **structured incremental (delta) updates** against the changed knowledge set rather than monolithic regeneration — iterative wholesale LLM rewriting of an evolving artifact erodes accumulated detail over time ("context collapse" [13]) and costs more. Periodic full compaction is permitted but must be diffed and bounded.
- **FR-KN-23** An **entity card** shall be a scope-bounded projection over active governed statements that mention one resolved entity. The entity cache remains account-global and private: a card may use `entity_id` only as an internal cache coordinate and shall expose no entity id, canonical name, or alias list. A card inherits the strictest sensitivity of its sources and shall not be built below a bounded minimum-source threshold. *(Amended by ADR-0011: a card shall also carry a label and a kind. The label shall be one mention surface form, selected only from the card's own source statements in the card's own scope, so it repeats text the card already returns; the kind shall be recomputed from those same forms. Neither shall be read from the entity row. The minimum-source threshold for the card and the threshold for generating its summary may differ.)*

### 4.4 Entity resolution

*(Added by ADR-0006. The field treats resolution as a distinct ingestion stage — Extract → **Resolve** → Store → Index — and entity matching as a third retrieval signal beside semantic and lexical [16, 17].)*

- **FR-KN-18** The system shall maintain **canonical entities**: account-scoped referents (`kind` ∈ person, org, system, artifact, concept) carrying a canonical name and observed aliases, resolved from the statements that mention them. An entity is a *referent*, **not** a triple — `FR-KN-2` is unchanged, statements remain natural-language and human-validatable, and no human is asked to gate anything other than a statement.
- **FR-KN-19** Each resolved mention shall be recorded as an **entity mention** linking a knowledge item to an entity with the observed surface form and a resolution confidence.
- **FR-KN-20** Entity resolution shall run at **dream-time over already-validated statements only**, inheriting each parent statement's gate. Statements pending a gate therefore carry no entity links and are not reachable by entity-based retrieval — consistent with pending statements being unreachable as knowledge by any path.
- **FR-KN-21** Entities shall be **account-global and shall carry no visibility of their own**; mentions inherit scope from the statements they annotate, and retrieval shall continue to filter statements by scope and policy. Consequently a resolution error shall be capable of degrading accuracy but **never** of crossing the account wall or a scope boundary. **Entities shall not be readable through any external surface** (REST, MCP, SDK, or UI): a canonical name derived from a restricted statement is itself information, and exposing it would route around the statement-level filter. Entities exist solely as a retrieval-internal index. *(Amended by ADR-0011: the entity row remains unreadable, and this prohibition continues to cover canonical names, alias lists, and entity ids. A scope-bounded entity card may carry one surface form as its label under `FR-KN-23`, because that form is bounded to the card's own sources and therefore cannot route around the statement-level filter.)*
- **FR-KN-22** Entities and mentions shall be a **derived cache** (`AINV-5`), rebuildable from statements, excluded from the logical export, and **recomputed on erasure** — every entity whose sources included an erased statement shall be recomputed, and any entity left with no surviving source shall be pruned (`FR-GOV-15`, `FR-GOV-16`). Entity merges and splits are recomputation, not history rewriting, and therefore require no governance gate.

---

## 5. Skill Knowledge & Self-Evaluation  (`FR-SK`)

*(The procedural-memory layer [1]: authored contracts about what an agent must know before it acts.)*

- **FR-SK-1** The system shall provide a **Skill Requirement Card** as a distinct **authored** entity (a requirement contract, not a knowledge assertion).
- **FR-SK-2** A Skill Requirement Card shall be bound to a skill and contain a list of requirements, each: `{ selector over knowledge (kind / target peer|scope), level: required | preferred, source policy: from-memory | ask-peer | either, optional freshness: revalidated-within N }`.
- **FR-SK-3** Skill Requirement Cards shall **inherit and override along the scope tree** (nearest scope wins) — e.g., a generic `write-copy` requirement globally, a richer brand-voice requirement in `marketing`, narrower still in `marketing/social`.
- **FR-SK-4** Before an agent runs a skill, the system shall perform a **pre-flight readiness check**: resolve the (inherited) card, query memory (peer-global + peer×scope + scope + ancestors) for matching **active, fresh** knowledge, and produce a **gap report**.
- **FR-SK-5** In the gap report, **required** gaps shall block the skill; **preferred** gaps shall warn but allow it to proceed.
- **FR-SK-6** Required gaps shall be filled from memory when available, otherwise by **eliciting the missing knowledge from the peer** before the skill runs, per the requirement's source policy.
- **FR-SK-7** Knowledge that is `expired` or `needs_revalidation` shall count as a gap (or trigger revalidation) rather than satisfying a requirement on stale data.

---

## 6. Knowledge Formation: Sessions, Ingestion & Pipeline  (`FR-FORM`)

### 6.1 Sessions

- **FR-FORM-1** A session shall **open within one scope**: an explicitly provided scope, or the peer's **default scope** when none is given.
- **FR-FORM-2** A session shall carry a **dynamic set of scopes** (1:N), not a single scope.
- **FR-FORM-3** Scope tagging of a session shall be **tentative live** (a cheap classifier, for in-session context) and **confirmed at dream-time**.
- **FR-FORM-4** Additional scopes shall be **appended to a session dynamically** as the conversation touches new topics/projects.
- **FR-FORM-5** When session content fits no existing scope, dream-time shall **propose a new child scope** under the nearest fitting parent; such proposals shall follow the same `proposed → validated` path as knowledge, routed to a **curator**, and shall default to **always curator-confirmed** (configurable auto-create threshold).
- **FR-FORM-6** A session shall support **multiple peers** (users and agents).
- **FR-FORM-7** A **message** shall be modeled as any timestamped, peer-attributed observation (chat turn, document, or event). *(Initial implementation may ingest chat turns + documents; events/tool-traces later.)*
- **FR-FORM-8** The system shall **store all sessions and raw messages** indefinitely (subject to right-to-be-forgotten, see `FR-GOV`).

### 6.2 Ingestion, RAG & external sync

- **FR-FORM-9** A document shall be ingested into a scope and be visible down that scope's subtree (per `FR-TOP-10`). *(Extraction from PDF/Office/email/markdown is performed natively via Extractous — the ExtractousEx NIF with Apache Tika bundled, no JVM/sidecar — plus MDEx for markdown→AST.)*
- **FR-FORM-10** Documents shall be **dual-ingested**: (a) chunked + embedded for retrieval, and (b) run through the extraction pipeline to mint knowledge. *(Chunking, hybrid search, and groundedness/relevance eval are provided by the `bitcrowd/rag` pipeline, used against pgvector in every deployment mode — since ADR-0003 there is no alternate store to swap in.)*
- **FR-FORM-11** The system shall support **external sync connectors** (pluggable) running on a schedule, pulling incrementally via **content-hash change detection**.
- **FR-FORM-12** When a synced source document changes, the system shall **re-extract** knowledge from the new version and **supersede** knowledge derived from the old version.
- **FR-FORM-13** The embedder shall be **pluggable** via the **`AshAi.EmbeddingModel` behaviour** (see `FR-API` model roles).

### 6.3 The two-stage reasoning pipeline

*(Ingest-time is the fast extract-then-update phase, the two-phase pattern validated in production by Mem0 [4]; dream-time is the slow lane — system-level sleep-time compute [5], whose deduction step is the "reflection" mechanism of Generative Agents [2].)*

- **FR-FORM-14** **Ingest-time (fast, per message/document):** a cheap extractor shall emit **proposed** knowledge (statement, kind, subject, level, confidence, sensitivity, temporal fields) and update the running session summary. For each candidate statement it shall resolve an **update operation** against existing nearby memory: **add** (genuinely new), **merge** (duplicate → attach provenance, per FR-KN-9), **supersede-candidate** (clear change signal, per FR-FORM-20), or **no-op** (nothing memory-worthy) [4]. *(Amended by ADR-0006: where the candidate's subject resolves to a known canonical entity (`FR-KN-18`), **referent identity shall be an input to the `merge` decision** alongside statement similarity. Resolution itself stays at dream-time — ingest consumes already-resolved entities and never resolves new ones, so this adds a lookup, not reasoning.)*
- **FR-FORM-15** **Subject ≠ source resolution:** the extractor shall determine *who/what each statement is about* (subject → attribution) rather than assuming it is the speaker, and shall **discount confidence for third-party (hearsay) claims** relative to self-assertions.
- **FR-FORM-16** **Dream-time (slow, periodic, per scope):** a stronger reasoner shall revisit the delta + working set to: draw higher-order deductions (reflection [2]); detect contradictions/supersessions; perform **corroboration-based leveling** (the same fact across multiple peers crossing a count raises its attribution via Gate B); perform **memory evolution** — when new knowledge links to existing items, update those items' relations (`supports` / `contradicts` / `derived_from`) and mark affected projections dirty (Zettelkasten-style link maintenance [6]); refresh projections; and run revalidation/expiry from the temporal fields.
- **FR-FORM-17** Dream-time shall be triggered by a **schedule** (e.g., nightly) **and events** (session close, document sync).
- **FR-FORM-18** Pipeline cost shall be controlled via **incremental lookback**, **per-scope budgets**, and **model tiering** (cheap model for ingest, stronger for dream-time).

### 6.4 Conflict resolution

*(Invalidation-not-overwrite is the same posture as Graphiti's temporal edge invalidation [3]: the old belief is dated and retained, never erased.)*

- **FR-FORM-19** On contradiction between new and existing active knowledge (same subject), the system shall **never silently overwrite**; it shall record a `contradicts` relation.
- **FR-FORM-20** Where a clear **change signal** exists ("moved", "no longer", "now"), the new item shall **supersede** the old; the old item shall be marked `superseded` (retained, not deleted) and may clear automatically.
- **FR-FORM-21** Where the conflict is **non-obvious** (contradiction without a change signal), the item shall be **routed to validation regardless of confidence thresholds** (conflict is effectively a third gate condition).
- **FR-FORM-22** A validation-queue item for any conflicting knowledge shall **bundle the prior knowledge it would invalidate** (both statements, both provenances) so the curator can decide *supersede / keep-both / reject / merge*.

### 6.5 Core write invariant

- **FR-FORM-23** **Context flows down freely; knowledge flows up only through a gate.** Dream-time reasoning over scope S may **read** from ancestor and cross-linked scopes for context, but may only **write** knowledge to a more widely-visible (ancestor) scope by passing through **Gate B**. No silent upward writes.

---

## 7. Memory Consumption: Query, Context, API, SDK, Models  (`FR-API`)

### 7.1 Query model

- **FR-API-1** Every read shall be **scope-anchored**, taking either an explicit **list of scopes** or `session` (= the session's full linked scope set).
- **FR-API-2** Reads shall **merge along the containment path** (target scope + ancestors), with **nearest scope winning** on conflict, and shall optionally pull **cross-linked** scopes.
- **FR-API-3** Cross-linked-scope reads shall be **filtered by the caller's permissions** (a caller cannot pull memory it is not entitled to).
- **FR-API-4** The system shall expose **`get_context(peer, scope|session, session)`** — prompt-ready context (session summary + relevant peer profile slice + scope card(s) + a salience-ranked knowledge slice).
- **FR-API-5** `get_context` shall be **reasoning-free** (assembled from precomputed projections + a salience filter, no LLM call) and intended to run at **session start** and on **scope-set change** (cadence configurable), not unconditionally every turn. *(The reasoning was already paid at dream-time [5] — and since ADR-0004 so was the retrieval: the `:thorough` profile runs at dream-time to build the projections this call reads. A cache miss falls back to the `:fast` profile, which is the only retrieval work this path may do live.)*
- **FR-API-6** The system shall expose **`ask(question, scope, [peer])`** — a natural-language **dialectic** query answered by reasoning over relevant knowledge/projections; it may decompose the request and multi-hop (e.g., resolve "my team" → scope → members). Its default retrieval profile is **`:thorough`** (FR-API-27) — `ask` is the surface with no hard latency target, so it is where the expensive strategies and the reranker belong.
- **FR-API-7** The system shall expose **`search(query, scope)`** — retrieval over the scope's document chunks, using the multi-strategy retrieval of FR-API-25 at its default **`:balanced`** profile (FR-API-27).
- **FR-API-8** The system shall expose **`query_knowledge(filters)`** — a structured filter over knowledge **metadata** (kind / attribution / state / temporal / provenance), returning NL statements. *(Content-level graph/triple queries are deferred — see §12.)*
- **FR-API-9** The system shall expose **`check_readiness(skill, peer, scope)`** — returns the gap report (per `FR-SK`).

### 7.2 Temporal, provenance & retrieval semantics

- **FR-API-23** The system shall support **point-in-time reads**: an `as_of(D)` filter on `query_knowledge` (and on the history surfaces of FR-GOV-21) returning the knowledge that was `active` at belief-time D — *"what did we know on date D"* — computed from belief-time intervals (FR-KN-17), optionally excluding items whose valid-time had already expired at D.
- **FR-API-24** Reads shall support **provenance and source filtering**: restrict results by source peer, source document/connector, extracting model + pipeline version, or minimum corroboration count — e.g., *"only knowledge corroborated by ≥ 2 peers"*, *"exclude items sourced solely from connector X"*.
- **FR-API-25** Knowledge retrieval and `search` shall use **multi-strategy retrieval** by default: **N independent candidate-generation strategies** run concurrently, their ranked lists merged by **reciprocal rank fusion**, plus an **optional reranking stage** (model-based cross-encoder or fusion-only) over the fused head, all behind the retrieval seam (ARCH `AD-SEAM-3`). The shipped strategies are **semantic** (vector), **lexical** (keyword/BM25), **temporal** (belief-time / valid-time / relevant-window interval filter, honouring `as_of` per FR-API-23), **salience-recency** (embedding-free, over the FR-API-10 terms), and **relation expansion** (hop-1 over `supersedes`, upkeep links, and scope relations); a **graph** strategy is reserved (§12). *(Amended by ADR-0006:* **entity match** *— statements mentioning the canonical entities a query resolves to (`FR-KN-18`) — is added as a cheap seed strategy in the `:balanced` and `:thorough` profiles but not `:fast`; relation expansion additionally traverses shared-entity edges.)* Pure-semantic and pure-lexical are configuration options, not separate code paths. *(Rewritten by ADR-0004; was "hybrid semantic + lexical". Fusion is rank-based rather than score-based because candidate scores are strategy-local and not comparable across strategies. Since ADR-0003 there is one storage backend, so every strategy is a concurrent query on the same connection and retrieval behaviour is identical in every deployment mode by construction.)*
- **FR-API-26** `ask` shall produce **grounded answers with abstention**: every answer cites the knowledge items (ids + provenance) it relied on, and when the relevant knowledge is absent, `expired`, or `needs_revalidation`, `ask` shall say so (*"not known"* / *"stale since …"*) rather than fabricate. Abstention is a first-class memory capability, not an error path — it is where memory systems measurably fail [11, 12].
- **FR-API-27** Retrieval shall be selected by **named, versioned profiles** — a profile being a strategy set plus fusion weights plus rerank on/off. Three ship: **`:fast`** (semantic + salience-recency, no rerank), **`:balanced`** (semantic + lexical + temporal, no rerank; the `search` default), **`:thorough`** (all strategies + relation expansion + rerank; the `ask` default). A profile may be selected **per query** (`retrieval_profile`), defaulted **per scope** with nearest-wins inheritance, and constrained **per deployment** (which strategy modules are enabled at all). A raw strategy list may be passed only by internal and evaluation callers. Profiles are versioned, and **any published benchmark number shall cite the profile version it was measured under**.
- **FR-API-28** Retrieval shall be **deadline-bounded and self-reporting**. Each profile carries a wall-clock deadline; a strategy that does not return within it is **dropped from fusion** rather than retried or treated as an error, so adding a strategy can change what fills the latency budget but never exceed it. Every retrieval response shall report **which strategies contributed and which were dropped**. Evaluation runs shall be able to disable the deadline, so benchmark scores do not vary with machine load.
- **FR-API-29** **Cross-strategy disagreement shall be an input to abstention** (FR-API-26): when independent strategies surface disjoint candidate sets with low raw scores, that is corroborated evidence the corpus does not hold the answer. This signal shall be computed **before fusion** — rank fusion always emits a ranked list, including from candidates that are all bad, so a fused rank cannot express "nothing was found".

### 7.3 Context assembly & budget

- **FR-API-10** Context assembly shall reserve budget for summary + profile + scope card, then fill remaining budget with **top-k knowledge** ranked by **topical-relevance × salience × durability**, where salience combines the relevant-window (FR-KN-12) with a recency/decay term. *(This is the relevance × recency × importance retrieval triad of Generative Agents [2], with forgetting-curve-style decay [9] and validated confidence/durability standing in for model-scored "importance". The budget discipline itself is the context-paging insight of MemGPT [15].)*

### 7.4 MCP interface

- **FR-API-11** The system shall expose an **MCP interface** (provided by the **`ash_ai` MCP server**) providing the five reads above plus an **`ingest` / `add_message`** write.
- **FR-API-12** **Agents shall submit raw observations only; they shall never write knowledge or attribution directly.** All knowledge is written solely by the pipeline through Gates A/B.
- **FR-API-13** **Governance actions** shall **not** be exposed on the MCP surface; they shall live in a separate authenticated human API/UI. *(ADR-0005 narrows this to its intended target: **curator gate decisions on any item, scope confirmation and promotion, decisions concerning knowledge whose subject is a peer other than the caller, and any widening of a peer's own ask-rate limits**. A peer answering a question about knowledge whose **subject is that same peer** is **self-assertion, not a governance action** — it is the route FR-GOV-8 and FR-GOV-10 already describe — and is permitted on the MCP surface under FR-API-30/31, subject to the channel assurance of FR-GOV-22.)*

- **FR-API-30** A read tool response **may carry at most one pending peer validation question**, selected only from knowledge whose **subject is the calling peer**, gated by topical relevance to the current call and by the peer's ask-rate limits. Attachment shall **not** compromise the reasoning-free guarantee of FR-API-5: it shall run under its own wall-clock deadline after the read result is assembled, and **any failure, timeout, or empty selection shall return the read unchanged**. A question shall never fail a read.
- **FR-API-31** The MCP surface shall expose **`resolve_validation(id, verdict, [shown_text], [correction_text])`** and **`set_ask_preference(...)`**. `resolve_validation` shall resolve **only** within the calling peer's own pending questions, with the peer derived from identity (AINV-6) and never from a request parameter; an unknown or foreign id shall return **not-found rather than forbidden**. A `reject` verdict **retracts** the questioned item as a supersession; `correction_text` shall **never** be written as knowledge — the correction reaches the pipeline through normal ingest and passes the gates like any other observation, preserving FR-API-12. `set_ask_preference` shall be **clamp-only** over MCP: a peer may lower their ask-rate limits or pause questions, never raise them; raising requires the human API/UI.

### 7.5 Harness SDK

- **FR-API-14** The system shall provide a **harness SDK** of thin primitives plus an optional opinionated agent-loop helper.
- **FR-API-15** The SDK shall provide: session/peer/scope helpers; a **context-injection helper** that formats `get_context` into any provider's message format; **auto-forwarding** of each turn to `ingest`; and a **skill-readiness wrapper** that runs `check_readiness` and drives elicitation when required knowledge is missing.
- **FR-API-16** SDK primitives shall be usable **directly or over MCP**, and shall be **provider-agnostic** (never assume a specific model/provider). *(Consumer SDKs are shipped for TS and Python; Elixir is server-side only.)*

### 7.6 Model-agnosticism

- **FR-API-17** The system shall define four pluggable **model roles**: **embedder**, **ingest extractor** (cheap/fast), **dream-time reasoner** (stronger), **dialectic agent**.
- **FR-API-18** Model roles shall be configured at **Account level** (per-scope overrides deferred to v2 — see §12).
- **FR-API-19** The provider layer (**ReqLLM**) shall support OpenAI-compatible and **self-hosted** endpoints (e.g., Ollama, vLLM). The default embedder shall be a **self-hosted Ortex/ONNX** model (an API embedder is also supported).
- **FR-API-20** The **consumer's** agent model is out of scope: the system never calls it, only supplies context.

### 7.7 Session tracking across third-party harnesses

- **FR-API-21** The system shall support three integration modes with differing capture guarantees: **(a) MCP tools** (works broadly; capture is model-discretionary; some hosts are tools-only); **(b) gateway proxy** (OpenAI/Anthropic-compatible endpoint giving full transparent capture + context injection where the host allows a custom base URL); **(c) native adapter / hooks** (best experience, built per-harness).
- **FR-API-22** Session identity shall be taken from the harness's conversation/thread id (or the gateway request stream) when available, and otherwise **inferred** by `(peer + scope + idle-gap)`.

---

## 8. Governance, Trust & Privacy  (`FR-GOV`)

### 8.1 Validation gates & queue

- **FR-GOV-1** Each new knowledge item shall pass two **independent** gates with **independent thresholds**: **Gate A** ("keep it?", driven by confidence) and **Gate B** ("at what level?", driven by attribution target + sensitivity + corroboration).
- **FR-GOV-2** By default, both gates shall require **human-in-the-loop** validation of the knowledge **and** its attribution; **auto-acceptance** shall be available per a configurable matrix of *confidence × target level × sensitivity*.
- **FR-GOV-3** **Upward attribution toward a more widely-shared scope shall require a higher bar** (the blast-radius principle); high confidence alone shall not permit sharing a sensitive item.
- **FR-GOV-4** A **validation queue** shall hold items requiring review. Each item shall present: the proposed statement, proposed level, confidence, sensitivity, provenance, and (for conflicts) the prior knowledge it would supersede.
- **FR-GOV-5** Curator actions shall include **approve / edit / reject / merge / defer**, with **bulk operations**.
- **FR-GOV-6** **Pending-state policy** shall be level-dependent: **peer-level** proposals are usable **provisionally** (flagged unverified, retractable on rejection); **scope-level** proposals are **held** (not surfaced) until approved.
- **FR-GOV-7** Pending items shall **age**; stale items shall **escalate or auto-reject** per configuration so the queue cannot grow unbounded.
- **FR-GOV-8** **Validation routing** shall depend on attribution target: **peer-level** knowledge → the peer (inline or auto); **scope-level** knowledge → a **scope curator** (async queue). *(ADR-0005: "inline" means delivered in the peer's own session — by the SDK where a harness adapter exists, and **over the MCP surface** per FR-API-30 where it does not. Both are best-effort channels layered over the human API/UI, never replacements for it.)*

### 8.2 Revalidation

- **FR-GOV-9** **Episodic peer revalidation** shall reuse the skill-card freshness machinery: it shall be **optional and scheduled**; when `revalidate-after` elapses, the item flips to `needs_revalidation`.
- **FR-GOV-10** Revalidation shall be surfaced **inline** — by the SDK, or **over the MCP surface** per FR-API-30 (ADR-0005) — in the peer's next relevant session. Confirmation resets the timer and raises confidence; a correction is treated as a supersession; if the peer is not reached within the window, confidence **decays** (forgetting-curve-style [9]) and the item eventually becomes stale and routes to a curator. Items that inline relevance never matches shall follow this same decay path; inline delivery shall not be able to starve an item indefinitely.
- **FR-GOV-22** **Channel assurance.** An inline answer shall count as **verified** only where the system can evidence that the peer was shown the **verbatim** statement — for the MCP channel, by finding the frozen statement text in the ingested transcript of that session. An **unverified-channel** answer shall **defer the revalidation timer only**: it shall not raise confidence, shall not resolve a Gate A decision, and shall **never** satisfy the FR-GOV-12 consent requirement, for which a verified answer or the human API/UI is required. Where a self-reported answer and the transcript disagree, **the transcript governs** and the item shall be flagged for a curator. The audit log (FR-GOV-20) shall record the verbatim statement shown and the channel's verification state alongside the decision.

### 8.3 Sensitivity & consent

- **FR-GOV-11** Sensitivity shall be a classification (e.g., `public` / `internal` / `personal` / `restricted`), **proposed** by the extractor (PII/health/financial detection), set by **scope policy**, and **overridable** at validation.
- **FR-GOV-12** **Upward attribution of *personal* knowledge shall require the peer's consent** — not merely a curator's approval. Corroboration alone shall not push a personal fact into a shared scope.

### 8.4 Transparency & data-subject rights

- **FR-GOV-13** The data model shall support a **peer self-view**: a peer can see the knowledge whose subject is them, plus their profiles.
- **FR-GOV-14** A peer shall be able to **contest or redact** knowledge about them. (This also resolves third-party assertions: the subject can **confirm** — raising it to self-asserted/high-confidence — or **dispute** — retracting/flagging it.)
- **FR-GOV-15** **Right-to-be-forgotten (default = proportionate):** deleting a peer shall delete their raw messages and all knowledge whose **subject** is them; knowledge they **sourced** about others/scopes shall have its provenance link scrubbed but **persist if otherwise corroborated** (if they were the sole source, it is retracted and flagged). Affected projections **and entity resolutions** shall recompute (`FR-KN-22`).
- **FR-GOV-16** A **strict** erasure mode (delete everything the peer ever touched) shall be available per Account.
- **FR-GOV-17** Erasure shall not break the audit log: the log shall reference content **by id/hash**, so the **event** of an action survives while the erased **content** does not.

### 8.5 Access control, audit & history

- **FR-GOV-18** The system shall provide **per-scope roles** that inherit down the tree: **account-admin** (boundary, billing, model config, connectors), **curator**, **member**, **reader**.
- **FR-GOV-19** **Read enforcement:** a caller may read scope S iff it holds a role in S or an ancestor of S; cross-account access is forbidden (the hard wall).
- **FR-GOV-20** The system shall maintain an **immutable audit log** of every gate decision (auto or human, with actor), state transition, attribution change, deletion, and configuration change.
- **FR-GOV-21** The system shall provide a **knowledge history / diff view**: for any knowledge item, its full lifecycle ledger (state transitions, attribution/level changes, confidence events, gate decisions with actors) and its supersession chain, rendered as a human-readable diff (*what changed, when, by whom or what*); for any scope, a time-windowed change feed. Backed by the transition ledger (FR-KN-17) + audit log (FR-GOV-20); serves curators, peer self-view, and compliance review.

---

## 9. Platform, Deployment & Licensing  (`FR-PLAT`)

### 9.1 Deployment modes

- **FR-PLAT-1** The system shall ship as **one codebase** with the **Account as the always-on isolation boundary** (self-host runs one/few Accounts; SaaS runs many; identical isolation guarantees).
- **FR-PLAT-2** **Single-node mode (free):** one BEAM node running everything, against a **local PostgreSQL** with **pgvector, pgvectorscale, and PG-FTS**, with **Oban (Postgres engine)** for jobs and background workers. Limited to a **single Account**. A pinned `pg0` binary supervised by the release provisions PostgreSQL on glibc Linux x86_64/ARM64 and Apple Silicon. Windows, Intel macOS, and Linux musl use external PostgreSQL or a container. Pointing the same release at externally managed PostgreSQL shall remain a connection-string change (ARCH `AD-CFG-2`, ADR-0003).
- **FR-PLAT-3** **Queue mode (enterprise-licensed):** Postgres + pgvector + **Oban (Postgres engine)** + **N identical clustered Elixir/Phoenix nodes** (via libcluster) with **one Oban cron leader**; supports multi-node scaling and multiple Accounts. **All of queue mode is behind the commercial licence.** *(No Redis: BEAM/Ash-native concurrency replaces the Redis + BullMQ + separate API/orchestration/gateway node topology.)*
- **FR-PLAT-4** The **vector layer**, **lexical layer**, **data layer**, and **job-queue** shall be **identical in every deployment mode** (pgvector with pgvectorscale DiskANN, PG-FTS, AshPostgres, Oban-Postgres). They shall remain behind interfaces so the implementation is replaceable, but **no second backend is maintained**, and no deployment mode may be served by a different storage, index, or queue implementation than the one exercised by the test suite (ADR-0003; supersedes the earlier two-backends-per-interface requirement).
- **FR-PLAT-5** Self-host shall be distributed as a **single Mix release** by three paths, all from the same build: (a) **no-container** — release + pinned `pg0` and ABI-matched pgvectorscale on supported platforms (the default local on-ramp, FR-PLAT-2); (b) **container image + compose files** for single-node and queue mode, which shall use PostgreSQL with pgvector and pgvectorscale, not `pg0`; (c) **external PostgreSQL** with the same extensions via connection string. Deployment mode is selected through runtime config, not a different build.

### 9.2 Isolation & encryption

- **FR-PLAT-6** **SaaS tenant isolation default = Ash `:context` multitenancy + Postgres row-level security (RLS) keyed on Account** (defense-in-depth: the app-level tenant filter plus a DB-enforced policy). (Since ADR-0003 every mode runs Postgres, so RLS is **available** everywhere; it is *material* only where multiple Accounts exist, i.e. queue/SaaS mode. Single-node is licence-limited to one Account, not structurally unable to enforce isolation.)
- **FR-PLAT-7** **db/schema-per-account isolation** shall be available as a high-isolation **enterprise** option (via AshPostgres `manage_tenant` schema templating, or a separate Repo per Account for full db isolation).
- **FR-PLAT-15** **Customer-managed keys (CMK):** enterprise deployments shall support customer-supplied, customer-rotated encryption keys for data at rest (database volumes and blob storage), implemented at the storage/volume layer so lexical and vector search keep working. Optional field-level application encryption of `restricted` content shall be available with its searchability trade-off made explicit (encrypted fields are excluded from FTS/vector indices).
- **FR-PLAT-16** **Compliance / data-boundary posture:** an Account shall be able to confine knowledge content to its boundary — an **allowlist of permitted interaction channels**, **notify-only delivery** (no content) over external channels for sensitive items, and data residency by self-hosting. Together with the audit log (FR-GOV-20/21) and the erasure modes (FR-GOV-15–17), this constitutes the regulated-buyer posture.

### 9.3 Observability, cost & portability

- **FR-PLAT-8** The system shall **meter per Account/scope**: storage, LLM tokens **by role** (embed/extract/reason/dialectic), and API/ingest volume — for SaaS billing **and** self-hoster cost visibility.
- **FR-PLAT-9** The system shall support **per-scope budgets** with **graceful throttling** (shedding dream-time work first).
- **FR-PLAT-10** The system shall expose operational metrics: queue depth (validation + pipeline), processing/retrieval latency, and error rates.
- **FR-PLAT-11** The system shall provide **account-level export/import** for portability and **self-host ↔ SaaS migration** (no lock-in). The export is logical and backend-agnostic and **includes the audit log with its hash chain intact** (ARCH `AD-PORT-1`); export/import is **free core** in both directions.
- **FR-PLAT-13a** *(clarification of the FR-PLAT-13 boundary)* The free portability export (FR-PLAT-11) is distinct from the enterprise **audit streaming** capability: continuous SIEM export and extended retention controls are licensed; taking your own data with you never is.

### 9.4 Licensing

- **FR-PLAT-12** The core shall be released under a **fair-code, source-available licence** (n8n Sustainable Use License model): free to use/modify/redistribute for **internal/own or non-commercial** use; **no offering it as a hosted service to third parties** without a commercial licence; not OSI "open source."
- **FR-PLAT-13** **Enterprise-licensed tier** shall comprise: **multiple Accounts**, **all of queue mode**, **SSO/SAML + SCIM**, **db/schema-per-account isolation**, **granular RBAC**, **CMK** (FR-PLAT-15), and **audit SIEM streaming + extended retention controls** (see FR-PLAT-13a).
- **FR-PLAT-14** Everything else — the full memory engine, MCP interface, SDK, gateway, basic RBAC, row-level isolation, single-node mode, self-hosted model support, and the logical export/import — shall remain in the free core.

---

## 10. Cross-Cutting Invariants

1. **Context flows down freely; knowledge flows up only through Gate B.** (`FR-FORM-23`)
2. **Agents submit observations only; the pipeline is the sole writer of knowledge.** (`FR-API-12`)
3. **Blast radius scales the bar:** the wider a fact's exposure, the higher the confidence/sensitivity/consent requirement to attribute it there. (`FR-GOV-3`, `FR-GOV-12`)
4. **Knowledge is the only atom; profiles, scope cards, and summaries are projections.** (`FR-KN-1`)
5. **Reasoned artifacts pass validation gates; authored artifacts use plain versioning.**
6. **Belief-time ≠ valid-time ≠ salience; confidence ≠ sensitivity; subject ≠ source** — each triple/pair is a set of independent axes. (`FR-KN-10/12/17`, `FR-KN-5/6`, `FR-FORM-15`)
7. **Everything scoped inherits down the containment tree, nearest-wins** (knowledge visibility, profiles, skill cards, curator roles, read access, policy config).
8. **Cross-account isolation is absolute.**

---

## 11. Non-Functional Requirements & Architecture

Non-functional targets, architecture decisions, and the concrete technology stack are specified in the companion **ARCH spec** (`memory-system-architecture-and-nfr.md`; `AD-*` / `NFR-*` / `AINV-*` anchors), which is **authoritative** for that layer. The load-bearing summary: Elixir/BEAM end-to-end with **Phoenix** (HTTP + LiveView) surfaces; an **Ash**-native ports-and-adapters core where single-node and queue mode are the same codebase over **the same data layer** — Postgres via **AshPostgres** + pgvector + PG-FTS + **Oban** on the Postgres engine — differing only in *where Postgres runs* (an embedded, release-supervised **pg0** locally; an operator-run cluster in queue mode) and whether libcluster is on (**ADR-0003**); **no Redis**, **no SQLite tier**; **ReqLLM** as the provider layer behind the four model roles (with a self-hosted Ortex/ONNX default embedder); self-host from a single Mix release, installable with one command and no dependencies. Retrieval is **N pluggable strategy modules fanned out under a hard wall-clock deadline via `Task.async_stream`, merged by reciprocal rank fusion, with an optional cross-encoder over the fused head**, selected by named versioned profiles (**ADR-0004**); `get_context` stays a reasoning-free projection read, and the expensive profile runs at **dream-time to build those projections**. This section intentionally carries no further detail so the two documents cannot drift.

---

## 12. Deferred / Future Items

- **Structured / knowledge-graph layer + graph retrieval strategy** — optional, additive enrichment on top of NL statements (NL remains the human-validatable anchor); enables content-level graph/triple queries (`FR-KN-2`, `FR-API-8`) and a **graph** candidate-generation strategy under `FR-API-25`. *Evidence base:* graph-structured memory consistently improves multi-hop and relational retrieval — HippoRAG's PageRank-over-KG [7], its continual-learning successor [8], GraphRAG's community summaries [10], and Mem0's graph variant [4] — which is why the seam is reserved now even though NL-first ships first. *Constraint (ADR-0004):* triples shall be **derived at dream-time from already-validated statements**, inheriting the parent statement's gate, because `FR-KN-2`'s natural-language-only rule exists so a human gates one statement rather than forty triples. Write-time graph construction is not available to a gated system. *(Amended by ADR-0006: the multi-hop gain this layer was staged for appears to be largely available from **entity resolution** (`FR-KN-18`..`FR-KN-22`) at a fraction of the derived-structure cost — Mem0 replaced external graph databases with entity linking and kept the improvement [17]. ADR-0004's stage 4 is retargeted to the entity graph accordingly. The graph layer and the `graph` strategy stay deferred and may prove unnecessary; the seam stays reserved.)*
- **Per-scope model-role overrides** — v2 (currently account-level only, `FR-API-18`).
- **Threshold-learning feedback loop** — auto-tune the gate auto-accept matrix from curator approve/reject patterns.
- **Message breadth beyond chat + documents** — first-class events/tool-traces (`FR-FORM-7`).
- **Auto-create-scope threshold** — currently defaults to always curator-confirmed (`FR-FORM-5`).

### 12.1 Explicit non-goals

*(Deliberate refusals, recorded so they read as decisions rather than omissions.)*

- **Agent-written knowledge.** Parts of the field treat agent-generated facts as primary data, written directly to memory [17]. MemHouse does not and will not: `FR-API-12` and invariant 2 make agents submitters of **observations** and the pipeline the sole writer of knowledge. Agent observations remain a first-class *source*, subject to `FR-FORM-15`'s subject-versus-source resolution and its hearsay discount. *Reason:* knowledge that entered without passing a gate cannot be promoted, audited, or consented to on the same terms as knowledge that did, and a mixed population defeats the guarantee that makes the governance model worth anything. This is a cost — it forecloses the fastest path to agent self-improvement — and it is accepted.

---

## 13. Research Grounding & References

The design deliberately matches the converging table-stakes of the field (temporal handling, invalidation-not-overwrite, hybrid retrieval, prompt-ready context [3, 4]) and concentrates novelty where the literature is silent: the recursive governed scope tree, human-gated upward promotion, and skill-readiness. Citations above use the numbers below.

1. Sumers, T., Yao, S., Narasimhan, K., Griffiths, T. *Cognitive Architectures for Language Agents (CoALA).* TMLR 2024. arXiv:2309.02427.
2. Park, J. S., et al. *Generative Agents: Interactive Simulacra of Human Behavior.* UIST 2023. arXiv:2304.03442. — memory stream; retrieval = relevance × recency × importance; reflection.
3. Rasmussen, P., Paliychuk, P., Beauvais, T., Ryan, J., Chalef, D. *Zep: A Temporal Knowledge Graph Architecture for Agent Memory.* 2025. arXiv:2501.13956. — bi-temporal edges; invalidation over deletion (Graphiti).
4. Chhikara, P., Khant, D., Aryan, S., Singh, T., Yadav, D. *Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory.* ECAI 2025. arXiv:2504.19413. — two-phase extract/update; graph variant Mem0g.
5. Lin, K., Snell, C., Wang, Y., Packer, C., Wooders, S., Stoica, I., Gonzalez, J. E. *Sleep-time Compute: Beyond Inference Scaling at Test-time.* 2025. arXiv:2504.13171. — offline reasoning over persistent context cuts test-time compute ~5×.
6. Xu, W., et al. *A-MEM: Agentic Memory for LLM Agents.* 2025. arXiv:2502.12110. — Zettelkasten-style note linking and memory evolution.
7. Gutiérrez, B. J., Shu, Y., Gu, Y., Yasunaga, M., Su, Y. *HippoRAG: Neurobiologically Inspired Long-Term Memory for LLMs.* NeurIPS 2024. arXiv:2405.14831.
8. Gutiérrez, B. J., Shu, Y., Qi, W., Zhou, S., Su, Y. *From RAG to Memory: Non-Parametric Continual Learning for LLMs (HippoRAG 2).* ICML 2025. arXiv:2502.14802.
9. Zhong, W., et al. *MemoryBank: Enhancing Large Language Models with Long-Term Memory.* AAAI 2024. arXiv:2305.10250. — Ebbinghaus forgetting-curve decay.
10. Edge, D., et al. *From Local to Global: A Graph RAG Approach to Query-Focused Summarization.* 2024. arXiv:2404.16130. — hierarchical community summaries (the precedent for scope cards as precomputed collective summaries).
11. Wu, D., et al. *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory.* ICLR 2025. arXiv:2410.10813. — names abstention and knowledge-update as core memory abilities.
12. Pakhomov, E., et al. *ConvoMem Benchmark: Why Your First 150 Conversations Don't Need RAG.* 2025. arXiv:2511.10523. — abstention, temporal-change, and implicit-connection categories; small-corpus full-context baseline.
13. Zhang, Q., et al. *Agentic Context Engineering: Evolving Contexts for Self-Improving Language Models.* 2025. arXiv:2510.04618. — context collapse under monolithic rewriting; structured incremental delta updates.
14. Snodgrass, R. T. *Developing Time-Oriented Database Applications in SQL.* Morgan Kaufmann, 1999. — the bi-temporal valid-time / transaction-time model.
15. Packer, C., et al. *MemGPT: Towards LLMs as Operating Systems.* 2023. arXiv:2310.08560. — context-window paging between in-context and external memory.
16. Vectorize. *Best AI Agent Memory Systems.* 2026. https://vectorize.io/articles/best-ai-agent-memory-systems — Extract → Resolve → Store → Index as the ingestion shape; the benchmark-insufficiency critique behind `EV-TASK`.
17. Mem0. *State of AI Agent Memory 2026* and *Research.* 2026. https://mem0.ai/blog/state-of-ai-agent-memory-2026, https://mem0.ai/research — entity matching as a third retrieval signal; graph databases replaced by entity linking; agent-generated facts as primary data (declined, §12.1).

---

*End of v1.0 (Elixir/Ash edition). FR ids are stable, append-only anchors for review and traceability. Pairs with the ARCH spec (how it is built) and the EV spec (how it is validated).*
