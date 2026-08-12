# ADR 0007: Unattended governance consent

## Status

Accepted

## Context

`FR-GOV-12` requires the subject's own consent, not merely a curator's
approval, before personal knowledge attributes upward to a shared scope.
`MemHouse.Governance.Engine.consent_required?/3` enforces this
unconditionally for any `personal`-sensitivity item aimed above its subject's
peer level, and `MemHouse.Governance.Consent.decide` refuses a `"granted"`
verdict that did not arrive over a channel the system can verify belongs to
the real subject — by design, so a matrix cell or a curator can never waive a
subject's own say over their own information.

That guarantee has no exception for accounts where no real human subject
exists: evaluation harnesses, benchmark corpora, and imported historical data
about third parties who hold no Peer identity in the system. Confirmed
empirically against a benchmark account: 28 of 29 pending `ValidationItem`
rows stayed permanently blocked after `account_admin` approval, across
confidence values from 0.225 to 1.0, because `decide/4` correctly reports
`consent_required: true` and there is no supported path to a verified grant
for a subject who was never a real peer. `MemHouse.Governance.GateRule`'s
existing `auto_keep`/`auto_place` modes do not help — the consent check runs
independently of and after Gate A/B, per `consent_required?/3`'s own
moduledoc comment explaining why that is deliberate.

This is squarely a human-governance-semantics question — "who may approve
knowledge, consent, or scope promotion" — one of the areas `ADR-0002` reserves
as human-only. The decision below was made interactively with the account
administrator who scoped the request, not inferred or auto-applied.

## Decision

MemHouse adds two independent, orthogonal, off-by-default switches that let
an operator explicitly declare that an account, or an entire deployment
process, has no real human subject and no human curator in the loop:

1. `MemHouse.Accounts.Account.consent_mode`: `"subject_required"` (default)
   | `"auto"`, settable only by a password-session `account_admin` (narrower
   than `curator`) through a dedicated, audited action.
2. `config :memhouse, :governance, unattended: boolean`
   (`MEMHOUSE_GOVERNANCE_UNATTENDED`), a boot-time deployment-wide flag for
   a process that never has a console session at all — the case a single
   per-account toggle cannot reach.

Neither switch changes what consent *means*, what `GateRule.requires_consent`
does (it remains inert, exactly as documented), or how Gate A/B automation
works. When either is active, the engine does not skip the consent check —
it **auto-grants** it: the pipeline actor writes a real `Consent` row,
`status: "granted"`, `verified: true`, distinguished from a real subject's
grant only by its `channel` value (`"auto:account_mode"` or
`"auto:unattended_deployment"`). Every existing reader of `Consent`
(`approve!/4`, console, history, future export) sees an ordinary granted row;
the audit trail is what makes the bypass visible, not a hidden code path.

`FR-GOV-12` is amended with this narrow carve-out: consent may be auto-granted
by the pipeline only for an account or deployment that has made this explicit
declaration. It is unchanged for every account and deployment that has not.

The auto-grant needed a `target_scope_id` resolution fix to reach the ordinary
ingestion path, not only `request_promotion/3`.

## Consequences

Evaluation, benchmark, and import workloads against synthetic or
non-participating subjects gain a legitimate, audited, supported path to
completion, instead of permanently stuck `held` knowledge with no way out
regardless of `GateRule` configuration or curator action.

The cost is a second thing every future reader of `Consent` needs to know:
`status: "granted"` no longer always means a subject spoke. That is
mitigated by keeping the distinction entirely in the existing `channel`
field rather than adding new status values or new code paths at the
consumption sites, and by making both switches loud (audited
`account_admin`-only writes; a boot-time log line and an `/api/ready` field
for the deployment flag) rather than something that can be flipped silently
or by a machine credential.

This does not touch Gate A/B automation, which remains entirely `GateRule`'s
decision, and does not touch the real-subject consent path
(`subject_consent/6`), which is unchanged.

## Anchors

- `FR-GOV-12` — narrowed here with an explicit, declared-account/deployment
  carve-out; unchanged otherwise.
- `AINV-3` (blast radius scales the bar) — the reason the override is
  `account_admin`-only, not `curator`, and audited like `GateRule`.
- `AD-SEC-1` — the account wall; the deployment-wide switch is per-process,
  not a cross-account bypass.
- `ADR-0002` — human governance semantics as a human-only decision area; this
  ADR is the recorded human decision it requires.

## Related Documents

- `specs/architecture/gate-a-b-governance.md`
- `specs/adr/0002-l3-automation-boundary.md`
