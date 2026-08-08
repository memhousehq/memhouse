<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# MemHouse skill-readiness helpers

Two small, transport-neutral modules that interpret one MemHouse API response — the
skill-readiness report — and turn it into a decision a program can act on: run the
skill, or stop and ask the peer some questions first.

- `typescript/src/skill-readiness.ts`
- `python/memhouse/skill_readiness.py`

Both implement the same three things and nothing else: a plan builder, an enforcing
guard, and the error the guard raises.

## What these are not

**Not generated SDKs.** There is no HTTP client, no MCP client, no authentication
handling, no retry policy, no request builder, and no pagination here. There is also no
package manifest — no `package.json`, no `pyproject.toml` — because nothing is published
to npm or PyPI. Copy or vendor the file you need into your own project.

Generated clients and a published OpenAPI description of the HTTP surface do not exist in
this release. Do not describe them as shipped, and do not build a release process that
assumes they are there.

The modules perform no I/O whatsoever: no network, no filesystem, no model calls. You
fetch the report yourself, parse it, and pass the resulting object in. That is what makes
them safe to call on a hot path, inside a retry loop, or in a unit test with a literal
fixture.

## Background: what a readiness report is

A **skill requirement card** is human-authored procedural memory. It states, for one skill
in one scope, which governed knowledge must be present before an agent runs that skill.
Cards are authored configuration rather than reasoned knowledge: they are plainly
versioned, they never pass the knowledge approval gates, and a card can never satisfy
another card's requirement. Publishing one requires the `account-admin`, `curator`, or
internal system role, and no MCP tool exposes card authoring — the tool surface offers
`check_readiness` and nothing that writes a card.

`check_readiness(skill, peer, scope)` compares that card against what the peer actually
knows and returns a **readiness report**. The evaluation is reasoning-free — it matches
knowledge metadata, runs no text search, and calls no model — so the same inputs always
produce the same report.

Requirement keys inherit down the scope tree with the nearest scope winning: a nearer
card's key replaces an ancestor's, a new key extends the inherited contract, and a key
marked disabled removes an inherited one. A gap you see may therefore originate several
scopes above the one you asked about.

Only two kinds of knowledge can satisfy a requirement: `active` knowledge the caller is
authorized to read, and `provisional` knowledge belonging to the calling peer. Expired
items and items due for revalidation count as gaps from the instant they come due, so a
background sweeper that has not yet run cannot leave a window in which a skill looks ready
and is not.

## Getting a report

Two surfaces produce the identical report:

- `POST /api/v1/readiness` with a bearer credential. Body: `skill` and `scope_path` are
  required; `peer_id` or `peer_key` may name another peer the caller is allowed to read,
  otherwise the authenticated caller is used. The Account is taken from the credential,
  never from the request body. The response wraps the report as `{"data": {...}}` — pass
  the inner object to these helpers, not the envelope.
- the MCP tool `check_readiness`, which returns the report directly.

The report carries `report_version`, currently the string `"f9-1"`. That value versions
the requirement selector language together with this gap-report shape. It is a contract
identity, not an application version: changing it is a deliberate contract transition that
obliges a maintainer to update the contract evidence, the changelog, and every client that
pins it. Clients may and should reject a value they do not recognise.

Fields the helpers read:

| Field | Meaning |
| --- | --- |
| `blocked` | True when any required requirement is unmet. The authoritative go/no-go flag. |
| `ready` | True exactly when there are no blockers. |
| `blockers` | Unmet requirements whose `level` is `required`. |
| `warnings` | Unmet requirements whose `level` is `preferred`. |
| `<gap>.key` | Stable requirement name from the card. |
| `<gap>.status` | `missing`, `stale`, or `missing_card`. |
| `<gap>.source_policy` | `ask-peer`, `from-memory`, or `either`. |
| `<gap>.elicitation` | `allowed`, an optional authored `prompt`, and the required round trip. |

The report contains more than this — the matched and stale knowledge ids, each
requirement's selector, the originating scope, the card version. Gap objects reach the
plan's `warnings` and `hardBlockers` untouched, so those extra fields survive; the
`prompts` list is a narrowed projection carrying only the key, the prompt, and whether
the gap blocks.

## What the helpers do

- Refuse to continue when `blocked` is true, by raising `SkillReadinessBlockedError`.
- Keep preferred gaps as non-blocking warnings, so a caller can note degraded input and
  carry on rather than silently losing the signal.
- Turn `ask-peer` and `either` gaps that carry an authored prompt into elicitation
  prompts, flagged `blocking` when the underlying requirement is required.
- Separate out the required gaps no question can close — `from-memory` requirements, and
  the blocker raised when no active card is visible at all — as hard blockers, so a caller
  does not present an unanswerable situation to the peer as an interview.

## Rules a caller must not break

**Never override a server blocker.** `blocked` is decided server-side against the caller's
authorization, the inherited card version, and lifecycle freshness. A client cannot see
enough to second-guess it. Required gaps block execution; preferred gaps only warn.
Catching the error and proceeding anyway defeats the entire check.

**Never write knowledge from an elicited answer.** Neither the server nor these helpers
turn an answer into a fact. Every elicitation descriptor spells out the round trip:
`submit_via: "ingest"`, then `then: "check_readiness"`. The answer is submitted as an
ordinary raw observation, the extraction pipeline is the only writer of knowledge, and
what it extracts must pass the approval gates before it can satisfy anything. Re-running
the skill without fetching a fresh report is a bug.

**An absent card is a blocker, not permission.** A scope with no active requirement card
produces a `missing_card` blocker. Treating it as "no requirements, therefore ready"
inverts the intended failure direction.

**Keep prompts and answers out of logs.** Prompt text is authored card content and answers
are peer content. Server-side readiness telemetry deliberately records only report
identity, counts, and the final boolean — no skill names, card descriptions, selectors,
statements, prompts, or matched content. Client-side logging should hold the same line.
Requirement keys, knowledge ids, and counts are safe to log; free text is not.

## Usage

### TypeScript

```ts
import {
  requireSkillReady,
  SkillReadinessBlockedError,
} from "./skill-readiness";

const response = await fetch("https://memhouse.example/api/v1/readiness", {
  method: "POST",
  headers: {
    authorization: `Bearer ${apiKey}`,
    "content-type": "application/json",
  },
  body: JSON.stringify({ skill: "write-copy", scope_path: "/acme/marketing" }),
});

const { data: report } = await response.json();

try {
  const plan = requireSkillReady(report);
  for (const warning of plan.warnings) {
    console.warn("proceeding without preferred input:", warning.key);
  }
  await runSkill();
} catch (error) {
  if (!(error instanceof SkillReadinessBlockedError)) throw error;

  for (const blocker of error.plan.hardBlockers) {
    console.error("needs governed knowledge or a published card:", blocker.key);
  }

  // Ask, then submit each answer through ordinary ingest and re-check. Do not
  // run the skill on the strength of the answers alone.
  for (const prompt of error.plan.prompts) {
    const answer = await askPeer(prompt.prompt);
    await ingestObservation(answer);
  }
}
```

Requires ES2015 or newer. When targeting ES5, `class ... extends Error` loses its
prototype chain and `instanceof SkillReadinessBlockedError` silently returns false — check
`error.name` instead, or raise the target.

### Python

```python
from memhouse.skill_readiness import (
    SkillReadinessBlockedError,
    require_skill_ready,
)

report = http_post(
    "/api/v1/readiness",
    {"skill": "write-copy", "scope_path": "/acme/marketing"},
)["data"]

try:
    plan = require_skill_ready(report)
except SkillReadinessBlockedError as blocked:
    for gap in blocked.plan.hard_blockers:
        log.error("needs governed knowledge or a published card: %s", gap["key"])

    # Ask, then submit each answer through ordinary ingest and re-check.
    for prompt in blocked.plan.prompts:
        ingest_observation(ask_peer(prompt.prompt))
    raise

for warning in plan.warnings:
    log.warning("proceeding without preferred input: %s", warning["key"])

run_skill()
```

Requires Python 3.7 or newer. Annotations are postponed via
`from __future__ import annotations`, so the builtin generic syntax needs no typing
backport. There are no third-party dependencies.

Use `build_elicitation_plan` / `buildElicitationPlan` directly when you want to inspect a
report without raising — for example to render a readiness panel. It returns the same plan
and never decides on its own that execution is acceptable; only `can_proceed` /
`canProceed`, which mirrors the server's `blocked` flag, may gate a run.

## Where authority lives

The server stays the authority for requirement matching, lifecycle freshness, Account
isolation and scope authorization, and which inherited card version applies. These modules
add no policy of their own — they read a verdict and make it hard to ignore.
