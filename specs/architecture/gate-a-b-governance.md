<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Gate A/B Governance

The durable governance operation layer replaces 0.1.0 auto-activation. It
implements `FR-GOV-1` through
`FR-GOV-22`, including the ADR-0005 peer-inline path, while preserving
`AD-GOV-1` through `AD-GOV-5`, `AD-PIPE-2`, `AD-PIPE-8`, `AINV-1`, `AINV-2`,
and `AINV-5`.

## Boundary

`MemHouse.Governance.Engine` is the only operation layer for Gate A/B
evaluation and human decisions. `MemHouse.Governance.PeerQueue` is the
peer-delivery adapter, `MemHouse.Governance.Sweeper` owns dream-time aging,
and `MemHouse.Governance.Erasure` owns subject erasure. All durable mutations
go through Ash actions under the authenticated Account tenant and PostgreSQL
RLS.

Eight persisted Ash resources raise the durable count from 28 to 36:

| Resource | Purpose |
| --- | --- |
| `GateRule` | Versioned evidence × target × sensitivity matrix cell |
| `ValidationItem` | Common curator/peer queue and conflict bundle |
| `GateDecision` | Immutable automatic and human gate history |
| `Consent` | Subject-owned, target-specific upward personal consent |
| `PeerQuery` | Frozen peer question over a validation item |
| `PeerQueryDelivery` | Session delivery and transcript-assurance evidence |
| `PeerAskPreference` | Peer-lowerable interruption limits |
| `ErasureRequest` | Durable proportionate/strict erasure result |

`KnowledgeItem` gains target level, verification state, held target, source
corroboration, supersession, revalidation, and deletion metadata. Knowledge
remains the only atom; queue, consent, history, and self-view records refer to
it rather than becoming a second knowledge store.

## Gate flow

Every newly extracted item starts as `proposed`. The matrix lookup uses the
nearest exact scope row, then the Account default row, then the conservative
built-in human rule.

Gate A uses the persisted, schema-derived source evidence level. Only a source
Peer speaking about itself is `direct`; every other source-to-subject relation
is `indirect`. Model confidence remains reviewer metadata and is never an
automatic Gate A input. Gate B never automatically places `personal` or
`restricted` knowledge.

Gate A produces one of:

- `active` for a matrix-backed automatic keep;
- `provisional` for peer-only visibility while human validation is pending;
- `rejected` for an explicit automatic or human rejection; or
- a deferred validation item for curator/peer review.

Gate B evaluates the target level, sensitivity, corroboration, and consent.
Scope/account proposals remain `held` at their source scope and are excluded
from retrieval. Personal knowledge cannot move upward until the subject grants
target-specific consent through a verified human or transcript-backed channel.
A curator approval before consent changes the validation state to
`awaiting_consent`; it does not activate or relocate the knowledge.

All human actions—approve, edit-as-replacement, reject, merge, defer, and bulk
decisions—enter through `Engine`. Edits mint a pipeline-owned replacement
and supersede the original; merges retain combined source evidence. Each
decision writes an immutable `GateDecision`, a content-safe hash-chain audit
event, a lifecycle event where state changes, and a replay-keyed validation
continuation.

## Declared-auto consent (ADR-0007)

`FR-GOV-12` always requires verified subject consent before personal knowledge
moves upward; `GateRule` cannot waive it. Accounts without a human subject
therefore keep those items `held` unless an operator explicitly declares
unattended consent.

Two off-by-default switches enable that declaration:

- Account-scoped `Account.consent_mode="auto"`, restricted to `account_admin`
  and audited with `MemHouse.Governance.Changes.AuditResource`.
- Deployment-wide `MEMHOUSE_GOVERNANCE_UNATTENDED`, loaded by
  `MemHouse.Governance.UnattendedMode`, logged at boot, and reported by
  `GET /api/ready`.

Either makes `Engine.resolve_consent/5` write a real pipeline-owned `Consent`
with `status: "granted"`, `verified: true`, and channel
`"auto:account_mode"` or `"auto:unattended_deployment"`. Existing readers need
no special case, and the channel keeps the declaration auditable.

When ordinary ingest supplies no `target_scope_id` for a scope-level proposal,
the gate uses the item's `scope_id` for the hold, validation item, and consent;
none of those target fields receives `nil`.

Full design: `specs/design/2026-07-30-unattended-governance-consent-design.md`.
Decision record: `specs/adr/0007-unattended-governance-consent.md`.

## Human and machine surfaces

`/governance` is a password-session-only LiveView for account administrators
and curators. It exposes the queue, provenance/conflict IDs, individual
actions, edits, merges, and bulk decisions. Machine API keys cannot establish
that session, and `MemHouse.Policy.HumanRoleIn` prevents them from invoking
curator Ash actions directly.

Authenticated human peers use `/api/v1/self/knowledge` to inspect their subject
knowledge, contest or redact it, and request proportionate or strict erasure.
Machine credentials are rejected from these human-governance routes.
Erasure removes subject observations, knowledge and inline delivery text,
scrubs shared provenance in proportionate mode, removes all sourced knowledge
in strict mode, and marks/recomputes affected projections and entities.
Content-safe audit IDs, hashes, actions, and counts survive.

The AshAi MCP surface exposes only:

- `ingest`
- `get_context`
- `search`
- `ask`
- `query_knowledge`
- `resolve_validation`
- `set_ask_preference`

There are no curator tools. Reads may attach one relevant question for the
calling peer under a separate 15 ms deadline. Timeout, error, rate limit, or no
match leaves the read unchanged; tests only raise the deadline for deterministic
scheduling.

`resolve_validation` treats the tool answer as a claim. Confirmation or
rejection changes knowledge only when an assistant transcript turn after
delivery contains the frozen statement text under NFKC/case/whitespace/quote
normalization. An unverified channel only defers the timer and can never grant
upward consent. Correction text is recorded as supplied evidence but cannot
mint knowledge through the MCP tool.

## Aging and recomputation

The existing revalidation, expiry, dream-time, validation-continuation, and
answer-correlation AshOban lanes now call real governance operations:

- due active knowledge becomes `needs_revalidation` and receives a peer query;
- expired knowledge becomes `expired`;
- overdue validation escalates once, then auto-rejects;
- unanswered peer queries decay confidence and become stale;
- verified confirmation resets the timer and raises confidence; and
- erasure recomputes or marks affected projections and entity derivations.

The same workflows run with pg0 or operator-run Postgres; there is no alternate
queue, cache, or governance implementation.

## `poc-0` transition

HTTP shapes, identity-derived tenancy, downward inheritance, raw durability,
pipeline-only creation, deterministic fallback, and fixture normalization remain
regression floors. Lifecycle semantics advance to `f4-1`: ingest records
`proposed → provisional` by default instead of the removed
`poc_auto_gate → active` shortcut, and health reports `f4-1`. Extractor and
retrieval profile versions remain the historical `poc-0` contract here. The
model layer later advances extraction and health to `f5-1`; retrieval later
advances retrieval and context profiles to `f7-1`.

## Evidence

- Resource migration:
  `priv/repo/migrations/20260727220024_f4_real_gate_a_b_governance.exs`
- Generated resource snapshots: `priv/resource_snapshots/repo/`
- Gate A/B governance acceptance suite:
  `test/memhouse/f4_real_gate_a_b_governance_test.exs`
- Updated baseline contract evidence:
  `test/memhouse/poc_contract_test.exs` and
  `test/memhouse_web/controllers/memory_controller_test.exs`
- Operation layer: `lib/memhouse/governance/`
- Human and self-service adapters: `lib/memhouse_web/`
- Declared-auto consent: `lib/memhouse/governance/unattended_mode.ex`,
  `MemHouse.Governance.Engine.resolve_consent/5` in
  `lib/memhouse/governance/engine.ex`, and `consent_mode`/`configure_governance`
  on `MemHouse.Accounts.Account` in `lib/memhouse/accounts.ex`; regression
  and RBAC evidence in `test/memhouse/f4_real_gate_a_b_governance_test.exs`
- Deterministic Gate A evidence: ADR 0012 and
  `test/cartulary/model/schema_extraction_test.exs`
