<!-- SPDX-License-Identifier: Apache-2.0 -->
# MemHouse Memory Format: conformance vectors

The specification is [docs/memory-format.md](../docs/memory-format.md). This directory holds the
test vectors any reader or writer of the format can check itself against. It is kept apart from
the code so it can move to a repository of its own (RP-06).

| File | What it tests |
|---|---|
| `vectors/v2-minimal.jsonl` | the smallest valid file |
| `vectors/v2-full.jsonl` | every kind and state, provenance, scope, labels, a version chain, a second vector, a structured record, code references, links and a policy |
| `vectors/v2-memory-types.jsonl` | schema 7: a `taxonomic` candidate, a session's working memory with its scope and expiry, and a record promoted from it |
| `vectors/v1-export.jsonl` | a version 1 file, read and upgraded |
| `vectors/invalid-*.jsonl` | one broken rule each |
| `vectors/manifest.json` | the expected outcome of every file |

A reader conforms when it reads every valid file with the counts in the manifest and rejects
every invalid one with an error that names the rule. A writer conforms when importing
`v2-full.jsonl` and exporting again reproduces every line after the header byte for byte.

In this repository, `cargo test -p memhouse-core conformance_vectors` checks the reader, and the
governance check `format_roundtrip` (`memhouse bench run --suite governance`) checks the writer
against a real database.
