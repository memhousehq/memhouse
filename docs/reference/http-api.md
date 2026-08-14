<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# HTTP API reference

Domain actions return `{"data": ...}`; probes return unwrapped JSON; refusals
return `{"error": "..."}`. Every response includes `x-trace-id`.

There is **no generated OpenAPI description** in this release — see
[Limitations](limitations.md).

## Route table

| Route | Auth | Purpose |
| --- | --- | --- |
| `GET /api/health` | none | Liveness and contract identity |
| `GET /api/ready` | none | Component readiness |
| `POST /api/auth/password` | none | Human sign-in |
| `POST /api/v1/ingest` | any identity | Submit a raw observation |
| `GET /api/v1/ingest/:message_id` | any identity | Read extraction status and visible results |
| `POST /api/v1/search` | any identity | Ranked retrieval |
| `POST /api/v1/ask` | any identity | Cited answer |
| `POST /api/v1/context` | any identity | Projection-backed context |
| `POST /api/v1/readiness` | any identity | Skill-readiness gap report |
| `GET /api/v1/knowledge` | any identity | Governed knowledge query |
| `GET /api/v1/operations/costs` | account-admin | Usage and estimated cost |
| `POST /api/v1/operations/reconcile` | account-admin | Enqueue an Account reconciliation sweep |
| `POST /api/v1/operations/dream` | account-admin | Enqueue an immediate Account dream-time pass |
| `GET /api/v1/self/knowledge` | human only | Your own record |
| `POST /api/v1/self/knowledge/:id/contest` | human only | Dispute a statement about you |
| `POST /api/v1/self/knowledge/:id/redact` | human only | Withdraw a statement about you |
| `POST /api/v1/self/erasure` | human only | Erase your data |
| `/mcp` | any identity | Model Context Protocol endpoint |

"Any identity" means a human password token **or** an agent API key. "Human
only" rejects an API key with 403 even when it belongs to the same peer.

### Browser routes

Browser routes serve HTML/LiveView and use a signed session cookie plus CSRF.
Both sign-in forms create the same role-limited session.

| Route | Auth | Purpose |
| --- | --- | --- |
| `GET /` | none | Redirects to `/console` |
| `GET`, `POST /sign-in` | none | Console sign-in for any human role |
| `DELETE /sign-out` | session | Ends the browser session |
| `/console` | any human session | Overview dashboard |
| `/console/knowledge` | any human session | Knowledge explorer, filters and retrieval preview |
| `/console/knowledge/:id` | any human session | One statement: evidence, history, readable co-mention links, available actions |
| `/console/scopes` | any human session | Scope directory, relations, role grants |
| `/console/graph` | any human session | One scope drawn as a graph; `scope` selects it, `descendants=1` adds its subtree |
| `/console/sources` | any human session | Documents, versions, connectors, observations |
| `/console/skills` | any human session | Skill cards and a readiness check |
| `/console/tools` | any human session | Forms for every MCP tool and the latest result payload |
| `/console/me` | any human session | Statements about you, consent, erasure |
| `/console/operations` | account-admin | Readiness, usage, entity-resolution aggregates, gate rules, retrieval tunings |
| `/governance/sign-in` | none | Curator sign-in |
| `/governance` | human curator session | Gate queue and skill-card authoring |

Agent API keys cannot open browser sessions. See
[Exploring memory in the web console](../guides/web-console.md).

**Account is never selected by the request.** An `account_key` body field and
the legacy `x-memhouse-account-key` header are accepted and ignored.

---

## `GET /api/health`

Liveness. Touches no database and no queue.

```json
{"status": "ok", "app": "memhouse", "version": "f5-1"}
```

`version` identifies the extraction-and-pipeline contract, not the application
version.

---

## `GET /api/ready`

Readiness. Runs database, Oban, queue-depth, lifecycle-sweep, model-role,
model-call, and embedding-index checks. **200** only when every component reports `ok`,
otherwise **503**.

The body is the whole check map: per-component status, queue depths by queue
and job state, an error class per failing component, the last completed expiry
and revalidation sweep (`"never"` before the first completion), and `"f10-1"` — the
readiness payload shape identity.

`checks.embedding_index` includes only the configured embedder provider,
model, version, configured dimensions, and installed index dimensions. A
configured width without a matching installed index reports `error`.

`checks.model_calls` is informational. It reports the prior 24 hours of model
attempts, failures, failure rate, unmetered failures, and content-safe error
classes. Provider failures do not change readiness because durable jobs retry.
An unmetered failure returned no token usage, so its cost is unknown.

The payload contains no credentials, secrets, or stored content.

---

## `POST /api/auth/password`

```json
{"email": "admin@example.test", "password": "..."}
```

Returns a short-lived bearer token. A wrong email and a wrong password produce
the same opaque 401.

---

## `POST /api/v1/ingest`

Records one raw observation. The only write path an agent has.

| Field | Required | Default | Notes |
| --- | --- | --- | --- |
| `session_id` | yes | — | Created on demand |
| `scope_path` | yes | — | Created on demand |
| `content` | yes | — | The observation text |
| `peer_key` | no | the calling peer, when one exists | Who spoke the turn. The Peer is created on first use. Internal callers without a peer must provide this explicitly |
| `peer_name` | no | the key | Display name, used only when that Peer is created |
| `role` | no | `"user"` | Speaker role |
| `occurred_at` | no | now | ISO 8601, for backfill. No offset means UTC; an unparseable value falls back to now |

Returns **202** after the raw observation and extraction job commit:

```json
{"data":{"message_id":"c479dd01-36a8-4f27-964e-27d425534b18","status":"accepted"}}
```

The request never calls a model or returns knowledge. Extraction always runs in
the durable `ingest` job lane.

Three paths decide who the turn is attributed to:

- A **machine credential** — an API key or an internal system identity — may
  relay a conversation it was not part of. A `peer_key` in the body attributes
  the turn to that named speaker.
- A **password session** always speaks as itself. A `peer_key` in the body is
  ignored, so nobody can post under another person's name.
- An **internal caller** carries no peer of its own and must supply `peer_key`.

The named key is trusted as supplied. Per-peer authentication is not implemented
yet, so a machine credential can attribute an observation to any Peer in its
Account.

Relaying transfers no authority. The write keeps the calling credential's own
roles and authorised scopes, so naming a Peer with wider grants cannot widen
what the request may write. An existing Peer is resolved rather than rewritten.
See [Who a turn is attributed to](../concepts/ingest-pipeline.md#who-a-turn-is-attributed-to)
and [Recording observations](../guides/ingesting-observations.md).

A missing required field raises, which surfaces as an error status rather than
a partially written session.

---

## `GET /api/v1/ingest/:message_id`

Reads the extraction state of an observation the caller may access. Pending and
failed responses carry an empty `knowledge` list. A completed response includes
only governed knowledge visible to that caller.

```json
{
  "data": {
    "message_id": "c479dd01-36a8-4f27-964e-27d425534b18",
    "status": "pending",
    "extraction_completed_at": null,
    "knowledge": [],
    "last_error_class": null,
    "attempt_count": 0
  }
}
```

`status` is `pending`, `failed`, or `completed`. `last_error_class` is a
content-safe exception class, never a provider message. Missing and unauthorised
message ids both return the same opaque **404**.

---

## `POST /api/v1/search`

All fields optional.

| Field | Default | Notes |
| --- | --- | --- |
| `query` | `""` | Terms match individually; `"phrase"`, `-term`, and `or` narrow. See [Retrieval and context](../concepts/retrieval.md) |
| `scope_path` | `"/poc"` | Selects the scope **and its ancestors** |
| `peer_key` | none | The peer the results are read for. A machine credential that names none reads **public statements only** |
| `profile` | `"balanced"` | `fast`, `balanced`, `thorough` |
| `limit` | `12` | Candidate cap |
| `include_cross_links` | off | Requires authorisation at both endpoints |
| `as_of` | unset | Read memory as it stood then. Omitting it also turns the `temporal` strategy off, so a point-in-time question must send it |
| `min_score` | none | |
| `source_filters` | none | |
| `deadline` | profile default | `"disabled"` removes the budget; offline only |

`peer_key` names the peer the results are read **for**. It is trusted as
supplied, exactly as on ingest. Naming a reader borrows nothing from it: scope
authorisation stays the caller's. The named reader sees public and internal
statements, its own statements, statements about the scope rather than about a
person, and anything promoted to scope or account level. A password session that
names no peer reads as itself. A key naming no Peer in the Account is an error,
not an empty result. No request can ask to read the whole corpus; that posture
belongs to server-side work alone. See
[A read is performed for a peer](../concepts/retrieval.md#a-read-is-performed-for-a-peer).

Returns `{"data": result}` with the profile name, `profile_version` (`"f7-1"`),
the fused `candidates`, and three per-strategy outcomes:
`contributed_strategies` (returned candidates), `empty_strategies` (ran, matched
nothing), and `dropped_strategies` (disabled, timed out, or failed).
Each knowledge candidate carries `relevant_from` and `relevant_until` — the
window in which the claim is true, both nullable, and both populated for a
statement of kind `event`. Use them to date an answer; the statement text alone
may say "last weekend". Document-chunk candidates have no validity period and
omit the pair.

The additive `retrieval_outcomes` field reports component status, reason class,
elapsed milliseconds, and remaining budget without query or candidate content.
`pre_rerank_remaining_ms` reports the budget available before reranking, and
`reserved_rerank_ms` reports how much of the deadline was withheld from the
strategies to pay for it.

`degraded` is `true` when any component was dropped, or completed with a reason
class, and `degraded_components` names those components. Check it before
presenting results as relevance-ordered, and read the reranker's reason class to
know how much ordering was lost. A dropped or `invalid_result` reranker leaves
every candidate in reciprocal-rank order; `partial_rankings` means the model
ordered the candidates it judged and only the rest kept fusion order.

`disagreement.query_dependent_empty` is `true` when no strategy that reads the
query text produced a candidate. A text search does not fill that gap with a
recency list, so `candidates` is usually empty in this state; treat the flag,
not the list length, as the signal.

Account, authorised-scope, lifecycle, and source filtering happen **inside**
retrieval. A raw `strategies` override is refused for external callers.

---

## `POST /api/v1/ask`

`question` is required; every `search` field is also accepted, including
`peer_key`, but `profile` defaults to `"thorough"`.

Returns the search payload merged with `answer`, `citations`, `abstained`,
`answer_confidence`, `answer_degraded`, `answer_context_count`, and
`answerer_prompt_tokens`. Retrieval is restricted to
knowledge items, so citations are governed statements. `abstained: true` is an
ordinary outcome.

The search payload keeps all returned candidates. The answerer sees only the
first `MEMHOUSE_ANSWER_CONTEXT_LIMIT` candidates after reranking. It also sees
each statement's validity window and an explicit reference time. `as_of` is the
reference time when supplied; otherwise the request time is used.

`answer_context_count` is the number of candidates sent to the answerer.
`answerer_prompt_tokens` is the provider-reported input-token count across the
initial call and any structured-output repairs. It is `null` when the answer
model call fails and `0` when no answer model ran. The durable usage ledger
still records metered failed attempts.

`answer_degraded` and `degraded` answer different questions. The first is about
the answering model call; the second is about the retrieval that fed it. An
answer can be soundly reasoned over a candidate list the reranker never ordered,
and that shows only in `degraded`.

`answer_confidence` is an integer from 0 to 100. For a model answer it is the
model's own probability that the answer is correct. The model always answers:
it states what the retrieved statements make most probable instead of refusing,
and a weak answer arrives with a low `answer_confidence` rather than as a
refusal. A model answer below 50 sets `abstained: true` whatever the model
claimed.

| `citations` | `abstained` | `answer_confidence` | `answer_degraded` | Meaning |
| --- | --- | --- | --- | --- |
| non-empty | `false` | 50-100 | `null` | The cited statements support the answer well enough to act on. |
| non-empty | `true` | 0-49 | `null` | The cited statements make the answer the most probable one, but weakly. Read it as a lead. |
| empty | `true` | 0 | `null` | No retrieved statement survived to ground an answer on. |
| non-empty | `false` | 40 | `null` | The deployment has no model configured; `answer` is the top retrieved statements, concatenated. |
| non-empty | `true` | 0 | a failure class | The model call failed. `answer` states that, not a conclusion; the retrieved statements are in `supporting_statements`. |

`answer_degraded` is `null` unless the model call itself failed — a transport
or provider error, or exhausted structured-output repair. When it is set,
`answer` is a fixed statement that the call failed, never the retrieved
statements presented as a conclusion; `supporting_statements` carries those
statements as plain text, separately from `answer` and from `citations`.
Failure classes match the `error_class` values the usage ledger records, for
example `provider_upstream_error`, `missing_structured_object`, and
`structured_validation_failed`.

Citation ids not present in the retrieved candidates are removed before the
response is returned. If none survive, the response uses the empty abstention
regardless of what the model claimed, and `answer` reports that no statements
were retrieved.

A missing `question` raises rather than answering over an empty query.

---

## `POST /api/v1/context`

| Field | Default |
| --- | --- |
| `scope_path` | `"/poc"` |
| `peer_key` | none |
| `session_id` | none |
| `budget_chars` | unset |

`peer_key` names the peer the context is assembled for, on the
[same terms as `search`](#post-apiv1search): a machine credential that names
none gets public statements only. Scope cards and entity cards are shared
projections and carry shareable statements only, so a personal peer-level
statement never appears in one.

Returns `{"data": context}` with `knowledge`, `session_summary`, `scope_cards`,
`entity_cards`, `peer_profile`, `profile_version`, and two diagnostics:
`projection_cache_hit` and `fast_fallback`.

Each projection contains a bounded `summary`, its `summary_mode` and
`summary_provenance`, and small `pinned_facts` with a source id and statement
excerpt. A dated excerpt includes a date-only valid-time suffix rendered from
its structured fields. The complete source set remains internal. Each entity card also
contains a `label`, a `kind`, and the strictest source `sensitivity`.

A card requires at least two active source statements in one scope. A summary
requires three: below that, `summary` and `summary_provenance` are `null` and
`summary_mode` is `"none"`. A summary the model failed to produce reads the same
way with `summary_mode` `"unavailable"`, and a later rebuild retries it. Treat
all three fields as optional.

`label` is a surface form taken from that card's own sources in that card's own
scope, and `kind` is one of `person`, `org`, `system`, or `concept`, recomputed
from the same forms. Either may be `null`. Entity ids, canonical names, and
aliases are never returned, and no surface form from another scope is returned.

At most eight cards are returned per scope, ordered by source count. Cards are
spent against the character budget before individual statements.

No generation model is ever called on this path.

---

## `POST /api/v1/readiness`

| Field | Required | Notes |
| --- | --- | --- |
| `skill` | yes | |
| `scope_path` | yes | Requirement keys inherit, nearest-scope wins |
| `peer_id` / `peer_key` | no | Another peer you may read; defaults to the caller |

Returns `{"data": report}` with `report_version` (`"f9-1"`), the resolved
skill/peer/scope, a per-requirement `requirements` list, and unsatisfied items
split into `blockers` and `warnings`. `ready` is true exactly when there are no
blockers.

---

## `POST /api/v1/operations/reconcile`

Account administrators can enqueue a reconciliation sweep without submitting a
new observation. The Account comes from the credential. The response is **202**:

```json
{"data":{"run_id":"e303e6b4-686c-4dc6-b076-29d6addcb3fd","status":"accepted"}}
```

The sweep finds durable observations whose extraction did not finish and
re-enqueues their replay-safe work.

---

## `POST /api/v1/operations/dream`

Account administrators can enqueue an immediate Account-wide dream-time pass.
The Account comes from the credential. The response is **202** with the same
`run_id` and `accepted` status shape as reconciliation. The pass remains an
ordinary durable pipeline run and obeys the configured dream-time budget.

---

## `GET /api/v1/knowledge`

Query parameters:

| Parameter | Default |
| --- | --- |
| `scope_path` | `"/poc"` |
| `peer_key` | none |
| `state` | `"active"` |
| `limit` | `12` |

Covers the named scope plus its ancestors, ordered by confidence then recency,
each row annotated with the `scope_path` it lives at. `peer_key` selects the
reader on the [same terms as `search`](#post-apiv1search).

Read-only by design: there is deliberately no POST counterpart.

---

## `GET /api/v1/operations/costs`

Account-admin only; any other role gets 403.

Returns exact usage-event counts, API request and ingest counts,
input/output/embedding token totals overall and per model role, logical storage
bytes, and an estimated cost in USD computed from operator-supplied rates.
`ingest_economics` reports extractor calls, tokens, and estimated cost per
ingested message over the full retained ledger. Call counts include failed
extractor calls. An unmetered failure has unknown token usage and cost, so it
contributes only to `calls_per_message`.

---

## Self-governance routes

Human password identity only. The subject is always the authenticated caller.

| Route | Effect |
| --- | --- |
| `GET /api/v1/self/knowledge` | Your record, newest first, including `provisional` and `held` items |
| `POST /api/v1/self/knowledge/:id/contest` | Moves to contested; queues curator review with a 24-hour deadline |
| `POST /api/v1/self/knowledge/:id/redact` | Moves to redacted; no review queued |
| `POST /api/v1/self/erasure` | Body `{"mode": "proportionate" \| "strict"}` |

Erasure answers only with the request's id, mode, and state. An unknown id and
another peer's id are deliberately indistinguishable.

---

## `/mcp`

Model Context Protocol, protocol revision `2025-03-26`, same bearer
authentication. Eight tools: `ingest`, `get_context`, `search`, `ask`,
`query_knowledge`, `check_readiness`, `resolve_validation`,
`set_ask_preference`.

No curator tool exists. See [Connecting an MCP client](../guides/mcp.md).

---

## Errors

Authorization, missing-parameter, and not-found failures propagate to Phoenix,
which returns an error status and generic body, never 200 with an empty result.
