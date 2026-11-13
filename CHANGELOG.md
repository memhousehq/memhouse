<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to MemHouse. Versions follow [Semantic Versioning](https://semver.org/); the
REST and MCP API has its own version and stability policy ([docs/api-stability.md](docs/api-stability.md)).

## 2.0.0 (unreleased)

A new implementation in Rust on Postgres + pgvector. It replaces the Elixir implementation
(0.x), which is archived, with its history, releases and issues, at
[memhousehq/archive-memhouse](https://github.com/memhousehq/archive-memhouse); there is no upgrade
path from 0.x data other than export and import.

- Write gate with redaction and injection quarantine, deduplication, supersession, validity
  windows and `as_of` recall.
- Hybrid recall (BM25 and vectors, weighted RRF, optional cross-encoder, token budget) with a
  stored explanation for every recall.
- Public API v1 over REST and MCP: remember, recall, revise, forget, ingest; idempotency keys,
  scopes, structured and rendered output; OpenAPI 3.1 document (API version 1.2.0).
- Principals, per-principal API keys, short-lived agent tokens, propose-only agents, labels and an
  authorizer checked on every operation.
- Hash-chained audit log, deletion ledger, retention; Memory Format v2 export and import.
- OpenTelemetry traces and a Prometheus metrics endpoint. Logs and traces carry identifiers and
  timings, never memory content or query text; errors from embedding and LLM providers keep only
  the status and the provider's error type and code.
- Policy engine v1: behaviour policy as a structured spec (memory types, write gate, retention,
  redaction, denied labels, ranking weights), compiled under governance so it can only tighten it;
  only approved, versioned specs run; diff, approve with a named approver, roll back, without a
  restart; every record and trace carries the policy version (`memhouse policy`, `/v1/policies`,
  API 1.3.0, schema version 5).
- Write pipeline v2: every write is authorized, redacted and durably queued, then answered
  `candidate` at once (`wait: true` to answer after the gate); a statement gate commits facts,
  holds plans and speculation as candidates (recalled only with `include_candidates`), and
  supersedes what a correction or a changed value updates; structured records are answered by
  exact query; workers resume proposals after a crash and set poison ones aside; failed
  retrieval answers empty and flagged, a write that can't be queued is refused as retryable
  (`503 unavailable`). API 1.4.0, schema version 6 (`mh_intake`), `[intake]` settings.
- Memory types: each type has its own write gate, retention, retrieval method and access rules,
  set per type in the compiled policy (`[types.<kind>]` sections tighten them). Working memory is
  a session's scratchpad, served first from a per-session cache; scopes inherit from tenant to
  session and a keyed preference resolves user over team over org
  (`GET /v1/subjects/{subject}/preferences`); `POST /v1/promote` writes an audited, linked record
  of another type; agents read each other's agent-scoped memory only with a grant
  (`/v1/grants`, `memhouse grant`); procedural memory waits for confirmation and the new
  `taxonomic` kind for an administrator's approval. API 1.5.0, schema version 7 (`mh_grant`),
  `[memory] working_cache_*` and `[intake] preference_signals` settings. Behaviour changes for
  1.4 clients are listed in [docs/api-stability.md](docs/api-stability.md).
- Ranking and packing v2: the final score combines relevance, recency, confidence and validity
  with weights from the compiled policy (`[ranking] relevance_weight`, `confidence_weight`,
  `validity_weight`); recall leaves out near-duplicates by vector cosine and text shingles and
  fills the freed places (`dedup`, `dedup_cosine`, `dedup_overlap`); `token_budget` is a hard cap
  on the hits and on the rendered block; `render_format` picks the block's form (`plain`,
  `markdown`, `xml`). API 1.6.0; `[memory] relevance_weight`, `confidence_weight`,
  `validity_weight` and `recall_dedup*` settings. The budget change for 1.5 clients is recorded in
  [docs/api-stability.md](docs/api-stability.md).
- Evaluation platform: suites of scripted conversations with ground truth at checkpoints (YAML),
  replayed through the real write and recall paths in a scratch tenant and scored for storage
  and retrieval precision, recall and F1, the stale-fact rate and the contamination rate;
  `memhouse bench synth` generates them from a seed for five profiles; `memhouse eval` stores a
  tenant's suites and replays; the regression gate replays them before a policy is approved and
  refuses one that degrades them (`[eval]` settings, `policy.gate` and `policy.refuse` audit
  events); `[write_gate] corrections` in a policy spec. API 1.7.0, schema version 8
  (`mh_eval_suite`, `mh_eval_run`). See [docs/evaluation.md](docs/evaluation.md).
- Fixed: a correction containing a word with letters outside ASCII ("Kraków") made its intake
  job panic and the write was set aside; the shared-word check now cuts between letters.
- Language packs: every word list and phrase pattern of the statement gate, query planning and
  the injection screen is data, one TOML file per language, validated and compiled at start.
  Packs for the 24 official EU languages are built in (English stable, the others drafts until
  a speaker reviews them), each with a labelled test set; `[language] enabled` turns on several
  at once, `packs_dir` loads your own, and a tenant's policy may narrow the set. The language of
  each write and question is detected without a model and recorded on the record; each record
  is indexed with its language's Postgres text-search configuration. The injection screen is
  never narrowed: every enabled pack's phrases and the built-in English ones apply to every
  write. With English alone, behaviour is unchanged. `memhouse lang list|check|detect|schema`;
  API 1.8.0 (`language` on a record, `language.enabled` in a policy spec), schema version 9.
  See [docs/languages.md](docs/languages.md).
- Identifiers and words are matched with Unicode letter classes ("Č-1001" is an identifier).
- `memhouse bench`: LongMemEval, LoCoMo, LLM-judged QA with cost caps, and the governance suite.
- The CLI stops quietly, with status 141, when the program reading its output exits early
  (`memhouse recall ... | head`).
