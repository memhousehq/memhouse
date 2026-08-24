# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Maintenance do
  @moduledoc """
  Settles one isolated evaluation Account's durable projection work.

  Deterministic evaluation runs Oban in manual mode. This barrier executes the
  Account's real pending projection actions and persists their terminal status
  before measurement, so planned savings cannot be reported as completed work.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Operations.PipelineRun

  require Ash.Query

  @doc "Executes every pending projection refresh and fails unless all become completed."
  def settle!(account_key) when is_binary(account_key) do
    {actor, runs} = projection_runs(account_key, ["pending", "failed"])

    Enum.each(runs, fn run ->
      run
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(run.account_id)
      |> Ash.Changeset.for_update(:execute, %{})
      |> Ash.update!(actor: actor)
    end)

    {_actor, remaining} = projection_runs(account_key, ["pending", "failed", "processing"])

    if remaining != [] do
      raise ArgumentError,
            "evaluation projection maintenance did not reach a completed durable state"
    end

    length(runs)
  end

  defp projection_runs(account_key, statuses) do
    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      runs =
        PipelineRun
        |> Ash.Query.filter(kind == "projection_refresh" and status in ^statuses)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor, page: [limit: 10_000])
        |> Map.fetch!(:results)

      {actor, runs}
    end)
  end
end
