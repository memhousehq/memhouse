<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Search and ask

`search` returns ranked evidence. `ask` writes a cited answer over that evidence
or abstains.

## search

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/search \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{
        "query": "who signs off on campaign copy",
        "scope_path": "/marketing/social",
        "profile": "balanced",
        "limit": 12
      }'
```

| Field | Default | Notes |
| --- | --- | --- |
| `query` | `""` | The search text. A full question works; `"phrase"`, `-term`, and `or` narrow it. |
| `scope_path` | `"/poc"` | Selects this scope **and its ancestors**. |
| `profile` | `"balanced"` | `fast`, `balanced`, or `thorough`. |
| `limit` | `12` | Candidate cap. |
| `include_cross_links` | off | Follow scope relations you are authorised for at both ends. |
| `as_of` | now | Read memory as it stood at a point in time. |
| `min_score` | none | Drop weakly fused candidates. |
| `source_filters` | none | Restrict by provenance kind. |
| `deadline` | profile default | `"disabled"` removes the time budget — offline use only. |

### Reading the response

```json
{
  "data": {
    "profile": "balanced",
    "profile_version": "f7-1",
    "candidates": [ ... ],
    "contributed_strategies": ["semantic", "lexical", "entity_match"],
    "empty_strategies": [],
    "dropped_strategies": ["temporal"],
    "disagreement": { "query_dependent_empty": false }
  }
}
```

- `candidates` is **already in the right order.** Do not re-sort by a
  per-strategy score: those scores live in different spaces and comparing them
  degrades results.
- `dropped_strategies` lists strategies that did not run: they missed the
  deadline or a dependency was unavailable. `semantic` appears here when the
  embedder failed. Frequent deadline drops mean the profile's budget is too
  tight for your data size.
- `retrieval_outcomes` gives each component's status, deterministic drop reason,
  elapsed time, and remaining budget. The reason is one of
  `disabled`, `deadline_exhausted_before_start`, `timeout`,
  `dependency_unavailable`, `provider_error`, or `invalid_result`. It contains
  no query or candidate text.
- `pre_rerank_remaining_ms` shows how much of the hard ceiling remained before
  reranking. Reranking receives the smaller of that value and
  `MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS`.
- `empty_strategies` lists strategies that ran and matched nothing. That is a
  result, not a failure — but a strategy in this list did not vote on the order.

!!! warning "Check the flag, not the page"
    `temporal` and `salience_recency` never read your query text, so they do not
    run for an ordinary text search: `temporal` needs an explicit `as_of`, and
    `salience_recency` only serves a blank-query context read. When
    `disagreement.query_dependent_empty` is `true`, none of the strategies that
    do read your text produced a candidate, and the search returns an empty
    page rather than the scope in recency order. A run in that state usually
    means embeddings or entity mentions have not been rebuilt for the scope
    yet.
- Account, scope authorisation, and lifecycle filtering already happened inside
  retrieval. You do not need to post-filter.

## ask

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/ask \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{
        "question": "Who signs off on campaign copy?",
        "scope_path": "/marketing/social"
      }'
```

`question` is required. All `search` parameters apply; `profile` defaults to
`thorough`.

The response is the search payload plus `answer`, `citations`, `abstained`, and
`answer_confidence`.

!!! tip "Read the confidence, not only the answer"
    `ask` does not refuse. It answers with what the retrieved statements make
    most probable and reports its certainty as `answer_confidence`, an integer
    from 0 to 100. Below 50 the response also sets `abstained`, which marks the
    answer as a lead rather than a conclusion. Both still carry citations, so
    you can check the reasoning yourself.

    An empty citation list with `abstained` means no statement survived to
    ground an answer on. That is a report about the index, not a guess about
    the subject. An answer invented from an empty candidate set is worse than
    silence, and much harder to notice.

Retrieval for `ask` is restricted to knowledge items, so every citation is a
governed statement rather than a raw message. Citation ids the model invented
or did not retrieve are removed; if none survive, the answer becomes the empty
abstention with `answer_confidence` 0.

## Choosing a profile

```mermaid
flowchart TD
    Q{What is this read for?}
    Q -->|"A user is waiting on an answer"| T["thorough — every strategy, reranked, 1500 ms"]
    Q -->|"Interactive search box"| B["balanced — four strategies, 300 ms"]
    Q -->|"Filling a context window"| F["fast — two strategies, 100 ms"]
```

Profiles inherit down the scope tree, nearest-wins, so a scope can be tuned
without a global change. See [Retrieval and context](../concepts/retrieval.md)
for the exact strategy sets and weights.

## Time travel with `as_of`

`as_of` reads past belief-time: what the system believed then, not what was true
then.

## What you will not find

Search and ask return no entity rows, names, aliases, surface forms, or ids.
These internal caches improve matching without affecting authorization
boundaries.

`get_context` is the one exception, and a narrow one: an entity card names
itself with a wording from its own scope. See
[Context](context.md#the-response).
