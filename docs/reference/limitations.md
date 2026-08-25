<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Limitations

MemHouse `0.4.0` is a community beta. These capabilities are unavailable.

The machine-readable inventory is
[`test/fixtures/eval/surface-contract-inventory.json`](https://github.com/memhousehq/memhouse/blob/main/test/fixtures/eval/surface-contract-inventory.json),
which marks these surfaces `unavailable`. Release checks reject contrary claims.

## Not implemented

**Generated AshJsonApi OpenAPI.** There is no published machine-readable
description of the HTTP surface. Use the [HTTP API reference](http-api.md).

**Complete generated TypeScript and Python clients.** The modules under `sdk/`
are transport-neutral skill-readiness helpers — no HTTP client, no
authentication, no retries, no pagination, and nothing published to npm or
PyPI. See [SDK helpers](../guides/sdk-helpers.md).

**The OpenAI-compatible and Anthropic-compatible gateway proxy.** You cannot
point an existing OpenAI client at MemHouse and have memory injected
transparently.

**The full grounded `ask` dialectic loop with in-loop citation verification.**
`ask` retrieves, answers, cites, and abstains — but the multi-turn dialectic
with citation verification inside the loop is not there.

**Connector administration and Account archive administration UIs.** Both are
driven from the command line. See [Mix tasks](mix-tasks.md). The
[web console](../guides/web-console.md) shows connector status and sync history
but cannot create, edit, or trigger one.

## What the web console does not do

**It does not edit gate rules or retrieval tunings.** Both change behaviour for
everyone in a scope, so the operations page shows what is in force and nothing
more; changing them is a database or code-level act today.

**It does not administer peers, roles, or API keys.** Role grants are listed on
the scope directory, but granting, revoking, and provisioning are Mix tasks.

**It has no bulk export.** Panels are capped at 50 rows and the explorer pages
25 at a time. A complete copy of an Account is the portability archive — see
[Export and import](../operations/portability.md).

**It never shows the entity cache.** Entity and mention rows span every scope
that mentioned a name, so no canonical name, alias, or entity identifier
appears in the console, including in the graph. That is a permanent design
rule, not a missing feature.

A graph hub may still be named. The name is a wording taken from the statements
in that hub's own scope, which the same panel already shows you, so it crosses
no boundary. Hubs whose statements resolved to more than one referent stay
unnamed. Account admins see aggregate resolution quality signals, and statement
detail links only co-mentioned statements the reader may already read.

**It shows no embedding vectors or chunk contents,** only their counts and
identities. They are rebuildable caches.

**Readiness checks are for yourself only.** Checking another peer's readiness
in the browser would disclose which knowledge exists about them in scopes you
may not hold; the JSON surface is where an agent checks its own peer.

## Evaluation evidence is deliberately small

Upstream-scale scores and independent live-model judge evidence do not exist.
Committed fixtures are smoke-scale; recorded reports are historical baselines,
not current performance claims.

Published quality numbers require application version, retrieval profile and
version, five model-role versions, dataset id/SHA-256/split, deadline, date,
judge, strategy override, and run limits.

## Operational gaps worth planning around

**Bootstrapping a packaged release** goes through `bin/memhouse rpc` rather
than a first-run wizard.

**Ortex embedding artefacts are operator-supplied.** The embedder downloads
nothing. Semantic retrieval requires the Qwen3 ONNX model and tokenizer.

**Single-node pg0 is unavailable on Windows, Intel macOS, and Linux musl.**
The pgvectorscale build supports the shipped pg0 path on glibc Linux
x86_64/ARM64 and Apple Silicon. Use external PostgreSQL or a container on the
unsupported platforms.

**No job pruning.** Nothing deletes rows from the Oban jobs table; plan for
that growth.

**Single Account.** The community build serves one Account. Multi-Account
isolation is an enterprise concern.

## What is *not* a limitation

These are deliberate designs, not gaps:

| Behaviour | Why it is intentional |
| --- | --- |
| `ask` abstains | An answer invented from an empty candidate set is worse than silence |
| Extracted knowledge is not immediately visible to everyone | Blast radius scales the bar; that is the product |
| Agents cannot approve their own submissions | The gates exist precisely to prevent this |
| Entity data is unreachable through every API | A resolution error must never cross a scope or Account boundary |
| No embedded alternative database engine | Every lane runs PostgreSQL, so no lane tests software nobody ships |

## Where the outstanding work is tracked

Current limitations are listed on this page. Scoped acceptance work is tracked
in the repository's [open GitHub issues](https://github.com/memhousehq/memhouse/issues).
Current behavior is verified by the suite under
[`test/`](https://github.com/memhousehq/memhouse/tree/main/test).
