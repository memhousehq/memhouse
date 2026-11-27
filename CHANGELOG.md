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
- Coding template: memories linked to files, git-aware staleness and file-touched recall. A
  memory names the files it is about with their content hash (`code_refs`); when a file is
  reported changed, deleted or renamed with other content, the memory is stale and left out of
  default recall, in both profiles, until it is revalidated (`POST /v1/code/revalidate`),
  revised or forgotten. `POST /v1/code/touched` returns the memories linked to files an agent
  opened or edited, under the access decision of a recall, with those needing revalidation
  listed apart; `POST /v1/code/changed` reports a commit's files. `memhouse hook file-opened |
  file-edited | post-commit` are the adapters harnesses and git run: they take the file's git
  blob hash (they prefer git's own, and fall back to hashing the file as read when git is not
  installed or cannot hash it), only call the API and never block a read, an edit
  or a commit;
  `memhouse connect claude-code --hooks` and `gemini --hooks` install them without touching
  other hooks, `memhouse hook install-git` the post-commit hook, and `memhouse remember
  --file` links a memory from the command line. MCP: `file_memories` and `revalidate`, and
  `code_refs` on `remember` and `revise`. API 1.9.0, schema version 10 (`stale_since` and
  `seen_hash` on a code reference, exported in Memory Format from schema 10). See
  [docs/coding.md](docs/coding.md).
- Procedural memory is promoted on repeated correction: an agent's procedural proposal marked
  as a correction is committed without a reviewer once the same correction has been given
  `[intake] procedural_corrections` times (3; one occurrence never promotes, 0 turns it off),
  audited with the reason and the count. A reviewer's confirmation works as before.
- Changed: a `procedural` memory is returned by a recall only for a task it matches (two
  content words in common with the query, a requested tag, or a file named in the new `paths`
  field); one that does not is listed in the explanation with the reason `task`.
- Changed: the `coding` profile of `memhouse bench synth` covers the template's memory
  categories and writes suite format 2 (file links, file changes, file-touched questions), so
  `bench/suites/coding` is a new suite; it is now a tier 1 run of the benchmark guard. Format
  1 suites and the other profiles are unchanged.
- Fixed: a write identical to a stored one is matched with the live record of that content (committed, else candidate), not with whichever row the store returned first; a rejected repeat could be picked on Postgres, and a repeated correction was then not counted.
- Changed: on Postgres the recall statement is planned for the values of each call instead of
  being kept as a prepared statement. A kept statement could be given a generic plan that
  knows no subject and joins by nested loops, several times slower on a large subject.
- Corrections replace what they correct: a statement with a correction marker ("no longer",
  "actually", "correction:") supersedes every older version of the fact, at a lower similarity
  than an unmarked value update (`[intake] marked_correction_threshold`, 0.6). On the synthetic
  starter suite the share of questions about a corrected fact that still get a stale version
  fell from 84.9% to 15.1%.
- Tiered write gate (`[intake] classifier = "tiered"`): the rules first, a small model when
  they find no marker, a large model only when the small one is unsure and the tenant is within
  its cap. A model can add caution, never release what the rules hold.
- Tiered extraction: every extracted fact carries a confidence (how much of it is found in the
  rounds it cites); with `[enrich] escalate`, an unsure session is extracted again by a larger
  model, for at most 30% of a tenant's sessions. Tier metrics for both.
- Suites can be replayed as ingested conversations (`memhouse bench run --suite ... --enrich`),
  which scores the extracted facts.
- The Lite profile: `memhouse up --lite` runs the same engine on one SQLite file, with no
  Docker and no database server (`sqlite:` database URL; FTS5 keyword search, exact vector
  scoring over half-precision vectors). `memhouse backup` and `memhouse restore` for Lite,
  the restore re-applying every deletion made since the backup; an automatic upgrade first
  writes a copy of the database. See [docs/lite.md](docs/lite.md).
- `memhouse migrate --from <url> --to <url> [--dry-run]` moves a whole installation between
  profiles (Lite to Standard and back): records, vectors as stored, policies, principals and
  keys, the deletion ledger and the audit chain. Every record is verified by hash before the
  configuration is switched; the source is only read. See
  [docs/operations.md](docs/operations.md#moving-between-profiles).
- The built-in local models are pinned to a revision, and every model file's SHA-256 is checked
  on download and when first loaded (`[embedding] revision` and `sha256` pin other models).
- The governance suite runs on both profiles; a check that cannot apply to a profile is
  reported as not applicable, apart from passed and failed.
- Conformance kits (`memhouse-conformance`): one reusable test suite per adapter type (store,
  intake queue, embedder, reranker, chat model, authorizer) and a profile suite that runs one
  scenario through REST, MCP and the command line and requires the same outcomes. `revise`,
  `forget` and `ingest` take `--json` on the command line. See
  [docs/conformance.md](docs/conformance.md).
- Python and TypeScript SDKs (`sdk/python`, `sdk/typescript`), generated from the OpenAPI
  document, with lifecycle hooks that only call the API; MemHouse embedded in a Python or Node
  process (`bindings/python`, `bindings/node`): the whole REST API in process, with the same
  authentication, write gate and audit; adapters for the OpenAI Agents SDK and LangGraph. The
  profile scenario gives the same outcomes through each. Packages are not published yet. See
  [docs/sdk.md](docs/sdk.md).
- Admin console at `/` in both profiles, replacing the Memory Browser page: view, search, edit,
  supersede and delete memories; the explanation of a recall; the review queue with candidates
  and quarantined records (approve, reject, or rephrase and approve: the new wording passes
  the write gate, and a quarantined record is never committed as it stands); principals and
  keys; policy versions; evaluation suites, replays and each quality metric by policy
  version; and a profile advisor that warns from 80% of the sizes Lite is measured at and
  names the `memhouse migrate` command (also `GET /v1/advisor` and a line of `memhouse
  doctor`). The console holds no rule of its own: every action is an API call as the
  logged-in principal. **Session login** replaces the key in the browser's storage: a key is
  presented once (`POST /v1/session`), the browser keeps a cookie script cannot read
  (`HttpOnly`, `SameSite=Strict`, `Secure` except on a loopback host), requests made with it
  need the session's CSRF token and the server's own origin, and the session ends on logout,
  expiry, idleness, key revocation or a disabled principal. The pages are served with a
  Content-Security-Policy without inline script or style. **CORS is closed by default**:
  browser pages of other origins are refused unless listed in `[server] cors_origins`
  (before, every origin was allowed). API 1.10.0: `/v1/session`, `GET /v1/review/queue`,
  `/v1/principals`, `/v1/keys`, `/v1/eval/*`, `/v1/advisor`, `content` on a review, and the
  `principal:manage` permission (an admin key created before does not carry it: create a new
  one). Schema version 11 (`mh_session`; a Lite file is copied before the upgrade, as for
  every schema version). `memhouse restore` ends every console session. New settings:
  `[server] console`, `cors_origins`, `public_url` (the server's origin behind a proxy that
  rewrites `Host`), `session_ttl_secs`, `session_idle_secs`, `session_cookie_secure`, and
  `[advisor]`. See [docs/console.md](docs/console.md).
- A proposal that fails and will be retried always keeps its content in the intake queue (found
  by the queue's kit).
- Identifiers and words are matched with Unicode letter classes ("Č-1001" is an identifier).
- `memhouse bench`: LongMemEval, LoCoMo, LLM-judged QA with cost caps, and the governance suite.
- The CLI stops quietly, with status 141, when the program reading its output exits early
  (`memhouse recall ... | head`).
