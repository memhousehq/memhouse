# Unattended governance consent — design

## 1. Problem

`MemHouse.Governance.Engine.consent_required?/3` treats every `personal`
knowledge item aimed above its subject's own peer level as consent-blocked,
regardless of `GateRule` configuration:

```elixir
defp consent_required?(knowledge, rule, target_level),
  do:
    target_level != "peer" && knowledge.sensitivity == "personal" &&
      (rule.requires_consent || knowledge.sensitivity == "personal")
```

This is deliberate (`FR-GOV-12`): a curator's approval must never substitute
for the subject's own say over their own personal information, and
`Consent.decide` refuses a `"granted"` verdict that did not arrive over a
verified channel (a real subject, or a pipeline actor holding transcript
proof).

That guarantee has no escape valve for accounts that have no real human
subject at all — evaluation harnesses, benchmarks, and imported historical
corpora about third parties who never hold a Peer identity in the system.
Empirically: 28 of 29 pending `ValidationItem` rows in a benchmark account
stayed blocked after `account_admin` approval, because `decide/4` correctly
reported `consent_required: true` and `Consent.decide` has no channel it can
verify for a subject who does not exist.

A second, structural gap compounds this. The ordinary ingestion path
(`MemHouse.Memory`) calls `Engine.evaluate_proposal(knowledge, actor)` with no
`:target_scope_id` option. `request_consent!/3` is only reachable when
`is_binary(target_scope_id)`, and `Consent.target_scope_id` is
`allow_nil?: false` — so for a direct (non-promotion) proposal, **no `Consent`
row is ever opened at all**, pending or otherwise. The block a curator hits in
`approve!/4` is not "consent requested and refused"; it is "consent was
structurally unrequestable for this path, only for `request_promotion/3`."

## 2. Decisions

1. Two independent, orthogonal switches, both defaulting to today's behavior
   exactly:
   - `MemHouse.Accounts.Account.consent_mode` — `"subject_required"`
     (default) | `"auto"`. Per-account, admin-set, audited.
   - `config :memhouse, :governance, unattended: boolean`
     (`MEMHOUSE_GOVERNANCE_UNATTENDED`, default `false`). Per-deployment
     process, no Account row required.
2. Neither switch touches `GateRule.requires_consent`, which stays exactly as
   inert as its moduledoc already states. This is a new, separate mechanism —
   not a matrix waiver a curator could quietly flip.
3. When either switch is active for an item's account, the engine does not
   silently skip the consent check — it **auto-grants** it: writes a real
   `Consent` row (`status: "granted"`, `verified: true`) via the pipeline
   actor, with a `channel` value that names which switch fired. Every
   downstream reader of `Consent` (`approve!/4`, console, history, export)
   sees an ordinary granted row and needs no special-case code; the only
   difference from a real grant is the `channel` field, which is exactly what
   makes it auditable.
4. `target_scope_id` resolution is fixed as part of this change: when no
   explicit target scope was supplied (the ordinary-ingestion case), the
   consent target is `knowledge.scope_id` — the scope the item already lives
   in, since "widening" a direct scope/account-level proposal means becoming
   visible to that scope's membership, not the subject alone. This is
   required for the auto-grant to reach the reported failure at all: without
   it, only the `request_promotion/3` path would ever exercise the new
   mechanism. It also happens to make the real, human-subject consent path
   reachable for direct proposals for the first time — previously dead code,
   not a behavior this design intentionally changes for real subjects.
5. `consent_mode` may only be set by a password-session `account_admin` —
   narrower than `curator`, because this is a bigger blast radius than
   anything a curator can otherwise do. It is a dedicated action
   (`configure_governance`), not folded into the generic `:update`, so it
   gets its own audited change like `GateRule` create/update already have.

## 3. Architecture

### 3.1 `MemHouse.Accounts.Account`

New attribute:

```elixir
attribute :consent_mode, :string,
  allow_nil?: false,
  default: "subject_required",
  public?: true
```

New action, audited the same way `GateRule`'s `:create`/`:update` are
(`MemHouse.Governance.Changes.AuditResource`, category `"configuration"`,
action `"account.consent_mode_changed"`, content field `:consent_mode`):

```elixir
update :configure_governance do
  accept [:consent_mode]

  validate one_of(:consent_mode, ["subject_required", "auto"])

  change {MemHouse.Governance.Changes.AuditResource,
          category: "configuration",
          action: "account.consent_mode_changed",
          resource_type: "account",
          content_fields: [:consent_mode]}
end
```

Policy: restricted to `{MemHouse.Policy.HumanRoleIn, roles: [:account_admin]}`
only — no `curator`, no `pipeline?` bypass. The pipeline never needs to set
this; only a human declares an account synthetic.

### 3.2 Deployment-wide config

```elixir
# config/runtime.exs
config :memhouse, :governance,
  unattended: System.get_env("MEMHOUSE_GOVERNANCE_UNATTENDED") == "true"
```

Read through a small accessor, not `Application.get_env/3` scattered inline:

```elixir
defmodule MemHouse.Governance.UnattendedMode do
  @moduledoc """
  Whether this deployment process has declared itself to have no human
  governance participant at all.

  Checked once per proposal evaluation, never cached across config changes
  (there are none at runtime — this is read at boot), and consulted only by
  `MemHouse.Governance.Engine`'s consent resolution. It does not affect Gate
  A/B automation, which is governed entirely by `GateRule` as before.
  """

  @doc "True when MEMHOUSE_GOVERNANCE_UNATTENDED was set at boot."
  def enabled?, do: Application.get_env(:memhouse, :governance, [])[:unattended] || false
end
```

Application boot logs a `Logger.warning` when `enabled?/0` is true, naming
what it disables. `GET /api/ready` gains a `governance.unattended` boolean
field alongside existing component-status fields — content-safe, matches
existing readiness-payload conventions.

### 3.3 `MemHouse.Governance.Engine`

Consent resolution becomes a three-way outcome instead of a boolean gate,
computed wherever the engine currently either blocks on
`consent_required?/3` (the `proposal_outcome/3` fast-accept check) or opens a
request (`evaluate_proposal/3`'s defer branch, `request_promotion/3`):

```elixir
# :not_required   — consent_required?/3 is false; nothing to do.
# {:granted, row}  — auto mode is active; a granted Consent row was written.
# {:pending, row}  — ordinary path; ask the subject.
defp resolve_consent(knowledge, rule, target_level, target_scope_id, actor) do
  cond do
    not consent_required?(knowledge, rule, target_level) ->
      :not_required

    auto_consent?(knowledge.account_id, actor) ->
      {:granted, auto_grant_consent!(knowledge, target_scope_id || knowledge.scope_id, actor)}

    true ->
      {:pending,
       request_consent!(knowledge, target_scope_id || knowledge.scope_id, pipeline_actor(actor))}
  end
end

defp auto_consent?(account_id, actor) do
  MemHouse.Governance.UnattendedMode.enabled?() or
    account!(account_id, actor).consent_mode == "auto"
end

# Writes the same shape a real subject grant would: status "granted",
# verified true, decided_by_peer_id nil (no peer decided). `channel` is the
# only thing distinguishing this from a real grant, and it is what makes the
# bypass auditable rather than silent.
defp auto_grant_consent!(knowledge, target_scope_id, actor) do
  pipeline = pipeline_actor(actor)

  request_consent!(knowledge, target_scope_id, pipeline)
  |> Ash.Changeset.for_update(:decide, %{
    status: "granted",
    channel: auto_consent_channel(knowledge.account_id, actor),
    verified: true,
    decided_by_peer_id: nil,
    decided_at: Clock.utc_now()
  })
  |> Ash.Changeset.set_tenant(knowledge.account_id)
  |> Ash.update!(actor: pipeline)
end

defp auto_consent_channel(_account_id, _actor) do
  if MemHouse.Governance.UnattendedMode.enabled?(),
    do: "auto:unattended_deployment",
    else: "auto:account_mode"
end
```

`proposal_outcome/3` uses `resolve_consent/5`'s result instead of the bare
`consent_required?/3` call: `:not_required` or `{:granted, _}` both count as
satisfied for the fast-accept path; `{:pending, _}` forces `:defer`, same as
today. The defer branch and `request_promotion/3` call `resolve_consent/5`
instead of their current bare `consent_required?/3` + `request_consent!/3`
pair; a `{:granted, _}` result there means the item still goes through
`:held`/`awaiting curator`, same as any other Gate B human-mode cell — auto
mode only removes the *consent* block, not the Gate A/B human-review modes,
which remain entirely `GateRule`'s decision as before. `approve!/4` is
**unchanged**: it reads `Consent` through the existing `consent_for/3`, and a
`channel: "auto:..."` granted row satisfies its existing
`consent.status != "granted" || !consent.verified` check exactly like a real
grant would.

`account!/2` is a new private point-read (`Ash.get!`-style, elevated via
`pipeline_actor/1`, the same pattern `scope!/3` and `knowledge!/3` already
use). It does not set a tenant: `MemHouse.Accounts.Account` is not
multitenant — it *is* the tenant — the same reason
`MemHouse.DataLayer.with_actor/2` reads it without one.

### 3.4 What does not change

- `GateRule.requires_consent` — still inert, still cannot waive consent by
  itself, per its own moduledoc.
- Gate A/B automation — entirely `GateRule`'s decision, untouched by either
  switch.
- `Consent`'s resource contract — no new status value, no new columns; only a
  new class of `channel` string.
- `subject_consent/6` — the real-subject answer path is untouched.

## 4. Security and audit

- `consent_mode` changes are `account_admin`-only and hash-chain audited
  (category `"configuration"`), matching `GateRule`.
- `MEMHOUSE_GOVERNANCE_UNATTENDED` is boot-time only (no runtime toggle),
  logged loudly, and visible on `/api/ready` — an operator or auditor can
  always tell, without reading source, whether a given deployment process has
  disabled subject consent.
- Every auto-granted `Consent` row carries a `channel` distinguishing it from
  a real grant (`"auto:account_mode"` / `"auto:unattended_deployment"` vs a
  real subject's channel, e.g. `"self_view"`, `"mcp"`). Nothing about the
  `Consent` resource's read surface needs to change for this to be queryable
  — the existing `channel` attribute already carries it.
- `FR-GOV-12` (peer consent required for upward attribution of personal
  knowledge) is amended with an explicit, narrow carve-out: an account
  explicitly declared `consent_mode: "auto"`, or a deployment process
  explicitly declared unattended, may have that consent auto-granted by the
  pipeline rather than the subject. The requirement is unchanged for every
  account and deployment that has not made that declaration.

## 5. Testing

Extend `test/memhouse/f4_real_gate_a_b_governance_test.exs`:

- Default (`consent_mode: "subject_required"`, `unattended: false`) is
  byte-for-byte unchanged — this touches the `poc-0` baseline's gate and
  needs an explicit regression assertion, not just absence of a new failure.
- `consent_mode: "auto"` unblocks both the direct-proposal path (no
  `target_scope_id` supplied) and the `request_promotion/3` path; the
  resulting `Consent` row has `status: "granted"`, `verified: true`, and a
  `channel` starting `"auto:"`.
- `MEMHOUSE_GOVERNANCE_UNATTENDED=true` unblocks regardless of
  `consent_mode`, and its `channel` reads `"auto:unattended_deployment"`.
- Only `account_admin` may call `configure_governance`; `curator` and a
  machine (`api_key`) credential are both rejected.
- `configure_governance` writes an audit entry with
  `action: "account.consent_mode_changed"`.

## 6. Documentation

- `docs/reference/configuration.md` and `.env.example` —
  `MEMHOUSE_GOVERNANCE_UNATTENDED`.
- `docs/concepts/` governance page — the two switches, what they do and do
  not affect, and that this is off by default.
- `specs/architecture/gate-a-b-governance.md` — consent section gains the
  auto-grant path and its audit shape.
- `CHANGELOG.md`.

## 7. Out of scope

- Any change to `GateRule.requires_consent`'s semantics.
- Any change to Gate A/B automation.
- A UI/console control for flipping `consent_mode` beyond exposing its
  current value (a write control can follow as a separate, focused change).
- Retroactively resolving the ordinary-ingestion `target_scope_id` gap for
  anything other than the consent path it blocks here (the fix is scoped to
  `resolve_consent/5`'s call sites, not a general default applied elsewhere).
