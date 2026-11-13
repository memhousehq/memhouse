<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Policies

A **behaviour policy** says how MemHouse treats one tenant's memory: which kinds may be written,
how the write gate admits them, how long they are kept, what is redacted, which labels are never
read, and how recall ranks. It is a structured spec in TOML or JSON. The engine runs a policy only
after a named person has approved it, can always say which version admitted a record, and can roll
back to an earlier version without a restart (requirements POL-01, POL-03, POL-04, POL-08,
GOV-03).

## Contents

- [Precedence: a policy can only tighten governance](#precedence-a-policy-can-only-tighten-governance)
- [The spec](#the-spec)
- [Lifecycle](#lifecycle)
- [Versions and provenance](#versions-and-provenance)
- [REST API](#rest-api)
- [When governance changes](#when-governance-changes)
- [Limits of v1](#limits-of-v1)

## Precedence: a policy can only tighten governance

Settings come in layers. A lower layer may make the rules stricter, never looser (PR-1):

| Layer | Where it is set | Example |
|---|---|---|
| Security baseline | built in | `secret` is always redacted; the injection screen is always on |
| Tenant governance | `[governance]` and `[access]` in `config.toml` | redact `card` and `email`; purge episodic memory after 90 days; proposals wait for review |
| Behaviour policy | an approved spec | allow only `semantic` and `preference`; also deny the label `legal`; favour recent memories |

The compiler starts from governance and applies the spec on top of it. A setting that would loosen
governance fails compilation, and the message names the governance rule it would break. The
compiler reports every problem at once:

```text
$ memhouse policy validate loose.toml
Error: the policy does not compile (3 problems):
  - retention.episodic_days: 0 keeps episodic memory forever, but governance purges it after 90 days ([governance] episodic_retention_days); a behaviour policy may only make governance stricter (PR-1)
  - redaction.categories: drops "email", which governance redacts ([governance] redact); a behaviour policy may add categories, never remove them (PR-1)
  - write_gate.quarantine_injection: the injection screen is part of the security baseline and can't be turned off (TR-CORE-05)
```

A refused proposal or activation is audited as `policy.reject` and nothing is stored.

## The spec

Every section and field is optional. A field the spec leaves out keeps its value from the
configuration, so an empty spec compiles to exactly the configured behaviour.

```toml
format = 1
name = "support-desk"
description = "Support agents: no documents, recent tickets first"

[scope]
tenant = "default"            # the tenant the policy governs

[memory_types]
allowed = ["semantic", "preference", "episodic", "commitment", "working"]

[write_gate]
admission = "review"          # agents' proposals wait for a reviewer
dedup_threshold = 0.95
max_content_chars = 8000

[retention]
episodic_days = 180
working_ttl_secs = 3600

[redaction]
categories = ["secret", "card", "ssn", "iban", "email", "phone"]

[recall]
denied_labels = ["legal"]
audit_reads = true

[ranking]
recency_weight = 0.3
recency_half_life_days = 30
keyword_weight = 1.0
vector_weight = 1.2

[types.semantic]
gate = "confirmation"         # every agent's fact waits for a reviewer
retention_days = 730

[types.semantic.access]
agent_private = true          # an agent's facts are its own until granted

[types.preference.access]
partition = "author"          # a user's own preferences are stored with the user
```

| Field | Values | Governance limit |
|---|---|---|
| `format` | `1` | |
| `name` | 1–64 letters, digits, `.`, `_`, `-` | |
| `scope.tenant` | the tenant the spec is proposed for | must match |
| `memory_types.allowed` | kinds that may be written; other kinds are refused | — (allowing fewer is always stricter) |
| `write_gate.admission` | `auto`, `review` | `auto` is refused where `[access] admission = "review"` |
| `write_gate.dedup_threshold` | above 0.5, at most 1 | |
| `write_gate.max_content_chars` | at least 1 | at most `[governance] max_content_chars` |
| `write_gate.quarantine_injection` | `true` | can't be `false` (security baseline) |
| `write_gate.corrections` | `true` (default), `false` | with `false` a correction or a changed value no longer supersedes what it updates: both versions stay current. For tenants that keep every statement as made; the [regression gate](evaluation.md#the-regression-gate) measures what it costs and refuses it for a tenant whose suites it degrades |
| `retention.episodic_days` | days, 0 = keep | where governance purges: 1 to its days |
| `retention.working_ttl_secs` | 1 second to 30 days | |
| `types.<kind>.*` | per-type rules, [below](#per-type-sections) | a type's rules may be tightened, never loosened |
| `redaction.categories` | `secret`, `card`, `ssn`, `iban`, `email`, `phone`, `ip` | must include `secret` and every governance category |
| `recall.denied_labels` | labels never read, and refused on writes through the API | must include every `[governance] denied_labels` label |
| `recall.audit_reads` | `true`, `false` | can't be `false` where governance audits reads |
| `ranking.*` | `default_k` (1–200), `candidates` (1–1000), `rrf_k` (above 0), `keyword_weight`, `vector_weight`, `recency_weight`, `relevance_weight`, `confidence_weight`, `validity_weight`, `window_weight`, `window_top_weight`, `subquery_weight` (0–100), `recency_half_life_days` (above 0), `window_top` (0–100), `query_analysis`, `dedup`, `dedup_cosine`, `dedup_overlap` (above 0, at most 1) | `keyword_weight` and `vector_weight` can't both be 0 |

The meaning of each ranking weight is in the [configuration reference](configuration.md); how
relevance, recency, confidence and validity combine into the score, and how `dedup` packs a
recall, is in the [API reference](api.md#ranking-four-features-weights-from-the-policy). Unknown
sections and fields are errors, so a typo is never silently ignored.

### Per-type sections

Each memory type has its own gate, retention, retrieval method and access rules
([memory-types.md](memory-types.md#the-types)). A section `[types.<kind>]`, for `working`,
`episodic`, `semantic`, `preference`, `procedural`, `commitment`, `document` or `taxonomic`,
tightens the rules of that type:

| Field | Values | Limit |
|---|---|---|
| `types.<kind>.gate` | `none`, `source`, `full`, `explicit`, `confirmation`, `approval` | at least as strict as the type's own gate (`none` < `source` < `full` = `explicit` < `confirmation` < `approval`) |
| `types.<kind>.retention_days` | days after which records of the type are purged, 0 = keep | `episodic`: within governance's limit, and the same value as `retention.episodic_days` if both are given; not for `working` |
| `types.working.ttl_secs` | 1 second to 30 days | the same value as `retention.working_ttl_secs` if both are given |
| `types.<kind>.access.agent_private` | `true`: an agent's writes of the type are scoped to that agent and read by others only with a [grant](memory-types.md#sharing-across-agents) | can't be `false` for `working` |
| `types.<kind>.access.partition` | `subject` (default), `author`: stored in the partition of the verified user the write is made for ([partitions](memory-types.md#partitions)) | |
| `types.<kind>.access.approver` | `reviewer` (any principal with `memory:review`), `admin` | can't be `reviewer` for `taxonomic` |

The retrieval method of a type is fixed by the engine and shown in the compiled policy
(`types.<kind>.retrieval`); a spec can't set it.

The defaults, as `memhouse policy show` prints them:

| Type | `gate` | Retention | `retrieval` | `agent_private` | `approver` |
|---|---|---|---|---|---|
| `working` | `none` | `ttl_secs` = `[memory] working_ttl_secs` | `session_cache` | true | reviewer |
| `episodic` | `source` | `retention_days` = `[governance] episodic_retention_days` | `hybrid_time` | false | reviewer |
| `semantic` | `full` | kept | `hybrid_exact` | false | reviewer |
| `preference` | `explicit` | kept | `scope_ordered` | false | reviewer |
| `procedural` | `confirmation` | kept | `task_matched` | false | reviewer |
| `taxonomic` | `approval` | kept | `exact` | false | admin |
| `commitment`, `document` | `full` | kept | `hybrid` | false | reviewer |

## Lifecycle

```text
validate ──► propose (v3, proposed) ──► approve --approver "Dana" (v3 active) ──► rollback (v2 or default active)
```

| Command | What it does |
|---|---|
| `memhouse policy validate FILE` | Compiles a spec against the configuration. It needs no database, so it can run in CI. |
| `memhouse policy propose FILE [--note TEXT]` | Stores the spec as the tenant's next version, `proposed`. It does not run. |
| `memhouse policy diff --to v3` | Lists the settings that differ between the running policy and v3. Also `diff FILE` for an unstored spec, and `--from` to compare other versions. |
| `memhouse policy approve 3 --approver "Dana Reviewer"` | Records the approver, compiles the spec again under the governance in force now, and activates it. |
| `memhouse policy rollback --approver "Dana Reviewer" [--to v2\|default]` | Activates the policy that was active before the current one, or the named one. Only approved versions and the default can be activated. |
| `memhouse policy status` | Shows the running policy, every version with its proposer and approver, and the activations, newest first. |
| `memhouse policy show [3]` | Prints a stored spec as TOML, or with no version the running compiled policy as JSON. |

All of them take `--tenant` (default: the configured tenant). Every change writes an audit event:
`policy.propose`, `policy.approve`, `policy.rollback`, or `policy.reject` for a refusal.

Only approved versions execute. The engine refuses to activate anything else, and so does the
database: a trigger on `mh_policy_activation` rejects any row naming a version that is not
approved.

A change takes effect without a restart. The process that approves or rolls back uses the new
policy for its next operation. Other processes (another `memhouse serve`, an MCP server) pick it
up within 2 seconds.

## Versions and provenance

A compiled policy has a version derived from its contents:

- `gov-<hash>`: the default policy, compiled from the configuration alone;
- `policy-v3-<hash>`: approved spec v3, compiled under the governance in force when it was
  activated;
- `draft-<hash>`: a spec that was only validated (never stamped on anything).

Equal policies get equal versions on every node. Each compiled policy is kept in `mh_policy` before
any record carries its version, and exported with the Memory Format. Every record's
`provenance.policy_version`, every write and recall span (`memhouse.policy_version`) and every
recall explanation names the version that admitted or ranked it. Explanations are replayed with the
weights of the version they ran under.

## REST API

| Operation | Permission |
|---|---|
| `GET /v1/policies`: the running policy, versions and history | `policy:read` |
| `POST /v1/policies/validate` `{"spec": {...}}`: compile, store nothing | `policy:read` |
| `POST /v1/policies/diff` `{"from": "default", "to": "v3"}` or `{"spec": {...}}` | `policy:read` |
| `POST /v1/policies` `{"spec": {...}, "note": "..."}`: propose | `policy:propose` |
| `POST /v1/policies/{version}/approve`: the caller is the named approver | `policy:approve` |
| `POST /v1/policies/rollback` `{"to": "v2"}` (or no `to`) | `policy:approve` |

Admin keys carry all three permissions. The schemas are in [`api/openapi.json`](../api/openapi.json).
Over REST the spec is JSON with the same fields as the TOML above.

## When governance changes

Governance can change after a policy was approved, for example when an operator adds `email` to
`[governance] redact`. The active spec might then loosen the new governance. In that case it stops
running and the default policy runs instead, because governance always wins. The engine logs an
error, and `memhouse policy status` and `GET /v1/policies` show a warning. Propose a new version, or
roll back to one that compiles. Rolling back to a version that no longer compiles is refused.

## Limits of v1

- One policy per tenant. Layered org, team and agent policies with conflict reports (POL-06), and
  templates as policy packages, come in G24.
- Plain-language authoring (POL-02) and dry runs against recent traffic (POL-05) come in G24.
- An approver is a name: the authenticated principal over REST, `--approver` on the CLI. The
  engine doesn't require the approver to differ from the proposer. Enforce that through who holds
  `policy:approve`.
- Retention runs for the configured tenant (`memhouse retention`, and hourly in `memhouse serve`).
