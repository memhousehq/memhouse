<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# API stability policy

This policy covers the MemHouse public API: the REST API, the MCP tools, and the OpenAPI document
that describes them. It is requirement QUAL-09. In short: within a major version, nothing that a
correct client relies on is removed or changed. A breaking change needs a new major version, and
the previous major version keeps working for at least 12 months.

The current version is **v1** (`1.0.0`), frozen on 2026-11-02. Its contract is
[`api/openapi.json`](../api/openapi.json), served at `/v1/openapi.json`.

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
| `preview` | works and is tested, but may change in a minor release, announced in the release notes: `/v1/subjects`, `/v1/stats`, `/v1/audit`, `/v1/enrich/status`. They become stable, or are replaced by admin routes, with G06 and G20. |
| `deprecated` | still works exactly as before, with a successor; see below |

## Known changes inside v1

The roadmap already plans these. They are additive under the rules above, and they are written
here so clients are ready for them:

| When | Change | What a client should do now |
|---|---|---|
| G06 | API keys belong to principals; the authenticated principal sets `actor`, `tenant` and the default `scope`. A body naming another tenant is refused (`403`, a new code `forbidden`). | Send `tenant` only if you mean it; handle `403`. |
| G06 | Agent keys can be propose-only: their writes stay `candidate` until committed. | Don't assume `status: committed` after `remember`. |
| G10 | Admission becomes asynchronous: `remember` returns `status: candidate` and the record becomes `committed` or `rejected` shortly after. | Read the state with `GET /v1/memories/{id}` when it matters. |
| G11 | Scopes are resolved by precedence in ranking (user over team over org). | Nothing: the filter rule stays. |
| G30 | A gRPC binding of the same operations ([ADR 0008](adr/0008-grpc.md)). | Nothing. |

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
