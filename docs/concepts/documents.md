<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Documents and connectors

A document is a raw observation. MemHouse stores it before processing, and
extracted knowledge follows the same pipeline and gates as messages.

```mermaid
flowchart TB
    SRC[Connector or direct upload] --> V{Content hash seen before?}
    V -->|"yes, identical"| NOOP[No-op — cursor still advances]
    V -->|"no, or changed"| NEW[Append an immutable document version]
    NEW --> BLOB[(Content-addressed blob<br/>local dir or S3)]
    NEW --> PARSE[Parse: MDEx / Extractous]
    PARSE --> CHUNK[Chunk and embed<br/>rebuildable cache]
    PARSE --> EXTRACT[Knowledge extraction]
    EXTRACT --> GATES[Gate A / Gate B]
    NEW -.->|supersedes| OLD[Prior version's derivations]
```

## Versions are immutable and hash-addressed

Changed content appends an immutable version and supersedes stale derivations.
An identical content hash is a no-op.

Original bytes go to a content-addressed blob store — a local directory by
default, or any S3-compatible bucket by configuration. The blob adapter is a
runtime infrastructure choice and changes nothing about document semantics.

## Processing holds no database connection while it works

Fetch, parsing, embedding, and extraction run between two short database
transactions, following the
[ingest pipeline](ingest-pipeline.md#the-model-call-holds-no-database-connection)
shape. Long parsing or model calls therefore hold no database connection.

The first transaction reads; the second atomically writes chunks, knowledge,
supersession, and processing status. Completion is recorded only after commit,
so interrupted work retries.

## Supersession and deletion do not silently retract knowledge

When a document version is superseded, or a remote document is deleted, the old
version becomes a **tombstone** rather than disappearing. Knowledge derived
from it is retracted only if that document was its *last* remaining support.

```mermaid
flowchart LR
    K["Statement:<br/>'The roundup ships Thursday'"] --- D1[Document v1]
    K --- M1[A chat message]
    D1 -->|deleted remotely| T[Tombstone]
    T --> Q{Any surviving provenance?}
    Q -->|"yes — the message"| KEEP[Statement stays active]
    Q -->|no| RETRACT[Statement is retracted]
```

A statement with independent corroboration keeps living. Only a statement whose
last supporting row disappears is retracted.

## Connector sync

Connectors submit raw document versions. They do not write knowledge, and they
do not get a shortcut past the gates.

The sync loop is built so that a crash mid-page cannot lose or duplicate work:

1. fetch a page from the remote source;
2. handle every document in it durably;
3. **only then** advance the cursor.

A crash before step 3 replays the page; the repeated content hashes make the
replay a no-op.

## Chunks and vectors are rebuildable

Document chunks and their embeddings are derived caches. They are excluded from
logical exports and rebuilt at the destination through ordinary ingest, which
is also why an import into a differently configured embedder is safe: vectors
are recomputed in the destination's vector space rather than reused.

| Included in a logical export | Excluded |
| --- | --- |
| Checksum-verified original blobs | Chunks |
| Durable document-version metadata | Embeddings |
| Governed knowledge and audit graph | Extracted-text caches |

See [Export and import](../operations/portability.md).

## Erasure

Erasure removes exclusive blobs and document-only knowledge, while preserving
content-safe audit evidence and any knowledge that has surviving provenance
from elsewhere.

## What never leaves the document boundary

Document bytes, extracted text, connector cursors, source metadata, and
connector secrets are never copied into audit metadata, telemetry, or job
arguments. Only ids, hashes, counts, and error classes cross that line.

## Current limitation

Connector administration has no user interface in this release; connectors are
configured and driven programmatically. See
[Limitations](../reference/limitations.md).
