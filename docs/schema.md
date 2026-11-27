<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Logical schema v2

This is the data model every MemHouse store holds, independent of how a store lays it out
(TR-CORE-04). The Postgres store maps it to the tables at the end; the Lite store (G16) will map
the same model to SQLite. Exports carry exactly this model ([Memory Format v2](memory-format.md)).

Schema version **12** (`mh_meta.schema_version`). Version 1 to 11 databases upgrade in place on
start-up; see [Upgrading from v1](#upgrading-from-v1). Version 3 added the identity tables
(principals, API keys, token signing keys), version 4 the recall explanations, version 5 the
policy specs and their activations, version 6 the write pipeline's intake queue, version 7
the grants between agents and version 8 the evaluation suites and their runs; none of them is
memory, so none is exported. Version 7 also added the
`taxonomic` kind and made a record's scope part of its deduplication key. Version 9 added the
record's `language`. Version 10 added the staleness of code references (`stale_since` and
`seen_hash` on a reference, `stale_since` on its record); the upgrade to it also puts the
paths of stored references in the one form they are matched in (`./src//a.rs` becomes
`src/a.rs`; of two references of a record to one file, the one already in that form is kept).
On Postgres a trigger on `mh_code_ref` keeps new rows in that form too, so a version 9
process still running during a rolling upgrade cannot store another spelling; a Lite file is
opened by one build at a time, and an older build refuses a newer file. Version 11 added the
[console sessions](#session): one new table, which is not memory and is not exported. Version
12 added [legal holds, deletion requests and job runs](#legal-hold-deletion-request-job-run):
three new tables, none of them memory.

A stored path that has no such form is left as it is. With `\` read as `/`, that is a path
with a `..` segment (`../x`, `src/../a.rs`), a path with nothing but empty and `.` segments
(the empty path, `.`, `./`, `/`), and a path whose canonical form is over 1,024 bytes (UTF-8).
A leading `/` alone is no such case: `/src/a.rs` becomes `src/a.rs`. Such a reference
**matches no file report**, so its memory never goes stale. The upgrade logs a warning with
their number (not the paths). To find them on Postgres:

```sql
SELECT memory_id, path FROM mh_code_ref, LATERAL (SELECT replace(path, chr(92), '/') AS p) n
WHERE p = '..' OR p LIKE '../%' OR p LIKE '%/../%' OR p LIKE '%/..'   -- a `..` segment
   OR p ~ '^(\.?/)*\.?$'                                              -- nothing but '' and '.'
   OR octet_length(path) > 1024;                                       -- too long
```

In a Lite file, which has no regular expressions:

```sql
SELECT memory_id, path FROM (SELECT memory_id, path, replace(path, char(92), '/') AS p FROM mh_code_ref)
WHERE p = '..' OR p LIKE '../%' OR p LIKE '%/../%' OR p LIKE '%/..'
   OR trim(p, './') = ''
   OR length(CAST(path AS BLOB)) > 1024;
```

Both return every path the upgrade counted, and may return a few it did not: the length test
is on the stored path, which can be longer than its canonical form (the one the upgrade
measures), and the Lite query's `trim` test also returns a path made of dots and slashes
only that has a segment of three or more dots (a valid name). To fix a reference, revise the
memory with `code_refs` that name the file by its path from the repository root.

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
| `kind` | enum | yes | `working`, `episodic`, `semantic`, `preference`, `procedural`, `commitment`, `document`, `taxonomic` (from version 7); each has its own gate, retention, retrieval and access rules ([memory-types.md](memory-types.md)) |
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
| `scope` | {org, team, agent, user, session} | no | where the record applies inside the subject (MEM-04); empty = the whole subject. A reader sees a record when every level it names is the reader's own ([inheritance](memory-types.md#scopes-and-inheritance)) |
| `source` | text | yes | the source label (v1: the writer) |
| `confidence` | 0..1 | yes | |
| `provenance` | object | yes from v2 | `agent` (writing agent), `user` (acting user), `policy_version`, `request_key`, `extractor` and `extractor_config` for derived records |
| `language` | text | no | the language the text was detected as, among the enabled ones: a [language pack](languages.md) code (`en`, `de`). From version 9; absent on records written before |
| `stale_since` | timestamp | no | derived: the earliest `stale_since` of the record's [code references](#code-reference), absent when none is stale. A store keeps it on the record so that recall filters on the record alone; it is not exported (an import derives it from the references). From version 10 |
| `alt_hash` | sha256 hex | no | the key of the round's second vector (the user's words alone) |
| `metadata` | JSON object | yes | open attributes (round number, message references, derivation sources), and the engine's own keys, below |
| `created_at`, `updated_at` | timestamp | yes | |

Not in the logical record, but kept by the store with each vector: `embedder` (model id) and
`embedder_config` (hash of model, dimension and passage prefix), so every vector says what made it.

The engine's keys in `metadata`: `statement` and `route` (what the gate read and where it routed
the record), `held` (`plan`, `speculation` or `signal`: why a candidate is held) and `signals`
(how often a held signal was seen), `duplicate_of`, `supersedes_because`, `confirmed_by`,
`derived` with `source_ids` (an extracted fact and the rounds it came from), `promoted_from`
with `promoted_from_kinds` and `promotion_reason` (a promoted record's sources, MEM-05),
`pref_key` (a keyed preference's key), `ttl` (`session`: working memory that lives as long as
its session), `quarantine_reasons`. A write can't set `promoted_from`, `held`, `signals` or
`pref_key` itself.

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

Only `committed` records are recalled (and `candidate` ones when a recall asks with
`include_candidates`, labelled, PR-7). `superseded`, `rejected` and `expired` are terminal. A
store refuses any other transition (`set_status` changes nothing and says so), and the
governance check `lifecycle` proves it. Every write is answered as a `candidate` while it waits
in the intake queue (G10; it is not yet a stored row, but its id reads as one). The write gate
then stores it as `committed`, `quarantined`, `rejected` (a near-duplicate, or a revision of a
version that is no longer current), or keeps it `candidate`: a plan or speculation (QUAL-02,
marked `metadata.held`), a plan committed when a completed event in its scope confirms it, and
either `expired` at its `valid_to` or after `intake.plan_ttl_days`; or a proposal from an agent without a commit grant under `[access]
admission = "review"` (GOV-08), which a reviewer commits or rejects.

### Working memory (MEM-01)

`kind = working` records always have `expires_at`: the write's own value, or now + the type's
`ttl_secs` (`[memory] working_ttl_secs`, default 24 hours). One written in a session
(`scope.session`) without its own expiry carries `metadata.ttl = "session"`: every later
working-memory write in the session moves it to the new expiry, so it lives until the session's
last write plus the TTL. Recall skips working memory once expired, and the hourly retention pass
moves it to `expired`. In a session it is served first, from the
[session cache](memory-types.md#working-memory-and-sessions).

## Structured record

`{record_type, attrs}` where `attrs` is a JSON object. Lookups are exact (`attrs @> {...}` on
Postgres), never by similarity (HYB-02). The record's `content` is the text form, so the same id
is also found by recall.

## Code reference

`{path, blob_hash, stale_since?, seen_hash?}` per record, at most one per path (TR-TPL-02).

| Field | Type | Meaning |
|---|---|---|
| `path` | text | the file, relative to the repository root, `/` separators |
| `blob_hash` | text | the content hash of the file when the memory was written or last revalidated (the git blob hash by convention) |
| `stale_since` | timestamp, optional | since when the file is known to have other content, or to be deleted. From version 10 |
| `seen_hash` | text, optional | the content hash the file was last seen with while stale; absent for a deleted file. Only with `stale_since`. From version 10 |

The rules, the same in every store (`memhouse_core::staleness::plan`): a file seen with a hash
other than the stored one makes the reference stale (from the first time it is seen so); a file
seen with the stored hash is not stale; a deleted file is stale with no hash seen; a rename
moves the reference to the new path, and is then judged by the hash like any other (a record
that already references the new path keeps that reference and the old one is dropped).
Observations apply to committed and candidate records. A record with a stale reference is left
out of recall unless the recall asks for stale records; revalidation gives a reference its new
hash and clears the mark ([coding.md](coding.md)). A writer can't set the marks: `remember` and
`revise` drop them.

## Link

`{tenant, subject, linked_subject, link_type, memory_id?, created_by, created_at}`, unique on
(tenant, subject, linked_subject, link_type). Held in the subject's own partition. Following a link
will require a relationship with the linked subject too (G27). Deleting the justifying record
deletes the link; erasing either subject deletes it.

## Policy

`{version, body, created_at}`: a compiled policy ([policy.md](policy.md)). `version` ends in a hash
of the body, so equal policies get equal versions everywhere: `gov-<hash>` for the default policy
(the configuration), `policy-v<n>-<hash>` for approved spec version n. The body holds every
setting the policy decides (memory types, write gate, retention, redaction, recall, ranking) and,
from G28, the access-decision values (D-01 to D-07). Each record's `provenance.policy_version`
names the policy that admitted it; records from before v2 carry `legacy-v1`.

The specs a compiled policy comes from, their approval and their activations are kept per tenant
(v5) and are not exported: a spec is configuration, not memory.

## Request key

`{tenant, key, subject, operation, request_hash, response, created_at}`. A write with a key that
was seen before returns the stored response if the request is the same, and fails if it differs
(CORE-06). Erasing the subject removes its keys. Exactly-once under concurrent repeats of the same
key arrives with the intake queue (G10).

## Session

`{id, tenant, principal_id, key_id, key_check, created_at, expires_at, last_seen_at}` (v11): a
session of the [admin console](console.md), opened by presenting an API key once (threat
model T3).

- `id` is the SHA-256 of the session's secret. The secret itself is only in the browser's
  cookie, so a reader of the database cannot use a session.
- `key_id` is the key that opened it, or `admin:bootstrap`. Every request made with the
  session is checked against that key and its principal: a revoked or expired key, or a
  disabled principal, ends the session. For a bootstrap key, which has no row to revoke,
  `key_check` holds an HMAC of the key under a token signing key, so the session ends when
  that key leaves the configuration.
- `last_seen_at` is written at most once a minute per session.
- **A row exists only while its session can be used.** Logging out deletes it; so does
  presenting it past `expires_at` or past the idle limit, and the hourly retention pass
  removes the ones nobody came back for. Erasing a tenant deletes its sessions.
- It holds no memory content and no subject data: a principal id, a key id and three times.
  It is not exported and not migrated between profiles (`memhouse migrate`): after a
  migration, log in again.

## Legal hold, deletion request, job run

Added in version 12 (G22). None of them is memory: they hold identifiers, counts and hashes,
never content, and none is exported in the Memory Format. Legal holds and deletion requests
move with `memhouse migrate`; job runs do not (an unfinished run is simply run again).

- **Legal hold** `{id, tenant, target_kind, target, reason, placed_by, placed_at, released_by,
  released_at}`: while `released_at` is empty, every record the hold matches is exempt from
  retention and deletion (GOV-09). `target_kind` is `subject`, `user`, `agent`, `source`,
  `org`, `team`, `session` or `tenant`; a `user` hold matches a record's `provenance.user` or
  `scope.user`, and so on, as the corresponding `forget` does.
- **Deletion request** `{id, tenant, scope, value, actor, requested_at, status, completed_at,
  deleted, held, executions, canaries, certificate}`: one per `forget`, from the request to its
  completion certificate (TR-WF-01). `status` is `running`, `held` (a legal hold keeps records
  back) or `completed`; a completed request is never changed. `canaries` are the ids and
  cached-vector keys sampled before the deletion; `certificate` is the certificate as JSON.
- **Job run** `{id, tenant, job, state, started_at, updated_at, finished_at}`: a durable run of
  a background job (TR-WF-02). At most one unfinished run per tenant and job; `state` holds the
  records counted per step and the steps whose audit event is written.

Version 12 changes no column of a record. On Postgres it adds one nullable column to the
memory table, `epart`: the month of an episodic record on a database whose memory table is
partitioned by it ([monthly partitions](operations.md#monthly-partitions-for-episodic-memory)),
empty everywhere else. It is the store's own and is not part of the logical record. A version
11 process keeps working against a version 12 database: it reads none of the new tables and
leaves `epart` empty.

## Postgres mapping

| Logical | Postgres |
|---|---|
| Record | `mh_memory` (one row; `scope_*` and `prov_*`, `policy_version`, `request_key`, `extractor*` columns; `tsv` generated; `embedding`, `embedding_alt`, `embedder`, `embedder_config`) |
| Language (v9) | `mh_memory.language`; `ts_config` (the Postgres text-search configuration of the record's language, NULL for `english`) and `tsv_lang` (the keyword index in that configuration, filled by the trigger `mh_memory_tsv_lang` when `ts_config` is set; partial GIN index). `tsv`, the `english` index, stays on every row. Neither `ts_config` nor `tsv_lang` is exported: an import derives them from `language` |
| Structured | `mh_structured` (`memory_id` → `mh_memory.id ON DELETE CASCADE`, GIN on `attrs`) |
| Code reference | `mh_code_ref` (`memory_id` → `mh_memory.id ON DELETE CASCADE`; v10: `stale_since`, `seen_hash`) and `mh_memory.stale_since` (v10), which the recall statement filters on, so it reads no other table |
| Link | `mh_link` (`memory_id` → `mh_memory.id ON DELETE CASCADE`) |
| Policy | `mh_policy` |
| Request key | `mh_request_key` |
| Store metadata | `mh_meta`: `schema_version`, `embedder`, `embedding_dim`, `passage_prefix`, re-embedding state |
| Not exported | `mh_embed_cache`, `mh_llm_cache`, `mh_enrich_job`, `mh_audit`, `mh_deletion_ledger` |
| Legal holds, deletion requests, job runs (v12, not exported) | `mh_legal_hold`, `mh_deletion_request`, `mh_job_run` (a partial unique index keeps one unfinished run per tenant and job) |
| Monthly partitions (v12, optional) | with `[database] episodic_partitions`: `mh_memory` partitioned by list on `epart`; `mh_memory_rest` (the table as it was: rows without a month) and `mh_memory_e<YYYYMM>` per month of episodic memory, each with its own primary key on `id`. The foreign keys of `mh_structured`, `mh_code_ref` and `mh_link` are replaced by the trigger `mh_memory_children`, which deletes them with their record |
| Row-level security (v12, optional) | with `[database] row_level_security`: the policy `mh_isolation`, enabled and forced, on `mh_memory` and its partitions, `mh_structured`, `mh_code_ref`, `mh_link`, `mh_recall`, `mh_intake`, `mh_request_key`, `mh_enrich_job` (tenant and subject from the session settings `memhouse.tenant` and `memhouse.subject`) and on `mh_embed_cache` and `mh_llm_cache` (the service scope only); the function `mh_rls_service()` |
| Small durable state (v12) | `mh_meta` keys `state.*`: the installation's id, the SIEM export's cursors and lease |
| Recall explanations (v4, not exported) | `mh_recall` (id, tenant, subject, principal, acting user, time, the recall record as JSON); erased with the subject, tenant or user, purged after `explanation_retention_days` |
| Policy specs (v5, not exported) | `mh_policy_spec` (tenant, version, spec as JSON, status `proposed` or `approved`, proposer, approver), `mh_policy_activation` (which version, or the default, runs from when, by whom; a trigger refuses a version that is not approved) |
| Intake queue (v6, not exported) | `mh_intake` (the proposal's id, a `seq` for per-subject order, tenant, subject, record ids, writer, user, source and scope for erasure, `status` `pending`, `running`, `done` or `dead`, attempts, lease, the redacted proposal as JSON until it is stored, its outcome, error, embedder with the same guard trigger as `mh_memory`); erased with the subject or tenant, by user, agent or source, pruned after `intake.keep_done_secs` |
| Evaluation (v8, not exported) | `mh_eval_suite` (tenant, name, hash, the suite as JSON, who added it) and `mh_eval_run` (id, tenant, suite, suite hash, policy version, trigger, the run as JSON: counts, metrics, per-conversation counts, record outcomes, engine fingerprint); erased with the tenant ([evaluation.md](evaluation.md)) |
| Grants (v7, not exported) | `mh_grant` (id, tenant, grantor and grantee agents, subject pattern, kinds, who created it, expiry, revocation); erased with the tenant. v7 also adds two partial indexes on `mh_memory`: on `metadata -> 'promoted_from'` (what was promoted from a record) and on `(tenant, subject, scope_session)` (a session's records) |
| Console sessions (v11, not exported, not migrated) | `mh_session` (sha256 of the session secret, tenant, principal, the key that opened it, a check value for a bootstrap key, created, expires, last seen); deleted at logout, at expiry, by the retention pass and with the tenant |
| Identity (v3, not exported) | `mh_principal` (kind, tenant, subjects, kinds, denied labels, org, team, `can_commit`, `act_as`), `mh_api_key` (sha256 of the secret, permissions, expiry, revocation), `mh_signing_key` (token signing secrets) |

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
