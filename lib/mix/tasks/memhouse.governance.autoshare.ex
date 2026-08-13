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

    {written, consent_mode} =
      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        rules =
          for level <- @levels, sensitivity <- @sensitivities do
            write_rule!(account.id, actor, level, sensitivity)
          end

        {rules, account.consent_mode}
      end)

    Mix.shell().info("account: #{account_key}")
    Mix.shell().info("gate rules written: #{length(written)}")
    Mix.shell().info("consent_mode: #{consent_mode}")

    unless consent_mode == "auto" or MemHouse.Governance.UnattendedMode.enabled?() do
      Mix.shell().info("""

      Personal knowledge will still be held: it needs its subject's consent, and this
      Account has nobody to give it. An account administrator must set consent_mode to
      "auto", or the deployment must run with MEMHOUSE_GOVERNANCE_UNATTENDED=true.
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
  defp write_rule!(account_id, actor, target_level, sensitivity) do
    existing =
      GateRule
      |> Ash.Query.filter(
        is_nil(scope_id) and target_level == ^target_level and sensitivity == ^sensitivity
      )
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
      [rule | _] ->
        rule
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)

      [] ->
        GateRule
        |> Ash.Changeset.for_create(
          :create,
          Map.merge(attrs, %{target_level: target_level, sensitivity: sensitivity})
        )
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.create!(actor: actor)
    end
  end
end
