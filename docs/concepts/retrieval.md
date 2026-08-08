<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Retrieval and context

MemHouse runs independent candidate generators in parallel, fuses their ranks,
and may rerank the fused head under one wall-clock deadline.

```mermaid
flowchart LR
    Q[Query + scope + profile] --> F{Fan out<br/>under a deadline}
    F --> S1[Semantic<br/>pgvector ANN]
    F --> S2[Lexical<br/>PostgreSQL FTS]
    F --> S3[Temporal]
    F --> S4[SalienceRecency]
    F --> S5[EntityMatch]
    S1 & S2 & S3 & S4 & S5 --> EX[RelationExpand<br/>one hop]
    EX --> RRF[Weighted reciprocal-rank fusion]
    RRF --> RR{Rerank?}
    RR -->|thorough profile| M[Model-backed rerank<br/>of the fused head]
    RR -->|otherwise| OUT
    M --> OUT[Ranked candidates<br/>+ contributed, empty, and dropped strategies]
```

## Filtering happens before candidates leave retrieval

Each strategy applies Account, scope, lifecycle, provisional-subject, and source
filters **inside its query**. The API does not post-filter candidates.

## How the lexical strategy reads your query

Plain text matches statements sharing **any** of its terms, ranked by how many
of them a statement covers and how closely together. Ask a full question: it
does not need every content word to appear in one statement.

For English questions, the lexical analyzer (`lexical-question-v2`) removes a
small reviewed set of interrogative boilerplate. It keeps the remaining query
terms, names, dates, negation, and quoted text. It does not expand terms with a
hand-written synonym list. A statement that also places two of your terms
within eight words of each other earns a bounded bonus, so a
sentence that answers the question outranks one that merely mentions the same
words. Only the highest-ranked matches compete for that bonus; a statement far
down the list cannot be promoted by it. The analyzer version appears in the
content-free operator diagnostic, so a ranking can be reproduced without
recording query text.

Three operators override that, following PostgreSQL `websearch` syntax.

| Syntax | Meaning |
| --- | --- |
| `"exact phrase"` | Only statements containing that phrase, in order |
| `-term` | Excludes statements containing the term |
| `a or b` | Either term |

Using any of them switches the whole query to `websearch` parsing, where bare
terms must **all** appear in one statement.

## Why fusion, and why you must not re-sort

Each strategy scores in its own space: cosine distance, full-text rank, time
relevance, salience, mention confidence. Those numbers are **not comparable**.

Fusion merges ranks, not scores. A candidate at rank `r` contributes
`weight / (k + r)`, with the baseline-compatible `k = 60`.

!!! warning "The returned order is the answer"
    Re-sorting the returned candidates by a raw per-strategy score compares
    numbers from different scoring spaces and silently degrades results.

Strategy disagreement is computed *before* fusion, so it measures what the
strategies actually thought rather than an artefact of the merge. Fusion always
emits a ranked list, including from lists that are all bad, so a fused rank
cannot say "nothing was found".

## Three per-strategy outcomes

A response separates strategies that **contributed** candidates, strategies that
ran and found **nothing**, and strategies that were **dropped** — disabled,
timed out, or failed. Collapsing the middle case into either of the others hides
the run worth knowing about: `temporal` and `salience_recency` read no query
text, so applicability must keep them from turning a text-search miss into a
recency page.
`disagreement.query_dependent_empty` is the flag for exactly that state.

For ordinary text searches, Temporal runs only when you pass `as_of`, and
SalienceRecency does not add a general recency list. That keeps the visible
head based on evidence about the question. Blank context fallback may still
use salience-recency, and explicit historical reads retain temporal recall.

## Profiles

A profile is a named, versioned bundle: which strategies run, their fusion
weights, whether the head is reranked, and the deadline.

| Profile | Strategies | Rerank | Deadline | Used by |
| --- | --- | --- | --- | --- |
| `fast` | semantic, salience-recency | no | 100 ms | The only profile allowed to run live when context assembly misses its projection cache |
| `balanced` | semantic, lexical, temporal, entity-match | no | 300 ms | Default for `search` |
| `thorough` | all six, including one-hop relation expansion | yes | 1500 ms | Default for `ask` |

Profiles inherit down the scope tree, nearest-wins, so a scope can tighten or
loosen retrieval without a global change. The profile version travels back with
every result as `profile_version`.

`deadline_ms` covers strategy execution and reranking. Late strategies are
dropped, not retried, and reported. Larger deadlines trade latency for recall.

An operator-level allowlist can switch off an expensive strategy across the
whole deployment: a strategy absent from it never runs, whatever a profile
asks for.

Raw per-request strategy overrides are internal and evaluation-only; external
callers cannot select strategies directly.

## Entities are internal

Dream-time entity resolution links aliases such as "Dana", "Dana R.", and
"our copy lead" across validated statements.

Entity rows and mentions are **rebuildable, pipeline-internal caches**. The
rows themselves reach no surface: no canonical name, alias, or entity id
appears in HTTP, MCP, SDK, LiveView, projection, or retrieval output.

One exception, and it is bounded by scope. An entity card may name itself with
a wording drawn from that card's own source statements in that card's own
scope, and may report a `kind` recomputed from the same wordings. Both are text
the card already returns, so neither carries a name across a scope boundary.
The entity row is not read to produce them.

Resolution errors affect accuracy, never scope or Account authorization.
Erasure and archive import rebuild entities from surviving governed statements.

### Rebuilding a scope holds no database connection while it works

Rebuilds use the ingest pipeline's
[read → model → write](ingest-pipeline.md#the-model-call-holds-no-database-connection)
shape. Model calls hold no database connection. The final transaction replaces
old mentions and writes rebuilt ones together, so failure leaves the previous
index intact.

## Cross-scope expansion is authorised twice

Scope relations and shared-entity edges can expand retrieval into a linked
scope — but only after **both** endpoint scopes pass the caller's
authorisation. A cross-link never grants access; it only follows access the
caller already has.

## Vectors carry an identity

An embedding is stored with its provider, model, version, and dimensions. Those
four values together are the vector-space identity.

```mermaid
flowchart LR
    Q[Query embedding<br/>provider · model · version · dims] --> C{Identity matches<br/>the stored vectors?}
    C -->|yes| U[Use them]
    C -->|no| RE[Explicit re-embed path]
    RE --> U
```

A mismatch never silently substitutes or reuses vectors — the numbers are only
comparable within one pinned identity. Bump the embedding version whenever the
model artefact, tokenizer, pooling, or dimensions change.

## Context assembly is reasoning-free

`get_context` is a different operation from `search`. It assembles a budgeted
context payload — governed knowledge, a session summary, scope cards, and a
peer profile — from **projections**, and it never calls a generation model.

```mermaid
flowchart LR
    R[POST /api/v1/context] --> P{Projection cached?}
    P -->|hit| A[Assemble within the character budget]
    P -->|miss| F["Fast profile runs live<br/>(fast_fallback = true)"]
    F --> A
    A --> O["Payload + projection_cache_hit + fast_fallback"]
```

Two diagnostic flags come back with every response: `projection_cache_hit` says
a stored projection was reused, and `fast_fallback` says the projection was
missing and the fastest retrieval profile filled in live.

Projection updates preserve dirty marking, bounded delta compaction, source ids,
and PubSub/ETS invalidation. A model call does not belong on this read path.

## Ask answers with a confidence

`ask` retrieves with the `thorough` profile, restricts retrieval to knowledge
items so that citations are governed statements, and answers over what it
found. It does not refuse: it states what the retrieved statements make most
probable and reports `answer_confidence`, an integer from 0 to 100, for its own
certainty.

A model answer below 50 also sets `abstained`. That pair — cited answer, low
confidence, `abstained == true` — is the normal shape for a weakly supported
inference. Treat it as a lead to check rather than a conclusion to act on.

One reply is not an attempt at the question: when no retrieved statement
survives, the response is an empty citation list, `abstained == true`, and
`answer_confidence` 0. That reports the state of the index, not the subject. An
answer invented from an empty candidate set would be worse than silence. Every
model citation is intersected with the retrieved candidate ids before the
response leaves the server, and no surviving citation means that empty
abstention wins.
