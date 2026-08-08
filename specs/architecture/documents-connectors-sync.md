<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Documents, Connectors, And Sync

Status: implemented

Documents are a first-class free-core observation path. This implements
`FR-TOP-10`, `FR-KN-5`, `FR-FORM-9` through
`FR-FORM-12`, `FR-FORM-14`, `FR-FORM-17`, `AD-SEAM-1` through `AD-SEAM-4`,
`AD-DATA-5`, `AD-PIPE-1` through `AD-PIPE-4`, `AD-PORT-1`, `AINV-5`,
and the document-outage portion of `NFR-8`.

## Durable and derived boundaries

The configured boundary contains ten Ash Domains and 38 Resources.
`MemHouse.Observations.Document` identifies one logical source document and
its scope. `DocumentVersion` is immutable source history carrying:

- SHA-256 content hash and byte count;
- media type and content-bearing source metadata;
- a durable blob reference;
- source occurrence time; and
- content-safe processing state and counts.

The local free-core adapter stores immutable bytes under
`account/content-hash`; the S3-compatible adapter uses ExAws and the same
reference contract. Adapter choice is runtime infrastructure configuration.
It does not change hashes, version behavior, gates, or sync semantics. A
deterministic content-addressed put may leave a harmless orphan when the later
database transaction rolls back; it can never replace a different object and
is eligible for later reconciliation.

`MemHouse.Documents.ConnectorConfig` is durable authored state: scope, owner,
adapter kind, interval schedule, cursor, next/last sync timestamps, status,
content-safe config, and an optional secret reference. Raw credentials are
rejected. `DocumentChunk` is a rebuildable derived cache: version and byte
range, chunk hash, text, vector, and pinned embedding identity. Chunks and
vectors are excluded from logical export and regenerated from version blobs.

Both new Account tables retain PostgreSQL RLS, foreign keys, schedule/lookup
indexes, and document-version FTS. Pre-existing inline content uses a
`legacy-db://` reference. Chunk embeddings use PostgreSQL `vector`, DiskANN, and
generated FTS indexes for Semantic and Lexical retrieval.

## Dual ingest

`MemHouse.Documents.ingest_bytes/2` writes the content-addressed blob, creates
or reuses the scoped logical document, appends a new immutable version only
when the hash changed, and uses the existing transactional-write, audit, and
job Ash change to commit:

1. the raw `DocumentVersion`;
2. a content-safe hash-chain audit event;
3. a deterministic `PipelineRun`; and
4. its AshOban extraction job.

The ingest job reads bytes through the blob port. Markdown is parsed through
MDEx into a validated AST and normalized Markdown. PDF, Office, email, HTML,
and the other supported binary formats use the native ExtractousEx NIF; plain
UTF-8 text uses the direct no-loss path.

TextChunker supplies format-aware chunks and byte offsets. The bitcrowd/rag
embedding stage attaches vectors produced by the pinned model-layer `embedder`
role. Every chunk records provider, model, version, and dimensions. The same
parsed text then enters the structured extractor. Subject remains distinct
from the document source, provenance links the resulting item to
`document_version_id`, and every new item enters the unchanged Gate A/B
lifecycle. Agents and connectors therefore submit raw observations only.

Processing uses a short read transaction, connection-free blob/parse/embed/
extract work, then a short result transaction. Failure marking also uses a
short transaction. This prevents external work from exceeding connection
ownership timeouts and losing already-billed results.

Processing records counts, parser name, byte size, and IDs in telemetry. It
never copies bytes, extracted text, statements, source metadata, cursors, or
secrets into spans, audit metadata, or Oban arguments. Provider/parser failure
leaves the raw version, blob, audit, and retryable job durable.

## Incremental sync and history

Connector adapters implement `pull(config, cursor)` and return raw items plus
the next cursor. Advance only after every item is versioned, recognized as an
unchanged hash, or tombstoned.
Schedules use a durable next-sync timestamp and deterministic
connector/cursor/scheduled-time job identity. The Account reconciler also
re-enqueues due connectors and pending/failed document versions.

For changed sources, unchanged statements merge new provenance. Missing
prior-version statements become `superseded` while retaining statement,
provenance, lifecycle, and audit history; replacements add a `supersedes`
relation. Prior chunks are superseded. Remote deletion
tombstones the document and its chunks. Knowledge supported only by that
document is retracted without deleting history; items with independent
provenance remain governed and retrievable.

## Erasure and portability

`MemHouse.Documents.Portability` contributes documents to the Account archive.
Its `f6-document-1` bundle contains durable metadata and checksum-verified blob bytes but excludes
chunks and embeddings; import passes every raw version through ordinary ingest
and enqueue, so derived data is rebuilt under the target embedder identity.
Portability owns the complete transaction-consistent archive, JSONL layout,
audit verification, and commands.

Document erasure removes derived chunks, document/version metadata, exclusive
blob objects, and document provenance. Knowledge supported only by the erased
document is removed through the Gate A/B governance erasure helper; knowledge
with surviving provenance remains. Shared content-addressed blobs remain. Audit
retains only IDs, hashes, actions, and counts.

## Evidence and version posture

- Document, connector, chunk, blob, parser, sync, and portability code:
  `lib/memhouse/documents/`
- Ash domain/resources: `lib/memhouse/documents.ex` and
  `lib/memhouse/observations.ex`
- Pipeline integration: `lib/memhouse/pipeline/`
- Resource migration:
  `priv/repo/migrations/20260728082728_f6_documents_connectors_sync.exs`
- Generated snapshots: `priv/resource_snapshots/repo/`
- Documents acceptance suite:
  `test/memhouse/f6_documents_connectors_sync_test.exs`

HTTP shapes, Gate A/B lifecycle, and message extraction remain unchanged. The
additive document path keeps `f5-1` health/message identity; retrieval later
advances its profile to `f7-1`. Both are historical contract tags.
