# MemHouse — Multi-Scope Agent Memory System — Architecture & Non-Functional Requirements

> **Edition:** Elixir/Ash. This supersedes the TypeScript implementation while
> preserving every `AD-*`, `NFR-*`, and `AINV-*` anchor.
>
> **Status:** v1.0 — final. The FR spec defines behavior; the EV spec defines
> validation; this document defines architecture and non-functional targets.
> **Anchors:** `AD-*` decisions, `NFR-*` targets, and `AINV-*` invariants are
> stable. `FR-*`, `EV-*`, and `INV-*` refer to the companion specs; `[n]`
> refers to §19.
> **Prime directive:** *one codebase, two deployment modes, identical guarantees.* Single-node and queue-mode are the same artifacts with different adapters wired in — never a fork, never a "lite" reimplementation. Almost every decision below follows from this. On BEAM the two modes converge further than they did on Node: single-node is one supervised OS process, queue-mode is *N identical clustered nodes* — never a different set of programs. Since **ADR-0003** the convergence is total on the storage seam too: **Postgres is the only data layer in both modes**, differing only in *where* the server runs (embedded via pg0 on a laptop, operator-run in queue-mode) and whether clustering is enabled.
>
> **Amendments:**
> - **ADR-0003 — embedded Postgres (pg0) replaces the SQLite tier.** AshSqlite, in-memory `hnswlib`, FTS5, and `Oban.Engines.Lite` are retired; AshPostgres + pgvector + PG-FTS + the Oban Postgres engine serve every mode, with **pg0** as the zero-dependency local launcher. Affected anchors are amended in place below and listed in `specs/adr/0003-embedded-postgres-pg0.md`.
> - **ADR-0004 — multi-strategy retrieval with deadline-bounded fusion.** The single retrieval seam splits into three — **candidate generation** (N `Strategy` modules), **fusion** (reciprocal rank fusion), and **rerank** (the existing `AD-MODEL-1` `Reranker`) — fanned out under a hard wall-clock deadline via `Task.async_stream`, selected by named versioned **profiles** (`:fast` / `:balanced` / `:thorough`). `get_context` stays a projection read; multi-strategy retrieval serves it by running at **dream-time to build those projections**. Affected anchors are amended in place below and listed in `specs/adr/0004-multi-strategy-retrieval.md`.
> - **ADR-0005 — peer inline validation over MCP.** Peer-level validation questions are attached to read-tool results by a deadline-bounded, fail-open hot-path selector (`Governance.Attach`), and answers are graded by a dream-time transcript check. Adds **AD-PIPE-8**; amends **AD-PIPE-2** with the one governance read permitted on the hot path. Affected anchors are amended in place below and listed in `specs/adr/0005-peer-inline-validation-over-mcp.md`.
> - **ADR-0006 — entity resolution as a dream-time stage.** Statements gain canonical **referents**: two derived resources (`Entity`, `EntityMention`), a dream-time resolution cascade, and an `EntityMatch` seed strategy. Entities are account-global, carry no visibility of their own, and are readable through **no** public surface — so a resolution error costs accuracy and can never cross a scope or account boundary. Adds **AD-DATA-10**, **AD-PIPE-9** (read/write cost asymmetry as the placement rule), **NFR-11** (token efficiency); amends **AD-SEAM-3**, **AD-EVAL-3**, **NFR-1**, and §18. Affected anchors are amended in place below and listed in `specs/adr/0006-entity-resolution.md`.
> - **ADR-0009 — scope-bounded entity cards.** A private `entity_id` coordinate keys one projection per scope and resolved entity. Cards use at least three distinct active sources, carry their strictest sensitivity, and expose only a bounded summary plus governed statement fields. ***Amended by ADR-0011:*** two sources build a card and three summarise it, and a card also carries a `label` and `kind` derived from its own in-scope surface forms. Adds **AD-DATA-11** and `FR-KN-23`; retrieval candidates remain deferred pending evaluation.
>
> **v1.0 changes:** FR references now target FR v1.0; the slow lane is called
> **dream-time**; **AD-PIPE-7** was added; grounding and abstention moved into
> **AD-MODEL-3**; and §15 names public replay benchmarks. No structural
> decision changed.

---

## 1. Purpose & how to read this document

The architecture is **observe → extract → reason at dream-time → gate → project
→ serve**. Agents and connectors submit observations; cheap ingest proposes
knowledge; dream-time reasoning reconciles it and refreshes projections; gates
control promotion; reads consume precomputed context. Heavy inference and
embedding run outside the serving path. One release runs locally or as a
cluster.

---

## 2. Architecture invariants

These are the non-negotiable structural anchors. Every `AD-*` is consistent with them; they parallel the FR spec's §10. **They are unchanged from the TypeScript edition** — they are product/architecture invariants, not platform choices.

- **AINV-1 — One codebase, two modes, identical guarantees.** Single-node and queue-mode are the same release image; there is no fork and no capability divergence beyond what the licence gates. On BEAM this is sharper: both modes run the *same* supervision tree. Since ADR-0003 it is sharper still — **the data layer, vector index, lexical index, and job engine are identical in both modes** (AshPostgres + pgvector + PG-FTS + Oban-Postgres); queue-mode merely enables clustering and points the connection string at an operator-run server instead of the pg0-supervised local one. "Identical guarantees" is now a structural property rather than a claim the contract suite has to police across two divergent backends.
- **AINV-2 — The user owns the data and the keys.** Bring-your-own database, cloud, and model key; a logical, backend-agnostic export exists for every account. No proprietary managed service is a hard dependency on the core path.
- **AINV-3 — Don't reinvent wheels.** Every subsystem first asks which mature library owns the problem before any code is written. On this platform that means Ash (domain/persistence/policy/multitenancy), Oban (jobs), Phoenix (surfaces), and a deliberate Rust/C NIF tier (parse/embed/ANN) before any bespoke code.
- **AINV-4 — Edition split without a fork.** Free core and enterprise features live in one umbrella project, gated at runtime; the community edition always builds in isolation.
- **AINV-5 — System of record vs derived cache.** The durable stores are raw messages, validated knowledge, and the audit log. The vector/lexical indices, ETS/`persistent_term` caches, and the projections are derived caches, rebuildable from those stores. (Oban jobs live in the same Postgres transaction as the write that spawns them, so the queue is durable-by-construction rather than a cache to reconcile.) Losing a cache is a timeliness problem; losing a store is data loss.
- **AINV-6 — Account is derived from identity, never from a request parameter.** The hard isolation boundary is enforced upstream of any handler (Phoenix plug / Ash `actor` + `tenant`) and re-checked in depth (Ash policies + DB RLS); cross-account access is structurally impossible.
- **AINV-7 — Two integration paths.** The asynchronous write/pipeline path integrates through the durable substrate (Oban job in the same DB transaction as the write), never through direct service-to-service RPC. The synchronous heavy-read path fans out across the BEAM (`Task.async_stream`, across the cluster only if needed). Different needs, different mechanisms.
- **AINV-8 — Infrastructure ports vs domain strategies.** Swapping an infrastructure adapter (an Ash data layer, a blob store, a secrets backend) changes *where* data lives, never *what the system does*; swapping a domain strategy (a behaviour implementation) changes *behaviour*. The two are never conflated behind one abstraction.

---

## 3. Language, runtime & repository topology

- **AD-LANG-1 — Elixir, single language, end to end for the engine.** Rationale: the system is I/O-bound orchestration with heavy fan-out, soft-real-time reads, and long-running background reasoning under multi-tenant isolation — precisely the BEAM's sweet spot. The scheduler gives cheap concurrency for the `ask`/`get_context` fan-out; supervision trees give crash-isolation for the pipeline; `Phoenix.PubSub` gives realtime governance for free. Ash's Resource/Action/data-layer model *is* the ports-and-adapters architecture the TypeScript edition built by hand, so the single biggest source of bespoke code disappears. A TypeScript SDK is still mandatory because the agent-harness ecosystem is JS/TS-native — but it is a **generated client** off the OpenAPI contract (§9), not part of the engine language. (Confirms FR §11 with the platform reasoning made explicit; the *behaviour* requirement is unchanged.)
- **AD-LANG-2 — Single Mix release now; no second runtime.** A single Mix release is the distributable in every mode (§13). There is no "faster gateway in another language" escape hatch of the kind the TypeScript edition reserved — the BEAM already gives soft-real-time edge behaviour, and the heavy compute is either in an external model endpoint, in the native NIF tier (Extractous/MDEx parse, Ortex embed), or in Postgres itself (pgvector ANN), all of which are Rust/C already. Bun-single-binary and similar are not applicable; the equivalent "small footprint local on-ramp" is the same release image run as one node.
- **AD-TOPO-1 — Mix umbrella (or a single app with clear internal boundaries) + Hex releases for the few publishable artifacts.** Mix + Hex give a content-addressed dependency store and a task graph natively; the publishable artifacts are the **generated consumer SDKs** (TypeScript + Python, from OpenAPI) rather than internal packages. Umbrella apps or `boundary`-enforced contexts hold the module graph; the strict layer-cake enforcement of the TypeScript edition is replaced by Ash's own domain boundaries plus the `boundary` compile-time checker where an explicit wall is wanted.
- **AD-TOPO-2 — Ash-shaped module graph; the conceptual seams are preserved as extension points.** The TypeScript edition's five layers collapse as follows, but the *seams* remain nameable and swappable:

```
SURFACES        Phoenix endpoint: AshJsonApi (/v1) · ash_ai MCP server · gateway proxy · LiveView governance
   ──────────────────────────────────────────────────────────────────── over ▼
DOMAINS + ACTIONS   Ash Domains group Resources; Actions are the typed op layer (the "one op set")
   modules: domain · pipeline(ingest+dream-time via Ash.Reactor) · retrieval(strategies·fusion·rerank)/context ·
            governance(gates·queue·audit) · skills
   ──────────────────────────────────────────────────────────────────── depends on ▼
SEAMS (behaviours / extension points)   Retrieval.Strategy(N) · Fusion · Reranker · EmbeddingModel ·
            gate/auto-accept · chunking · model-tiering   (domain strategies — shipped as code)
   DATA LAYERS + INFRA PORTS   AshPostgres (storage+vector+lexical; pg0-embedded or external) · Oban (job-queue) ·
            ReqLLM (model) · secrets · ExAws/FS (blob)      (infrastructure — wired by config)
   ──────────────────────────────────────────────────────────────────── over ▼
PRIMITIVES      Ash resources & types (the lingua franca) · runtime config · telemetry (OTel/:telemetry/Logger)
```

  Dependency rules are now largely *given*: Ash resources define the shared types; **Actions depend on data layers through Ash, never on a concrete Repo directly** (the config/OTP-app boundary is the only binding point — this *is* AINV-1); the **SDKs are generated clients** (depend only on the OpenAPI contract, never on the engine); **enterprise resources/extensions depend on core, core never imports enterprise**, enforced by `boundary` and by keeping `ee` modules in their own OTP app under the licence header.
- **AD-TOPO-3 — Edition boundary = a dedicated `ee` OTP app + runtime licence gate.** Enterprise code lives in a distinct OTP app under a distinct (commercial / Sustainable Use) licence header; the default build can produce a community-only release that excludes it. Modelled on n8n. (See §13 for the gate mechanics.)
- **AD-TOPO-4 — `core` is a modular monolith of Ash Domains** with the five internal modules above kept as separate Domains/contexts — minimising churn, with extraction into separate OTP apps kept mechanical for later.

---

## 4. Component decomposition & internal seams

**Amended by ADR-0003:** the storage / vector / lexical / job-queue ports each collapse from two implementations to one. What remains swappable on the storage port is *where the Postgres server lives*, not *which database it is*.

- **AD-SEAM-1 — Two kinds of seam (AINV-8).** **Infrastructure ports** (driven side: the Ash data layer, model endpoints, secret stores, blob) are chosen by config at boot. **Domain strategies** are pluggable *policy* behaviours inside `core`/`ee`, shipped as code. "Point at a pg0-embedded Postgres instead of an operator-run cluster" and "add a graph strategy to the retrieval profile" are different categories.
- **AD-SEAM-2 — Infrastructure ports.**
  - **storage** — transactional persistence of the whole domain (knowledge, scopes, peers, sessions, messages, attributions, provenance, lifecycle, relations, skill cards, audit log, projection cache) as **Ash Resources over AshPostgres**, in every mode. Multi-entity operations commit atomically via Ash transactions (`Ash.Changeset` + `Ash.bulk_*` inside a data-layer transaction, or an `Ash.Reactor` transaction step). The only variable is the connection target: a **pg0-supervised local server** (single-node) or an **operator-run cluster** (queue-mode) — see AD-CFG-2.
  - **vector** — embedding upsert + similarity search: **pgvector via `ash_ai` `vectorize`**, with the index write riding the resource's transaction. Identical in both modes; no in-memory index, no boot rebuild, no reconciler. An `Nx` brute-force cosine path is retained as a tiny-corpus baseline for tests and eval, not as a tier.
  - **lexical** — text indexing + keyword/BM25 search via **PG-FTS**, expressed as Ash data-layer fragments. Co-located with storage, so one data layer serves storage + lexical + vector against one connection. Tokenisation and ranking no longer vary by tier, so lexical recall measured locally is the recall an enterprise deployment gets.
  - **job-queue** — enqueue + delayed/repeatable jobs + retry/backoff + concurrency + rate-limit (the rate-limit doubles as the per-scope budget; FR-FORM-18, FR-PLAT-9). **Oban on the Postgres engine** in both modes, driven through **AshOban**. **Redis is removed**, and so is `Oban.Engines.Lite` — one queue, one engine, everywhere.
  - **model** — a provider layer over **ReqLLM** (ash_ai's provider layer; see §8).
  - **secrets** — `get/set/rotate` by reference; env/runtime-config vs Vault/KMS/CMK.
  - **blob** — raw document/object storage (`put/get/delete/signed-url`); local FS vs S3-compatible via **ExAws**.
- **AD-SEAM-3 — Domain strategies.** Four strategy seams: **retrieval** (below), the **gate / auto-accept matrix** (FR-GOV-2), the **chunking/splitting** strategy, and the **model-tiering** policy. *Amended by ADR-0003:* the retrieval seam no longer carries a per-backend adapter split (pgvector vs HNSW), which frees it to carry what it was always meant for — alternative retrieval *strategies* rather than alternative storage engines. ***Rewritten by ADR-0004:*** the single `RetrievalStrategy` was conflating three jobs, so it splits into three seams:

  1. **Candidate generation — `MemHouse.Retrieval.Strategy`, N modules.** Callbacks: `name/0`, `cost_class/0` (`:cheap | :moderate | :expensive`), `stage/0` (`:seed | :expand`), `applicable?/1`, `candidates/2`. A `Candidate` carries `{id, score, rank, strategy, evidence}`; a `Budget` carries `{deadline_ms, started_at, max_candidates}` with `started_at` from the injected `Clock` (AD-EVAL-4). Shipped seeds: **`Semantic`** (pgvector ANN; brute-force `Nx` cosine as a tiny-corpus baseline), **`Lexical`** (PG-FTS/BM25), **`Temporal`** (indexed interval filter over belief-time / valid-time / relevant-window, honouring `as_of` — AD-DATA-1, FR-API-23), **`SalienceRecency`** (embedding-free, ranks on the precomputed FR-API-10 terms). Expansion: **`RelationExpand`** (hop-1 over `supersedes`, A-MEM upkeep links, `ScopeRelation`). Reserved: **`Graph`** over the dream-time KG (FR §12). ***Amended by ADR-0006:*** a fifth seed strategy, **`EntityMatch`** (`:cheap`, `:seed`) — statements mentioning the canonical entities a query's surface forms resolve to (AD-DATA-10), ranked by mention confidence combined with the statement's own score; and `RelationExpand` gains a second edge type, the **shared-entity edge**. Entity resolution is what makes `Lexical` stop failing on aliases, which is the gap it was carrying silently.
     - `applicable?/1` makes each strategy **self-gating** — there is no central query planner, so adding a strategy never means editing one.
     - `stage/0` records that strategies are **not all parallel-independent**: expansion needs seeds. Retrieval runs in two phases (all `:seed` concurrently, then all `:expand` over the union of the seed heads), so wall clock is seed-deadline + expand-deadline.
  2. **Fusion — reciprocal rank fusion.** `score(d) = Σ_s w_s / (k + rank_s(d))`, `k = 60`, weights `w_s` from config. Chosen because candidate scores are **strategy-local and not comparable across strategies** — cosine, BM25, and interval overlap live on different scales, so score fusion would need a calibration that must be re-derived on every embedder / analyzer / corpus change, while RRF uses only within-strategy rank order. RRF's cost is that it discards magnitude, mitigated at the source: every strategy carries a `min_score` cutoff and `max_candidates` cap, so a strategy that finds nothing good returns nothing rather than noise.
  3. **Rerank — the `AD-MODEL-1` `Reranker`.** Not a new seam; ADR-0004 only fixes where it sits — an optional expensive precision pass over the **fused head**, on in the `:thorough` profile.

  **Fan-out is deadline-bounded.** Each phase runs through `Task.async_stream` with `on_timeout: :kill_task, ordered: false`; fusion runs over whoever returned. A timed-out strategy is dropped — not retried, not fatal. Consequently **adding a strategy cannot blow the latency budget, only change what fills it**, and a mis-gated strategy costs latency, not correctness (fusion is rank-based and strategies are additive). Every response reports which strategies contributed and which were dropped. The cost is nondeterminism, so eval runs deadline-disabled or against a fixed fake clock (AD-EVAL-4).

  **Profiles** are named, versioned strategy-set + weights + rerank bundles: **`:fast`** (`Semantic` + `SalienceRecency`, no rerank — the live fallback for a `get_context` cache miss), **`:balanced`** (`Semantic` + `Lexical` + `Temporal`, RRF, no rerank — default for `search`), **`:thorough`** (all seeds + `RelationExpand` + rerank — default for `ask`). Versioning is load-bearing: a quoted benchmark number that does not cite a profile version is not reproducible (§15). Selection layers per AD-CFG-1. *Amended by ADR-0006:* `EntityMatch` joins **`:balanced`** and **`:thorough`**, and stays out of **`:fast`** — that profile exists to serve a `get_context` cache miss and must stay minimal.
- **AD-SEAM-4 — Cross-port invariants.**
  1. **System of record vs derived cache (AINV-5)** — a reconciler re-enqueues (as an Oban job) any durable record left `pending`/unprocessed, so queue/index/projection loss self-heals. *Amended by ADR-0003:* the boot-time HNSW rebuild-from-blobs is gone — the pgvector index is transactional and durable, so the reconciler's remaining job is projections and unprocessed records, not index reconstruction.
  2. **Unit-of-work + transactional audit** — every state change and its audit entry commit together, in one Ash transaction; partial writes are structurally impossible (FR-GOV-20).
  3. **Transactional outbox** — domain events (session close, doc sync; FR-FORM-17) are realised as an **Oban job inserted in the same DB transaction as the state change** (AshOban), on both engines. This *replaces* the TypeScript edition's separate outbox table + relay: a committed write cannot be lost to a failed enqueue because the enqueue *is* part of the commit. There is no poller/LISTEN-NOTIFY relay to operate.
  4. **Indices update in-transaction, everywhere** — the pgvector + PG-FTS index writes are co-located inside the knowledge-write transaction (atomic, no drift), in every deployment mode. *Amended by ADR-0003:* the SQLite carve-out ("no drift *in spirit*", index authoritative only as a cache) is gone; the invariant now holds literally, and read-your-writes on the vector index is a property of the transaction rather than of process-local synchrony. An eventual-consistency external vector DB remains an opt-in path (via an Oban job), not the baseline.

---

## 5. Deployment topology & process model

Single-node is one supervised BEAM process. Queue-mode runs the same release on
identical libcluster nodes, with Oban distributing work and one cron leader.
Synchronous heavy reads use `Task.async_stream`, spanning nodes only when one
node lacks capacity.

- **AD-DEPLOY-1 — One image, one program, scaled by node count.** A single Mix release. Single-node runs one node with everything supervised in-process (surfaces + all Domains + Oban on the Postgres engine + the cron leader) alongside a **pg0-supervised local Postgres** (ADR-0003). Queue-mode runs the *same* release on N nodes against an operator-run Postgres; every node is identical and can serve edge traffic, assemble context, and run pipeline jobs. There is no per-service build and no `MEM_ROLE`-selected subset — a node is either the whole system at small scale or one of many identical peers at large scale.
- **AD-DEPLOY-2 — Two integration paths (AINV-7).** The asynchronous write/pipeline path integrates through the durable substrate: the edge persists raw input and inserts the pipeline Oban job in the same transaction, then returns; any node's Oban workers pick the job up. The synchronous heavy-read path fans out across the BEAM with `Task.async_stream` — across cores on one node, and across the cluster only if needed. *Since ADR-0004 this same primitive carries retrieval strategy fan-out (AD-SEAM-3), with `on_timeout: :kill_task` turning the latency budget into a hard wall-clock bound enforced by the harness rather than by each strategy author's discipline.* In single-node this identical data-flow runs entirely in-process, which is exactly why the two modes are the same system.
- **AD-DEPLOY-3 — The edge is a Phoenix endpoint, not a separate program.** AuthN, Account/tenant scoping, rate-limiting, routing, fan-out orchestration, and response assembly are Phoenix plugs + Ash actor/tenant setup on every node. The OpenAI/Anthropic-compatible proxy (FR-API-21) is one route group *behind* that endpoint, not a distinct process.

```
SINGLE-NODE  (free · one machine · one BEAM node)
  one supervised process tree = Phoenix endpoint (MCP · JSON:API · gateway proxy · LiveView gov)
              + all Ash Domains + Oban (Postgres engine, all queues) + Oban cron leader
              + pg0 port/child process (embedded PostgreSQL 18 + pgvector, ~/.pg0/instances/<name>)
  data layer  = AshPostgres  ·  vector = pgvector  ·  lexical = PG-FTS
  blob        = local FS     ·  secrets = runtime config
  → one command, zero dependencies, no container runtime   (ADR-0003)
     (external Postgres instead of pg0 = a connection-string change; containers use stock PG)

QUEUE-MODE  (enterprise · SAME release · N identical nodes)
  node × N   each: Phoenix edge (authN + tenant scoping + rate-limit + routing) ·
                   in-VM context fan-out (Task.async_stream) · Oban workers (ingest + dream) ·
                   gateway proxy · LiveView governance
  one Oban cron leader (scheduler singleton; elected via Oban/`:global`)
  clustering via libcluster
  ─────────────────────────────────────────────────────────────────────────────
  integrate ONLY through the durable substrate:
    Postgres(pgvector + FTS + Oban) · S3-blob · KMS      → no service-to-service RPC on the write path
    (Redis is gone; Oban is the queue; PubSub rides Phoenix.PubSub over distribution)
```

- **AD-DEPLOY-4 — Nodes scale horizontally; the cron leader is the one singleton.** Every node is stateless (all durable state in Postgres/S3; ephemeral caches in ETS) and scales by adding nodes. The **Oban cron leader** is the singleton analogue of the old `scheduler` — its outage delays *scheduled* dream-time work only (no data loss; jobs are idempotent, and leadership re-elects). HA leader-election beyond Oban's built-in mechanism is the upgrade if a timeliness SLO ever demands it (§18).
- **AD-DEPLOY-5 — What flips between modes** (everything else is byte-identical, driven by runtime config). *Amended by ADR-0003:* the storage-seam flips are gone. What remains: Postgres location `pg0-supervised local ↔ operator-run cluster` (a connection string plus whether the release starts a pg0 child); blob `local-FS ↔ S3`; secrets `runtime-config ↔ Vault/KMS`; clustering `off ↔ libcluster`; multitenancy strategy `single-account ↔ :context(+RLS)/schema/db`. The data layer (AshPostgres), vector index (pgvector), lexical index (PG-FTS), and Oban engine (Postgres) **no longer flip at all**. The transactional outbox needs no flip either — it is an Oban insert in-transaction, always.
- **AD-DEPLOY-6 — Internal traffic is authenticated in multi-node.** BEAM distribution between nodes uses TLS-distribution with a shared release cookie / cert, so the cluster network is not a trust boundary; any HTTP the deployment still exposes internally uses mTLS / signed tokens as before.

---

## 6. Data & storage architecture

- **AD-DATA-1 — Temporal / lifecycle model: immutable content + an append-only state-transition ledger.** Per FR-FORM-20, a content change is a *new item that supersedes the old* — content is never edited in place — so a knowledge item's statement is effectively immutable; what changes over its life is state, attribution/level, and confidence. Therefore: immutable content + stable id, plus an append-only transition ledger per item. In Ash this is enforced structurally by **not defining `update`/`destroy` actions on the content and ledger resources**: a `Knowledge` row is create-only, and a content change creates a new `Knowledge` with a `supersedes` relationship. The ledger (`LedgerEvent`) *is* the belief-time source (FR-KN-17). Valid-time is the `expires` field; salience is `relevant-window`. This is the classical bi-temporal split — transaction-time (here: belief-time) vs valid-time [12] — the same model the temporal-knowledge-graph memory line converged on for agent memory (Graphiti's `t_created`/`t_invalid` vs `t_valid`/`t_invalid` edge dating [1]); ours adds the independent salience axis on top. `as_of(D)` (FR-API-23) is an **Ash calculation/preparation** producing an indexable interval filter — "items whose active interval covered belief-time D" — no log fold; optionally AND'd with "not expired as of D". The history/diff view (FR-GOV-21) is the ledger + audit entries; supersession chains are walked via the `supersedes` relation.

```
K1  proposed@t0 → active@t1 → superseded@t3   (expires = t5)
K2                proposed@t2 → active@t3      (supersedes K1)
   belief-time active intervals:  K1 = [t1,t3)   K2 = [t3,…)
   as_of(t2) → K1     as_of(t4) → K2
```

- **AD-DATA-2 — Confidence is computed, not journaled.** Store base confidence + last-revalidated timestamp + decay policy; compute effective confidence at read time as an **Ash calculation** (FR-GOV-10). The decay function is a strategy behaviour (default: exponential, Ebbinghaus-style forgetting curve [8]). Only material events — confirm, correct, gate decision, supersede — append to the ledger.
- **AD-DATA-3 — Materialize current state.** Lifecycle state, base confidence, and current attribution are materialised as attributes on the knowledge row, kept in sync with the ledger inside the same Ash transaction (via an `after_action` change or a `Reactor` step). The hot read path (`get_context` / `ask`) is then a cheap indexed read with no fold; the ledger remains the source of truth.
- **AD-DATA-4 — Scope tree = materialized path; graph = edge table.** Containment is a path-string attribute + prefix index, giving the ordered ancestor chain directly for "merge along the containment path, nearest-wins" (FR-API-2) and subtree visibility (FR-TOP-10); ancestor merge is a `like 'path/%'` Ash filter. The cross-cutting relationship graph is a `ScopeRelation` resource (`from_scope, to_scope, relation_type, metadata`), traversed permission-filtered (FR-API-3). *Amended by ADR-0003:* the original rationale for avoiding `ltree` was two-backend parity, and that rationale is void — `ltree` (and PG recursive CTEs) are now available in every mode. The materialized path stays the default because it is measured-adequate and simpler, not because it is forced; switching to `ltree` becomes an open, benchmark-driven decision (§18).
- **AD-DATA-5 — Vector + lexical co-located; two embedding collections.** Both indices live with storage: `ash_ai` `vectorize` + pgvector with pgvectorscale StreamingDiskANN + PG-FTS over one connection, in every mode (ADR-0003). Vector indexes and embeddings are rebuildable projections; raw messages and governed knowledge remain the durable system of record (AINV-10). Two logical collections hold knowledge-statement embeddings and document-chunk embeddings. Both feed the FR-API-25 fusion stage as `Retrieval.Strategy` modules (`Semantic`, `Lexical`). Co-location keeps fan-out to concurrent queries on one pool instead of scatter-gather across heterogeneous stores.
- **AD-DATA-6 — Isolation.** Single-node is licence-limited to a single Account, so isolation is moot there in practice — but *amended by ADR-0003*, it is no longer structurally impossible: RLS is available in every mode, so the free tier is no longer the weaker isolation story, merely the smaller one. Queue/SaaS default: **Ash `:context` multitenancy** (a tenant filter applied to every query) **plus Postgres RLS keyed on Account** as DB-enforced defense-in-depth (FR-PLAT-6) — Ash gives the app-level filter, RLS is a deliberate add-on, not automatic. Enterprise high-isolation makes tenancy a data-layer strategy: `:context`+RLS → **schema-per-account** (AshPostgres `manage_tenant` templating) → **db-per-account** (a separate Ash `Repo` per Account) (FR-PLAT-7).
- **AD-DATA-7 — CMK = storage/volume-level encryption with a customer-supplied KMS key** (DB volume + blob bucket), because that is what "supply and rotate your own keys for data at rest" (FR-PLAT-15) means and it avoids the trap that you cannot FTS or vector-search ciphertext. Field-level app-encryption of specific `restricted` fields is an optional additional layer via an Ash custom type / `change` (e.g. `cloak`-style), with that searchability caveat noted (and made explicit in FR-PLAT-15).
- **AD-DATA-8 — Audit log: append-only, reference-by-id/hash, per-Account hash-chain.** No `update`/`destroy` actions on the `AuditEntry` resource (immutability as contract); written in the same transaction as the change (AD-SEAM-4.2) via an Ash `change`; references content by **id + content-hash, not value** (FR-GOV-17), so erasure leaves the *event* intact while the content goes; a **per-Account hash-chain** (each entry carries the prior entry's hash, computed in the write `change`) gives cryptographic tamper-evidence without serialising appends across tenants.
- **AD-DATA-9 — Migrations: Ash-generated, one set, expand/contract.** Ash generates migrations from resource definitions for AshPostgres (`mix ash.codegen`), keeping the SQL-first control needed for pgvector/RLS/FTS via data-layer options and custom migration statements where the generator stops. *Amended by ADR-0003:* there is **one migration set**, not a shared core plus per-backend fragments — the same DDL that runs against a pg0 instance runs against an operator's cluster. Rolling deploys require **expand/contract** migrations so old and new code run simultaneously mid-deploy. Postgres **major-version** upgrades are handled by the logical export/import path, not by in-place migration (AD-PORT-1, ADR-0003 condition 2).
- **AD-DATA-10 — Entities and mentions are a derived, non-exported cache (ADR-0006, FR-KN-18..22).** Two resources: `Knowledge.Entity` (`account_id`, `canonical_name`, `kind`, `aliases`, `alias_embedding`, `derived_from`) and `Knowledge.EntityMention` (`statement_id`, `entity_id`, `surface_form`, `confidence`). They are **rebuildable from statements and never the system of record** (AINV-5) — excluded from the AD-PORT-1 export and regenerated on import, which the manifest's embedder model/version already supports. Three properties follow and each is load-bearing. (a) **Entities are account-global and carry no visibility of their own**, following the Peer precedent (AD-SEC-2); mentions inherit scope from the statement they annotate and retrieval filters *statements* exactly as before, so **a resolution error costs accuracy and cannot cross the account wall or a scope boundary** — nothing at the entity layer is consulted for either. (b) **No public surface returns them.** No REST, MCP, SDK, or LiveView endpoint exposes entity rows, alias lists, or canonical names; *amended by ADR-0011*, one surface form may appear as an entity card's label, and only when it is drawn from that card's own sources in that card's own scope, which is text the card already returns; an entity resolved from a restricted-scope statement would otherwise leak a referent name past the statement filter doing all of the security work. Asserted by a test in the deterministic PR gate (AD-EVAL-3), not by review discipline. (c) **Correction is recomputation.** A merge or split needs no governance gate and writes no ledger entry, and erasure (FR-GOV-15/16) must recompute every entity whose `derived_from` touched an erased statement, pruning any left with no surviving source.
- **AD-DATA-11 — Entity cards are scope-bounded projections, not entity content (ADR-0009, FR-KN-23).** `Projection.entity_id` is a nullable, private cache coordinate; the Account-local key is `entity:<scope_id>:<entity_id>`. The visible payload contains a bounded summary, its model provenance, the strictest source sensitivity, and allowlisted governed statement fields. *Amended by ADR-0011:* it also contains a `label` and a `kind` derived from the card's own in-scope surface forms, never read from the entity row. Cards use distinct active statements only and require at least two sources, with the summary held at three, so provisional subject-only knowledge cannot enter a subjectless aggregate and long-tail mentions cause no summary call. Current core reads authorize sensitivity at Gate B and then scope at read time; there is no independent reader-clearance axis to invent here. Persisting the strictest sensitivity keeps the aggregate correctly classified and is the policy filter point if sensitivity-scoped field reads are introduced later. Lifecycle invalidation remains scope-wide, and rebuilds leave cards below threshold dirty.

---

## 7. Asynchronous pipeline & job orchestration

Both modes use AshOban on Postgres. Ash.Reactor owns pipeline steps and
compensation; jobs inserted with durable writes form the transactional outbox.
Human approvals resume held work with a decision-triggered Oban job.

- **AD-PIPE-1 — Oban (via AshOban) for jobs; Ash.Reactor for orchestration.** The queue engine is **Oban-Postgres in every mode** — same job code, same engine, same semantics (uniqueness, priorities, cron, rate limits) locally and clustered. This is a strict improvement on both the TypeScript edition's two different runners and the pre-ADR-0003 two Oban engines: single-node no longer runs a different queue implementation than the one it is tested against in production. Each pipeline lane is an **Ash.Reactor** flow: discrete steps with compensation (saga rollback) and a durable-continuation / signal-on-approval seam for the human gate. A heavyweight external durable-execution engine (Temporal/DBOS) is explicitly **not** adopted — Reactor + Oban already give step orchestration, retries, idempotency, and human-in-the-loop parking, and the long-running-approval case is pre-solved by the durable knowledge-lifecycle state machine.

```
INGEST-TIME  (fast lane · cheap model · event-triggered · high-priority Oban queue)
  raw msg/doc persisted by edge → Oban job inserted in SAME tx (outbox)
    → extract: propose knowledge (subject≠source, hearsay-discounted; temporal + sensitivity proposed)
               + resolve update-op per candidate: add / merge / supersede-candidate / no-op (FR-FORM-14)
               + update session summary
    → cheap exact/near-dup check (embedding lookup)
    → gate-matrix check (NO LLM): peer-level → provisional-accept ; scope-level → hold ;
                                   below bar / sensitive → route to queue
    → write proposed/active + ledger + indices   (one Ash transaction)

DREAM-TIME  (slow lane · strong model · per scope · Oban cron + events · low-priority, budget-capped)
  over (scope, since-watermark) delta + working set:
    → higher-order deductions (reflection)
    → deep contradiction / supersession → non-obvious conflict = validation item
         (prior knowledge bundled) → curator/peer   [3rd gate]
    → corroboration leveling (Gate B) · pattern surfacing · memory evolution (relation upkeep)
    → entity resolution over validated statements (AD-DATA-10): exact alias → alias-embedding
                                   → reasoner adjudication of the ambiguous band only
    → refresh projections (incremental, AD-PIPE-7) · revalidation / expiry

SWEEPS & SYNC  (Oban cron)
  revalidation/expiry · pending-item aging (escalate / auto-reject)
  connector sync (content-hash) → changed docs → re-extract + supersede
```

- **AD-PIPE-2 — Ingest-time = extraction + cheap gating only.** No LLM reasoning, no leveling, no deep conflict at ingest-time (FR-FORM-14). A cheap, no-LLM gate-matrix check runs so **peer-level knowledge is usable provisionally and immediately** (FR-GOV-6) — load-bearing for the personal and SaaS shapes. Everything needing the working set or a strong model runs at dream-time (FR-FORM-16). The two-lane split is grounded twice over: the fast extract-then-update phase is the production pattern validated by Mem0 [2]; spending strong-model tokens offline so the hot path needs none is the sleep-time-compute result [4] — it cut test-time compute ~5× for equal accuracy precisely because idle-period reasoning over persistent context is amortised across future queries. ***ADR-0004 applies the same split to retrieval:*** the `:thorough` profile — all strategies, relation expansion, cross-encoder rerank — runs **at dream-time to build the projections `get_context` reads**, not on the hot path. That is the only honest way to get high benchmark accuracy under a ~100ms reasoning-free budget: you do not run a cross-encoder in 100ms, you run it earlier. The cost is more slow-lane budget per write, which is budget-capped and shed first as this lane already specifies — so the failure mode is staler projections, never a stalled queue. ***ADR-0005 admits exactly one governance read to the hot path:*** `Governance.Attach` selects at most one pending peer validation question (FR-API-30) — one pgvector round trip over the caller's own small pending set plus two indexed rate counts — running **after** the read result is assembled, under its own short deadline, and **failing open**: timeout or error returns the read unchanged. It is stated as an exception here so it stays the only one; anything needing a model call still belongs at dream-time.
- **AD-PIPE-3 — Priority & backpressure.** Separate named Oban queues per job-type, each with its own concurrency and rate-limit. Ingest-time runs high-priority/low-latency and effectively uncapped; dream-time runs low-priority and **budget-capped, and is shed first under pressure** (FR-PLAT-9). Raw ingest never blocks on extraction (persist-then-enqueue-in-tx + reconciler), so under load the system loses *freshness*, never data. Provider rate-limits feed the same backpressure. Oban's per-queue rate-limiting is the mechanism, and it doubles as the per-scope budget lever.
- **AD-PIPE-4 — Per-scope budgets at admission; model tiering; idempotency.** Before dispatching an expensive dream-time pass, check the scope's remaining token budget (from the §12 meter); if exhausted, defer (Oban `snooze`). Jobs map job-type → model-role (cheap extractor / strong reasoner / dialectic). Every job is keyed with an **Oban unique key** derived deterministically (`extract` by message-id+content-hash, `dream` by scope+watermark), so re-runs are safe via dedup/merge (FR-KN-9) and the reconciler's re-enqueue is harmless.
- **AD-PIPE-5 — Event-triggered dream-time is debounced with a nightly floor.** Session-close marks the scope dirty and schedules a coalesced Oban job after a quiet period (unique-key debounce), with a guaranteed nightly cron run — balancing freshness against budget, since provisional peer-level knowledge is already live from the fast lane.
- **AD-PIPE-6 — Human-signal continuation seam.** The third-gate "wait for curator approval" is a continuation point: the Reactor flow writes the validation item + hold state and completes; the curator's decision event (supersede / keep-both / reject / merge; FR-FORM-22) enqueues the continuation Oban job that resumes the downstream steps. Same domain step-sequence as the TypeScript edition, now expressed as a Reactor flow parked on a decision rather than a BullMQ callback — no separate durable-execution substrate needed.
- **AD-PIPE-7 — Projection refresh is incremental, never a monolithic rewrite (FR-KN-16).** The dream-time projection step computes the delta of changed knowledge since the projection's watermark and applies **structured delta updates** (add/replace/remove sections keyed to knowledge ids), with periodic full compaction allowed only when diffed and bounded. Rationale: iterative wholesale LLM rewriting of an evolving artifact measurably erodes accumulated detail — "context collapse" [9] — and costs strictly more tokens than a delta; keying projection fragments to knowledge ids also makes the FR-GOV-21 diff view and FR-GOV-15 recomputation surgical instead of total. (Semantics unchanged.)
- **AD-PIPE-8 — Answer correlation is a dream-time step, not a hot-path one (ADR-0005, FR-GOV-22).** Peer answers to inline validation questions arrive by two paths that converge in one Reactor step. The **fast path** is the `resolve_validation` tool call (FR-API-31), which records a *claim*. The **backstop** is the transcript: the peer's session was ingested anyway, so a dream-time step searches the turns after delivery for the frozen statement text — normalised (NFKC, casefold, whitespace-collapsed, quote-glyphs stripped) — and reads the following peer turn, classifying it with the dream reasoner where the tool never fired. Finding the verbatim statement is what makes the channel **verified**; its absence downgrades the answer to `unverified_channel` whatever the tool claimed. **The transcript governs over the claim**, and disagreement flags the item for a curator. The step is idempotent and keyed one-per-`(question, session)`, so replay and the two paths cannot double-count. This placement is the same trade as AD-PIPE-2: the cheap, certain part (recording a claim) is synchronous; the part needing a model and the full session is not.
- **AD-PIPE-9 — Read/write cost asymmetry is the placement rule (ADR-0006).** AD-PIPE-2, AD-PIPE-7, AD-PIPE-8, and now entity resolution are four instances of one principle, stated once here so the fifth case is decided rather than re-argued: **memory is read far more often than it is written, so work moves to the write side whenever it can be amortised across future reads.** Three tests decide placement, in order. (1) *Does it need a model?* If yes it is dream-time — AD-PIPE-2's exception list stays closed at one entry (ADR-0005's `Governance.Attach`, which is a lookup, not reasoning). (2) *Does it need corpus context beyond the current message?* If yes it is dream-time; ingest is per-message by construction. (3) *Is it amortisable — does one computation serve many later reads?* If yes, prefer dream-time even when the hot path could technically afford it. Two obligations attach to every stage placed this way, and neither is optional: it is **budget-capped and shed first** (AD-PIPE-3, AD-PIPE-4), so its degradation mode is staleness rather than a stalled queue; and its output is a **derived cache under AINV-5**, rebuildable, so shedding is a delay and never data loss. The asymmetry is also the honest answer to the benchmark-latency argument (§16): competitors quoting sub-200ms retrieval are measuring the read side of a system that does less on the write side.

---

## 8. Model & provider abstraction

- **AD-MODEL-1 — A provider layer over ReqLLM + capability behaviours.** Configured by a role → (provider, model, params) map at **Account level** (FR-API-18; per-scope overrides deferred, FR §12). Capability behaviours: `Embedder` (the `AshAi.EmbeddingModel` behaviour), `StructuredGenerator` (extractor and reasoner share it, differing by configured tier), `ChatGenerator` (streaming; dialectic + gateway), optional `Reranker` (model-based cross-encoder *or* score-fusion; the FR-API-25 rerank stage — *ADR-0004* places it over the **fused head**, in the `:thorough` profile only, and it is the *only* seam of the three in AD-SEAM-3's retrieval split that already existed). ReqLLM supports OpenAI-compatible and self-hosted endpoints (Ollama, vLLM; FR-API-19). BYO-key throughout. The four roles are unchanged: embedder, ingest extractor (cheap), dream reasoner (strong), dialectic agent.
- **AD-MODEL-2 — Structured output via Ash resource schemas + validate-and-repair.** The extractor/reasoner emit records against the *same* Ash resource schemas as the DB shape (no separate Zod layer — the resource *is* the schema). Generation via a structured-output action with a bounded **validate-and-repair retry** as the portable baseline (essential for weak self-hosted models), plus optional **constrained decoding** where a provider supports it (e.g. vLLM guided decoding). Extraction/reasoning are non-streaming. ash_ai's prompt-backed actions provide the structured-generation plumbing.
- **AD-MODEL-3 — Streaming only for dialectic + gateway; `ask` is a bounded, grounded, read-only tool-calling loop.** `ChatGenerator` streams; the gateway proxy tees the upstream stream (to the client + accumulate for capture). `ask` is a prompt-backed action given the *read* APIs as tools (resolve-scope, `query_knowledge`, `search`) for decomposition and multi-hop (FR-API-6) and can never write (FR-API-12); its sub-queries are what the edge fans out with `Task.async_stream` (AD-DEPLOY-2). **Grounding & abstention (FR-API-26) are enforced structurally, not by prompt alone:** the dialectic loop must return the knowledge ids it used (the response schema requires citations), and the assembler verifies every cited id was actually retrieved in-loop; absent / `expired` / `needs_revalidation` knowledge is surfaced to the model as explicitly *unknown-or-stale*, and an "insufficient memory" answer is a first-class, schema-valid outcome — abstention is where memory systems measurably fail [10, 11], so it is designed in, not hoped for. (`bitcrowd/rag`'s built-in groundedness / context-relevance / answer-relevance eval is a bonus signal for this NFR; see §15.) ***Extended by ADR-0004 — one new input and one prohibition.*** The input is **cross-strategy disagreement**: when `Semantic`, `Lexical`, and `Temporal` surface disjoint candidate sets with low raw scores, that is corroborated evidence the corpus does not hold the answer — stronger than any single strategy's score, because the failure is independently reproduced. It feeds the existing abstention decision alongside confidence-at-read (AD-DATA-2). The prohibition: **abstention must be computed pre-fusion.** RRF always emits a ranked list, including from three lists of garbage, so a fused rank carries no information about whether anything was found; any abstention logic reading the fused output is reading a number that cannot say no.
- **AD-MODEL-4 — Single provider for v1; fallback is a deployment concern; the embedder is pinned.** Retry+backoff on transient errors; provider rate-limits feed backpressure. Multi-provider fallback is achieved by pointing a role at an OpenAI-compatible proxy (e.g. LiteLLM) — not built into the engine. The **embedder is pinned and never silently falls back to a different model** (incompatible vector spaces would corrupt the index); changing it is a **versioned re-embed migration**, and every embedding is tagged with its model + version. This intent is unchanged; the mechanism is the `AshAi.EmbeddingModel` behaviour (Ortex default), pinned per embedding at write time.
- **AD-MODEL-5 — Provenance records model + version + prompt/pipeline version** (extends FR-KN-5), so extraction is auditable and the eval harness (§15) can pin versions for regression.
- **AD-MODEL-6 — Secrets by ref; one metering emission point.** Configs hold secret refs only; raw keys live solely in the secrets backend, redacted from logs/audit/metering. The ReqLLM provider layer is the single emission point for a usage record per call — `{account, scope, role, provider, model, tokens in/out/embed, latency, ts}` — feeding budgets, SaaS billing, and self-host cost visibility (FR-PLAT-8). The consumer's agent model is out of scope (FR-API-20).

---

## 9. API surfaces & contracts

- **AD-API-1 — One operation definition, many transports.** The five reads + `ingest` are defined once as **Ash Actions** on the domain resources; every surface is a thin adapter Ash already provides over those actions.

```
CLIENTS   agent-host(MCP) · generated SDK (TS/Py) · OpenAI-compat harness · curator(browser/LiveView)
                               │
                     ┌─────────▼──────────┐
                     │  PHOENIX ENDPOINT   │  authN · tenant scoping · rate-limit · routing · fan-out
                     └─┬─────┬───────┬───┬─┘
        reads+ingest    │     │       │   │   governance (human SSO + RBAC, NOT on MCP)
        for agents →  MCP  JSON:API gw-proxy  LiveView GOV
                        └─────┴───┬───┴────────┘
                                  ▼
                        ASH ACTIONS  (one typed op set on the resources)
                                  ▼
                              core Domains
```

- **AD-API-2 — Four surfaces.** The **HTTP API** (AshJsonApi, versioned `/v1`, language-neutral JSON:API) is the canonical machine transport, used by the generated SDKs, governance flows, and the gateway. **MCP** (the `ash_ai` MCP server) is a parallel surface for agent hosts: the same reads + ingest actions annotated as MCP tools (FR-API-11). The **gateway-proxy** internally calls inject (read) + capture (ingest). The **governance** surface is separate (FR-API-13) and is the LiveView app (§10).
- **AD-API-3 — OpenAPI is the canonical contract, generated by AshJsonApi.** Versioned in-path (`/v1/…`); the generated SDKs and the resource schemas carry semver; MCP tool schemas are versioned too (they are part of what the agent's model sees). Evolution is additive / expand-contract.
- **AD-API-4 — Auth as a structural boundary.** FR-API-12/13 is realised as **separate surfaces with separate auth**, not just separate endpoints: agents and the SDK authenticate with machine credentials and reach only MCP + the read/ingest JSON:API actions; an agent credential *cannot* reach a governance action because governance isn't on the agent-facing surface at all (and Ash policies deny it in depth). The governance surface uses human SSO + curator RBAC.
- **AD-API-5 — Harness SDK shape** (FR-API-14–16): the generated TS/Python clients provide thin primitives (session/peer/scope helpers, the reads, ingest) + an optional agent-loop helper; a context-injection helper that formats `get_context` into any provider's message shape; auto-forwarding of each turn to ingest; a skill-readiness wrapper that runs `check_readiness` and drives elicitation. Client-only dependency, usable over HTTP/MCP, provider-agnostic. (The engine is Elixir; the SDKs are generated artifacts, so the harness ecosystem's JS/TS requirement is met without the engine being TS.)
- **AD-API-6 — Gateway-proxy modes + session identity.** Three integration modes (MCP tools / proxy / native hooks); session id taken from the harness thread id or gateway request stream, else inferred by peer + scope + idle-gap (FR-API-21/22).

---

## 10. Headless governance & interaction channels

- **AD-GOV-1 — Governance is delivered through channel adapters over the governance op layer; the LiveView app is one adapter.** Outbound *notify* (a validation item needs a curator, or a peer needs revalidation/consent → push an actionable message) and inbound *act* (the response translates back into a governance Ash action: approve / reject / merge / defer / confirm-scope / consent; FR-GOV-5/8/12). LiveView subscribes to `Ash.Notifier.PubSub` so the validation queue, curator dashboards, knowledge history/diff view, and peer self-view update in realtime with no polling. This directly mitigates the blueprint's governance-latency risk by pushing approvals to where curators already are, and extends FR-GOV-10's inline revalidation to reach people *between* sessions.
- **AD-GOV-2 — Channel assurance is a hierarchy, and authZ runs against the mapped peer regardless.** Slack/Teams have request-signing and verified identities (high assurance — a signed action is trusted as that user); Telegram is usable only after explicit one-time linking (medium); **email is notify + magic-link only — a reply is never authorization** (the action happens behind a one-time, expiring, single-purpose authenticated link). Each inbound channel webhook is a Phoenix endpoint that must verify the channel signature and resolve tenant as rigorously as the edge (a plug enforcing AINV-6 before any Ash action runs).
- **AD-GOV-3 — Sensitivity-gated routing + per-Account channel allowlist.** Low-sensitivity items may include content inline; high-sensitivity items go *notify-only* (content stays inside the boundary). An Account sets which channels are permitted at all (e.g. a regulated org allows only Slack within its tenant and forces the LiveView UI for `restricted`). This implements the FR-PLAT-16 compliance posture.
- **AD-GOV-4 — Audit is enriched, not weakened.** Every action through any channel flows through the governance Ash action → gate decision → hash-chained audit (AD-DATA-8), with the actor being the *mapped peer* and the channel recorded as provenance.
- **AD-GOV-5 — Phasing.** Build the interaction-channel port now (the LiveView UI is itself an adapter); ship LiveView UI + Slack + email-notify early; Teams and Telegram as later adapters. A basic validation/curator UI ships in the free core; heavier compliance surfaces (audit-export views, org-wide dashboards, advanced RBAC management) are enterprise.

---

## 11. Security, identity & tenancy

- **AD-SEC-1 — The hard wall (AINV-6).** Account is derived from the authenticated identity, never from a request parameter, and is re-checked in depth: identity-bound account set as the Ash `tenant`/`actor` at the Phoenix edge, authZ re-checked by Ash policies at the action layer, RLS or schema/db-per-account at storage, per-Account namespaces for blobs and secrets. Cross-account access is structurally impossible (FR-TOP-1, INV-8).

```
REQUEST AUTHZ  (every request, every surface)

  external identity                 resolves to
    SSO subject (SAML/OIDC)  ┐
    API key / token          ├──►  PEER  (account-scoped)
    signed Slack/Teams action│         │
    linked Telegram id       │         ├─► role grants on the scope tree
    SSO-verified email       ┘         │     (per-grant propagate flag, Linux/ACL-style)
                                       │             │
            identity's assurance ◄─────┘             ▼
                    │                        read S iff an applicable grant on S
                    ▼                        or a propagating ancestor (FR-GOV-19)
        sensitivity × assurance
        (restricted ⇒ high-assurance only)
                    │
                    ▼
  ── HARD WALL (account never crossed · defense in depth) ──
   edge    : account derived from IDENTITY → Ash tenant/actor, never from request params
   actions : Ash.Policy.Authorizer re-checks; any caller-supplied account_id ignored
   storage : Ash :context + Postgres RLS / schema-per-account   blob+secrets: per-account namespaces
```

- **AD-SEC-2 — Identity model.** The **peer** is the domain identity (human or agent, symmetric), an Ash resource. External identities are *linked to a peer*, account-scoped, in a `peer ↔ external_identity` resource (`{kind: idp|apikey|slack|teams|telegram|email, external_id, assurance, linked_at}`). A verified email claim comes free from SSO; Slack/Teams/Telegram require a one-time **account-linking flow** (authenticate the trusted way, then bind the channel id). Each link carries an **assurance level** consumed by the sensitivity×assurance check (AD-GOV-2).
- **AD-SEC-3 — RBAC: per-grant propagation flag (Linux/Windows-ACL semantics), via Ash policies.** Roles — account-admin, curator, member, reader (FR-GOV-18) — are granted per-scope. Each grant carries a `propagate` flag (this-scope-only vs this-scope-and-subtree). Resolution at scope S: gather S + propagating ancestors via the materialized path, take the applicable allows. **Deny entries** (Windows-ACL style, deny-wins) are the mechanism for carving a peer out of a sensitive subtree (decision pending, §18 — lean: include). This is expressed as **Ash policies** (read/action authorization) plus **field policies** for sensitivity-scoped attributes; RLS enforces the **account** wall at the DB, these policies enforce **scope-level** read access at the action layer — defense in depth, not duplication. A Zanzibar-style relationship-tuple engine [13] (OpenFGA / SpiceDB) remains droppable behind the policy layer as an enterprise ReBAC adapter.

```
role_grant = { peer_id, scope_id, role, effect: allow|deny, propagate: bool, granted_by, granted_at }
effective at S = max(applicable allows where scope=S OR (ancestor AND propagate)) MINUS matching deny
read S iff effective is non-empty      (evaluated in an Ash policy check)
```

- **AD-SEC-4 — Build auth on Ash-native + standards libs; do NOT depend on Clerk/WorkOS.** Both are hosted SaaS and would break "runs out of the box locally," "own your data," and self-host↔SaaS portability — and are a dealbreaker for the regulated buyer. Instead: free core uses **AshAuthentication** (password / API-key / magic-link, local, owns its tables); enterprise adds standards-based **SAML SP via ExSaml or Samly** (SP- and IdP-initiated SSO, Single Logout, SP metadata, multi-IdP; both are mature and Azure-AD-proven — pick one in the spike) + **OIDC via assent** + a **SCIM 2.0 endpoint implemented over Ash** (Users/Groups CRUD + filter, with group → scope-role mapping; the `scim` hex Plug scaffold is a starting point, OIDC-JIT provisioning is the early-customer fallback). The same self-hostable stack runs in every mode, including the managed SaaS — no hosted-auth dependency anywhere.
- **AD-SEC-5 — Agents are peers (member/reader); curator is a human role.** Granting curator to an agent is a no-op for governance actions (the governance surface is human-only, enforced by Ash policy). API keys are per-Account, bound to a peer, optionally scope-restricted for least privilege (AshAuthentication API-key strategy).
- **AD-SEC-6 — Deprovisioning ≠ erasure.** SCIM offboarding revokes access and unlinks identities; knowledge the peer sourced or that is about them persists until the separate, governed right-to-be-forgotten flow runs it (FR-GOV-15/16). Losing access never silently deletes data.

---

## 12. Observability & metering

- **AD-OBS-1 — Three telemetry pipelines, never conflated.** **Operational observability** (operator-facing, lossy-tolerant, their backend), **metering** (money/budgets, exact, in their DB), and **product telemetry** (vendor-facing, anonymous).
- **AD-OBS-2 — Observability via OpenTelemetry, vendor-neutral, off-by-default on single-node.** OpenTelemetry Elixir + the `:telemetry` ecosystem (Phoenix, Ecto, Oban, Ash all emit `:telemetry` events) for traces and metrics; structured JSON via `Logger` correlated to trace ids. Emit OTLP; the operator points it at their own backend (Grafana/Tempo/Loki, Datadog, Honeycomb…). The key engineering bit: **trace context (W3C `traceparent`) is propagated through the queue** (injected into the Oban job args, continued by the worker), giving end-to-end traces from "message in" → "knowledge minted" → "projection refreshed." Metrics include the FR-PLAT-10 ops set (queue depth via Oban, latency, error rates) plus RED/USE. On single-node it is zero-config off; opt-in to enable.
- **AD-OBS-3 — Sensitivity-aware log redaction.** Secrets/keys never logged; knowledge content is **never logged above debug level**, and at debug only behind an explicit config flag and **never for `restricted`** (FR-GOV-11). Ash field policies keep `restricted` fields out of default logging paths.
- **AD-OBS-4 — Metering is a durable, exact ledger, not OTel.** An append-only `UsageEvent` Ash resource in the DB — exact, attributed to `{account, scope, role}`, sourced from the ReqLLM provider layer's single emission point (AD-MODEL-6) plus periodic storage-size measurement and edge-side ingest/API counts. It rolls up into materialised per-scope counters (kept warm in ETS for fast budget admission, AD-PIPE-4) and feeds SaaS billing and the self-host cost dashboard (FR-PLAT-8). Sampled-and-lossy for OTel; exact-and-durable for money.
- **AD-OBS-5 — Product telemetry is anonymous opt-out on self-host, identified on SaaS, opt-in for contacts.** A mandatory phone-home is rejected — it contradicts the data-ownership thesis, is impossible air-gapped, risks GDPR, and is unnecessary (opt-out captures the overwhelming majority of installs). So: self-host free = anonymous, on-by-default, **opt-out** (random instance id, version, deploy mode, feature-usage; never content, never contacts; first-run notice + `MEM_TELEMETRY_ENABLED=false`), built on PostHog (self-hostable); self-host enterprise = off / air-gapped (the licence is the relationship); managed SaaS = fully identified usage, ToS-governed (legitimate, not phone-home); **contacts only via an opt-in free-licence registration** that unlocks some otherwise-enterprise features (specific set TBD, §18; gate additive niceties, never core, transparently).
- **AD-OBS-6 — Optional local observability stack.** Emit-only by default, plus an optional `--profile observability` compose stack (OTel Collector + Grafana/Tempo/Loki/Prometheus, or Jaeger) — never required, one command away.
- **AD-OBS-7 — Health/readiness endpoints** (liveness + DB/queue reachability, via a Phoenix health route + Oban/Repo checks) feed the compose/k8s healthchecks. Edition: OTLP emission, ops metrics, health, and basic cost-visibility are free core; advanced retention, prebuilt dashboards, and audit/usage export to a SIEM are enterprise (FR-PLAT-13, FR-PLAT-13a).

---

## 13. Configuration, packaging, distribution & licensing

- **AD-CFG-1 — Configuration is two kinds; only one is layered.**

```
INFRA / DEPLOY  (config/runtime.exs · validated at boot · fail-fast · per node)
  data-layer selection · connection strings · clustering topology · OTLP endpoint ·
  LICENSE KEY · ports · retrieval: ENABLED STRATEGY MODULES + DEADLINE CEILINGS
                             secrets are NOT here — referenced by ref, resolved via the secrets port

POLICY / BEHAVIOUR  (DB-stored Ash resources · runtime-editable · no redeploy)
  account level   model roles (FR-API-18) · channel allowlist · auto-accept matrix ·
                  budgets · retention · sensitivity defaults
       ▼ scope overrides account, INHERITS DOWN the tree (nearest-wins)
  scope level     scope policy · per-scope budget · skill-card overrides ·
                  DEFAULT RETRIEVAL PROFILE + FUSION WEIGHTS
  → effective config = scope (nearest-wins) over account

PER-QUERY  (request parameter · narrowest layer · additive to the API contract)
  retrieval_profile: :fast | :balanced | :thorough
  strategies: [...]   raw module list — INTERNAL/EVAL AUTH ONLY
```

  Infra/deploy config is `config/runtime.exs`, validated at boot, fail-fast. Policy/behavioural config lives in the DB as Ash resources, runtime-editable via the admin/governance LiveView surface, with the scope layer inheriting down the tree (nearest-wins) — the same grain as knowledge visibility and RBAC (FR §10, invariant 7). Secrets appear in neither.

  *Added by ADR-0004:* retrieval strategy selection lands on all three layers, and the split is not arbitrary. **Which strategy modules exist at all** and **what deadline ceilings apply** are properties of the deployment, so they are infra. **Which profile and weights a scope defaults to** is a policy question at the same grain as visibility, so it inherits down the tree. **Per-query** overrides carry the named profile only; the raw `strategies:` list is restricted to internal and eval callers, because publishing internal module names would freeze them into the API contract and we intend to rename, merge, and delete strategies as the ablation data comes in.
- **AD-CFG-2 — Packaging & distribution.** *Rewritten by ADR-0003 and amended by issue 179.* The primary on-ramp is **one command with zero dependencies and no container runtime**: a self-contained Mix release plus pinned pg0 and ABI-matched pgvectorscale. The release supervises pg0, stages the extension, runs migrations, and serves. Data lives in the pg0 instance directory. The packaged matrix is glibc Linux x86_64/ARM64 and Apple Silicon; Windows, Intel macOS, and Linux musl use external PostgreSQL or a container. **Three distribution paths, one release:**
  1. **No-container (default local):** release + pinned pg0, one command, offline.
  2. **Containers:** the same release image published to GHCR, run against **stock Postgres** — never pg0, which refuses to run as root and fails in root-only containers. Compose files for single-node (app + PG + volume) and queue-mode (PG + MinIO + N clustered nodes; **no Redis**), with compose **profiles** for optional pieces.
  3. **External Postgres:** any deployment can skip the embedded server entirely — set the connection string, do not start the pg0 child. This is a config change, not a build, and is the permanent escape hatch from ADR-0003's dependency on a young component.

  Migrations auto-run on boot for single-node (`Ash`/Ecto migrate on start); an explicit migrate step before rollout in production; **Postgres major-version moves go through the tested logical export/import** (AD-PORT-1), not in-place. The pg0 version is pinned in the release and in CI, and bumping it is a reviewed change with a restore test. Helm for k8s/cloud scale (with libcluster topology) comes later.
- **AD-CFG-3 — Licence gate: signed, offline-verifiable token + entitlement service.** An ed25519-signed, JWT-shaped licence token carries entitlements (features, limits, expiry); the app verifies it **offline in Elixir** against an embedded public key (essential for air-gapped buyers), with periodic online renewal and an offline grace window. A central `enabled?(feature)` entitlement module gates the `ee` OTP app's code paths at boot/config (queue-mode entitlement; 2nd Account → multi-account; SAML → SSO; etc.). Missing/expired licence turns enterprise features **off with a clear message** — never a crash, never data loss. Modelled on n8n's licence-SDK pattern.
- **AD-CFG-4 — The gate is honesty + legal terms, not unbreakable DRM.** The `ee` source is visible (source-available under the Sustainable Use Licence); a determined actor could patch the check, but doing so violates the licence, and the model relies on enterprises buying for legitimacy, support, and compliance. Over-hardening would be futile (source-available) and against the fair-code spirit.
- **AD-CFG-5 — One image (use-gated), plus a free-licence middle band.** A single release image with the `ee` OTP app present-but-gated (a community-only build that excludes it is kept available if a provably-clean artifact is ever demanded). A free-licence registration unlocks some otherwise-enterprise features (specific set TBD, §18), gating additive niceties, never core capability.

---

## 14. Portability & migration

**Amended by ADR-0003:** with one data layer everywhere, the export's job is no longer to bridge two engines. It gains a *new* load-bearing job instead — **it is the supported Postgres major-version upgrade path**, because pg0 documents no in-place major upgrade. What was a portability nicety is now also an operational necessity, and is tested as one.

- **AD-PORT-1 — Export is logical, not physical.** The format is a versioned, self-describing archive of the *domain model* (manifest with schema version + embedder model/version + counts + sha256 checksums, then JSONL per Ash resource type, plus blobs) — **not** a `pg_dump` — because a logical, engine-version-agnostic format is what makes self-host ↔ SaaS migration, cross-major-version moves, and "leave with your data" all the same mechanism. The format is versioned (expand/contract). **PG-major upgrade procedure:** export from major N → fresh `initdb` on major N+1 → import → verify; this round-trip is a tested path, not a documented hope (ADR-0003 condition 2).

```
ACCOUNT EXPORT — what travels, and how
  domain data       knowledge (+ledger, provenance, attributions, relations, lifecycle), scopes
  (portable, §6)    (tree+graph), peers, sessions, messages, skill cards, config, queue state,
                    identity links  → JSONL per resource, streamed
  audit log         exported WITH its per-account hash-chain intact; import verifies, then continues
  blobs             raw bytes (bundled for small accounts, streamed separately for large)
  derived indices   pgvector / PG-FTS — NOT exported; REBUILT on import (re-embed job)
  secrets / keys    NEVER exported — refs only; operator re-provisions at target
                    (CMK: decrypt at source → transport-encrypted → re-encrypt under target key)
  usage/metering    optional (cost-history continuity)
```

- **AD-PORT-2 — Migration runs both directions; the reverse one is the point.** Self-host → SaaS is the GTM upgrade path; **SaaS → self-host is the credibility move** — being able to leave with all data, for free, is what makes the compliance buyer trust you. Therefore export/import is **free core** (FR-PLAT-11/14); gating it would make the no-lock-in claim hollow. (Enterprise adds scheduled/automated backups on top.)
- **AD-PORT-3 — Offline snapshot + cutover; rebuild embeddings — for v1.** Migration is a transaction-consistent point-in-time export, transfer, import, and switch (briefly quiescing writes for the final cutover); live/streaming migration is deferred (§18). Embeddings are rebuilt on import (robust, embedder-agnostic), which is also why a Postgres major-version jump carries no pgvector storage-format risk; a carry-vectors fast path when the target embedder + version match is deferred (§18).
- **AD-PORT-4 — Logical export doubles as portable DR.** Distinct from physical backup/restore (`pg_dump` / data-directory + blob backup, including a pg0 instance directory), which is standard operator tooling we document; the logical export is the *portable* path and an input to the §16 DR posture.

---

## 15. Quality & evaluation architecture

> This section is the *testing/CI architecture* that hosts the EV spec, not a re-derivation of the EV design.

- **AD-EVAL-1 — The model provider layer is the determinism seam.** Because every LLM call goes through the ReqLLM provider behaviour, tests inject a stubbed or replayed model adapter and *everything except the model call becomes deterministic* — gating, conflict, dedup, temporal logic, projection assembly, RBAC. This is the single biggest enabler of fast, deterministic CI and a direct payoff of the ports architecture (here, Ash + behaviours).

```
TWO TIERS, SPLIT BY DETERMINISM
PR / COMMIT GATE  (deterministic · fast · blocks merge)
  format · dialyzer/credo
  unit          pure domain logic (RBAC, tree, gates, temporal, dedup) — no model, Ecto sandbox
  data-layer    one contract suite, one backend (AshPostgres) — CI PG via Testcontainers or pg0
  contract      OpenAPI + generated-SDK + MCP surface conformance
  guardrails    cross-account isolation (property test); promotion/consent (crafted scenario + MOCKED model)
        └─ model provider stubbed / replayed from cassettes → fully deterministic
NIGHTLY / RELEASE  (live or pinned models · graded · reported separately)
  EV framework: scenarios + probes, golden set, judges, frontier sweeps, benchmark replay
  guardrail regressions BLOCK release; quality/cost/latency tracked vs the frontier
        └─ runs through the REAL surface + privileged internal probes
```

- **AD-EVAL-2 — Testing pyramid.** Unit (ExUnit) for pure domain logic; **data-layer conformance suite** — *amended by ADR-0003*, this runs **once against AshPostgres** rather than twice against two divergent backends. The class of bug it used to hunt (backend behavioural divergence, EV-PERF-2) no longer exists, so the suite's remaining job is schema/action conformance and index behaviour, and CI wall-clock roughly halves. Postgres in CI comes from **Testcontainers** where Docker is available and **pg0** where it is not — which incidentally makes CI exercise the same on-ramp a self-hoster uses. Two things must now be tested that the old split did not cover: **pg0 lifecycle** (cold start, ungraceful shutdown and restart, stale lock file, port conflict) and the **export → fresh instance → import round-trip** across a PG major. *Added by ADR-0004:* a **per-strategy contract suite** — each `Retrieval.Strategy` module is independently testable by construction (`applicable?/1` gating, `min_score`/`max_candidates` truncation, deadline compliance, candidate shape), which is the mitigation for the extra moving parts multi-strategy retrieval puts on the read path. Plus: contract tests against the AshJsonApi OpenAPI spec + generated SDKs + MCP; **`stream_data`** for property/invariant tests (cross-account isolation, EV-MET-3, is the canonical property); a **provider-level cassette layer** records/replays model I/O for deterministic, realistic pipeline tests. Ecto sandbox gives per-test transactional isolation.
- **AD-EVAL-3 — Two tiers by determinism.** The deterministic PR gate blocks merge; the EV framework runs nightly/on-release against live or pinned models (EV-REPRO-1), judges from a different model family (EV-GRADE-3). As many guardrails as possible are pushed into the deterministic gate; guardrail failures gate (EV invariant 1); quality/cost/latency are frontier-tracked. **Benchmark replay targets the public memory benchmarks** — LongMemEval [10] (knowledge-update, temporal-reasoning, and abstention abilities), LoCoMo [14] (multi-hop, temporal, adversarial recall over very long conversations), and ConvoMem [11] (abstention, temporal change, implicit connections; also the small-corpus full-context baseline that any memory system must beat to justify itself) — adapted through the real surface so reported numbers reflect the shipped path, not a harness shortcut. Credible numbers here are a stated marketing input (blueprint §15/§16), which is why replay lives in the release tier rather than a side repo. ***Amended by ADR-0004 — two additions.*** (a) **Stage 0 baseline first:** per-category LongMemEval and LoCoMo scores must be recorded through the real surface *before* any strategy work starts, otherwise there is nothing to attribute improvement to. (b) **Strategy-ablation harness:** replay runs as benchmark × strategy-set × profile, **deadlines disabled** (or fixed against a fake clock, AD-EVAL-4) so scores do not vary with CI machine load, reporting per-category. That matrix is the evidence for the default profile weights — it replaces argument about which strategies matter with measurement. Two disciplines attach: fusion weights are tuned only against a **held-out set** that never informs the published number (weights are config, not code, so a deployment with a different corpus shape can retune without a release), and **every published score cites a profile version plus the deadline setting**. ***Amended by ADR-0006 — four additions.*** (a) **The tier split is renamed for what it measures.** Release-tier replay is **engine benchmarks** (LongMemEval, LoCoMo, ConvoMem, BEAM); the MemHouse-specific measures — governance, promotion, scope, skill-readiness, token efficiency — are **product evaluations** (`EV-TASK`, EV spec). The public benchmarks measure conversational recall on an ungoverned single-scope corpus, which is a *fraction* of what this system claims [15]; keeping them in one undifferentiated list invites the mistake of treating a good LoCoMo score as evidence the product works. (b) **BEAM [16] joins the replay targets**, reported as a **degradation curve across corpus size rather than a single number** — it is the only public target that probes 1M–10M-token corpora, where the reported field-wide fall-off (64.1% → 48.6%) is precisely the regime a long-lived org memory occupies. A single headline figure would hide the shape, and the shape is the finding. (c) **Product evaluations own the measures no public benchmark covers** — repeated-run error reduction, correction learning, task outcome, and behaviour past 100K facts [15] — and these are the ones tied to the product's actual claim, so they are frontier-tracked with the same seriousness as the engine numbers. (d) **The deterministic gate hosts the no-public-entity-surface test** (AD-DATA-10): no REST, MCP, SDK, or LiveView route returns an entity or mention. It sits in the blocking tier because it is a rule guarding a security-adjacent boundary, and rules erode.
- **AD-EVAL-4 — Bridge affordances the system must expose** (always-present-but-gated behind internal-only auth + config): an injected **`Clock`** everywhere time is read (**never call `System.system_time`/`DateTime.utc_now` directly**; enables EV-SCEN-5 and deterministic testing of the entire tri-temporal model, AD-DATA-1 — and, since ADR-0004, it is what makes deadline-bounded retrieval fan-out reproducible: `Budget.started_at` comes from the `Clock`, so eval can disable or fix the deadline and get a stable strategy set); a **manual "run dream-time now"** trigger (enqueue the Oban job on demand; EV-SCEN-6); **read-only internal probes** (Oban queue state, lifecycle, belief-time intervals, audit — EV-STRAT-4; mostly needed anyway for FR-GOV-21).
- **AD-EVAL-5 — The eval framework lives in-repo** (an `eval` OTP app / mix task tree), so scenarios and golden sets version-pin to the prototype and coverage tracks against the FRs (EV-REPRO-1, EV-STRAT-5).

---

## 16. Non-functional targets, SLOs & resilience

- **NFR-1 — Latency targets (measured, revisable — not hard gates).** These are targets the eval framework and benchmarks measure against (EV §7.4); they are revisited as data arrives, not frozen into the contract.

```
LATENCY TARGETS  (warm path · p95 · both backends unless noted)
  get_context        ~100ms  TARGET   excl. query-embedding (EV-MET-22/24) — measured, revisable
  check_readiness    ~100ms  tracked  reasoning-free, mostly DB
  query_knowledge    ~100ms  tracked  metadata filter (incl. as_of interval filter, FR-API-23)
  ingest (ack)       ~50ms   tracked  persist raw + Oban outbox job in one tx; extraction is async
  search          100-600ms  tracked  incurs query embedding (model) — reported separately
                                      ADR-0004: :balanced profile, deadline-bounded fan-out
  ask            800-3000ms  tracked  reasoning / multi-hop (EV-MET-25)
                                      ADR-0004: :thorough profile, incl. rerank
  cold start         —       tracked  measured, NOT gated (EV-MET-23)
```

  *Amended by ADR-0004.* Multi-strategy retrieval lands on `ask` and `search` — the two rows with no target — and **not** on `get_context`. The comparable system (Hindsight) reports four strategies plus a cross-encoder in a 100–600ms band; that band sits *between* MemHouse's two read paths, and it is evidence that a fan-out fits in a few hundred milliseconds, not in a hundred. Because fan-out is deadline-bounded (AD-SEAM-3), the `ask`/`search` budget is set by the profile's deadline rather than by the sum of its strategies, so these rows stay trackable even as strategies are added. Any published number must cite the **profile version** and state whether deadlines were enabled (§15).

  *Amended by ADR-0006 (the bands above).* The two `—` rows are filled in as **bands, still tracked and still not gates** — the open decision on whether latency targets become gates (§18) is untouched. `search` takes the 100–600ms multi-strategy band the surveyed systems report [15]; `ask` takes 800–3000ms, which is the same band plus the LLM-synthesis cost those surveys measure separately [15]. The reason to write them down is asymmetric: an empty cell cannot be violated, so `ask` drifting to four seconds would be invisible until a user reported it. A band that is occasionally exceeded and reported is strictly more useful than no band.

- **NFR-2 — How the architecture serves the `get_context` target.** It is **reasoning-free** (FR-API-5) — no model call in the path; it reads **materialised projections + current-state** (AD-DATA-3), served from **ETS / `persistent_term`** with no synthesis and no ledger fold; ancestor merge is a **materialized-path prefix query** (AD-DATA-4); vector ANN + lexical are **co-located in the same database, reachable over one connection** (pgvector DiskANN + PG-FTS — identical in every mode since ADR-0003, so a locally measured p95 is a meaningful prediction of the deployed one); the **query-embedding is excluded** (EV-MET-24), and `get_context` can even run embedding-free — ranking on the precomputed **salience × durability × recency** terms of the FR-API-10 scoring function (the retrieval triad of [3], with the expensive relevance term optional on this path). Because the whole path is in-VM with no network hop, the budget decomposes into EV-PROBE-5's stages, every one a fast in-process or DB op — this is where BEAM/ETS/in-process assembly makes the target *more comfortably achievable* than the TypeScript edition's cross-process assembly. ***Unchanged by ADR-0004, deliberately.*** `get_context` does **not** fan out across retrieval strategies. It gets the benefit of them indirectly: the expensive profile runs at dream-time to build the projections this path reads (AD-PIPE-2), so retrieval quality is paid for offline and served online. A cache miss falls back to the `:fast` profile (`Semantic` + `SalienceRecency`, no rerank), which is the only multi-strategy work this path may ever do live.
- **NFR-3 — No fan-out caps in v1.** `get_context` does full-path ancestor merge in v1; latency is measured (worst case: deep tree × large store × many cross-links, EV-PERF-3) and fan-out caps are reconsidered only if the data demands it (§18). This follows from treating the target as revisable rather than forcing a number with caps.
- **NFR-4 — Read scaling: replicas in queue-mode.** `get_context` and other reads route to Postgres **read replicas** to protect the latency target under read-heavy load and scale reads off the primary, accepting small replication lag — tolerable because projections are already async-refreshed (and often served from ETS) — with read-your-writes only where a flow needs it.
- **NFR-5 — Throughput is measured and frontier-tuned, not pre-committed.** Ingest, extraction, and dream-time rates come from the EV frontier sweep. The architecture makes them scale: identical clustered nodes scale horizontally (add nodes via libcluster), Oban absorbs bursts, per-scope budgets + shed-dream-time-first keep the system responsive under pressure.
- **NFR-6 — Availability.** Single-node (free): one BEAM node, **no HA** by design (laptop / single VM); RPO/RTO bounded by backup cadence + restart (though BEAM supervision means in-node crashes self-heal). Queue-mode (enterprise): identical nodes are HA by replication behind a load balancer; the **Oban cron leader** is the one non-HA-by-default component (outage delays scheduled dream-time only; leadership re-elects); the data tier (Postgres/S3) HA is the operator's responsibility via standard managed patterns. App-tier target ≈ 99.9%+ given an HA data tier — comfortably so, since any node can serve any request and supervision restarts failed components in-VM; the managed-SaaS SLA is a business decision on top.
- **NFR-7 — Durability / RPO.** The system of record is raw messages + validated knowledge + audit log; **RPO is a function of the DB replication/backup strategy** (operator-tunable; near-zero with synchronous replication). The ETS caches and projections are derived caches — losing them is never data loss; the reconciler rebuilds (AINV-5). *Amended by ADR-0003:* the Oban queue and the vector/lexical indices are no longer in that category — they are transactional Postgres state, backed up and restored with everything else, which shrinks what recovery has to reconstruct.
- **NFR-8 — Resilience & graceful degradation.** The standout property: a **model-provider outage degrades only the reasoning queries** — writes survive (ingest persists raw + inserts the Oban job in one tx and returns; extraction catches up) and **context-serving survives** (`get_context` touches no model); only `ask`/`search` degrade. With ingest-never-blocks-on-extraction, the transactional-outbox-as-Oban-insert, idempotent jobs, self-healing caches, and BEAM supervision isolating crashes, the failure posture is: under load or partial outage you lose *freshness or reasoning*, never *data* and never *the account wall* (enforced at edge + Ash policy + RLS regardless of partial failure). The DB is the one hard dependency; HA Postgres is the mitigation.
- **NFR-9 — Disaster recovery.** Two paths: physical backup/restore (DB dump + blob backup, documented operator tooling) and the **logical account export (AD-PORT-1) as a portable DR artifact** — the same artifact that carries a PG-major upgrade (ADR-0003); queue-mode adds DB replication + S3 durability + a documented restore runbook.
- **NFR-10 — Scale ceilings (honest).** Single-node tops out at personal/small-team scale. *Amended by ADR-0003:* the old ceiling was three artificial limits stacked (SQLite's single-writer lock, `Oban.Engines.Lite`'s single-node scope, hnswlib's RAM-bound index) and all three are gone. The remaining ceiling is **one machine's CPU, RAM, and disk shared between the BEAM and a real Postgres** — a higher and more honest bound, but one that must be **re-measured** rather than inherited from the old numbers (ADR-0003 validation spike). Note the ceiling is now a resource limit, not a correctness limit: single-node is licence-limited to one Account, not structurally incapable of more. Queue-mode scales to org level, with **shared Postgres as the eventual bottleneck** — read replicas (NFR-4) and schema/db-per-account (AD-DATA-6) are the levers; true sharding is a deferred far-scale concern (§18).
- **NFR-11 — Token efficiency (ADR-0006).** Two figures, **tracked and reported, not gated**: **context tokens returned per `get_context`** and **end-to-end tokens per `ask`** (retrieval + synthesis, excluding the caller's own prompt). Both are reported against the **full-context baseline on the same corpus** — the ConvoMem discipline (AD-EVAL-3) applied to cost rather than accuracy. Rationale: the field's headline claim for memory systems is now economic, not qualitative — ~6,900 tokens per query against ~26,000 for full context [16] — and it is the claim a buyer can check. MemHouse is structurally well placed to make it (`get_context` is a projection read that touches no model, AD-PIPE-2) and currently measures nothing, so the advantage is unevidenced. Not a gate, for the same reason the latency rows are not: the number moves with corpus shape, profile, and projection freshness, and a threshold would be gamed by returning less context. It is a **frontier-tracked** figure whose regressions must be explained, and every published value cites a profile version (§15).

---

## 17. Recommended technology stack (concrete)

| Concern | Choice | Notes |
|---|---|---|
| Language / runtime | Elixir on the BEAM | single language for the engine; heavy compute in the native NIF tier |
| Project layout | Mix umbrella / `boundary`-enforced contexts; Hex for publishables | Ash domain boundaries replace the hand-built layer cake |
| Boundaries | Ash domains + `boundary` compile-time checker | enforce the AD-TOPO-2 dependency rules |
| Domain / core | **Ash Framework** (Domains, Resources, Actions) | data layers *are* the adapters; actions are the typed op layer |
| Relational + migrations | **AshPostgres** (Ash-generated migrations) | one data layer, one migration set; SQL-first control for pgvector/RLS/FTS |
| Storage (all modes) | Postgres + pgvector + PG-FTS | `:context` multitenancy + RLS keyed on Account |
| Local Postgres | **pg0** (pinned; PG 18 + pgvector 0.8.1, MIT) | ADR-0003; single binary, offline, no Docker; supervised as a release child |
| External Postgres | connection string, no pg0 child | always-available escape hatch; the only path in containers/k8s |
| Vector | **pgvector via `ash_ai` `vectorize`** | index write rides the transaction, in every mode; `Nx` brute-force as a tiny-corpus baseline |
| Lexical | **PG-FTS** | same tokenisation/ranking everywhere; local recall = deployed recall |
| Retrieval | **`Retrieval.Strategy` (N modules) + RRF fusion + `Reranker`** | ADR-0004: `Semantic`/`Lexical`/`Temporal`/`SalienceRecency` seeds + `RelationExpand`; deadline-bounded `Task.async_stream` fan-out; named versioned profiles |
| Queue | **Oban (Postgres engine) via AshOban** | one job system, one engine, both modes; **Redis removed** |
| Pipeline orchestration | **Ash.Reactor** (saga steps + compensation + idempotency keys) | triggered by AshOban |
| Transactional outbox | **Oban job inserted in the write transaction** | replaces outbox table + relay |
| Model layer | **ReqLLM** (ash_ai provider layer) | four roles; BYO-key; OpenAI-compat/Ollama/vLLM |
| Embedder | **`AshAi.EmbeddingModel` behaviour** → **Ortex/ONNX** default | Qwen3-Embedding-0.6B at 1024 dimensions; Bumblebee+EXLA for GPU; BYO-key API embedder |
| Multi-provider fallback | external proxy (e.g. LiteLLM) | deployment concern, not in-engine |
| RAG / ingestion | **`bitcrowd/rag`** | chunk / ingest / hybrid search / eval; pgvector-first — now the only target, no store swap |
| Doc extraction | **Extractous via `ExtractousEx` NIF** + **MDEx** | PDF/Office/email, Tika bundled in Rust — **no JVM/sidecar**; markdown→AST |
| Native (Rust/C) NIF tier | Extractous/MDEx (parse) · Ortex (embed) | deliberate architectural layer; ANN moved into Postgres (pgvector) |
| API contract | **AshJsonApi** (JSON:API + auto OpenAPI) | versioned `/v1/…` |
| Consumer SDKs | TypeScript + Python, generated from OpenAPI | AshGraphql omitted in v1 |
| MCP | **`ash_ai` MCP server** | reads + `ingest` as tools; governance NOT on MCP |
| Surfaces / realtime | **Phoenix** (HTTP + LiveView + Channels) + `Phoenix.PubSub` | governance UI is LiveView; realtime via `Ash.Notifier.PubSub` |
| Auth (free) | **AshAuthentication** | password / API-key / magic-link; owns its tables |
| Auth (enterprise) | **ExSaml or Samly** (SAML SP) + **assent** (OIDC) + SCIM over Ash | SP+IdP-initiated, SLO, multi-IdP; SCIM 2.0 implemented on Ash |
| AuthZ | **Ash.Policy.Authorizer + field policies** | OpenFGA / SpiceDB as a future enterprise ReBAC adapter [13] |
| Multi-tenancy | **Ash multitenancy** `:context`(+RLS) → `manage_tenant` → per-Account Repo | account derived from identity only |
| Observability | **OpenTelemetry Elixir + `:telemetry` + Logger** | vendor-neutral OTLP; off-by-default single-node |
| Product telemetry | PostHog | anonymous opt-out (self-host) / identified (SaaS) |
| Blob (cloud) | **ExAws** S3-compatible (MinIO for self-host) / local FS | per-account namespaces |
| Secrets (enterprise) | Vault / KMS | CMK at volume level (FR-PLAT-15); optional field-level via Ash type/change |
| Licence | **ed25519-signed token verified in Elixir** + entitlement module | offline-verifiable; n8n-style |
| Testing | **ExUnit + Ecto sandbox + Testcontainers + `stream_data` + provider cassettes** | deterministic PR gate |
| Eval framework | in-repo `eval` app | hosts the EV spec; replays LongMemEval / LoCoMo / ConvoMem [10, 14, 11] |
| Packaging | **single Mix release**: no-container (release + pinned pg0, one command, zero deps) · container image + compose profiles (stock PG) · external PG; libcluster; Helm later | one release, mode via runtime config |

---

## 18. Open & deferred decisions

Resolved items are retained for decision history; unmarked items remain open.

- ✅ **RESOLVED — Job queue.** Now **Oban via AshOban** on the **Postgres engine in every mode** (ADR-0003 retired `Oban.Engines.Lite`); **Redis/BullMQ dropped**. One job system, one engine.
- ✅ **RESOLVED — Local storage tier (ADR-0003).** The SQLite tier and its in-memory HNSW index are retired. **AshPostgres + pgvector + PG-FTS everywhere**, with **pg0** as the pinned zero-dependency local Postgres. This supersedes the earlier "SQLite-tier vectors → `hnswlib`" resolution and closes the HNSW-persistence question below.
- ✅ **RESOLVED — Default self-hosted embedder.** Now **Qwen3-Embedding-0.6B through Ortex (ONNX Runtime)** at 1024 dimensions, behind `AshAi.EmbeddingModel`; Bumblebee+EXLA for GPU and a BYO-key API embedder remain supported (not licence-gated).
- ✅ **RESOLVED — Enterprise SSO library.** Now **ExSaml or Samly** for SAML SP + **assent** for OIDC (pick one SAML lib in the spike); free-tier auth is **AshAuthentication**. No hosted-auth dependency.
- ✅ **RESOLVED (path) — SSO/SCIM.** SCIM 2.0 is a **bounded build over Ash** (Users/Groups CRUD + filter), with OIDC-JIT provisioning as the early-customer fallback; scheduled for the paid milestone, no longer an architectural blocker.
- **ash_ai version pin & upgrade cadence** (v0.2.x is fast-moving; "lean in, isolate risk" — keep embedder + retrieval behind our own behaviours). *Set a pin + policy.*
- **RBAC Deny entries** — include explicit deny-wins ACEs for subtree exclusion (AD-SEC-3)? *Lean: yes; confirm.*
- **Free-licence middle-band features** — which otherwise-enterprise features the free registration unlocks (AD-CFG-5, AD-OBS-5). *TBD.*
- **Pricing unit** — seat / scope / account / flat (blueprint §17). *Open.*
- **`get_context` fan-out caps** — bound ancestor depth / cross-links to guarantee latency (NFR-3). *Deferred; revisit if measurements demand.*
- **Latency targets as gates** — the ~100ms set is currently a measured, revisable target (NFR-1); whether to harden any into a release gate later is open.
- **Durable-execution orchestration adapter** — Temporal / DBOS beyond Ash.Reactor + Oban (AD-PIPE-1). *Deferred; not adopted — Reactor + Oban suffice.*
- ✅ **RESOLVED — HNSW persistence policy** (was: snapshot cadence + boot-rebuild + reconcile-from-blobs tuning). Moot under ADR-0003: pgvector's index is transactional and durable, so there is nothing to snapshot or reconcile.
- **pg0 version pin + upgrade policy** (ADR-0003 conditions 1–2, AD-CFG-2, AD-PORT-1) — which pg0/PG version ships, the review + restore-test procedure for bumps, and who runs the export/import when a PG major changes under a self-hoster. *Set the pin and write the runbook; validated by the ADR-0003 spike.*
- **pg0 lifecycle ownership** (AD-DEPLOY-1) — release-supervised child vs operator-run `pg0 start`; behaviour on stale lock file, port conflict, half-initialised data directory, and ungraceful shutdown. *Resolve in the ADR-0003 spike.*
- **Re-measured single-node ceiling** (NFR-10) — the old ceiling came from limits that no longer exist; the new one is one machine's resources shared with a real Postgres. *Measure; do not inherit the old numbers.*
- **`ltree` vs materialized path** (AD-DATA-4) — the two-backend-parity reason for avoiding `ltree` is void. Materialized path stays the default unless ancestor-merge measurements say otherwise. *Benchmark-driven; low priority.*
- ✅ **RESOLVED — Reranker default (ADR-0004).** Rerank is **off by default** and on only in the `:thorough` profile, over the fused head. `:fast` and `:balanced` are fusion-only, so the `search` default remains rerank-free; `ask` gets the cross-encoder. Whether the cross-encoder is model-based or a cheaper score-fusion pass stays an implementation choice inside `AD-MODEL-1`'s `Reranker`.
- **Live/streaming migration** (AD-PORT-3). *Deferred; offline snapshot for v1.*
- **Carry-vectors fast path on import** when embedder matches (AD-PORT-3). *Deferred; rebuild for v1.*
- **Per-scope model-role overrides** (FR-API-18, FR §12). *Deferred; account-level for now.*
- **AshGraphql surface** for rich clients (AD-API-3). *Deferred; JSON:API + OpenAPI only in v1.*
- **ETS/`persistent_term` projection cache invalidation** in queue-mode (NFR-2, NFR-4) — cross-node invalidation via PubSub. *Confirm mechanics.*
- **Leader-election for scheduler HA** beyond Oban's built-in mechanism (AD-DEPLOY-4). *Deferred; Oban cron leader for now.*
- **Postgres sharding** for far-scale (NFR-10). *Deferred.*
- **Full sensitivity × assurance matrix** (AD-GOV-3). *Deferred; allowlist + floor for now.*
- **External vector-DB adapter** (eventual-consistency Oban path, AD-SEAM-4.4). *Deferred.*
- **Structured knowledge-graph layer + `Graph` retrieval strategy** (AD-SEAM-3, FR §12). *Deferred to ADR-0004 stage 4; the seam is reserved as a `Retrieval.Strategy` module.* Note the constraint that fixes the shape: triples must be derived **at dream-time from already-validated statements**, inheriting the parent statement's gate, because FR-KN-2's natural-language-statement-only rule exists so a human gates one statement rather than forty triples, and the graph must stay a derived cache under AINV-5. Write-time KG construction — what Hindsight does — is not available to a gated system. ***Amended by ADR-0006:*** ADR-0004's stage 4 is retargeted to the **entity graph and `EntityMatch`**, so this entry no longer has a stage attached and stays deferred without a date. The reason is evidence, not preference — Mem0 replaced external graph databases with graph-style entity linking and kept the multi-hop gain (+23.1 on their reported measure) [16], which suggests the traversal benefit stage 4 was reaching for is available at a fraction of the derived-structure cost. The `Graph` seam stays reserved; nothing forecloses it.
- **Peer merge / cross-session identity (ADR-0006, AD-SEC-2, FR-KN-18..22).** Entity resolution canonicalises *referents inside statements*; it does not merge **Peers**. Two Peer records that are the same human — a SAML identity and a personal login, or one person across two agent clients — stay two peers, so their attribution, corroboration counts (Gate B), and consent records stay separate. The field names this unsolved [16], and MemHouse's version is harder than the general case: **the merge would have to rewrite history it cannot rewrite.** The audit log is an append-only per-Account hash chain (AD-DATA-8), and corroboration leveling has already consumed the old peer ids, so retroactively collapsing two peers into one is not available. *Deferred, with the shape of the answer already constrained: any solution must be **forward-only aliasing** — a link asserting two peer ids denote one person, applied to future corroboration and consent, leaving prior ledger entries and levels exactly as they were recorded.* Whether that link is itself a governed decision is open, and it is a human-governance-semantics question, so it is human-only under ADR-0002.
- **Retrieval strategies and the licence boundary (ADR-0004, open — human-only under ADR-0002).** May expensive strategies (rerank, graph) be enterprise-gated? *Recommendation: no.* Gating retrieval quality breaks AINV-1's identical-guarantees directive in the place users notice most and undercuts the free-tier credibility ADR-0003 was largely about; gate scale, operations, governance, and support instead. Licensing boundaries are a human-only decision area, so this stays open for the maintainer.
- **Fusion-weight tuning policy (ADR-0004).** Weights `w_s` tuned against LongMemEval/LoCoMo will flatter those benchmarks. *Required: a held-out set that never informs tuning.* Open: how large, drawn from where, and how often rotated.
- **Retrieval profile versioning scheme (ADR-0004).** Profiles must be versioned for any quoted benchmark number to be reproducible. Open: version identity (semantic vs content hash of the strategy-set + weights + rerank flag), where it is surfaced in the API response, and the deprecation policy for retiring a profile version.
- ~~**Working title / product name.**~~ *Resolved: **MemHouse** (v1.0).*

---

## 19. References

Cited inline as `[n]`. The FR spec (§13) has the fuller bibliography; this list
contains references used by architecture decisions.

1. Rasmussen, P., Paliychuk, P., Beauvais, T., Ryan, J., Chalef, D. *Zep: A Temporal Knowledge Graph Architecture for Agent Memory.* 2025. arXiv:2501.13956. — bi-temporal edge dating and invalidation-not-deletion (Graphiti); the convergent precedent for AD-DATA-1.
2. Chhikara, P., Khant, D., Aryan, S., Singh, T., Yadav, D. *Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory.* ECAI 2025. arXiv:2504.19413. — two-phase extract/update pipeline; the production precedent for the fast lane (AD-PIPE-2).
3. Park, J. S., et al. *Generative Agents: Interactive Simulacra of Human Behavior.* UIST 2023. arXiv:2304.03442. — relevance × recency × importance retrieval scoring (NFR-2, FR-API-10).
4. Lin, K., Snell, C., Wang, Y., Packer, C., Wooders, S., Stoica, I., Gonzalez, J. E. *Sleep-time Compute: Beyond Inference Scaling at Test-time.* 2025. arXiv:2504.13171. — offline reasoning over persistent context cuts test-time compute ~5×; the quantitative case for the dream-time/serving split (§1, AD-PIPE-2).
5. Xu, W., et al. *A-MEM: Agentic Memory for LLM Agents.* 2025. arXiv:2502.12110. — memory evolution / dynamic link maintenance (the dream-time relation-upkeep step, AD-PIPE-1).
6. Sumers, T., Yao, S., Narasimhan, K., Griffiths, T. *Cognitive Architectures for Language Agents (CoALA).* TMLR 2024. arXiv:2309.02427. — the episodic/semantic/procedural/working taxonomy mapped in FR §1.
7. Packer, C., et al. *MemGPT: Towards LLMs as Operating Systems.* 2023. arXiv:2310.08560. — context paging and budget discipline (FR-API-10).
8. Zhong, W., et al. *MemoryBank: Enhancing Large Language Models with Long-Term Memory.* AAAI 2024. arXiv:2305.10250. — Ebbinghaus forgetting-curve decay (AD-DATA-2).
9. Zhang, Q., et al. *Agentic Context Engineering: Evolving Contexts for Self-Improving Language Models.* 2025. arXiv:2510.04618. — context collapse under monolithic rewriting; incremental delta updates (AD-PIPE-7).
10. Wu, D., et al. *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory.* ICLR 2025. arXiv:2410.10813. — replay target; abstention and knowledge-update abilities (AD-EVAL-3, AD-MODEL-3).
11. Pakhomov, E., et al. *ConvoMem Benchmark: Why Your First 150 Conversations Don't Need RAG.* 2025. arXiv:2511.10523. — replay target; the full-context baseline a memory system must beat (AD-EVAL-3).
12. Snodgrass, R. T. *Developing Time-Oriented Database Applications in SQL.* Morgan Kaufmann, 1999. — the bi-temporal valid-/transaction-time model (AD-DATA-1).
13. Pang, R., et al. *Zanzibar: Google's Consistent, Global Authorization System.* USENIX ATC 2019. — relationship-tuple authorization; the ReBAC adapter path (AD-SEC-3).
14. Maharana, A., et al. *Evaluating Very Long-Term Conversational Memory of LLM Agents (LoCoMo).* 2024. arXiv:2402.17753. — replay target (AD-EVAL-3).
15. Vectorize. *The Best AI Agent Memory Systems.* 2026. https://vectorize.io/articles/best-ai-agent-memory-systems — the Extract → Resolve → Store → Index ingestion shape and entity matching as a third retrieval signal (AD-DATA-10, AD-SEAM-3); the benchmark-insufficiency critique behind the engine-versus-product split (AD-EVAL-3).
16. Mem0. *State of AI Agent Memory 2026* and *Research.* 2026. https://mem0.ai/blog/state-of-ai-agent-memory-2026 · https://mem0.ai/research — graph-style entity linking replacing external graph DBs while keeping the multi-hop gain (§18, ADR-0006); token-efficiency figures (NFR-11); BEAM's large-corpus degradation curve (AD-EVAL-3); cross-session identity as an open field problem (§18).
