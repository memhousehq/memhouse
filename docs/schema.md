<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Logical schema v2

This is the data model every MemHouse store holds, independent of how a store lays it out
(TR-CORE-04). The Postgres store maps it to the tables at the end; the Lite store (G16) will map
the same model to SQLite. Exports carry exactly this model ([Memory Format v2](memory-format.md)).

Schema version **2** (`mh_meta.schema_version`). Version 1 databases upgrade in place on start-up;
see [Upgrading from v1](#upgrading-from-v1).

## Entities

```mermaid
erDiagram
    RECORD ||--o| STRUCTURED : "same id"
    RECORD ||--o{ CODE_REF : "same id"
    RECORD ||--o{ LINK : "justifies"
    RECORD }o--|| POLICY : "admitted by"
    RECORD |o--o| RECORD : "supersedes"
    SUBJECT ||--o{ RECORD : holds
    SUBJECT ||--o{ LINK : "holds (to another subject)"
    REQUEST_KEY }o--|| SUBJECT : "about"
```

| Entity | What it is | Requirement |
|---|---|---|
| Record | one memory: text, its kind and state, validity, provenance, scope, labels | CORE-02, GOV-03, ACC-04, MEM-04 |
| Structured | the queryable attributes of a record, under the record's id | HYB-02, HYB-04 |
| Code reference | a file a record is about, with the file's content hash | TR-TPL-02 |
| Link | a reference from one subject to another, held by the first | ACC-06 |
| Policy | a compiled policy version and its body | GOV-03 |
| Request key | an idempotency key and the first response to it | CORE-06 |
| Vector | derived from a record's text; stamped with the model and its configuration | INT-07, TR-MS-02 |

One logical id joins a record's representations (HYB-04): its text, keyword index, vectors,
structured row and code references are written together and deleted together.

## Record

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | UUID (v7) | yes | the logical id, shared by every representation |
| `tenant` | text | yes | isolation boundary |
| `subject` | text | yes | whose memory it is (`customer:acme`, `user:ana`, `repo:memhouse`); the partition key |
| `kind` | enum | yes | `working`, `episodic`, `semantic`, `preference`, `procedural`, `commitment`, `document` |
| `status` | enum | yes | lifecycle state, below |
| `content` | text | yes | the text, after redaction |
| `content_hash` | sha256 hex | yes | deduplication key (scheme in [memory-format.md](memory-format.md#content-hash)) |
| `session_id`, `turn_ref` | text | no | the source turn: conversation and message references |
| `occurred_at` | timestamp | no | when the remembered thing happened |
| `valid_from`, `valid_to` | timestamp | from: yes | when the record is true (bitemporal validity) |
| `expires_at` | timestamp | working: yes | after this it is not recalled, and retention marks it `expired` |
| `supersedes`, `superseded_by` | UUID | no | the version chain |
| `labels` | text[] | no | sensitivity labels (ACC-04); recall can exclude labels |
| `tags` | text[] | no | free tags |
| `scope` | {org, team, agent, user, session} | no | narrower visibility inside the subject (MEM-04); empty = the whole subject |
| `source` | text | yes | the source label (v1: the writer) |
| `confidence` | 0..1 | yes | |
| `provenance` | object | yes from v2 | `agent` (writing agent), `user` (acting user), `policy_version`, `request_key`, `extractor` and `extractor_config` for derived records |
| `alt_hash` | sha256 hex | no | the key of the round's second vector (the user's words alone) |
| `metadata` | JSON object | yes | open attributes (round number, message references, derivation sources) |
| `created_at`, `updated_at` | timestamp | yes | |

Not in the logical record, but kept by the store with each vector: `embedder` (model id) and
`embedder_config` (hash of model, dimension and passage prefix), so every vector says what made it.

### Lifecycle (CORE-02)

```mermaid
stateDiagram-v2
    [*] --> candidate
    [*] --> committed
    [*] --> quarantined
    candidate --> committed
    candidate --> rejected
    candidate --> quarantined
    candidate --> expired
    committed --> superseded
    committed --> quarantined
    committed --> expired
    quarantined --> committed: released
    quarantined --> rejected
    superseded --> [*]
    rejected --> [*]
    expired --> [*]
```

Only `committed` records are recalled. `superseded`, `rejected` and `expired` are terminal. A
store refuses any other transition (`set_status` changes nothing and says so), and the
governance check `lifecycle` proves it. Today writes enter as `committed` or `quarantined`;
`candidate` becomes the entry state when admission turns asynchronous (G10).

### Working memory (MEM-01)

`kind = working` records always have `expires_at`: the write's own value, or now +
`[memory] working_ttl_secs` (default 24 hours). Recall skips them once expired, and the hourly
retention pass moves them to `expired`. Scoping them to a session (`scope.session`) and their own
gate and ranking arrive in G11.

## Structured record

`{record_type, attrs}` where `attrs` is a JSON object. Lookups are exact (`attrs @> {...}` on
Postgres), never by similarity (HYB-02). The record's `content` is the text form, so the same id
is also found by recall.

## Code reference

`{path, blob_hash}` per record, at most one per path. A recall that sends a file's current hash
gets back the records whose stored hash differs: those are stale (G19 wires this into recall and
the coding-agent hooks).

## Link

`{tenant, subject, linked_subject, link_type, memory_id?, created_by, created_at}`, unique on
(tenant, subject, linked_subject, link_type). Held in the subject's own partition. Following a link
will require a relationship with the linked subject too (G27). Deleting the justifying record
deletes the link; erasing either subject deletes it.

## Policy

`{version, body, created_at}`. `version` is `gov-` and a hash of the body, so equal settings give
equal versions everywhere. The body holds the governance settings now, and the access-decision
values (D-01 to D-07) from G08. Each record's `provenance.policy_version` names the policy that
admitted it; records from before v2 carry `legacy-v1`.

## Request key

`{tenant, key, subject, operation, request_hash, response, created_at}`. A write with a key that
was seen before returns the stored response if the request is the same, and fails if it differs
(CORE-06). Erasing the subject removes its keys. Exactly-once under concurrent repeats of the same
key arrives with the intake queue (G10).

## Postgres mapping

| Logical | Postgres |
|---|---|
| Record | `mh_memory` (one row; `scope_*` and `prov_*`, `policy_version`, `request_key`, `extractor*` columns; `tsv` generated; `embedding`, `embedding_alt`, `embedder`, `embedder_config`) |
| Structured | `mh_structured` (`memory_id` → `mh_memory.id ON DELETE CASCADE`, GIN on `attrs`) |
| Code reference | `mh_code_ref` (`memory_id` → `mh_memory.id ON DELETE CASCADE`) |
| Link | `mh_link` (`memory_id` → `mh_memory.id ON DELETE CASCADE`) |
| Policy | `mh_policy` |
| Request key | `mh_request_key` |
| Store metadata | `mh_meta`: `schema_version`, `embedder`, `embedding_dim`, `passage_prefix`, re-embedding state |
| Not exported | `mh_embed_cache`, `mh_llm_cache`, `mh_enrich_job`, `mh_audit`, `mh_deletion_ledger` |

## Changing the schema

Every change is **expand, backfill, switch, contract** (TR-DB-01), never a rewrite in place:

1. **Expand**: add nullable columns and new tables (`ADD COLUMN IF NOT EXISTS`). A process on the
   previous version keeps working against the new schema (the `schema_upgrade` check inserts a row
   the way a v1 process would).
2. **Backfill** in batches of 5,000 rows, idempotent, so it can be interrupted.
3. **Switch** readers and writers to the new fields; bump `schema_version`.
4. **Contract** (drop what is no longer used) only in a later version, after every process has
   moved.

A database newer than the binary is refused at start-up. No upgrade re-extracts or re-embeds
stored memories (QUAL-08): the upgrade check compares every vector before and after.

## Upgrading from v1

On the first start of a v2 binary against a v1 database:

| v2 field | Filled from |
|---|---|
| `provenance.agent` | `source` (`enrich` for `enrich:<model>`) |
| `provenance.policy_version` | `legacy-v1` |
| `provenance.extractor`, `extractor_config` | `metadata.extractor`, `metadata.prompt_version` of derived records |
| `embedder`, `embedder_config` | the database's embedder, for rows with a vector |
| `scope`, `user`, `request_key`, `expires_at` | empty (unknown before v2) |

The same rules turn a v1 export into v2 records on import, so upgrading a v1 database and
importing its v1 export give identical v2 exports (governance check `schema_upgrade`).
