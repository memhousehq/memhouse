# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Maintenance do
  @moduledoc """
  Settles one isolated evaluation Account's durable cache-maintenance work.

  Deterministic evaluation runs Oban in manual mode. This barrier executes the
  Account's real pending projection and entity actions and persists their terminal status
  before measurement, so planned savings cannot be reported as completed work.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Operations.PipelineRun

  require Ash.Query

  @cache_kinds ~w(projection_refresh entity_resolution)

  @doc "Executes new pending cache maintenance and fails unless every new run completed."
  def settle!(account_key, prior_run_ids)
      when is_binary(account_key) and is_struct(prior_run_ids, MapSet) do
    {actor, all_runs} = cache_runs(account_key)

    runs =
      all_runs
      |> new_runs(prior_run_ids)
      |> Enum.filter(&(&1.status in ["pending", "failed"]))

    Enum.each(runs, fn run ->
      run
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(run.account_id)
      |> Ash.Changeset.for_update(:execute, %{})
      |> Ash.update!(actor: actor)
    end)

    {_actor, completed_runs} = cache_runs(account_key)

    completed_runs
    |> new_runs(prior_run_ids)
    |> ensure_completed!()

    length(runs)
  end

  @doc false
  def new_runs(runs, prior_run_ids) when is_struct(prior_run_ids, MapSet) do
    Enum.reject(runs, &MapSet.member?(prior_run_ids, &1.id))
  end

  @doc false
  def ensure_completed!(runs) when is_list(runs) do
    incomplete = Enum.reject(runs, &(&1.status == "completed"))

    if incomplete != [] do
      statuses = incomplete |> Enum.frequencies_by(& &1.status) |> inspect()

      raise ArgumentError,
            "evaluation projection maintenance did not reach a completed durable state: #{statuses}"
    end

    :ok
  end

  defp cache_runs(account_key) do
    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      runs =
        PipelineRun
        |> Ash.Query.filter(kind in ^@cache_kinds)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor, page: [limit: 10_000])
        |> Map.fetch!(:results)

      {actor, runs}
    end)
  end
end
