<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Exploring memory in the web console

`/console` shows the memory your roles can reach, its provenance and history,
and the actions available to you.

```bash
open http://127.0.0.1:4000/sign-in
```

Readers, members, curators, and account admins may sign in. Roles change
visibility and available controls.

Agent API keys work on JSON and MCP, never the console.

## What you can reach

| Page | Shows |
| --- | --- |
| `/console` | Overview: totals, lifecycle and sensitivity mix, what is waiting, recent activity |
| `/console/knowledge` | The explorer: browse every statement you can read, or preview what retrieval would rank |
| `/console/knowledge/<id>` | One statement in full, with its evidence, history, readable shared-entity neighbours, and available actions |
| `/console/scopes` | The containment tree as a directory, with counts, index coverage, your role, and lateral links |
| `/console/graph` | One scope at a time, drawn as a graph of its statements, their shared-entity groups, and the scopes below it |
| `/console/sources` | Documents, their versions, connectors, sessions, and raw observations |
| `/console/skills` | Skill requirement cards, and a live readiness check for yourself |
| `/console/tools` | A workbench for all eight MCP tools, using your signed-in identity and showing the returned payload; account admins also get the retrieval diagnostic |
| `/console/me` | Everything recorded about you, and your consent and erasure controls |
| `/console/operations` | Account admins only: readiness, last expiry/revalidation sweep, usage, ingest economics, cost, entity-resolution quality, scope retrieval health, gate rules, retrieval tunings |
| `/governance` | Curators and account admins only: the gate queue and skill-card authoring |

Navigation hides inaccessible pages, but every destination independently
checks authority and refuses unauthorized requests.

## Trying the MCP tools in the browser

`/console/tools` provides one form for each tool exposed at `/mcp`. It calls
the same Ash actions as MCP, under your signed-in identity. Account and
calling-peer identity never come from a form.

The cards are grouped by what you are trying to do:

After `search` or `ask`, the browser adds `retrieval_health` for the selected
scope. This browser-only object is not part of the MCP or HTTP contract. It
reports statement, embedding, entity-mention, and mentioned-statement counts;
embedding and mention coverage; stored embedding identities; the configured
query identity; and one of `ready`, `missing_embeddings`,
`no_mentions_indexed`, `partial_mention_coverage`, or `identity_mismatch`.
For Account administrators, it also reports whether query terms resolved no
entity or resolved an entity with no statement in the selected authorized
scope. It never returns entity or statement identity. When a derived index
needs attention, `next_action` says to rebuild the scope's derived data.

The operations page adds the same content-safe probe for an administrator-selected
scope and effective profile. It reports inherited profile version, deadline,
enabled and disabled strategies, and explicitly shows that the probe made no
model calls and read no stored content. Disabled strategies are reported
separately from missing indexes.

| Group | Cards | Action |
| --- | --- | --- |
| Retrieve | Ask memory, Search memory, Load context, Browse knowledge | `ask`, `search`, `get_context`, `query_knowledge` |
| Operate | Save observation, Resolve validation, Update question limits | `ingest`, `resolve_validation`, `set_ask_preference` |
| Evaluate | Check readiness | `check_readiness` |

Every card names its action under the submit button, so a payload you see here
maps to the tool an agent would call.

Most forms are governed reads. Three have durable effects and are marked in
the page: `ingest` persists and queues a raw observation,
`resolve_validation` answers one pending question addressed to you, and
`set_ask_preference` can only lower your own limits or extend a pause. The
workbench adds no curator, promotion, gate-administration, or bulk action.

## Session and scope on the workbench

**Run context** at the top of the page sets the session id and scope for every
card at once. The session id is generated when the page mounts; reuse it across
calls when you want inline validation delivery and later ingest to belong to
the same interaction, or press **Start a new session id** to begin a fresh one.

The scope box accepts any scope you can read and completes as you type, which
matters once an Account holds more paths than fit a list. A path you cannot
read is named as such before you submit, so a typo does not look like an empty
Account.

Each card keeps a collapsed **Context** section holding the same two fields.
Change them there to deviate for a single run without moving the page-wide
context.

## Reading a result

A completed call shows a short summary first — the answer, the counts, the
readiness verdict, the stored preference — followed by **What was submitted**
and the exact **Raw payload**. The summary is a reading aid; the payload is the
same value the underlying action returned, and stays available for debugging.

After `search` or `ask`, the browser adds `retrieval_health` for the selected
scope, and the summary reports its state. This browser-only object is not part
of the MCP or HTTP contract. It reports statement, embedding, and entity-mention
counts; embedding coverage; stored embedding identities; the configured query
identity; and one of `ready`, `missing_embeddings`, `missing_mentions`, or
`identity_mismatch`. When a derived index needs attention, `next_action` says to
rebuild the scope's derived data.

Up to five runs are kept under **Earlier runs** so you can compare a call with
the one before it. They live in the page only: a reload starts empty, and a
failed call leaves earlier results in place.

A ranked run that returned as many candidates as it asked for stopped at the
limit, not at the end of the matches, and the result says so. That note means
deeper candidates may exist; it does not mean any of them is a better answer.

## Diagnosing retrieval

Account administrators get one extra control at the bottom of `/console/tools`:
**Retrieval diagnostic**. It is closed until you open it, and opening it changes
nothing about the ordinary cards — `search` and `ask` keep their normal
defaults, and no other role sees the panel at all.

The mode exists to reproduce retrieval behaviour, not to serve it. Its results
are labelled **not production-equivalent** because they are: a diagnostic run
may do things no request path may do.

| Control | What it does |
| --- | --- |
| Limit | Returns up to 100 candidates instead of the ordinary 12 |
| Strategies | Runs only the strategies you tick, in place of the profile's own |
| Reranking | Forces the rerank stage on or off instead of following the profile |
| Keep the latency deadline | Clear it to let every strategy finish |
| Show only query-dependent candidates | Hides candidates that only scope-ranking strategies voted for |
| Explain the ranking | Adds a per-candidate account of how it reached its rank |

The result reports how many candidates rank below the ordinary top-12 window.
That is the honest form of the warning: a normal run would not have shown them,
and that alone says nothing about whether they are right.

**Explain the ranking** answers the question the fused list cannot: whether a
candidate was never generated, or was generated and then demoted. Its table
gives each returned candidate's per-strategy local rank and score, that list's
reciprocal-rank contribution, the fused rank, and the final rank.
`outside_rerank_head` means the candidate stayed in the fused tail;
`rerank_unavailable` means the reranker did not complete. Strategy scores use
different scales, so compare ranks and fusion contributions, never scores
between strategies. Asking for the explanation does not change the ranking it
describes.

Leaving every strategy box clear runs the profile's own strategies. Ticking only
strategies that do not read your words — `salience_recency`, `temporal`, and
`relation_expand` — produces a ranking of the scope rather than of the question;
combined with **Show only query-dependent candidates** the page returns nothing
and says why, rather than relabelling the same rows.

Matched query terms are highlighted in the statements shown. **Reproducible
request** holds a copyable JSON body carrying the scope, query, profile, limit,
and diagnostic options — and nothing else. No session id, token, cookie, or
Account identifier is in it, so it is safe to paste into an issue.

Every control is an ordinary checkbox, number, or select and is reachable by
keyboard in page order. The mode is refused server-side for anyone who is not a
password-authenticated account administrator, so hiding the panel is a courtesy,
not the boundary.

Diagnostic mode does not widen what you may read. Account, scope, lifecycle, and
subject rules apply exactly as they do to an ordinary search.

## What you see, and why you might see less than a colleague

Two rules narrow the console beyond the ordinary scope filtering.

**Provisional statements are visible only to their subject**, including against
account admins. Retrieval applies the same rule.

**Only curators and account admins see every state.** Members and readers see
`active`, `needs_revalidation`, `expired`, and `superseded`, but not
`proposed`, `held`, `rejected`, `contested`, or `redacted`.

**You always see statements about yourself**, regardless of state or scope, so
you can contest, redact, or erase them.

Two people looking at the same Account will therefore see different totals.
That is the scope tree working, not an inconsistency.

## Browse or find

`/console/knowledge` has two modes, and the tabs at the top say which you are
in.

**Browse** applies attribute filters — scope, lifecycle state, kind,
sensitivity, how wide it may travel, subject — and pages through the result. It
is exhaustive: what is not listed is either filtered out or not visible to you,
never merely ranked low.

**Find** runs the same multi-strategy engine that answers an agent's `search`
call, and shows its working: which strategies contributed, which found nothing,
which were dropped against the deadline, and what each candidate scored. It
ranks; it does not enumerate. The exhaustive list stays underneath the ranked
preview, so a miss is never mistaken for an empty memory.

Read the strategy tile before the results. A search where the strategies that
read your words all found nothing still returns a full page — of whatever is
most recent in the scope. It looks like an answer and is not one.

Find requires a scope, and says so rather than listing silently. Searching
`/team/project` also searches `/team` and `/`.

### Filters

Filters apply as you change them, and the URL holds all of them, so a filtered
view can be bookmarked or shared with someone whose roles reach the same rows.
Applied filters appear as chips above the results; each chip removes only
itself, and **Clear all** removes the rest without leaving the mode you are in.

The **Scope** field is a typeahead over the paths you can read. Type any part of
a path; a scope you hold no role on never appears. Choosing one reports how many
contained scopes come with it.

**What these labels mean** expands a legend for every lifecycle state and
sensitivity level you can be shown. Each badge carries a shape as well as a
colour, so the states remain distinguishable without relying on colour.

Sort by **Confidence** or **Recorded** from the column headers, and set 25, 50,
or 100 rows per page beneath the list. Statement text longer than the column
expands in place with **Show full text**; opening the statement itself shows all
of it.

An empty result says which kind of empty it is: no statements you can read at
all, none matching the filters, nothing ranked by retrieval, or a query still
waiting for a scope.

## Index coverage

`/console/scopes` reports, per scope, how many of its statements carry an
embedding (**Indexed**) and how many entity mentions were resolved from them
(**Mentions**), plus the embedding model in use.

Statements are durable; those two are derived caches rebuilt in the background.
A scope can therefore hold every statement and answer nothing semantically —
word-based search keeps working, which is what makes the gap easy to miss. When
Indexed is lower than Statements the figure is highlighted, and semantic and
entity recall are degraded for that scope until its refresh runs again. Two
embedding models listed for one scope means part of it predates a model change
and must be re-embedded before those statements are comparable again.

Coverage counts only. Mentions is a number, never a list of names.

## The statement page

Everything the system holds about one claim is on `/console/knowledge/<id>`,
ordered by the questions you arrive with:

1. **The statement itself**, with its lifecycle state, kind, sensitivity, target
   level, scope, confidence, corroboration count, and when it was recorded.
2. **What you can do** — the actions your authority allows, each with its
   consequence stated before you commit to it. When nothing is available, the
   panel says why rather than disappearing.
3. **How current and how trusted** — belief time against valid time: when the
   system holds the claim, against when the claim is true in the world.
4. **Scope, subject, and sensitivity** — who the claim is about, where it sits,
   and how far it may travel. A colleague can be the subject of something you
   said.
5. **Provenance and evidence** — every route by which it entered, then the raw
   observations and document versions it was extracted from, in full.
6. **Lifecycle**, its shared-entity neighbours, and its cross-references in both
   directions, including the supersession chain.
7. **Technical details** — expand for the model, model version, and prompt
   version that extracted it, the embedding identity attached to it, the
   immutable gate decisions, and attribution.

Times are shown as elapsed time; hover any of them for the exact UTC value.
Identifiers and scope paths are shortened for scanning, with a copy control
beside them for the whole value.

Unreadable cross-references are omitted. Missing and unauthorized statement ids
both return "not found".

Arriving from the explorer keeps your filters: **Back to the list** returns to
the view you left, and following a cross-reference carries it onward.

## What you can change

Controls appear according to your authority. Everything below is carried out by
the governance layer, which records an immutable decision and a hash-chained
audit entry alongside the change.

### As a curator or account admin

On a statement with an open queue entry:

- **Approve** — the statement becomes `active` in its scope.
- **Reject** — it moves to `rejected` and is retained as evidence.
- **Defer** — the queue entry's due date moves out; the statement is untouched.
- **Edit as replacement** — this does *not* rewrite the statement. It mints a
  new statement carrying your wording, supersedes the original, and sends the
  replacement back through the gates. The original text stays readable.
- **Merge** — folds this statement's confidence, corroboration count, and
  sources into another statement, and supersedes this one.

You can also **request promotion** to a wider scope. Promotion does not move
anything by itself: the statement is held at the target scope for a second
human decision, and personal knowledge additionally waits for its subject's
consent.

The full queue, with bulk approve, reject, and defer, is at
[`/governance`](governance-console.md). Publishing skill requirement cards
happens there too.

### As the subject of a statement

On `/console/me`, or on any statement about you:

- **Confirm** — it becomes `active` at full confidence. First-hand confirmation
  by the subject is the strongest evidence available.
- **Contest** — it becomes `contested` and is queued for a curator within 24
  hours.
- **Redact** — it is withdrawn.

None of these is a curator power, and a curator cannot exercise them for you.

**Consent.** Personal knowledge being promoted to a wider scope waits for your
own consent, specific to that target scope. A grant is accepted only over a
channel that authenticated you — the browser session is one. A refusal is
recorded whatever the channel, because it must never be harder to refuse
exposure than to allow it.

**Erasure.** Proportionate erasure removes your content and scrubs shared
provenance. Strict erasure additionally removes knowledge that was only ever
sourced through you. Neither retracts knowledge that still has independent
provenance, and both retain content-safe audit evidence: the trace records that
something was removed, never what. Erasure runs immediately and cannot be
undone, which is why the control asks you to type `erase` first.

## The graph

`/console/graph` draws one scope at a time. That scope sits in the middle, its
statements orbit it, and the readable scopes directly below it sit on the outer
ring as places to go next. A statement's size is its confidence and its colour
is its lifecycle state.

Navigate with the breadcrumb, the **Up to** button, or the chips under *Inside
this scope*. The focus is in the URL, so a view is linkable and survives a
reload. Tick **Include descendant scopes** to pull the whole subtree into one
picture; that is off by default because on a real Account it is unreadable.

A dashed hub is a **shared entity**: the statements it links resolved to the
same thing. Select the hub to list them.

A hub is named after a wording used in this scope when one referent explains
the whole group. Otherwise it keeps an ordinal — `E1`, `E2`, … — which happens
when more than one referent shares exactly that set of statements, or when the
group's card has not been rebuilt since the last lifecycle change. The panel
says which.

A named hub also carries a short brief, written during background refresh. When
that call fails the panel says the brief could not be written and a later
rebuild retries it. The hub's name and statements are unaffected.

A faint dotted line between two named hubs means **named together**: both
referents appeared in one statement. It is not a stated relation. MemHouse
records no relations between entities, so read this as co-occurrence and
nothing more. Unnamed hubs are never joined this way, because the count of
lines leaving a hub would otherwise reveal how many referents it holds.

Other lines are **containment**, **scope relations** between non-parent scopes,
and **knowledge relations** between statements.

Select a node for details, or tab to it and press Enter. Layout is
deterministic. When a scope holds more statements or more shared-entity groups
than the graph draws, the page says so rather than presenting a partial picture
as complete, and links to the explorer for the complete list.

## What the console deliberately does not show

- **The entity cache itself.** Entity and mention rows span every scope that
  ever mentioned a name, so no canonical name, alias, or entity identifier
  appears anywhere in the console. A hub's name is not read from those rows: it
  is a wording taken from the statements in the group's own scope, which the
  same panel already shows you. Nothing carries a name across a scope boundary.
  Account admins see only aggregate cache quality signals on the operations
  page. Two entities shared by exactly the same statements still read as one
  unnamed group, so the count of resolved entities stays private. A group needs
  at least two readable statements in the drawn scope, so a hub never implies
  that some statement you cannot see exists.
- **Embedding vectors and document chunks.** Rebuildable derived caches with no
  meaning to a reader. Chunk counts are shown; chunk contents are not.
- **Credentials.** Password hashes, API key hashes, and connector secrets are
  never rendered. Connectors show status, schedule, and error class only.

Console content never enters logs, telemetry, audit metadata, or job arguments.

## Appearance and offline use

The console uses your operating system's light or dark preference. It loads one
stylesheet and one small script, both served by this installation; there is no
content delivery network, no web font, and no image asset, so an air-gapped
deployment renders exactly the same page as any other.

## See also

- [Curating memory](governance-console.md) — the gate queue in depth
- [Acting on your own data](self-governance.md) — the same subject powers over HTTP
- [Isolation and access control](../concepts/security-model.md)
- [Search and ask](search-and-ask.md) — the retrieval engine the preview runs
