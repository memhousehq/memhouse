<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Assembling context

`POST /api/v1/context` assembles model-free scope context within a character
budget.

```bash
curl -fsS -X POST http://127.0.0.1:4000/api/v1/context \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{
        "scope_path": "/marketing/social",
        "session_id": "campaign-review-12",
        "budget_chars": 6000
      }'
```

| Field | Default | Notes |
| --- | --- | --- |
| `scope_path` | `"/poc"` | Selects this scope and its ancestors. |
| `session_id` | none | Picks the session summary to include. |
| `budget_chars` | unset | Caps the assembled size. |

## The response

```json
{
  "data": {
    "knowledge": [ ... ],
    "session_summary": { ... },
    "scope_cards": [ ... ],
    "entity_cards": [
      {
        "label": "billing service",
        "kind": "concept",
        "summary": "The billing service owns invoice generation and pages finance after failed settlement.",
        "summary_mode": "model",
        "sensitivity": "internal",
        "pinned_facts": [ ... ]
      }
    ],
    "peer_profile": { ... },
    "profile_version": "f7-1",
    "projection_cache_hit": true,
    "fast_fallback": false
  }
}
```

- **`knowledge`** — pinned facts from delivered projections, or ranked active
  statements from the fast fallback when no projection is available.
- **`session_summary`** — a bounded, grounded warm-start summary for this session.
- **`scope_cards`** — bounded summaries each ancestor scope contributes.
- **`entity_cards`** — short per-entity briefs built from at least two active
  governed statements in one scope, capped at eight per scope. The `label` and
  `kind` come from the card's own sources in its own scope. A summary needs
  three sources, so on a two-source card `summary` is `null` and `summary_mode`
  is `"none"`. If the summary model call fails, the rest of the card is still
  written with `summary_mode` `"unavailable"`, and a later rebuild retries the
  summary. Cards expose no entity ids, canonical names, or aliases.
- **`peer_profile`** — a bounded profile of active and provisional statements
  about the calling peer. Another peer's provisional statements are never included.
- **`pinned_facts`** — small source-linked excerpts that make a projection
  inspectable. Use search or a knowledge read for the complete source set.
- **`projection_cache_hit`** — a stored projection was reused.
- **`fast_fallback`** — the projection was missing, so the `fast` retrieval
  profile filled in live.

## Why this is not just a search

Profiles, scope cards, entity cards, and session summaries are cached
**projections** of governed knowledge, not another durable store. They contain
bounded summaries and pinned source excerpts, not raw knowledge rows. Summaries
are generated during background refresh; no model runs during this request.

Scope cards and session summaries are shared within their authorized scope, so
they contain active knowledge only. A provisional statement is visible through
the subject-keyed peer profile until a human decision settles it.

```mermaid
flowchart LR
    K[(Governed knowledge)] --> PR[Projection builder<br/>background job]
    PR --> C[(Projection cache)]
    C --> CTX[get_context assembly]
    K -. "marks dirty on change" .-> PR
    CTX --> R[Budgeted context payload]
```

No generation model runs on this path.

## Interpreting the diagnostic flags

| `projection_cache_hit` | `fast_fallback` | What it means |
| --- | --- | --- |
| `true` | `false` | Normal. Served from a warm projection. |
| `false` | `true` | The projection was missing; live retrieval covered it. Expect this right after ingest, an import, or an erasure. |
| `false` | `false` | Nothing to project yet — a new scope, or genuinely empty. |

Persistent `fast_fallback` means the `projection` job lane is not keeping up.
Check queue depth on `/api/ready`.

## Budgeting

`budget_chars` caps total assembled size. Assembly prefers the most relevant
governed knowledge and the nearest scope's cards, so a tighter budget loses the
most distant context first rather than truncating arbitrarily.

Leave room in the model window for the conversation and user question.

## When to use context versus search

| Use `context` | Use `search` |
| --- | --- |
| Priming an agent before a turn | Answering a specific question |
| "What should I know about this scope?" | "What do we know about X?" |
| Every turn, cheaply | On demand |
| No model call | May rerank with a model (`thorough`) |
