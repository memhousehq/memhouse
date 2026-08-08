# Peer Inline Validation (PIV) — design

**Status:** design approved, pending implementation plan
**Date:** 2026-07-27
**Scope:** peer-level knowledge validation delivered through the MCP surface to
consumer chat hosts
**Depends on:** FR v1.0 (`FR-API-*`, `FR-GOV-*`), ARCH v1.0 (`AD-PIPE-*`,
`AD-EVAL-*`, `AINV-6`), ADR-0002, ADR-0004

---

## 1. Problem

Dream-time produces knowledge that needs a human answer: Gate A proposals about
a peer, items whose `revalidate-after` has elapsed (`FR-GOV-10`), and personal
knowledge that cannot move upward without the peer's consent (`FR-GOV-12`).

Today the only route to that human is the LiveView governance console. For the
Phase-1 target user — an individual running MemHouse behind Claude Desktop —
the console is a second place they must remember to visit. The queue does not
drain, confidence decays, and items route to a curator who, in a single-peer
deployment, is the same person who never opened the console.

The desired behaviour: while the peer is already in a chat session, the
assistant occasionally says *"I was reviewing our earlier conversations — is it
still true that you use SQLite for local dev?"*, and the answer flows back into
the gate.

## 2. Protocol constraints

These are findings, not choices. They eliminated most of the design space
before it was explored.

**No unprompted server push exists.** MCP spec 2026-07-28 (SEP-2260) makes it a
requirement, not a recommendation, that server-initiated requests may only be
issued while the server is actively processing a client request. SEP-2322
(Multi Round-Trip Requests) further replaces the held reverse channel: a server
returns `InputRequiredResult` carrying `inputRequests` plus opaque
`requestState`, and the client re-issues the original call with
`inputResponses`. There is no primitive by which a server wakes a client and
puts text in front of a user.

**Elicitation is a developer-tool feature.** Client coverage as of this design:

| Client | Spec coverage | Elicitation |
|---|---|---|
| Claude Code | 48% | yes |
| Cursor | 41% | yes |
| Claude.ai / Claude Desktop | 25% | no / unknown |
| ChatGPT | 13% | no / unknown |
| Gemini CLI | 13% | no / unknown |
| GitHub Copilot | 6% | no / unknown |

Claude Code shipped `elicitation/create` in 2.1.76. Claude Desktop returns an
immediate `cancelled` without rendering any UI. The target audience for this
feature is non-developers, so elicitation is not even worth building as
progressive enhancement.

**ChatGPT consumer plans get read-only custom connectors.** Write-capable
custom connectors require Business, Enterprise, or Edu. ChatGPT additionally
mandates remote HTTPS with OAuth 2.1 and Dynamic Client Registration — no
stdio, no localhost. This blocks `ingest` as well, so a self-hosted MemHouse
already cannot serve consumer ChatGPT. PIV does not make that worse and does
not attempt to work around it.

**Conclusion.** Everything must ride inside `tools/call` results. That is the
one capability every target host has.

## 3. Governance boundary

`FR-API-13` currently states that governance actions shall not be exposed on
the MCP surface. `ADR-0002` lists "human governance semantics, including who
may approve knowledge, consent, or scope promotion" and "breaking API, SDK,
MCP, gateway, or storage behavior" as human-only decision areas.

The boundary this design draws:

- **On the MCP surface** — a peer answering a question about knowledge whose
  *subject is that same peer*. This is self-assertion, and `FR-GOV-8` already
  routes peer-level knowledge to the peer "inline or auto", while `FR-GOV-10`
  already specifies inline surfacing "in the peer's next relevant session".
  PIV implements a route the FR spec already describes; it does not invent a
  new authority.
- **Never on the MCP surface** — curator gate decisions, scope confirmation,
  scope promotion, and any decision concerning another peer's knowledge. These
  remain console-only, permanently.

Because ADR-0002 reserves this call for a human, the boundary is recorded in
`specs/adr/0005-peer-inline-validation-over-mcp.md` rather than as an inline FR
edit.

## 4. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Scope is peer-level only | Keeps `FR-API-13` intact in substance; MCP token assurance is weaker than a console session and should not carry curator authority |
| D2 | Delivery rides in read-tool results; no elicitation | Only mechanism present on every target host |
| D3 | Answers captured by both a tool fast path and a dream-time transcript backstop | Tool call is model-discretionary; the transcript is captured anyway |
| D4 | Attachment is relevance-gated | `FR-GOV-10` says "next *relevant* session"; embeddings already exist so the check is a cosine, not a model call |
| D5 | Verbatim statement required, verified against the transcript | The audit log must record what the human actually saw, not a paraphrase |
| D6 | Default 3 questions per session, 10 per day, lowerable by the peer via MCP | Drains the queue at a useful rate while leaving the peer a way to turn it down without uninstalling |

## 5. Architecture

Nothing is pushed. Questions are parked by dream-time and ride out on the next
relevant read.

### 5.1 Domain resources (`MemHouse.Governance`)

**`PeerQuery`** — one pending question addressed to one peer.

| Field | Notes |
|---|---|
| `knowledge_id` | the item under question |
| `peer_id` | must be the knowledge item's subject |
| `kind` | `:confirm` (Gate A) \| `:revalidate` (FR-GOV-10) \| `:consent_upward` (FR-GOV-12) |
| `statement_text` | frozen verbatim copy at enqueue time |
| `embedding` | copied from the knowledge item; no new embedding call |
| `state` | `:pending \| :delivered \| :answered \| :expired \| :superseded` |
| `deadline_at` | drives FR-GOV-10 decay |
| `attempts` | capped; exhausted attempts decay to curator |

`statement_text` is frozen so that editing the knowledge item later cannot
retroactively change what the human was asked. A divergence between
`statement_text` and the live item marks the query `:superseded`.

**`PeerQueryDelivery`** — attempt ledger, and the rate-limit source of truth.

| Field | Notes |
|---|---|
| `peer_query_id`, `session_id` | unique together |
| `tool_name`, `delivered_at` | |
| `shown_text` | nullable; model self-report via `resolve_validation` |
| `verification` | `:pending \| :verified \| :unverified_channel` |
| `answered_at`, `verdict` | |

No separate counter table: rate limits are indexed counts over `delivered_at`
and `session_id`.

**`PeerAskPreference`** — `peer_id`, `max_per_session` (default 3),
`max_per_day` (default 10), `paused_until`. Writes over MCP are **clamp-only**:
values may move downward from the default, never upward. Raising a limit
requires the console.

### 5.2 Modules

| Module | Lane | Responsibility |
|---|---|---|
| `Governance.PeerQueue` | dream-time | Enqueue `PeerQuery` rows from Gate A peer-level proposals, `needs_revalidation` flips, and FR-GOV-12 consent needs |
| `Governance.Attach` | hot path | Select at most one query per read-tool result; rate gate then relevance gate |
| `Governance.Resolve` | hot path | `resolve_validation` handler |
| `Pipeline.Dream.AnswerCorrelation` | dream-time | Transcript backstop, verbatim verification, conflict detection, dedupe |

PIV introduces no second queue. The `FR-GOV-4` validation queue still holds the
knowledge; `PeerQuery` is a delivery ledger over the `FR-GOV-8` peer-routed
subset. Console and chat read the same underlying rows.

### 5.3 Hot-path budget

`Attach` is one pgvector round trip — the peer's pending set (tens of rows, not
thousands) ordered by cosine distance against the call's query vector, with a
similarity floor and `LIMIT 1` — plus two indexed counts for the rate gate.

It runs **after** the read result is assembled, under its own short deadline.
Any failure or timeout returns the read unchanged. A question is never allowed
to break a read or push `get_context` past its `FR-API-5` budget. This is the
only governance read on the hot path.

### 5.4 Tunables

Starting values, all runtime config. None are load-bearing on correctness —
they trade queue drainage against interruption.

| Knob | Default | Notes |
|---|---|---|
| `attach_deadline_ms` | 15 | Hard ceiling; exceeded means no question, read unaffected |
| `relevance_floor` | 0.62 cosine | Tune against a labelled set before launch; too low reads as a survey |
| `max_per_session` | 3 | Peer-lowerable via `set_ask_preference` |
| `max_per_day` | 10 | Peer-lowerable |
| `max_attempts` | 2 | Per `PeerQuery`; exhausted → decay to curator |
| `attempt_cooldown` | 48h | After an unanswered delivery, before the query is eligible again |
| `answer_window` | 6 turns | How far after `delivered_at` the transcript check looks |

## 6. Data flow

```
dream-time                      hot path (any peer session)
──────────                      ───────────────────────────
Gate A peer-level proposal ─┐
needs_revalidation flip    ─┼──> PeerQuery(pending)
FR-GOV-12 consent needed   ─┘         │
                                      │  peer calls get_context / ask /
                                      │  search / query_knowledge
                                      ▼
                              Attach: rate gate → cosine ≥ floor → LIMIT 1
                                      │
                                      ▼
                              PeerQueryDelivery(pending)
                              payload rides in tool result
                                      │
                        ┌─────────────┴─────────────┐
                        ▼                           ▼
              resolve_validation()          nothing (model dropped it)
              → verdict recorded            → transcript backstop
              → shown_text stored              at next dream-time
                        │                           │
                        └─────────────┬─────────────┘
                                      ▼
                    AnswerCorrelation: verbatim check in transcript
                      verified            → confidence raises, timer resets
                      unverified_channel  → timer defers only
                      no answer, past deadline → FR-GOV-10 decay → curator
```

## 7. Wire contract

The question is appended to the tool result as a sibling of the memory
payload, structurally separated so a model cannot confuse a question with a
fact.

```json
{
  "context": "...normal get_context payload...",
  "pending_validation": {
    "id": "pq_01JQ...",
    "kind": "revalidate",
    "statement": "Aleksei uses SQLite as the local dev database for MemHouse.",
    "asked_because": "This was recorded 4 months ago and is due for a check.",
    "instruction": "Before or after answering the user's request, mention that you were reviewing earlier conversations and ask whether this is still true. Quote the statement text exactly as given, in quotation marks — do not paraphrase it. Do not invent a statement. If the user answers, call resolve_validation with this id. If the user does not engage, drop it and do not repeat it."
  }
}
```

`statement` must be verbatim: it is the string the transcript check searches
for. `instruction` is server-fixed and never derived from stored content.

### 7.1 New tools

```
resolve_validation(
  id:              string,
  verdict:         "confirm" | "reject" | "unsure" | "skip",
  shown_text?:     string,
  correction_text?: string
)

set_ask_preference(
  max_per_session?: integer,
  max_per_day?:     integer,
  pause_for?:       duration
)
```

`set_ask_preference` is monotonically restrictive over MCP.

Verdict semantics:

| Verdict | Effect |
|---|---|
| `confirm` | Verified channel: confidence raises, revalidation timer resets. Unverified channel: timer defers only. |
| `reject` | Item retracted as a supersession per FR-GOV-10. The replacement fact, if any, arrives through normal ingest — not from this call. |
| `unsure` | Counts as reached. Timer defers, confidence unchanged, query closes. The peer genuinely does not know; re-asking will not help. |
| `skip` | Not reached. `attempts += 1`, cooldown applies, query stays pending. For "the user changed the subject", not for a real answer. |

### 7.2 Corrections do not shortcut the gate

`correction_text` is never written as knowledge. A `reject` retracts the
original as a supersession per `FR-GOV-10`; the user's actual correction is
already in the transcript and passes through extraction, proposal, and the
gates like any other observation. The tool can retract, never mint.

### 7.3 Kind-specific rules

- `:consent_upward` — an `unverified_channel` answer is never sufficient.
  `FR-GOV-12` consent requires a verified answer or the console. Deferring a
  timer on weak evidence is a soft call; recording consent is not.
- `:confirm` and `:revalidate` — degrade per §8.

## 8. Verification and failure modes

### 8.1 Verbatim check

Normalize both sides — NFKC, casefold, collapse whitespace, strip surrounding
quote glyphs — then substring match. The search window is the turns in that
session after `delivered_at`.

- Statement found in an **assistant** turn → channel verified; the following
  **user** turn is the answer.
- Statement absent → `unverified_channel`, regardless of what the tool claimed.

### 8.2 Transcript wins over tool call

`resolve_validation` is a claim; the transcript is evidence. If the tool
reports `confirm` but the following user turn reads as a rejection, correlation
flags the delivery for curator review and does not apply the confirm.

The same rule provides dedupe: one `PeerQueryDelivery` per
`(peer_query_id, session_id)`, and correlation is idempotent — it only fills
fields the tool left blank.

### 8.3 Backstop-only path

If the model showed the question but never called the tool, correlation finds
the verbatim statement, reads the next user turn, and classifies
confirm/reject/unsure with the dream-time reasoner. The channel is verified, so
this path counts fully.

### 8.4 Failure modes

| Failure | Behaviour |
|---|---|
| `Attach` slow or errors | Read returns unchanged, no question. Logged, never surfaced. |
| Host never calls `resolve_validation` | Backstop path; full credit if verbatim found |
| Host never ingests turns | No verification possible; item runs out the FR-GOV-10 clock to a curator |
| Model paraphrases instead of quoting | `unverified_channel`; timer defers, confidence unchanged, item stays pending |
| Model shows question, user ignores it | Cooldown, `attempts += 1`, re-eligible later; capped, then decay |
| Knowledge edited or superseded after delivery | `PeerQuery` → `:superseded`; late answers discarded |
| Same item offered in two concurrent sessions | Unique index on `(peer_query_id, session_id)`; `Attach` excludes queries with a live unanswered delivery |
| Relevance never matches | Item decays per FR-GOV-10 and routes to a curator. Chat is best-effort, never the only channel. |

## 9. Security

- `resolve_validation(id)` resolves only within the calling peer's own rows,
  with the peer derived from identity per `AINV-6` and never from a request
  parameter. A foreign or unknown id returns not-found rather than forbidden,
  so the surface cannot be used to probe for existence. IDs are ULIDs.
- Only knowledge whose **subject is the calling peer** is eligible for
  `Attach`. Scope knowledge, other peers' knowledge, and curator queues never
  enter the selector.
- `set_ask_preference` cannot amplify. An attacker holding the peer's MCP token
  can silence questions — equivalent to uninstalling — but cannot increase
  question volume.
- `statement_text` is echoed into model context, so a hostile statement could
  carry injection text. This is not a new surface: the same statements already
  flow through `get_context`. Mitigation is that statements render as delimited
  data and the `instruction` field is server-fixed.
- Rate caps are abuse control as well as a UX budget.

## 10. Spec and ADR changes

New ADR: `specs/adr/0005-peer-inline-validation-over-mcp.md`, recording the §3
boundary. Required because ADR-0002 reserves governance semantics and breaking
MCP behaviour for a human decision.

| Anchor | Change |
|---|---|
| `FR-API-13` | Narrow "governance actions" to curator gate decisions, scope confirmation, and decisions about other peers; carve out peer self-validation |
| `FR-GOV-8` | Concretize "inline" for peer routing — MCP delivery, not SDK-only |
| `FR-GOV-10` | Inline surfacing delivered over MCP as well as SDK |
| `FR-API-30` (new) | Read tools may carry at most one pending peer validation; attachment never affects the reasoning-free guarantee; on failure the read returns unchanged |
| `FR-API-31` (new) | `resolve_validation` and `set_ask_preference`; preference writes clamp-only |
| `FR-GOV-22` (new) | Channel assurance: unverified-channel answers defer revalidation timers only, never raise confidence, never satisfy FR-GOV-12 consent |

FR ids are append-only per the FR spec's own rule, so these take the next free
numbers in their areas. `FR-API-27/28/29` are already held by ADR-0004
(retrieval profiles, deadline-bounding, disagreement-as-abstention), so the new
API requirements start at 30.

ARCH additions: `AD-PIPE-8` (answer correlation as a dream-time Reactor step)
and a note on `AD-PIPE-2` that `Attach` is the single deadline-bounded
governance read on the hot path.

## 11. Testing

Per `AD-EVAL-2` (pyramid), `AD-EVAL-1` (provider layer as determinism seam),
`AD-EVAL-4` (injected `Clock`).

- **Unit** — normalizer against quote glyphs, NFKC forms, and whitespace
  variants; rate-gate boundaries (third attaches, fourth does not; day rollover
  via injected clock); clamp-only preference rejects upward writes; relevance
  floor.
- **Property** — caps never exceeded across randomized delivery schedules;
  `Attach` never selects a query whose subject is not the caller; correlation
  is idempotent under replay.
- **Integration** — fake MCP client, stubbed provider, three loops end to end:
  tool fast path, transcript backstop, no-answer decay to curator.
- **Conflict** — tool claims `confirm` while the transcript shows rejection →
  flagged for curator, confirm not applied.
- **Concurrency** — same query offered in two sessions → unique index holds,
  one delivery survives.
- **Latency** — `get_context` p95 delta within budget with `Attach` enabled;
  the deadline is actually enforced under an artificially slow database.
- **Injection** — a statement containing instruction-shaped text stays
  delimited and leaves `instruction` unaltered.

## 12. Out of scope

- Elicitation and MRTR support. Revisit if Claude Desktop ships elicitation.
- Curator queue drainage over chat. Requires a channel-assurance model for MCP
  tokens; a later ADR at most.
- Consumer ChatGPT. Read-only custom connectors block `ingest`, so MemHouse
  as a whole does not function there.
- Out-of-band nudges (email, Slack). Orthogonal channel, separate design.
