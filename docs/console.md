<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# The admin console

`memhouse serve` serves a console at `/`, on every profile: a page for the people who run a
deployment. It shows memories and lets you search, edit, supersede and delete them; explains
a recall; lists what waits for review, with the quarantined records; manages principals and
their keys; shows policy versions, evaluation results and the profile advisor.

```bash
memhouse serve          # the console is at http://127.0.0.1:7077/
memhouse key            # a bootstrap key to log in with on a new installation
```

## Contents

- [What the console is, and is not](#what-the-console-is-and-is-not)
- [Logging in](#logging-in)
- [Pages and the permission each action needs](#pages-and-the-permission-each-action-needs)
- [Review and the quarantine](#review-and-the-quarantine)
- [Principals and keys](#principals-and-keys)
- [Evaluation](#evaluation)
- [The profile advisor](#the-profile-advisor)
- [Security](#security): [the session](#the-session), [the pages](#the-pages), [other origins](#other-origins), [behind a proxy](#behind-a-proxy)
- [What is checked](#what-is-checked)
- [Limits](#limits)

## What the console is, and is not

The console is three static files (a page, a stylesheet, a script) that call the
[REST API](api.md) from your browser. There is no build step and nothing is loaded from
another site.

**It holds no rule of its own.** Every action is an API call made as the principal that logged
in, with that principal's permissions, and the server decides it. A button the page shows is a
convenience: a principal without the permission is refused by the server (`403`), and the
refusal is audited (`access.denied`), whatever the page shows. Everything the console does
can be done with `curl`, an SDK or the command line, with the same result and the same audit
event.

Turn the pages off with `[server] console = false`; the API stays.

## Logging in

Paste an API key: a principal's key (`memhouse key create admin:ana`), or on a new
installation the bootstrap key (`memhouse key`). The page sends it once, to
`POST /v1/session`, and does not keep it. The server answers with a **session cookie** that
script cannot read, and the page works with that until you log out or the session ends.

- The session has the permissions of the key that opened it, and no more.
- It lasts `[server] session_ttl_secs` (8 hours) at most, and ends when it is not used for
  `session_idle_secs` (30 minutes).
- **Log out** ends it on the server, not only in the browser, and clears the page: nothing
  of a session stays on screen for the next one. If the server cannot be reached the page
  says that you are not logged out and stays, so you can try again.
- Revoking the key, letting it expire, or disabling its principal ends the session with its
  next request. A session opened with a bootstrap key ends when that key is removed from the
  configuration (and the server restarted).
- An agent token (`mht.…`) does not open a session: tokens are short-lived credentials of
  software, not of a person at a browser.

Give each person a principal and a key of their own, so the audit log names them. The
bootstrap key acts as `admin:bootstrap` for everyone who holds it.

## Pages and the permission each action needs

| Page | What you do there | API call | Permission |
|---|---|---|---|
| Memories | list a subject's memories, also superseded, quarantined and rejected ones | `GET /v1/subjects/{subject}/memories` | `memory:read` |
| | list the subjects | `GET /v1/subjects` | `ops:read` (without it, type the subject) |
| | search | `POST /v1/recall` | `memory:read` |
| | see why a recall returned what it did | `GET /v1/recalls/{id}/explanation` | `memory:read` (your own recalls; others' and hidden ids with `audit:read`) |
| | remember | `POST /v1/remember` | `memory:write` |
| | edit (a new version; the old one is kept as superseded) | `POST /v1/revise` | `memory:write` |
| | supersede by another memory | `POST /v1/remember` with `supersedes` | `memory:write` |
| | delete | `POST /v1/forget` | `memory:forget` |
| Review | the queue: candidates and quarantined records | `GET /v1/review/queue` | `memory:review` |
| | approve, reject, rephrase and approve | `POST /v1/review` | `memory:review` (and `memory:write` to rephrase) |
| Principals and keys | list, add, change, disable and enable principals | `GET /v1/principals`, `PUT /v1/principals/{id}`, `POST …/disable`, `…/enable` | `principal:manage` |
| | list, create, rotate and revoke keys | `GET` and `POST /v1/keys`, `POST /v1/keys/{id}/rotate`, `…/revoke` | `principal:manage` |
| Policies | versions, the running policy, activations | `GET /v1/policies` | `policy:read` |
| | validate, diff | `POST /v1/policies/validate`, `/diff` | `policy:read` |
| | propose | `POST /v1/policies` | `policy:propose` |
| | approve, activate an earlier version, roll back | `POST /v1/policies/{version}/approve`, `/rollback` | `policy:approve` |
| Evaluation | suites, replays, quality by policy version | `GET /v1/eval/suites`, `/runs`, `/trend` | `ops:read` |
| Status and advisor | the profile advisor, counts | `GET /v1/advisor`, `GET /v1/stats` | `ops:read` |
| Audit | the newest audit events | `GET /v1/audit` | `audit:read` |

Subjects, kinds and labels are checked as on every API call
([governance.md](governance.md#access-control)): a principal limited to `customer:*` sees and
changes only those subjects in the console too.

Every change writes an audit event with the logged-in principal as its actor: `memory.write`,
`memory.supersede`, `memory.delete`, `memory.admit`, `memory.reject`, `memory.rephrase`,
`principal.put`, `principal.disable`, `principal.enable`, `key.create`, `key.rotate`,
`key.revoke`, the `policy.*` events, and `session.login` and `session.logout` for the session
itself ([governance.md](governance.md#audit-log)).

## Review and the quarantine

The Review page lists what waits for a person: **candidates** (proposals held for review: every
agent proposal where `[access] admission = "review"`, an agent's procedural memory, taxonomic
memory, a plan or a guess the statement gate held) and **quarantined** records (writes the
injection screen held back, and writes the pipeline could not process).

| Decision | On a candidate | On a quarantined record |
|---|---|---|
| Approve | committed as it is | **refused**: what the screen held is never committed as it stands |
| Reject | rejected, with your reason in the audit log | the same |
| Rephrase and approve | your wording is committed, the candidate is rejected | the same |

**Rephrase and approve** is how a quarantined record becomes a memory. The wording you write is
stored as a write of yours and passes the whole write gate like any write: redaction, the
injection screen, deduplication. If the gate holds your wording too, the record under review
stays as it was and the page tells you; the refused wording, when it is a new record and not
the text of an existing one, is kept as a `rejected` record with its own audit events, like
any write the gate refuses. If your wording is already the
text of another record with other labels or another scope, it is refused too: review that
record instead. Otherwise the new record is committed with `metadata.rephrased_from` naming
the reviewed record, which is rejected; the audit log has `memory.rephrase` (on the reviewed
record, naming its replacement) and the write's own events. The new record keeps the reviewed
record's subject, kind, tags, labels, scope, structured form, the files it is linked to
(as the store holds them when the new record is written: a file reported changed while the
record waited leaves the new record stale too) and, for a revision, the version it replaces. Its
author (`provenance.agent`) is you, not the agent that proposed the original.

A rejected or quarantined record is never recalled.

## Principals and keys

A principal is an agent, a user or an admin ([governance.md](governance.md#access-control)).
The page lists them, and adds or changes one: the subjects it may use, kinds, denied labels,
org and team, and for an agent whether it commits directly (`can_commit`) or may state the
user it acts for (`act_as`). Disabling a principal stops its keys, tokens and sessions.

A new key is shown **once**, on the page that created it; nothing stores it. Rotation makes a
key with the same permissions and lets the old one work for a day.

Whoever manages principals cannot hand out more than they hold:

- a key carries at most the permissions of the credential that creates it (and at most what
  its principal's kind allows); rotating a key needs every permission that key carries;
- a key is created or rotated only for a principal that has no more access than the manager
  (the same three rules as below): a key acts with its principal's subjects and labels,
  whatever permissions it carries;
- a principal gets subjects within the manager's own, at least the manager's denied labels,
  and kinds within the manager's own;
- a principal does not disable itself, and `admin:bootstrap` is not a stored principal.

`principal:manage` is a new permission (API 1.10). Bootstrap keys carry it. **An admin key
created before this version does not**: keys list their permissions explicitly. Create a new
key for that admin (`memhouse key create admin:ana`) to manage principals from the console.

The command line does the same as the operator, across tenants: `memhouse principal …`,
`memhouse key …`.

## Evaluation

The Evaluation page shows, for the tenant, its suites, the stored replays, and the quality
metrics **by policy version**: storage F1, retrieval F1, the stale-fact rate and the
contamination rate of the latest replay under each version, oldest version first, with the
change from the version before ([evaluation.md](evaluation.md)).

Suites are added and replayed from the command line (`memhouse eval add`, `memhouse eval
run`), and replayed by the regression gate before a policy is approved. The console reads the
results; it does not start a replay.

## The profile advisor

Lite is measured at 100,000 memories, 10,000 per subject, with one writer
([lite.md](lite.md#when-to-choose-lite-and-when-not)). The advisor compares what the
deployment holds with those sizes and says when to move to Standard.

| Measure | What it counts | Lite limit | Key |
|---|---|---|---|
| `records` | records in the store, in every state and of every tenant | 100,000 | `[advisor] lite_max_records` |
| `largest_subject_records` | records of the tenant's largest subject | 10,000 | `lite_max_subject_records` |
| `file_mb` | the database file with its write-ahead log (on Standard: the database's size) | none: reported, not judged | `lite_max_file_mb` |
| `writes_per_hour` | records written in the last hour | none: reported, not judged | `lite_max_writes_per_hour` |

A measure at or above `[advisor] warn_at` (0.8) of its limit is `near_limit`; at or above the
limit, `over_limit`. The report then recommends the Standard profile and names the command:

```text
memhouse migrate --to postgres://<user>@<host>:5432/<database> --dry-run
```

Run it as a dry run first, then without `--dry-run`
([operations.md](operations.md#moving-between-profiles)). On Standard the same values are
reported and nothing is judged: there is no next profile to recommend yet.

The same report is at `GET /v1/advisor`, and as a line of `memhouse doctor`:

```text
✓ profile lite ok: records 2 of 100000 (0%), largest_subject_records 2 of 10000 (0%), file_mb 0.6, writes_per_hour 2
```

## Security

The console closes threat T3 of the [threat model](threat-model.md): a key kept where script
can read it, pages without a Content-Security-Policy, and an API open to every origin.

### The session

- **The key is presented once.** The page sends it to `POST /v1/session` and forgets it. It
  is never in the browser's storage, in a URL or in a log.
- **The session is a cookie script cannot read**: `HttpOnly`, `SameSite=Strict`, `Path=/`,
  no `Domain`. Its value is a random secret; the store keeps only its SHA-256
  ([schema.md](schema.md#session)), so reading the database does not give a session.
- **`Secure`, and when not.** The cookie is marked `Secure` and named
  `__Host-memhouse_session`, which browsers accept only over TLS and only from this host.
  The one exception is a request for a loopback host (`localhost`, `127.0.0.1`, `[::1]`),
  where there is no TLS: the cookie is then `memhouse_session` without `Secure`. That is the
  rule of `[server] session_cookie_secure = "auto"`. On any other host over plain HTTP the
  browser drops the cookie and login does not work: put TLS in front, which you need anyway.
  `"never"` exists for a network you trust; the cookie can then be read on the wire. With an
  `https` `[server] public_url`, `"auto"` gives the `Secure` cookie whatever `Host` a proxy
  sends upstream; the plain cookie is then never set and never read. (`"never"` still gives
  the plain one: it overrides everything.)
- **CSRF.** A request made with the cookie that changes anything must carry the session's
  token in `x-memhouse-csrf`. The page reads the token from `GET /v1/session` and keeps it in
  memory only. The token is derived from the session secret, so it is not stored either.
- **Own origin only.** A request made with the cookie whose `Origin` is not the server's own
  (scheme, host and port) is refused, reads included, also from an origin on the CORS
  allow-list. So is one whose `Sec-Fetch-Site` is anything but `same-origin`: a page on a
  sibling host of the same site, another site, or a navigation.
- **What a refusal leaves.** A request the session's own rules refuse (the CSRF token, a
  listed foreign origin, `Sec-Fetch-Site`) is refused and an `access.denied` event with rule
  `csrf` is written for it (if that write fails, the failure is logged and the request is
  refused all the same); it does not count as use of the session. A request from a foreign
  origin that is not on the allow-list never gets that far: it is refused by the CORS rule before authentication,
  counted in the metric `memhouse_refused_total{kind="cors"}`, and not audited.
- **A key in the header wins.** The cookie is read only when the request carries no
  `Authorization` or `x-api-key`. API clients are not affected by any of this.
- **The idle limit** counts from the last request the server accepted. The time is stored at
  most once per interval (a twentieth of the limit, at most a minute), and the limit allows
  for that interval: a session never ends before `session_idle_secs` have passed since its
  last accepted request, and at most a minute after.
- **A store that does not answer ends no session.** When the database cannot be read, or
  the session's last use cannot be written when that is due, the request is answered `503
  unavailable` with `Retry-After`, as for a key, and the session is kept. Only `401` says a
  session is over: on `503` the page stays logged in and says to try again.
- **Restart.** Sessions are rows in the database, so they survive a restart of `memhouse
  serve` and are valid on every replica. Rows are deleted at logout, when a session past its
  end is presented, and by the hourly retention pass.

### The pages

Each of the three files is served with

```text
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self';
  connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
```

and `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy:
no-referrer`. There is no `unsafe-inline` for script **or** style: the page has no inline
script, no event-handler attribute, no `<style>` and no `style` attribute, and the script
sets appearance through classes only. The script puts data on the page as text through the
DOM, never as markup, so a memory that contains HTML is shown as its characters.

### Other origins

By default a browser page of another origin cannot call the API at all: a request with a
foreign `Origin` is refused (`403`) before anything runs, preflight or not.

`[server] cors_origins` lists the origins that may, as exact values
(`https://admin.example.com`). A wildcard is refused when the configuration is read. A
listed origin is answered with `Access-Control-Allow-Origin: <that origin>` and never with
`Access-Control-Allow-Credentials`: its pages send a key or token of their own, and cannot
use the console's session. Requests without an `Origin` (curl, SDKs, servers) are not a
browser's and are not affected.

### Behind a proxy

The server must know its own origin to tell the console's requests from another page's. One
of two:

- the proxy passes the public host on as `Host`, port included (`proxy_set_header Host
  $http_host;` in nginx; Caddy does it by default). The origin is then `https://<Host>`.
  nginx's `$host` leaves the port out, which is right only on port 443;
- or `[server] public_url = "https://memhouse.example.com"` states it. It is then the only
  origin the console is used from: a browser pointed straight at the upstream
  (`http://localhost:7077`) is refused, while clients that are not browsers are not affected. Use this when the
  proxy sends another `Host` upstream, a non-default port included
  (`https://memhouse.example.com:8443`). Under the default cookie mode it also makes the
  session cookie the `Secure` one whatever the upstream `Host` is.

Forwarding headers (`X-Forwarded-Host`, `Forwarded`) are not read: nothing tells the server
that a proxy set them. With neither of the two, the console's own requests look foreign and
are refused. See [operations.md](operations.md#reverse-proxy-and-tls).

## What is checked

| Check | What it proves |
|---|---|
| governance `console_actions` | each PROF-09 action works through a session and is audited as the logged-in principal; a principal without the permission is refused by the server and the refusal audited |
| governance `console_session` | cookie flags, nothing secret in the login answer, the stored hash, CSRF, own origin, expiry, the idle limit, logout, revocation by key and by principal |
| governance `console_csp_cors` | the policy on every file, no inline script or style in the page, nothing in the browser's storage, the origin allow-list without wildcard or credentials |
| governance `quarantine_review` | 50 quarantined records decided: rejected, or rephrased and approved; every decision applied and audited |
| governance `console_evaluation` | suites, replays and each metric by policy version, for the tenant only |
| governance `profile_advisor` | at 90% of a Lite limit the next profile and the migrate command; on Standard, a report without a recommendation |
| server tests `tests/console.rs` | the same flows in process on a Lite file, with every header |

The governance checks run over HTTP on Postgres and on SQLite
([governance.md](governance.md#proving-it-the-governance-suite)). They send what the pages
send. **The pages themselves are not run in a browser by any test**: what is tested is every
request they make, the headers they are served with, and their text.

## Limits

- No single sign-on: a session is opened with an API key.
- No limit on login attempts. A wrong key is refused and audited (`auth.failed`); rate limits
  come with quotas (threat T14).
- The console does not start an evaluation replay, edit labels, manage grants between agents
  or erase a subject; the API and the command line do.
- The memory list shows one subject at a time, 50 records a page.
- The advisor counts on demand. On a large Standard database its counts read the whole
  memory table.
