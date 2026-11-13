<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# MemHouse Memory Format v2

An open, line-delimited format for everything a MemHouse tenant remembers: records with their
versions, provenance, labels and scopes, structured forms, code references, links between
subjects, and the policies that admitted them (TR-CORE-03, INT-10, PROF-02). Every profile reads
and writes it, so it moves memory between Lite, Standard and Scale, between deployments and
between embedding models.

Conformance vectors: [`memory-format/vectors/`](../memory-format/vectors/). The data model behind
it: [logical schema v2](schema.md).

```bash
memhouse export -o acme.jsonl                    # the configured tenant
memhouse export --subject customer:acme -o acme.jsonl
memhouse export --tenant eu-west -o eu.jsonl
memhouse import acme.jsonl                        # v1 or v2; ids already present are skipped
```

## File layout

UTF-8, one JSON object per line, `\n` line ends, no blank lines inside.

```text
{"format":"memhouse.memory","version":2,…}   ← header, exactly once, first
{"type":"policy",…}                           ← policies, by version
{"type":"record",…}                           ← records, by id
{"type":"link",…}                             ← links, by subject, linked_subject, link_type
```

A reader must accept the line types in any order except that the header comes first and a link
naming a `memory_id` comes after that record. Writers use the order above.

## Header

| Field | Type | Notes |
|---|---|---|
| `format` | `"memhouse.memory"` | required |
| `version` | `2` | the format version; a reader refuses a version it doesn't know |
| `schema_version` | integer | the [logical schema](schema.md) version of the writer |
| `producer` | text | e.g. `memhouse 2.0.0` |
| `exported_at` | RFC 3339 | |
| `tenant` | text | the tenant exported |
| `subject` | text | present when the file holds one subject |
| `embedder` | `{embedder, dim, passage_prefix}` | what the source's vectors were made with; informational |

Vectors are **not** in the file. They are a derivation of `content` by a particular model, and an
import makes them with its own configured model, so the format is model-independent (INT-09).

## `policy` line

| Field | Type | Notes |
|---|---|---|
| `version` | text | referred to by `provenance.policy_version` |
| `body` | JSON object | `governance` settings; `decisions` (access-decision values from G08) |
| `created_at` | RFC 3339 | |

## `record` line

Fields in this order; optional fields are left out when empty.

| Field | Type | Required | Rule |
|---|---|---|---|
| `id` | UUID | yes | |
| `tenant`, `subject` | text | yes | not empty |
| `kind` | `working` `episodic` `semantic` `preference` `procedural` `commitment` `document` `taxonomic` | yes | `taxonomic` from schema 7 |
| `status` | `candidate` `committed` `superseded` `quarantined` `rejected` `expired` | yes | `superseded` needs `superseded_by` |
| `content` | text | yes | not empty |
| `content_hash` | lowercase sha256 hex | yes | see below |
| `session_id`, `turn_ref` | text | no | |
| `occurred_at` | RFC 3339 | no | |
| `valid_from` | RFC 3339 | yes | |
| `valid_to` | RFC 3339 | no | not before `valid_from` |
| `expires_at` | RFC 3339 | `working`: yes | |
| `supersedes`, `superseded_by` | UUID | no | |
| `labels`, `tags` | text array | no | |
| `scope` | `{org?, team?, agent?, user?, session?}` | no | |
| `source` | text | yes | |
| `confidence` | number | yes | 0 to 1 |
| `provenance` | `{agent?, user?, policy_version?, request_key?, extractor?, extractor_config?}` | no | |
| `language` | text | no | the language the text was detected as: a language-pack code (`en`, `de`, `pt-BR`); from schema 9 |
| `alt_hash` | lowercase sha256 hex | no | the key of the second vector, below |
| `structured` | `{record_type, attrs}` | no | `attrs` is an object |
| `code_refs` | `[{path, blob_hash}]` | no | each path once |
| `metadata` | JSON object | no | |
| `created_at`, `updated_at` | RFC 3339 | yes | `updated_at` not before `created_at` |

Unknown fields and unknown line types are **errors**, not ignored: a v2 reader can't silently drop
what a newer writer added. New fields come with a new format version.

### Content hash

The deduplication key the engine gives a record, kept so an import deduplicates exactly as the
source did:

| Record | Hash input |
|---|---|
| episodic round (`metadata.round` present) | `episodic␟<session_id>␟<round>␟<content>`, then `␟scope␟<scope>` for a round with a scope |
| derived fact (`metadata.derived = true`) | `fact␟<session_id>␟<content>` |
| any other | `<kind>␟<content>`, then `␟<record_type>␟<attrs>` for a structured record, then `␟scope␟<scope>` for a record with a scope (the scope as canonical JSON, fields in the order above) |

`␟` is U+001F. The scope is part of the key from schema 7, so the same words noted in two
scopes are two records. Readers don't recompute it for v2 files; v1 files didn't carry it, so it is
computed on import.

### Second vector

An episodic round can have a second vector made from the user's words alone. Its text isn't
stored separately: it is the start of `content` after the first `role: `, up to a line end, and
`alt_hash` is sha256 of the passage prefix followed by that text. An importer finds the candidate
whose hash matches and embeds it; a round where none matches keeps only its main vector (the
import reports how many).

## `link` line

| Field | Type | Required | Rule |
|---|---|---|---|
| `tenant`, `subject`, `linked_subject`, `link_type` | text | yes | `subject` ≠ `linked_subject` |
| `memory_id` | UUID | no | a record in the file or the target |
| `created_by` | text | yes | |
| `created_at` | RFC 3339 | yes | |

## Canonical form

Writers emit each line canonically, so export → import → export reproduces every line byte for
byte (the header's `exported_at` aside):

- fields in the order of the tables above, the `type` field first;
- optional fields omitted when absent, empty arrays and empty objects omitted;
- keys inside `metadata`, `attrs` and `body` sorted;
- timestamps in UTC with `Z`, with as many fractional digits as needed (0, 3, 6 or 9);
- no insignificant whitespace.

Readers accept any valid JSON for a line; only writers are bound to the canonical form.

## Importing

- Records keep their ids, states, timestamps, provenance, scopes and labels. Ids already present
  are skipped, so an import can be repeated.
- Vectors are made with the importing configuration's model.
- Policies and links are added unless already present.
- The import writes one `memory.import` audit event.

## Version 1

Files written before schema v2 have the header `{"format":"memhouse.memory","version":1,
"exported_at":…,"embedder":"<id>"}` and one serialized record per line, without `type`. They are
read and upgraded with the [v1 rules](schema.md#upgrading-from-v1): provenance from `source`, the
policy `legacy-v1`, `content_hash` computed, `superseded_by` taken from the record in the file
that supersedes it, `updated_at` set to `created_at`.

## Conformance

[`memory-format/vectors/manifest.json`](../memory-format/vectors/manifest.json) lists each vector
and the expected outcome: the counts for valid files, and a phrase the error must contain for
invalid ones. A conforming reader reads every valid file with those counts and rejects every
invalid one. A conforming writer reproduces every line of `v2-full.jsonl` after importing it.
MemHouse runs both: the unit test `format::tests::conformance_vectors` and the governance check
`format_roundtrip` (import into a clean database, export, compare byte for byte).
