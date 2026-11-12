<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Memory types, scopes, promotion and sharing

A memory has a **type** (`kind`), and each type has its own write gate, retention, retrieval
method and access rules (MEM-01). A memory also has a **scope** inside its subject, and scopes
inherit from broad to narrow (MEM-04). Memories move between types by **promotion** (MEM-05),
and between agents by **grants** (INT-06). This page describes all four; the request and
response fields are in the [API reference](api.md), the settings in [policy.md](policy.md) and
[configuration.md](configuration.md).

## Contents

- [The types](#the-types)
- [Working memory and sessions](#working-memory-and-sessions)
- [Scopes and inheritance](#scopes-and-inheritance)
- [Preferences](#preferences)
- [Promotion](#promotion)
- [Sharing across agents](#sharing-across-agents)
- [Partitions](#partitions)
- [What is checked](#what-is-checked)

## The types

| Type | Holds | Write gate | Retention | Retrieval | Access |
|---|---|---|---|---|---|
| `working` | the state and scratchpad of the current task | `none`: committed as written | until the session's last write plus `ttl_secs` (24 hours) | the session cache: first in the session's recalls | session-local; private to the writing agent |
| `episodic` | what was said and what happened, with its time | `source`: the writer and source are on the record | `retention_days` (governance's `episodic_retention_days`; 0 keeps it) | hybrid search with a probe for the time the question names | the subject |
| `semantic` | facts about users, entities and the organisation | `full`: the statement gate | until superseded or deleted | hybrid search plus exact lookup of structured records | the subject |
| `preference` | likes, dislikes and ways of working | `explicit`: a stated preference commits, an inferred signal waits for a repeat | until superseded or deleted | scope-ordered lookup | the subject |
| `procedural` | how something is done | `confirmation`: an agent's proposal waits for a reviewer | until superseded or deleted | hybrid search (task matching comes with the coding template) | the subject |
| `taxonomic` | the organisation's own terms and classifications | `approval`: only an administrator commits | until superseded or deleted | exact lookup of its structured form, and hybrid search | the subject; approved by an admin |
| `commitment`, `document` | open items; reference text | `full` | until superseded or deleted | hybrid search | the subject |

The injection screen and redaction are not part of a type's gate: they apply to every write of
every type (security baseline).

**Gates**, loosest first:

| Gate | What a write must pass |
|---|---|
| `none` | Nothing more: no statement classifier, no duplicate check, no review. A plan noted in a scratchpad is a note, not a claim. |
| `source` | The writing principal and a source label are on the record; a record without them is `rejected`. What was said is not judged. |
| `full` | The [statement gate](api.md#post-v1remember-propose-a-memory) (QUAL-02): plans and speculation are held as candidates, near-duplicates rejected, corrections supersede. |
| `explicit` | The statement gate, and only explicit statements commit. A write marked as an inferred signal (`"metadata": {"signal": true}`) is held as a candidate until the same signal has been seen `[intake] preference_signals` times (2), in the same scope and, for a keyed preference, under the same key; the repeat commits the held record (which then replaces the value its key had in that scope) and is not stored twice. The stricter gates hold signals the same way. |
| `confirmation` | The statement gate, and a proposal from an agent without a commit grant waits for [`POST /v1/review`](api.md#post-v1review-commit-or-reject-a-candidate), also where `admission = "auto"`. A user's, an admin's or a trusted agent's own write is the confirmation. |
| `approval` | The statement gate, and only the type's approver commits: everyone else's write is a candidate until the approver reviews it. |

A [policy](policy.md#per-type-sections) may give a type a stricter gate, a shorter retention or
tighter access rules, never looser ones. The gate in force when a write is processed decides:
a write still queued when a policy raises its type to `confirmation` or `approval` waits for a
reviewer, whatever it was allowed when it was queued. `GET /v1/policies` shows the rules in force under
`running.policy.types`.

Procedural and taxonomic memory are stored and gated here; promoting a procedure after repeated
confirmation and matching procedures to the task at hand come with later goals
([roadmap](roadmap.md)).

## Working memory and sessions

A session is named by the caller: `scope.session` on a write and on a recall.

```bash
# Note something for the task at hand
curl -s $MH/v1/remember -H "authorization: Bearer $KEY" -H 'content-type: application/json' -d '{
  "subject": "customer:acme", "kind": "working", "scope": {"session": "ticket-4411"},
  "content": "Waiting for the seat count before I can draft the renewal quote"}'
# {"id":"01a1d0c2-…","status":"committed","deduplicated":false}

# Recall inside the session: its working memory comes first
curl -s $MH/v1/recall -H "authorization: Bearer $KEY" -H 'content-type: application/json' -d '{
  "subject": "customer:acme", "scope": {"session": "ticket-4411"}, "query": "renewal quote"}'
# {"hits":[{"memory":{"kind":"working",…},"working":true,…},{"memory":{"kind":"semantic",…},…}],…}
```

- **Write.** Working memory in a session answers with the gate's decision (it always waits, so
  the session reads its own note back at once). No classifier holds it and no reviewer is asked;
  the injection screen still quarantines.
- **Lifetime.** A note lives until the session's last working-memory write plus the type's
  `ttl_secs`: every write in the session moves the session's notes to the new expiry. A note
  written with its own `expires_at` keeps it, and a revised note keeps following its session.
  Past its expiry a note is never recalled or promoted, and retention marks it `expired`.
- **Recall in the session.** The session's notes come first, newest first, marked
  `"working": true`; they are not ranked against the query. A recall of mixed types keeps at
  least half of its `k` places for ranked memories. A recall of `"kinds": ["working"]` is
  answered from the session cache alone: no query embedding, no database statement (one
  statement when it asks for more notes than the cache keeps per session).
- **Session-local.** A recall or a list returns a session's records only when it names that
  session (this holds for every type scoped to a session, not only working memory). A record is
  still read by its id.
- **Private to its agent.** An agent's working memory is scoped to that agent
  (`scope.agent`); another agent in the same session reads it only with a
  [grant](#sharing-across-agents).
- **Outside a session.** Working memory written without `scope.session` is found by hybrid
  search until it expires, as before.

### The session cache

Each server process keeps the working memory of the sessions it serves (PERF-05): up to
`working_cache_items` notes per session and `working_cache_sessions` sessions, the least
recently used session evicted first. The cache holds nothing the database doesn't. It is loaded
on a session's first recall (while the query is being embedded, so a miss adds no latency),
updated by the writes that go through the process, dropped by a deletion, revision, relabel or
retention pass, and read again after `working_cache_secs` (5), so a change made through another
process shows within that time. Something read from the database before a deletion or relabel
is never put into the cache after it. Access rules are applied to what the cache returns on
every read. `working_cache_secs = 0` turns it off. The metric `memhouse_working_cache_total` counts
hits and misses.

## Scopes and inheritance

A record's `scope` names where it applies inside its subject: any of `org`, `team`, `agent`,
`user` and `session`. A record with no scope applies to the whole subject (the tenant level).
The levels, broadest first:

```mermaid
flowchart LR
    T[tenant] --> O[org] --> TM[team] --> A[agent] --> U[user] --> S[session]
```

**Inheritance is one rule**, applied to every read: a reader sees a record when, at every
level, the record either names nothing or names the reader's own value. So a session sees its
own records and those of its user, agent, team, org and tenant. Nothing flows the other way: a
user outside the session does not see the session's records, a teammate does not see another
user's, another team does not see the team's.

The reader's own scope is not taken from the request. The server sets the org and team from the
principal, the agent from the authenticated agent, and the user from the verified user
(`GET /v1/whoami` shows it as `scope`); a caller without one of them sees only records that
don't set it. Only the session comes from the request. An admin reads every scope. A write may
name a scope the caller is in, never another one (`403`).

The same words written in two scopes are two records: a write is deduplicated against, and
supersedes, only records of exactly its own scope.

## Preferences

A preference has a **key** when it is written with the structured form
`{"record_type": "preference", "attrs": {"key": "...", ...}}`:

```bash
curl -s $MH/v1/remember -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' -d '{
  "subject": "workspace:acme", "kind": "preference", "scope": {"org": "acme"},
  "content": "Reply in English",
  "structured": {"record_type": "preference", "attrs": {"key": "reply_language", "value": "en"}}}'
```

- In one scope a key has one value: writing the key again in the same scope supersedes the old
  value (the old version is kept, as for any revision).
- Across scopes the value at the **narrowest level the reader is in** wins: session, then user,
  agent, team, org, tenant. A user's preference overrides the team's, which overrides the
  organisation's.

`GET /v1/subjects/{subject}/preferences` returns the preferences that apply to the caller: per
key the winning record with its `level` and the ids it `overrides`, and preferences without a
key as they are. `?key=` asks for one key, `?session=` adds a session's own preferences.

```json
[{"key":"reply_language","level":"user","memory":{"id":"01a1d0c9-…","content":"Reply in Portuguese",…},
  "overrides":["01a1d0c7-…","01a1d0c5-…"]}]
```

Recall applies the same order: when a hit is a keyed preference that a narrower scope overrides,
the one that applies takes its place, and the [explanation](api.md#get-v1recallsidexplanation-why-a-recall-returned-what-it-did)
lists the other as `overridden`.

## Promotion

`POST /v1/promote` turns memories into a memory of another type: a note in working memory into a
fact, a run of events into a procedure.

```bash
curl -s $MH/v1/promote -H "authorization: Bearer $KEY" -H 'content-type: application/json' -d '{
  "sources": ["01a1d0c2-…"], "kind": "semantic", "reason": "confirmed by the customer", "wait": true}'
# {"id":"01a1d0d4-…","status":"committed","deduplicated":false,"statement":"fact","route":"fact"}
```

| Field | Notes |
|---|---|
| `sources` | 1 to 50 committed, unexpired records of one subject, which the caller can see |
| `kind` | `semantic`, `preference`, `procedural` or `taxonomic`; `episodic` for working memory. Promotion moves towards durable memory: never into `working`, never to the same kind (that is `revise`) |
| `content` | the promoted memory's text; required for several sources, for one it defaults to the source's text |
| `scope` | defaults to the sources' common scope without its session, so a note promoted out of a session becomes visible to the session's user |
| `reason`, `tags`, `labels`, `structured`, `valid_to`, `request_key`, `wait` | as for `remember`; `labels` are added to the sources' own |

The promoted record is a new record. It goes through the write pipeline, so **the target type's
gate applies**: an agent's promotion to procedural memory waits for confirmation like any other
procedural proposal. It keeps the ids and kinds of its sources in `metadata.promoted_from` and
`metadata.promoted_from_kinds`, the union of their labels, and the earliest of their event
times. The sources stay as they are. The insert and a `memory.promote` audit event (sources,
kinds, target type, scope, reason) are written in one transaction. A plain `remember` can't
claim a `promoted_from`: the key is removed.

Deleting a source with `forget` deletes what was promoted from it, as it deletes extracted
facts; a promotion still in the intake queue when its source is forgotten is not written.
Retention is different, and deliberately so: when a source ages out under its type's retention,
the promoted record stays, under its own type's retention. That is what promotion is for (a
fact outlives the conversation it came from), and the record's `promoted_from` then names a
source that is gone. A type kept in its author's partition (below) can't be the target of a
promotion from another subject: write it with `remember`.

The CLI equivalent is `memhouse promote <id>… --kind semantic [--content …]`.

## Sharing across agents

A record scoped to an agent (`scope.agent`) is read by that agent only. An agent's working
memory always is; a policy can make any type private to its agent
(`[types.semantic.access] agent_private = true`), and a write can set `scope.agent` itself.
Everything else in a subject is shared by the agents that may use the subject.

A **grant** makes one agent's agent-scoped memory readable to another:

```bash
curl -s $MH/v1/grants -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' -d '{
  "grantor": "agent:research", "grantee": "agent:support-bot", "subjects": "customer:*", "kinds": ["semantic"]}'
# {"id":"01a1d0e1-…","grantor":"agent:research","grantee":"agent:support-bot","subjects":"customer:*","kinds":["semantic"],…}
```

| Operation | Returns |
|---|---|
| `POST /v1/grants` `{grantor, grantee, subjects?, kinds?, expires_at?}` | the grant; `subjects` is an exact subject, a prefix ending in `*`, or `*` (default); `kinds` empty means all |
| `GET /v1/grants` | every grant, newest first, revoked and expired ones included |
| `DELETE /v1/grants/{id}` | `{"revoked": id}` |

All three need `grant:manage`, a permission of admins. A grant gives **read access only**
(recall, get, list, preferences): the grantee can't revise, forget or promote the grantor's
records. It ends at `expires_at` or when revoked. Grants and revocations apply at once in the
process that made them and within 2 seconds in others, and are audited (`grant.create`,
`grant.revoke`). The CLI equivalent is `memhouse grant add|list|revoke`.

## Partitions

A subject is a partition: a note about a patient is stored in the patient's subject, with the
writer and the acting user in its provenance (`provenance.agent`, `provenance.user`), whoever
wrote it and through whichever agent (ACC-10).

Some memories are about their author, not about the subject at hand: a clinician's own
preferences and procedures. A policy can keep a type in its author's partition:

```toml
[types.preference.access]
partition = "author"
[types.procedural.access]
partition = "author"
```

A write of such a type made for a verified user is then stored in that user's own subject (the
user's id, for example `user:dr-lee`), whatever subject the request named. The user needs no
subject pattern for the write, nor to read, revise or forget by its id a record they wrote
there; searching or listing that subject follows the usual subject rules.

## What is checked

The governance suite (`memhouse bench run --suite governance`) proves these properties on every
change:

| Check | What it proves |
|---|---|
| `memory_types` | the type-specific scenario suite: each type's gate, retention, retrieval and access rule, and that a policy can only tighten them (MEM-01) |
| `working_session` | cached recall p95 of 20 ms or less, working memory first, no extra latency in a session, read-your-writes, deletions and expiry honoured (PERF-05) |
| `scope_inheritance` | 20 preferences set at three levels in every order resolve user over team over org for every reader; readers inherit broader scopes only (MEM-04) |
| `promotion` | 100 promotions, each linked to its sources and audited; the target gate still applies (MEM-05) |
| `agent_grants` | agent A writes, agent B recalls with and without a grant, by kind, by subject, after revocation and expiry (INT-06) |
| `partitions` | 1,000 mixed writes land in the right partition with the right author, directly and through an agent (ACC-10) |
