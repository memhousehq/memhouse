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
| `POST /api/v1/source-search` | any identity | Governed source-message recall |
| `POST /api/v1/ask` | any identity | Cited answer |
| `POST /api/v1/lineage` | any identity | Bounded evidence lineage |
| `POST /api/v1/stable-profile` | any identity | Stable identity projection |
| `POST /api/v1/context` | any identity | Projection-backed context |
| `POST /api/v1/readiness` | any identity | Skill-readiness gap report |
| `GET /api/v1/knowledge` | any identity | Governed knowledge query |
| `GET /api/v1/operations/costs` | account-admin | Usage and estimated cost |
| `POST /api/v1/operations/reconcile` | account-admin | Enqueue an Account reconciliation sweep |
| `POST /api/v1/operations/ingest/:message_id/requeue` | account-admin | Explicitly requeue a repairable or terminal extraction anchor |
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

`governance` reports whether the process is unattended, how many open reviews
still require a person, and how many restricted proposals the unattended
policy withheld. These counts are disclosure and do not change the HTTP status.

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

`status` is `pending`, `failed`, `repairable`, `terminal`, or `completed`.
`repairable` requires an operator to correct configuration or approve a larger
context/chunking policy; `terminal` identifies source-specific poison after
bounded structured repair. `last_error_class` is a content-safe class, never a
provider message. Missing and unauthorised message ids both return the same
opaque **404**.

---

## `POST /api/v1/search`

All fields optional.

| Field | Default | Notes |
| --- | --- | --- |
| `query` | `""` | Terms match individually; `"phrase"`, `-term`, and `or` narrow. See [Retrieval and context](../concepts/retrieval.md) |
| `scope_path` | `"/poc"` | Selects the scope **and its ancestors** |
| `peer_key` | none | The peer the results are read for. A credential that names none reads as its own Peer when it has one, otherwise public statements only |
| `profile` | `"balanced"` | `fast`, `balanced`, `thorough` |
| `limit` | `12` | Candidate cap; clamped to `1` through `100` |
| `include_cross_links` | off | Requires authorisation at both endpoints |
| `as_of` | unset | Read memory as it stood then. This enables text-matched temporal ranking by distance from that time |
| `min_score` | none | Drops candidates below this score inside each strategy, before fusion |
| `source_filters` | none | |
| `deadline` | profile default | `"disabled"` removes the budget; offline only |
| `include_identity_profile` | off | Adds the stable identity projection for the selected reader without changing ranking |

`peer_key` names the peer the results are read **for**. It is trusted as
supplied, exactly as on ingest. Naming a reader borrows nothing from it: scope
authorisation stays the caller's. The named reader sees public and internal
statements, its own statements, statements about the scope rather than about a
person, and anything promoted to scope or account level. A password session or
machine credential that names no peer reads as its own Peer when the authenticated
actor has one. A peerless actor reads public statements only. A key naming no Peer
in the Account is an error, not an empty result. No request can ask to read the whole
corpus; that posture belongs to server-side work alone. See
[A read is performed for a peer](../concepts/retrieval.md#a-read-is-performed-for-a-peer).

Returns `{"data": result}` with the profile name, `profile_version` (`"f7-1"`),
the fused `candidates`, and three per-strategy outcomes:
`contributed_strategies` (returned candidates), `empty_strategies` (ran, matched
nothing), and `dropped_strategies` (disabled, timed out, or failed).
Each knowledge candidate carries `relevant_from` and `relevant_until` — the
window in which the claim is true. Both are nullable and require source
evidence, including for an event. Use them to date an answer; the statement text
alone may say "last weekend". Document-chunk candidates have no validity period
and omit the pair.

Each candidate also carries `strategies`, the names of the retrieval strategies
that returned it, and `fusion_score`, a value from 0 to 1. Fusion normalizes
scores inside each strategy list, combines 95% normalized score with a 5% rank
tie-break, applies profile weights, and divides by the weights of the strategies
that ran. The value is a ranking signal, not a probability or relevance
percentage. Do not compare it across profiles, apply a relevance threshold to
it, or re-sort the response. Use `min_score` to filter strategy-local scores
before fusion. `rrf_score` is a deprecated alias with the same value for this
contract version.

The additive `retrieval_outcomes` field reports component status, reason class,
elapsed milliseconds, and remaining budget without query or candidate content.
`reader_posture` reports `peer`, `public_only`, or `internal`, so an empty result
can identify the authorization posture. If lexical matches exist but reader
visibility removes them all, `retrieval_outcomes` adds the content-free
`candidate_filter` outcome with reason class `authorization_filtered`.
Inapplicable strategies report `not_applicable` with reason class `applicability`.
`pre_rerank_remaining_ms` reports the budget available before reranking, and
`reserved_rerank_ms` reports how much of the deadline was withheld from the
strategies to pay for it.

`degraded` is `true` when any component was dropped, or completed with a reason
class, and `degraded_components` names those components. Check it before
presenting results as relevance-ordered, and read the reranker's reason class to
know how much ordering was lost. A dropped or `invalid_result` reranker leaves
every candidate in fusion order; `partial_rankings` means the model
ordered the candidates it judged and only the rest kept fusion order.

`disagreement.query_dependent_empty` is `true` when no strategy that reads the
query text produced a candidate. A text search does not fill that gap with a
recency list, so `candidates` is usually empty in this state; treat the flag,
not the list length, as the signal.

Account, authorised-scope, lifecycle, and source filtering happen **inside**
retrieval. A raw `strategies` override is refused for external callers.
`identity_profile_status` is always present: `not_requested`, `ready`, `empty`,
or `unavailable`. When the profile is requested, `identity_profile` carries the
same response as the endpoint below. It is orientation, not an extra retrieval
candidate, and its statements remain citable only through their knowledge ids.

---

## `POST /api/v1/lineage`

`target_id` is required. `target_type` defaults to `knowledge` and may be
`knowledge`, `message`, or `document_version`.

| Field | Default | Bound |
| --- | --- | --- |
| `scope_path` | `"/poc"` | The scope and its ancestors; ordinary authorization still applies |
| `peer_key` | the calling peer | Same reader rule as search |
| `max_depth` | `3` | `0` through `8` |
| `max_fan_out` | `8` | `1` through `24` per node |
| `max_nodes` | `40` | `1` through `100` total |

The response is a deterministic breadth-first projection. Every node has a
stable `id`, `type`, integer `derivation_level`, `operation`,
`traversal_depth`, and typed `source_references`. Raw messages and document
versions are level zero; governed knowledge is level one or higher. A direct
message target is returned directly, without a synthetic reasoning node.

References are `visible`, `missing`, `lifecycle_hidden`, or
`authorization_hidden`. A hidden reference has no id or content. `terminations`
separates cycle, depth, fan-out, total-node, missing-source, lifecycle-hidden,
and authorization-hidden stops; `truncated` is true only for a budget stop. A
missing or unauthorized root returns the same opaque 404.

Lineage is evidence, not an audit log and not explanatory prose. It reads
provenance and typed knowledge relations. Audit records explain which governed
operation occurred and when. Neither surface exposes prompts, model rationale,
or chain-of-thought.

---

## `POST /api/v1/stable-profile`

All fields are optional. `scope_path` and `peer_key` follow search's reader
rules. The selected reader is also the profile subject; naming a peer never
borrows that peer's scope grants.

The profile is rebuilt on every read from visible active knowledge plus that
subject's own visible provisional knowledge. It is not a table, write path, or
model call. Eligible statements must be direct, source-backed facts in a small
taxonomy: name, pronouns, occupation, location, language, and time zone.
Transient state, preferences and behavioral generalizations, inferred claims,
and sensitive-trait statements are rejected.

Every item contains its `knowledge_id`, governed `statement`, category, conflict
fields, and bounded direct source references under `lineage`. Multiple distinct
claims in one category remain visible with the same deterministic
`conflict_group`; the projection never chooses a winner. The response is capped
at 16 items, four per category, 240 characters per statement, and 1,600 total
statement characters.

`projection_digest` identifies the selected canonical source set.
`diagnostic` reports only counts, exclusion classes, status, truncation, and
`model_calls: 0`; it contains no rejected text. Lifecycle transition, source
erasure, or subject/scope authorization changes affect the next read
immediately, so there is no stale-profile refresh window.

---

## `POST /api/v1/source-search`

Searches immutable source messages when governed knowledge is incomplete. It is
a read-only recovery surface: messages remain the sole source record and only
their full-text and vector indexes are derived and rebuildable.

| Field | Default | Notes |
| --- | --- | --- |
| `query` | `""` | Blank queries return an empty result without a provider call |
| `scope_path` | `"/poc"` | Selects the scope and its authorised ancestors |
| `mode` | `"semantic"` | `semantic` or model-free `exact` full-text search |
| `limit` | `12` | Clamped to `1` through `100` |
| `excerpt_chars` | `480` | Clamped to `80` through `2000` |
| `peer_key` | none | Uses the same reader and non-transferable-authority rule as search |
| `include_cross_links` | off | Both relation endpoints must be authorised |

Each result includes the stable message, session, scope, and speaker identities,
the source timestamp and role, a bounded excerpt, a strategy-local score, and a
deterministic rank. `status` is `ready`, `stale`, `empty`, `unavailable`, or
`failed`; `failure_class` is content-safe. The response deliberately has no
total corpus count. Account and scope filters run before ranking, so excerpts,
status, timing metadata, and result order cannot describe an unauthorised scope.

Semantic search compares only vectors with the configured provider, model,
version, and dimensions. `stale` means the authorised visible corpus mixes the
current identity with missing or older vectors. `unavailable` means visible
messages exist but none has a current vector. Provider failure writes nothing,
so a later rebuild can retry without losing the previous index. Erasing the
canonical message removes both full-text and vector hits in the same delete.

---

## `POST /api/v1/ask`

`question` is required; every `search` field is also accepted, including
`peer_key`, but `profile` defaults to `"thorough"`. Optional `effort` is
`low`, `medium`, or `high`; omission keeps fixed recall. A named effort runs the
bounded read-only recall planner over authorized knowledge and source-message
search. When the experimental minimal profile is enabled, effort-based Ask uses
it as the base pass unless the request explicitly selects another profile.

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
none reads as its own Peer when it has one; a peerless credential reads public
statements only. Scope cards and entity cards are shared
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

The sweep finds stale durable work whose job did not finish and re-enqueues its
replay-safe run. It ignores work younger than 5 minutes and processes at most
100 messages, document versions, connectors, and scopes per pass. The hourly
maintenance schedule runs the same bounded sweep.

Repairable and terminal extraction anchors are excluded from this automatic
replay. After correcting credentials, provider configuration, an oversized
input policy, or source-specific poison, an Account administrator explicitly
acknowledges the repair boundary with
`POST /api/v1/operations/ingest/:message_id/requeue`. It returns **202** with
the ordinary run-id response, or **409** when the anchor is not in a repairable
or terminal state.

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

Returns retained usage-event counts, API request and ingest counts,
input/output/embedding token totals overall and per model role, and an estimated
cost in USD computed from operator-supplied rates. `storage` separates durable
content bytes from operational row bytes, reports their ratio, and sets
`inverted?` when operational storage is larger. `logical_storage_bytes` remains
an alias for durable bytes. `operational_to_durable_ratio` is `null` when
durable storage is zero and operational storage is nonzero.
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
