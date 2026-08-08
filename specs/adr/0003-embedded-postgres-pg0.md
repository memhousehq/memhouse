# ADR 0003: Embedded Postgres (pg0) replaces the SQLite tier

## Status

Accepted, conditional on the validation spike defined below. The SQLite tier
stays in the specs as historical context but is no longer the target design; it
is removed from the codebase only once the spike passes.

This ADR changes deployment-mode parity and storage behavior, which ADR 0002
lists as human-only decision areas. The decision was taken by the maintainer.

## Context

The free tier was specified as SQLite via AshSqlite, with an in-memory
`hnswlib` index over an embedding BLOB column, SQLite FTS5 for lexical search,
and `Oban.Engines.Lite` for jobs. The enterprise tier was Postgres via
AshPostgres, with pgvector, PG-FTS, and the Oban Postgres engine. One codebase,
two data layers.

That split was chosen to keep the local footprint small. It bought a real cost:
two of everything on the storage seam. Two data layers and two sets of
migration fragments (`AD-DATA-9`). A vector path that is a transactional index
on one backend and a rebuildable in-memory cache with a boot reconciler on the
other (`AD-SEAM-4.1`, `AD-SEAM-4.4`, `AD-DATA-5`). Two lexical engines with
different tokenisation and ranking (`AD-SEAM-2`). Two Oban engines
(`AD-PIPE-1`). A contract suite that has to run twice (`AD-EVAL-2`). And a free
tier that structurally could not have row-level security, because SQLite has no
RLS (`AD-DATA-6`).

The prime directive — one codebase, two deployment modes, identical guarantees
(`AINV-1`) — was therefore true in intent and approximately true in fact.
Retrieval quality, tokenisation, and index durability all differed by tier.

The requirement that changes the calculus is the local on-ramp: setup must be a
single command with zero dependencies, **including no Docker**. That rules out
"just put Postgres in the compose file", which was the obvious way to delete the
second backend.

`vectorize-io/pg0` resolves the conflict. It is an MIT-licensed single
self-contained binary that bundles PostgreSQL 18 with pgvector 0.8.1, runs fully
offline with no system dependencies and no container runtime, and starts with
`pg0 start`. It supports macOS (Apple Silicon and Intel), Linux Debian/Ubuntu
(x86_64 and ARM64), Linux Alpine 3.20–3.21, and Windows x64. Data lives under
`~/.pg0/instances/<name>/`. Hindsight, the closest comparable system, uses it
for exactly this purpose.

Two constraints on pg0 are load-bearing and are handled in the decision below:
it is positioned for local development, testing, and CI rather than production;
and it documents no in-place major-version upgrade path.

PGlite was evaluated and rejected. It runs Postgres in single-user mode over a
single connection, which is incompatible with a Phoenix connection pool plus
concurrent Oban workers, and it has no mature Elixir path.

## Decision

**Postgres is the only data layer.** AshPostgres serves every deployment mode.
AshSqlite, `hnswlib`, FTS5, and `Oban.Engines.Lite` are removed from the
architecture.

**pg0 is how Postgres gets onto a laptop, and nothing more.** It is a process
launcher and a packaging choice. Ash, Ecto, Oban, and every migration see an
ordinary PostgreSQL server over an ordinary connection. Pointing the same
release at an externally managed Postgres is a connection-string change and
remains the always-available escape hatch. No domain code, no resource
definition, and no migration is aware that pg0 exists.

**The deployment modes still differ, but only in where Postgres runs and
whether clustering is on:**

- Single-node (free): one BEAM node, one pg0-supervised Postgres on the same
  machine, Oban Postgres engine, local-FS blobs, clustering off.
- Queue-mode (enterprise): the same release on N clustered nodes against an
  operator-run Postgres, S3 blobs, libcluster on.

Three conditions attach to the decision:

1. **Pin the pg0 version** in the release and in CI. pg0's changelog includes
   recent data-loss fixes; floating the version is not acceptable for a
   component that holds the system of record on a self-hoster's laptop. Version
   bumps are a reviewed change with a restore test.

2. **The logical account export (`AD-PORT-1`) is the supported
   Postgres-major-version upgrade path**, and must be tested as such: export
   from major N, fresh `initdb` on major N+1, import, verify. Embeddings are
   rebuilt on import (`AD-PORT-3`), so no vector-format coupling crosses the
   boundary. This turns pg0's missing upgrade path from a blocker into an
   already-required capability.

3. **Container images use stock Postgres, not pg0.** pg0 refuses to run as root
   and fails in root-only containers. The compose path and any Kubernetes
   deployment use a normal Postgres image; pg0 is the no-container on-ramp.

**Validation spike, required before removing the SQLite tier from the
codebase.** The spike must show, on macOS ARM64 and Linux x86_64 at minimum:
`pg0 start` to a usable connection in acceptable time from a cold install; the
full Ash migration set applying, including pgvector, RLS, and PG-FTS; the
release supervising pg0's lifecycle cleanly, including restart after an
ungraceful shutdown with no data loss; measured `get_context` p95 against
`NFR-1`; the export → fresh instance → import round-trip from condition 2; and
the `NFR-10` single-node ceiling re-measured, since the ceiling now comes from
one machine's resources rather than SQLite's single-writer lock.

## Consequences

The two-backend tax disappears. One data layer, one migration set, one vector
implementation, one lexical implementation, one Oban engine, one contract
suite. `AINV-1` moves from approximately true to literally true: identical
guarantees are now a structural property rather than a thing the test suite has
to police across two divergent backends.

Local retrieval gets better, not merely simpler. pgvectorscale's DiskANN index is
written inside the knowledge-write transaction and is durable, replacing an
in-memory index that had to be rebuilt from blobs at boot and reconciled on a
schedule. Lexical search becomes PG-FTS everywhere, so tokenisation and ranking
no longer vary by tier. Benchmark numbers measured locally now describe the
behavior an enterprise deployment gets.

Row-level security becomes available in every mode, closing the one place where
the free tier was structurally weaker on isolation.

The costs are real and accepted. The local footprint grows from one SQLite file
plus an in-process index to a supervised Postgres server with its own data
directory and memory. Cold start is slower than opening a file. The release
takes on responsibility for a child process's lifecycle, which is a new class of
operational failure — a stale lock file, a port conflict, a half-initialised
data directory. The required pgvectorscale extension narrows the packaged pg0
matrix to glibc Linux x86_64/ARM64 and Apple Silicon. Windows, Intel macOS, and
Linux musl use external PostgreSQL or a container. The project also depends on
a young launcher that is not marketed as production-ready while it holds the
system of record on self-hosted installs. Version pins, the tested export path,
and the external-Postgres escape hatch mitigate that risk.

MemHouse is not the first system to make this bet, which is part of why it is
defensible: Hindsight ships the same on-ramp.

## Anchors

- `AINV-1` - one codebase, two modes, identical guarantees; now literally true.
- `AINV-3` - don't reinvent wheels; pg0 replaces a bespoke embedded-PG build.
- `AINV-5` - system of record vs derived cache; the in-memory HNSW cache
  branch of this invariant is retired.
- `AINV-8` - infrastructure ports vs domain strategies; pg0 is an
  infrastructure packaging choice, never a domain strategy.
- `AD-DEPLOY-1` - one image, one program, scaled by node count.
- `AD-DEPLOY-5` - what flips between modes.
- `AD-SEAM-2` - infrastructure ports (storage, vector, lexical, job-queue).
- `AD-SEAM-3` - `RetrievalStrategy`; the in-memory HNSW adapter is removed.
- `AD-SEAM-4` - cross-port invariants 1 and 4.
- `AD-DATA-4` - materialized-path scope tree; the two-backend-parity rationale
  for avoiding `ltree` no longer applies.
- `AD-DATA-5` - vector + lexical co-located.
- `AD-DATA-6` - isolation; RLS is now available in every mode.
- `AD-DATA-9` - migrations; per-backend fragments are removed.
- `AD-PIPE-1` - Oban engine.
- `AD-CFG-2` - packaging & distribution; pg0 is the zero-dependency on-ramp.
- `AD-EVAL-2` - testing pyramid; the dual-backend contract suite collapses.
- `AD-PORT-1` - logical account export; now also the PG-major upgrade path.
- `AD-PORT-3` - offline snapshot + rebuild embeddings.
- `NFR-1` - latency targets; re-measured on the new local tier.
- `NFR-10` - scale ceilings; the SQLite single-writer ceiling is gone.
- `FR-PLAT-2` / `FR-PLAT-4` / `FR-PLAT-5` - single-node stack and the
  two-backends-per-interface requirement.

## Related Documents

- `specs/adr/0002-l3-automation-boundary.md`
- `specs/memory-system-architecture-and-nfr.md`
- `specs/memory-system-functional-requirements.md`
- `specs/memory-system-product-blueprint.md`
