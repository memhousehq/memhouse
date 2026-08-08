<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# SDK helpers

Two transport-neutral modules turn a skill-readiness report into a run-or-stop
decision:

- [`sdk/typescript/src/skill-readiness.ts`](https://github.com/memhousehq/memhouse/blob/main/sdk/typescript/src/skill-readiness.ts)
- [`sdk/python/memhouse/skill_readiness.py`](https://github.com/memhousehq/memhouse/blob/main/sdk/python/memhouse/skill_readiness.py)

!!! warning "These are not generated SDKs"
    These files provide no HTTP/MCP client, authentication, retries, request
    building, or pagination. Nothing is published to npm or PyPI; copy or
    vendor the needed file.

    Generated clients and a published OpenAPI description of the HTTP surface
    do not exist in this release — see [Limitations](../reference/limitations.md).

The modules perform no network, filesystem, or model I/O. Fetch and parse the
report, then pass the inner object to the helper.

## Getting a report

Two surfaces produce the identical report:

- `POST /api/v1/readiness` with a bearer credential — pass the **inner**
  object, not the `{"data": ...}` envelope;
- the MCP tool `check_readiness`, which returns the report directly.

`report_version` is `"f9-1"` and versions both the selector language and report
shape. Reject unknown versions.

## Fields the helpers read

| Field | Meaning |
| --- | --- |
| `blocked` | True when any required requirement is unmet. The authoritative go/no-go flag. |
| `ready` | True exactly when there are no blockers. |
| `blockers` | Unmet requirements whose `level` is `required`. |
| `warnings` | Unmet requirements whose `level` is `preferred`. |
| `<gap>.key` | Stable requirement name from the card. |
| `<gap>.status` | `missing`, `stale`, or `missing_card`. |
| `<gap>.source_policy` | `ask-peer`, `from-memory`, or `either`. |
| `<gap>.elicitation` | Whether asking is allowed, an optional authored prompt, and the required round trip. |

## What the helpers do

- Raise a blocked error when `blocked` is true.
- Preserve preferred gaps as non-blocking warnings.
- Convert prompted `ask-peer` and `either` gaps into elicitation prompts.
- Keep `from-memory` gaps and missing-card blockers as hard blockers that
  cannot be resolved by questioning the peer.

## TypeScript

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

Requires ES2015 or newer. When targeting ES5, `class ... extends Error` loses
its prototype chain and `instanceof` silently returns false — check
`error.name` instead, or raise the target.

## Python

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

Requires Python 3.7 or newer. No third-party dependencies.

Use `build_elicitation_plan` / `buildElicitationPlan` to inspect a report
without raising — for example to render a readiness panel. Only
`can_proceed` / `canProceed`, which mirrors the server's `blocked` flag, may
gate a run.

## Rules a caller must not break

**Never override a server blocker.** `blocked` is decided server-side against
the caller's authorisation, the inherited card version, and lifecycle
freshness. A client cannot see enough to second-guess it. Catching the error
and proceeding anyway defeats the entire check.

**Never write knowledge from an elicited answer.** Every elicitation descriptor
spells out the round trip: `submit_via: "ingest"`, then
`then: "check_readiness"`. The answer is submitted as an ordinary raw
observation, the pipeline is the only writer of knowledge, and what it extracts
must pass the gates. Re-running the skill without fetching a fresh report is a
bug.

**An absent card is a blocker, not permission.** A scope with no active
requirement card produces a `missing_card` blocker. Treating it as "no
requirements, therefore ready" inverts the intended failure direction.

**Keep prompts and answers out of logs.** Prompt text is authored card content
and answers are peer content. Requirement keys, knowledge ids, and counts are
safe to log; free text is not.

## Where authority lives

The server stays the authority for requirement matching, lifecycle freshness,
Account isolation and scope authorisation, and which inherited card version
applies. These modules add no policy of their own — they read a verdict and
make it hard to ignore.
