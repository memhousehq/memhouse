# ADR 0005: Peer inline validation over MCP

## Status

Accepted

## Context

Dream-time produces knowledge that needs a human answer: Gate A proposals about
a peer, items whose `revalidate-after` window has elapsed (`FR-GOV-10`), and
personal knowledge that cannot move to a shared scope without the peer's
consent (`FR-GOV-12`).

The only route to that human today is the LiveView governance console.
`FR-GOV-8` already routes peer-level knowledge to the peer "inline or auto",
and `FR-GOV-10` already specifies that revalidation is "surfaced inline by the
SDK in the peer's next relevant session" — but the MCP surface, which is how
the Phase-1 target user actually reaches MemHouse, has no way to carry that.
For an individual running MemHouse behind Claude Desktop, the console is a
second place they must remember to visit. The queue does not drain, confidence
decays, and stale items route to a curator who, in a single-peer deployment, is
the same person who never opened the console.

`FR-API-13` states that governance actions shall not be exposed on the MCP
surface. `ADR-0002` reserves "human governance semantics, including who may
approve knowledge, consent, or scope promotion" and "breaking API, SDK, MCP,
gateway, or storage behavior" as human-only decision areas. Delivering
validation questions over MCP and accepting answers touches both, so it
requires a recorded human decision rather than an inline FR edit.

Three protocol facts constrain any solution and were established before the
decision was taken:

- MCP spec 2026-07-28 (SEP-2260) makes it a **requirement**, not a
  recommendation, that server-initiated requests may only be issued while the
  server is actively processing a client request. SEP-2322 replaces the held
  reverse channel with a round-trip pattern. There is no primitive by which a
  server wakes a client and puts text in front of a user. Genuinely proactive
  delivery is not available and will not become available.
- `elicitation/create` is a developer-tool feature in practice. Claude Code and
  Cursor support it; Claude Desktop returns an immediate `cancelled` without
  rendering UI, and ChatGPT, Gemini CLI, and GitHub Copilot do not support it.
  The target audience for this capability is non-developers.
- ChatGPT consumer plans receive read-only custom connectors, and ChatGPT
  requires remote HTTPS with OAuth 2.1 and Dynamic Client Registration. This
  already blocks `ingest`, so a self-hosted MemHouse does not function there
  regardless of this decision.

The only mechanism present on every target host is content returned inside a
`tools/call` result.

## Decision

MemHouse shall deliver peer-level validation questions through the MCP surface
by attaching them to read-tool results, and shall accept answers through a
`resolve_validation` tool backed by a dream-time transcript check.

**A peer answering a question about knowledge whose subject is that same peer
is not a governance action for the purposes of `FR-API-13`.** It is
self-assertion, and it is the route `FR-GOV-8` and `FR-GOV-10` already
describe. `FR-API-13` is amended to say so explicitly.

The following remain off the MCP surface permanently:

- Curator gate decisions on any knowledge item.
- Scope confirmation and scope promotion (`FR-FORM-5`, Gate B).
- Any decision concerning knowledge whose subject is a peer other than the
  caller.
- Any widening of a peer's own ask-rate limits.

`FR-API-12` is unaffected: agents still never write knowledge or attribution
directly. A `reject` verdict retracts an existing item as a supersession; the
replacement fact travels through extraction and the gates like any other
observation. The tool can retract, never mint.

Because the MCP surface carries weaker channel assurance than an authenticated
console session, answers arriving over it are graded. An answer is **verified**
only when the frozen statement text is found verbatim in the ingested
transcript of that session. Unverified answers defer revalidation timers and do
nothing else — they do not raise confidence, and they never satisfy
`FR-GOV-12` consent, for which a verified answer or the console is required.

## Consequences

The peer-routed portion of the validation queue drains during ordinary use,
without the peer visiting a console. That is the difference between a
governance model that works for a single self-hosting individual and one that
quietly rots.

The cost is a governance concept on a surface that previously had none.
`FR-API-13` becomes a narrower rule that must be read carefully rather than a
blanket prohibition that could be checked mechanically, so future MCP additions
need to be tested against the boundary above rather than against a one-line
ban. The graded-answer model exists to keep that narrowing honest: the surface
gains the ability to answer, not the ability to be trusted unconditionally.

Delivery is model-discretionary. A host may show the question and never call
the tool, may paraphrase instead of quoting, or may drop it entirely. The
transcript backstop recovers the first case and detects the second, but no
guarantee of delivery is offered or should be claimed. Chat is a best-effort
channel layered over the console, never a replacement for it, and items that
relevance never matches still decay to a curator under `FR-GOV-10`.

`Attach` puts one governance read on the `get_context` hot path. It is
deadline-bounded and fails open — a timeout returns the read unchanged — so the
`FR-API-5` reasoning-free budget is preserved by construction rather than by
care.

Elicitation and the SEP-2322 round-trip pattern are deliberately not
implemented. If Claude Desktop ships elicitation, adopting it is an additive
change to the delivery layer that does not disturb this boundary.

## Anchors

- `AINV-6` - account and peer derived from identity, never from request
  parameters; the basis for `resolve_validation` scoping.
- `AD-PIPE-2` - fast lane vs dream-time slow lane; `Attach` is the one
  deadline-bounded governance read on the hot path.
- `AD-PIPE-6` - human-signal continuation seam; the peer answer is a second
  kind of decision event resuming a parked flow.
- `AD-PIPE-8` - answer correlation as a dream-time Reactor step.
- `AD-SEC-1` - the hard account wall.
- `AD-EVAL-1` - model provider layer as the determinism seam, used to stub the
  reasoner in the backstop tests.
- `FR-API-5` - `get_context` is reasoning-free; the budget `Attach` must not
  exceed.
- `FR-API-12` - agents submit observations only; unchanged by this ADR.
- `FR-API-13` - narrowed here.
- `FR-GOV-8` - validation routing by attribution target.
- `FR-GOV-10` - inline revalidation in the peer's next relevant session.
- `FR-GOV-12` - consent for upward attribution of personal knowledge.
- `FR-GOV-20` - immutable audit log; what the verbatim requirement protects.

## Related Documents

- `specs/adr/0002-l3-automation-boundary.md`
