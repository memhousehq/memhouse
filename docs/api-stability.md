<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# API stability policy

This policy covers the MemHouse public API: the REST API, the MCP tools, and the OpenAPI document
that describes them. It is requirement QUAL-09. In short: within a major version, nothing that a
correct client relies on is removed or changed. A breaking change needs a new major version, and
the previous major version keeps working for at least 12 months.

The current version is **v1**, `1.8.0`. v1 was frozen on 2026-11-02 (`1.0.0`); 1.1 added
principals, agent tokens, `/v1/whoami`, `/v1/tokens`, `/v1/review`, `/v1/labels` and the
`forbidden` error code; 1.2 added `recall_id`, `/v1/recalls/{id}/explanation` and `/metrics`
(preview); 1.3 added the policy operations under `/v1/policies`; 1.4 made admission asynchronous
(`remember`, `revise` and `ingest` answer once the write is queued, `wait` to answer after the gate)
and added `include_candidates`, `exact`, `degraded`, `statement`, `route`, `queued` and the
`unavailable` error code; 1.5 added memory types (`taxonomic`, `POST /v1/promote`,
`GET /v1/subjects/{subject}/preferences`, `/v1/grants`, `working` on a hit, `scope` in
`/v1/whoami`, the `overridden` exclusion reason and the `grant:manage` permission); 1.6 added
`render_format`, the `duplicate` exclusion reason, `features` on an explanation's returned records
and the ranking fields of a compiled policy; 1.7 added `write_gate.corrections` to a policy spec
and its compiled form; 1.8 added `language` to a record and `language.enabled` to a policy spec
(`languages` in its compiled form). Its contract is [`api/openapi.json`](../api/openapi.json), served at
`/v1/openapi.json`.

## Versions

| Part | Where it shows | Changes when |
|---|---|---|
| Major (`v1`) | the URL prefix `/v1/`; MCP tool names | something breaks (see below); the old prefix keeps working side by side |
| Minor (`1.1.0`) | `info.version`, `GET /health` → `api_version` | something is added |
| Patch (`1.0.1`) | the same | documentation or a fix that brings behaviour back in line with the document |

The API version is separate from the server version (`version` in `/health`). A server release
may change neither, either or both.

## What a minor release may do

- add an operation, a route or an MCP tool;
- add an optional request field, query parameter or header;
- add a response field, an enum value (a new memory kind, a new lifecycle state) or an error code;
- relax a limit (a longer maximum, a wider range);
- mark something deprecated, with a successor.

So a client must:

- ignore response fields it doesn't know;
- treat an enum value it doesn't know as "other", and not fail on it;
- treat an error code it doesn't know like its HTTP status;
- never depend on the order of fields, on message texts, or on the format of ids and cursors
  (they are opaque).

## What only a new major version may do

- remove or rename an operation, route, field, parameter, enum value, error code or MCP tool;
- add a required field or parameter, or make an optional one required;
- change a field's type or meaning, a default value, or the status code of an outcome;
- tighten a limit that valid requests could hit;
- change the response of a deprecated route.

Behaviour that isn't in the document but that clients can observe is kept within a major version
when practical. For example: a write without an idempotency key is still deduplicated by content.

## Stable and preview

Each operation in the OpenAPI document has `x-stability`:

| Value | Meaning |
|---|---|
| `stable` | covered by this policy: `remember`, `recall`, `revise`, `forget`, `ingest`, get and list memories, `/health`, `/v1/openapi.json`, and the MCP tools of the same names |
| `preview` | works and is tested, but may change in a minor release, announced in the release notes: `/v1/subjects`, `/v1/stats`, `/v1/audit`, `/v1/enrich/status`, `/metrics` (its metric names follow the Prometheus conventions and are listed in [operations.md](operations.md#traces-metrics-and-recall-explanations)). They become stable, or are replaced by admin routes, with G06 and G20. |
| `deprecated` | still works exactly as before, with a successor; see below |

## Known changes inside v1

The roadmap already plans these. They are additive under the rules above, except where a row
names a recorded exception, and they are written here so clients are ready for them:

| When | Change | What a client should do now |
|---|---|---|
| G06 (done, 1.1) | API keys belong to principals; the authenticated principal sets the actor, `tenant` and the scope filter. A body naming another tenant or user is refused (`403 forbidden`). | Send `tenant` and `user` only if you mean them; handle `403`. |
| G06 (done, 1.1) | Agents' writes are proposals: committed by the engine at once by default, or `candidate` until reviewed with `admission = "review"`. | Don't assume `status: committed` after `remember`. |
| G10 (done, 1.4) | Admission is asynchronous: `remember` returns `status: candidate` and the record becomes `committed`, `quarantined` or `rejected` shortly after, or stays `candidate` (a plan or speculation). | Read the state with `GET /v1/memories/{id}` when it matters, or send `wait: true`. Retry `503 unavailable` with the same `request_key`. |
| G11 (1.5) | `working` memory written with `scope.session` is session-local: a recall or a list returns it only when it names that session. Records of other types scoped to a session are returned as before, also to a request that names no session. | Send `scope.session` on the recalls that should see a session's working memory. Reads by id are unchanged. |
| G37 (next major version) | Strict scope inheritance at the session level: a request that names no session returns no session-scoped record of any type. | Nothing in v1. |
| G11 (1.5) | An agent's `working` memory is scoped to that agent; other agents read it only with a grant. | Create a grant (`POST /v1/grants`) where agents share a scratchpad. |
| G11 (1.5) | `procedural` memory proposed by an agent without a commit grant stays `candidate` until reviewed, also with `admission = "auto"`. `working` memory is committed without the statement gate and without review. | Review procedural proposals (`POST /v1/review`), or give the agent a commit grant. |
| G11 (1.5) | A keyed preference (`structured.record_type = "preference"` with `attrs.key`) supersedes the same key in the same scope, and recall returns the one at the narrowest scope (user over team over org). A write deduplicates only against records of its own scope. | Nothing. |
| G12 (1.6) | `token_budget` is a hard cap: the first hit is no longer returned when it alone exceeds the budget, and the `rendered` block counts against it too ([recorded exception](#recorded-exception-the-token-budget-is-a-hard-cap-16)). | Send a budget that fits at least one memory, and handle an empty `hits`. |
| G12 (1.6) | Recall leaves out near-duplicates of a better-ranked hit (cosine 0.97 or text overlap 0.9 by default); they are listed in the explanation as `duplicate`. | Nothing; a policy with `[ranking] dedup = false` returns them. |
| G13 (1.7) | Approving a policy version answers `409 conflict` when the tenant has evaluation suites and the version degrades them past the limits of `[eval]`; the version stays `proposed`. Tenants without suites are unaffected ([recorded exception](#recorded-exception-the-regression-gate-on-policy-approval-17)). | Read the report in the error message; fix the policy or the suite. |
| G36 (1.8) | A record carries `language`, the language its text was detected as. With `[language] enabled = ["en"]` (the default) nothing else changes: statements, questions and injection attempts are read as before. | Nothing; enable more languages in `[language]` ([languages.md](languages.md)). |
| G30 | A gRPC binding of the same operations ([ADR 0008](adr/0008-grpc.md)). | Nothing. |

### Recorded exception: session working memory (1.5)

One change in 1.5 is not additive, and is recorded here as an exception to the rule that a
behaviour change needs a new major version. It was approved by the maintainer on 12 November
2026, during the review of G11.

- **What changed.** Before 1.5, a recall or list that named no session also returned records
  written with `scope.session`, of every type. From 1.5 it no longer returns `working` memory
  written with `scope.session`. Records of every other type are returned as before.
- **Who is affected.** A non-admin client that wrote `working` memory with `scope.session` and
  read it back without naming the session. Admin callers and reads by id are unchanged.
- **Why it was allowed inside v1.** Before 1.5, `working` memory had no session behaviour of its
  own beyond its expiry: making it a session's scratchpad is what the type is for (the schema
  document announced it for G11), and a scratchpad that leaks into other sessions' recalls is a
  defect of that feature, not a contract worth a major version. The same change for the other
  types would have altered what clients store durably and read back, so it was not made: it is
  planned for the next major version (G37, in the table above).
- **What a client does.** Send `"scope": {"session": "…"}` on the recalls that should see a
  session's working memory.

### Recorded exception: the token budget is a hard cap (1.6)

- **What changed.** Before 1.6, `token_budget` stopped adding hits once the budget was reached
  but always returned the first hit, even when it alone was larger than the budget, and the
  `rendered` block was not counted. From 1.6 neither the returned content nor the block exceeds
  the budget: a memory that doesn't fit is left out (smaller ones below it may still be
  returned), and a budget smaller than every candidate returns no hits.
- **Who is affected.** A client that sent a budget smaller than its top memory and relied on
  getting that memory anyway, or that sent a budget and pasted `rendered`, which could be larger
  than the budget.
- **Why it was allowed inside v1.** The budget exists so that a caller can size a prompt; a cap
  that the response may exceed can't be relied on for that, which is what requirement PERF-06
  asks for (no response over its budget). The maintainer set this as the goal of G12 ("treat the
  token budget as a hard cap", 13 November 2026). The field's type and default are unchanged.
- **What a client does.** Send a budget that fits at least one memory, and treat an empty `hits`
  with a budget as "nothing fits", not as "nothing known".

### Recorded exception: the regression gate on policy approval (1.7)

- **What changed.** `POST /v1/policies/{version}/approve` is a stable operation. Before 1.7 it
  approved and activated any proposed version that compiled. From 1.7, for a tenant that has
  stored evaluation suites, the version's suites are replayed first, and a version that
  degrades them past the `[eval]` limits is refused with `409 conflict`; it stays `proposed`.
  The `409` status already existed for this operation (a version approved twice); what is new
  is that a valid, compiling version can be refused. An approval also takes as long as the
  replays do.
- **Who is affected.** A client that approves policies for a tenant whose operator has stored
  suites with `memhouse eval add`. No tenant has suites until someone adds them, so no existing
  deployment changes behaviour on upgrade; a tenant without suites approves exactly as before,
  and `[eval] gate = false` turns the gate off.
- **Why it was allowed inside v1.** The gate is requirement QUAL-05: a policy change that
  degrades the tenant's own suites must not be promoted. It only acts once the tenant's operator
  has opted in by storing a suite. The maintainer set it as the goal of G13 ("the regression
  gate that blocks a policy, model or engine change that degrades them", 13 November 2026).
- **What a client does.** Treat `409` from an approval as "not approved", read the report in the
  message, and allow for a slower answer when the tenant has suites.

No other exception has been made. The compatibility check below compares shapes, not this kind
of behaviour, so behaviour changes are reviewed against this section by hand.

## Deprecation

A deprecated route, field or tool:

- keeps working unchanged for **at least 12 months** after the deprecation date, and within the
  same major version until the next one;
- is marked `deprecated: true` in the OpenAPI document, with `x-successor` and `x-sunset`;
- answers with `Deprecation` (RFC 9745), `Sunset` (RFC 8594) and `Link: <successor>;
  rel="successor-version"` headers, so client logs show it;
- is listed in the table below and in the release notes.

| Deprecated | Successor | Deprecated on | Removed no earlier than |
|---|---|---|---|
| `POST /v1/memories` | `POST /v1/remember` | 2026-11-02 | 2027-11-02 |
| `GET /v1/memories` | `GET /v1/subjects/{subject}/memories` | 2026-11-02 | 2027-11-02 |
| `PATCH /v1/memories/{id}` | `POST /v1/revise` | 2026-11-02 | 2027-11-02 |
| `DELETE /v1/memories/{id}` | `POST /v1/forget` (`id`) | 2026-11-02 | 2027-11-02 |
| `DELETE /v1/subjects/{subject}` | `POST /v1/forget` (`subject`) | 2026-11-02 | 2027-11-02 |
| MCP `memory_recall`, `memory_remember`, `memory_update`, `memory_forget`, `memory_log_conversation`, `memory_list` | `recall`, `remember`, `revise`, `forget`, `ingest`, `list_memories` | 2026-11-02 | 2027-11-02 |
| `x-memhouse-actor` header, the bodies' `actor` field | ignored since 1.1: the authenticated principal is the actor | 2026-11-02 | 2027-11-02 |

The pre-v1 routes predate this policy. They keep their old responses. Only two things about them
changed when v1 was frozen: a malformed body or path gives a JSON `400` instead of a plain-text
`422`, and revising an already superseded version is a `409` instead of a silent fork. The
[API reference](api.md#deprecated-routes-and-tool-names) covers this.

## A new major version

When v2 comes:

- `/v2/` is served next to `/v1/` by the same server, and both appear in the OpenAPI documents
  (`/v1/openapi.json`, `/v2/openapi.json`);
- v1 keeps working for at least 12 months after v2's first release, with security fixes;
- a migration guide lists every change, with the v1 call and its v2 equivalent.

## How it is enforced

- **The document is generated from the types.** The request and response types in
  `memhouse-core` derive their JSON Schema, and `memhouse-server` builds the OpenAPI document from
  them (`openapi::spec`). `api/openapi.json` is that output, and a test fails when it is out of
  date. Regenerate it with `MEMHOUSE_WRITE_OPENAPI=1 cargo test -p memhouse-server openapi`.
- **Breaking changes fail the build.** `api/baseline/openapi-1.0.0.json` is the document as
  released. The test `no_breaking_change_since_baseline` compares the current document with it
  and fails on every change in the second list above: a removed operation, parameter, schema,
  property or enum value; a new required field; a type or reference change. Each release of a
  minor version adds its own baseline.
- **Behaviour matches the document.** The governance check `api_contract` starts a real server on
  a scratch database. It calls every documented operation with valid and invalid payloads, and
  validates every response against the document's schema for that status. It checks the MCP tools
  against the same schemas, and the deprecation headers. `api_idempotency`, `revise_history` and
  `forget_scopes` check the semantics behind CORE-04, CORE-05 and CORE-06. All four run in every
  benchmark guard ([roadmap §3](roadmap.md#3-the-benchmark-guard)).
