# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Governance.Autoshare do
  use Mix.Task

  @shortdoc "Writes the Account-wide gate rules a benchmark Account needs to share automatically"

  @moduledoc """
  Configures one Account to accept and place governed knowledge without a human.

  A fresh installation has no gate rules at all, and the built-in fallback cell is fully
  human at both gates. That is the right default and stays the default: knowledge waits
  for somebody to approve it. A benchmark has nobody, so its corpus never becomes
  retrievable and every measurement reads as zero recall.

  This task writes the Account-wide cells that let the engine decide on its own.

  It does not touch consent. Personal knowledge additionally needs its subject's
  agreement, and only a human administrator may declare that an Account has no subject
  who can give it — either by setting `consent_mode` to `auto`, or by running the
  deployment with `MEMHOUSE_GOVERNANCE_UNATTENDED=true`. A mix task holding a machine
  actor must not be able to weaken consent, so it prints the reminder instead.

  `restricted` knowledge is deliberately left alone. It still needs a person, whatever
  this task writes, and the engine refuses to place it automatically regardless.

  This loosens governance for the whole Account. Run it on a benchmark or evaluation
  Account, never on one holding somebody's real memory.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Governance.GateRule

  require Ash.Query

  # Every level and sensitivity the engine will place without a person. `restricted` is absent
  # on purpose: no cell can make it automatic, so writing one would only suggest otherwise.
  @levels ~w(peer scope account)
  @sensitivities ~w(public internal personal)

  @doc """
  Writes the automatic cells for the Account named by `--account-key`, and prints what it wrote.

  Raises when the Account key is missing or names no Account.
  """
  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} =
      OptionParser.parse(argv, strict: [account_key: :string], aliases: [a: :account_key])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    account_key = Keyword.get(opts, :account_key) || Mix.raise("--account-key is required")

    {outcomes, consent_mode} =
      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        outcomes =
          for level <- @levels, sensitivity <- @sensitivities do
            write_rule!(account.id, actor, level, sensitivity)
          end

        {outcomes, account.consent_mode}
      end)

    written_count =
      Enum.count(outcomes, fn
        {:created, _rule} -> true
        {:successor, _rule} -> true
        {:unchanged, _rule} -> false
      end)

    Mix.shell().info("account: #{account_key}")
    Mix.shell().info("gate rules written: #{written_count}")
    Mix.shell().info("consent_mode: #{consent_mode}")

    unless consent_mode == "auto" or MemHouse.Governance.UnattendedMode.enabled?() do
      Mix.shell().info("""

      Personal knowledge still needs human review: peer-level proposals become provisional,
      while scope and account proposals become held. An account administrator must set
      consent_mode to "auto", or the deployment must run with MEMHOUSE_GOVERNANCE_UNATTENDED=true.
      """)
    end
  end

  # One Account-wide cell per level and sensitivity.
  #
  # `minimum_evidence_level` is the field that decides whether any of this has an effect.
  # It defaults to `direct`, and a claim is direct only when its subject is the peer who
  # spoke it. Everything one participant says about another is indirect, which is most of
  # a relayed conversation, so leaving the default would auto-keep almost nothing.
  #
  # `minimum_corroboration: 1` for the same reason: a benchmark statement is usually said
  # once, and requiring two independent sources would hold the whole corpus.
  #
  # The upsert flow preserves versioned history: when an effective rule exists and its values
  # differ from the requested attributes, a new version is created instead of updating the
  # existing rule in place. The model's priority/version ordering selects the effective row.
  defp write_rule!(account_id, actor, target_level, sensitivity) do
    existing =
      GateRule
      |> Ash.Query.filter(
        is_nil(scope_id) and target_level == ^target_level and sensitivity == ^sensitivity and
          active == true
      )
      |> Ash.Query.sort(priority: :desc, version: :desc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    attrs = %{
      minimum_confidence: 0.0,
      minimum_evidence_level: "indirect",
      gate_a_mode: "auto_keep",
      gate_b_mode: "auto_place",
      minimum_corroboration: 1,
      requires_consent: false,
      active: true
    }

    case existing do
      [effective_rule | _] ->
        # Compare the effective rule's values with the requested attrs
        if rule_matches?(effective_rule, attrs) do
          # Values match; no-op
          {:unchanged, effective_rule}
        else
          # Values differ; create a successor version with the same priority
          rule =
            GateRule
            |> Ash.Changeset.for_create(
              :create,
              Map.merge(attrs, %{
                target_level: target_level,
                sensitivity: sensitivity,
                priority: effective_rule.priority,
                version: effective_rule.version + 1
              })
            )
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.create!(actor: actor)

          {:successor, rule}
        end

      [] ->
        rule =
          GateRule
          |> Ash.Changeset.for_create(
            :create,
            Map.merge(attrs, %{target_level: target_level, sensitivity: sensitivity})
          )
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.create!(actor: actor)

        {:created, rule}
    end
  end

  # Compare the effective rule's decision fields with the requested attributes for idempotent no-op.
  defp rule_matches?(rule, attrs) do
    rule.minimum_confidence == attrs.minimum_confidence and
      rule.minimum_evidence_level == attrs.minimum_evidence_level and
      rule.gate_a_mode == attrs.gate_a_mode and
      rule.gate_b_mode == attrs.gate_b_mode and
      rule.minimum_corroboration == attrs.minimum_corroboration and
      rule.requires_consent == attrs.requires_consent and
      rule.active == attrs.active
  end
end
