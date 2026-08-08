<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Skill Readiness And Procedural Memory

Status: implemented

Versioned `SkillRequirementCard` records define knowledge prerequisites;
`check_readiness(skill, peer, scope)` returns a reasoning-free gap report. This
implements `FR-SK-1` through `FR-SK-7`,
`FR-API-9`, `FR-API-15`, `AINV-2`, `AINV-6`, `AD-DATA-4`, and the
`check_readiness` NFR target.

## Authored card boundary

`SkillRequirementCard` remains one of 38 authoritative Ash Resources. Readiness
adds a description and pinned `requirement_schema_version` (`f9-1`), not a new
durable type. `f9-1` is a historical contract tag.

Cards are authored configuration, not reasoned knowledge:

- publishing creates a new immutable version and deactivates the prior version
  at the same scope and skill;
- the operation is serialized by an Account-local advisory lock;
- version/deactivation and content-safe hash-chain audit happen in one
  Account-scoped transaction;
- card requirements do not pass Gate A/B and cannot satisfy another card; and
- only authorized Account administrators, curators, or internal system actors
  can mutate a card. MCP exposes readiness only, never authoring.

For each scope on the root-to-target path, readiness selects the highest active
card version. Requirements merge by stable `key`: a nearer scope replaces an
ancestor's key, a new key extends the inherited contract, and
`{"key": "...", "enabled": false}` removes an inherited key. This is the
nearest-wins behavior of `FR-SK-3` without copying whole cards into every
descendant.

## Selector language `f9-1`

Each normalized requirement has this shape:

```json
{
  "key": "brand-voice",
  "description": "Current brand voice",
  "selector": {
    "kind": ["preference"],
    "subject": "scope",
    "sensitivity": ["internal"],
    "target_level": ["scope"],
    "source_types": ["message"],
    "verification": ["peer_verified"],
    "minimum_confidence": 0.7,
    "minimum_corroboration": 1
  },
  "level": "required",
  "source_policy": "either",
  "freshness": {"revalidated_within_seconds": 2592000},
  "prompt": "How should this scope's brand voice sound?",
  "enabled": true
}
```

All selector fields are optional, but the requirement `key`, `level`, and
`source_policy` are mandatory. Scalar metadata values normalize to one-element
lists. Unknown keys, unknown enum values, duplicate keys, invalid confidence
ranges, and non-positive freshness/corroboration limits are rejected before a
version is published.

Selectors match knowledge metadata only. They do not run text search or a
model, and they never treat profiles, entities, or card content as knowledge.
`subject` is `peer`, `scope`, or `either`; the target peer and scope are
resolved inside the authenticated Account. `source_types` is evaluated from
durable provenance. `ask-peer` is satisfied only when matching knowledge has a
message provenance from the target peer; `from-memory` and `either` may use any
otherwise matching governed source.

## Readiness and lifecycle rules

The readiness engine reads the target scope plus authorized ancestors and
considers only:

- `active` knowledge; and
- `provisional` knowledge usable by the relevant/calling peer.

It also loads `expired` and `needs_revalidation` candidates only to classify a
matching gap as stale. A nominally active item is stale immediately when
`expires_at` or `revalidate_after` is due, so a delayed sweeper cannot create a
readiness window. A requirement-level `revalidated_within_seconds` limit uses
the most recent active/provisional lifecycle transition as its deterministic
freshness watermark; embedding/index updates cannot make knowledge appear
newly validated.

The `f9-1` report contains card versions, effective requirements, matched and
stale knowledge ids, `blockers`, `warnings`, and:

- `ready: false`, `blocked: true` when any required gap exists;
- a non-blocking warning for each missing/stale preferred requirement;
- `status: missing`, `stale`, `satisfied`, or `missing_card`; and
- an elicitation descriptor only when the source policy is `ask-peer` or
  `either`.

An absent active card is a blocker rather than silent permission. Elicited text
must be submitted through raw `ingest`, processed through the model layer's
structured extraction and Gate A/B governance, then checked again. Neither the
server nor an SDK helper writes knowledge from an elicitation answer.

## Surfaces and governance

The same readiness implementation is available through:

- `POST /api/v1/readiness`;
- the AshAi MCP `check_readiness` tool; and
- `MemHouse.Skills.check_readiness/2` for internal callers.

The password-session governance LiveView lists cards and publishes normalized
versions from reviewed `f9-1` JSON. Machine credentials cannot author cards.

`sdk/typescript/src/skill-readiness.ts` and
`sdk/python/memhouse/skill_readiness.py` consume the report, preserve warnings,
build elicitation prompts, and throw when required gaps block. They are
transport-neutral helpers, not the complete generated clients still tracked in
`specs/roadmap/beta-roadmap.md`.

Readiness telemetry records only report identity, counts, and the final boolean.
It does not record skill names, card descriptions/selectors, statements,
elicitation prompts, or matched content.

## Migration and evidence

Migration:
`priv/repo/migrations/20260728101329_f9_skill_readiness_procedural_memory.exs`.
It adds `description` and the non-null `f9-1` identity. Snapshot:
`priv/resource_snapshots/repo/skill_requirement_cards/`.

Deterministic evidence is in
`test/memhouse/f9_skill_readiness_procedural_memory_test.exs`, covering:

- selector validation and requirement-level nearest-scope inheritance;
- transactional plain versioning and content-safe audit;
- required blocker versus preferred warning behavior;
- elicitation descriptors and source policy;
- due, expired, and `needs_revalidation` rejection; and
- HTTP, MCP metadata, governance UI, and SDK helper exposure.
