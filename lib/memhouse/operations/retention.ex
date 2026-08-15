# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.Retention do
  @moduledoc """
  Removes expired operational history without touching durable memory or audit evidence.

  One community release owns one Account. The daily worker enters that configured Account and uses internal Ash destroy
  actions. Active pipeline runs are never eligible. Raw messages, knowledge items, audit events,
  and rebuild watermarks have no prune action and cannot be reached by this worker.
  """

  use Oban.Worker, queue: :reconciler, max_attempts: 5

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.GateDecision
  alias MemHouse.Knowledge.LifecycleEvent
  alias MemHouse.Operations.{PipelineRun, UsageEvent}

  require Ash.Query

  @impl Oban.Worker
  @doc "Runs one bounded retention pass for the provisioned community Account."
  def perform(%Oban.Job{}) do
    DataLayer.with_existing_free_account(fn account, actor ->
      prune(account.id, %{actor | pipeline?: true})
    end)

    :ok
  rescue
    Ecto.NoResultsError -> :ok
  end

  @doc "Removes expired rows and returns the count removed from each operational table."
  def prune(account_id, actor) do
    config = Application.fetch_env!(:memhouse, :retention)
    now = Clock.utc_now()
    batch_size = Keyword.fetch!(config, :batch_size)

    %{
      pipeline_runs:
        prune_resource(
          PipelineRun,
          account_id,
          actor,
          Ash.Query.filter(
            PipelineRun,
            status in ["completed", "cancelled", "discarded"] and
              updated_at < ^cutoff(now, config, :pipeline_runs_days)
          ),
          batch_size
        ),
      usage_events:
        prune_resource(
          UsageEvent,
          account_id,
          actor,
          Ash.Query.filter(
            UsageEvent,
            occurred_at < ^cutoff(now, config, :usage_events_days)
          ),
          batch_size
        ),
      gate_decisions:
        prune_resource(
          GateDecision,
          account_id,
          actor,
          Ash.Query.filter(
            GateDecision,
            decided_at < ^cutoff(now, config, :gate_decisions_days)
          ),
          batch_size
        ),
      lifecycle_events:
        prune_resource(
          LifecycleEvent,
          account_id,
          actor,
          Ash.Query.filter(
            LifecycleEvent,
            occurred_at < ^cutoff(now, config, :lifecycle_events_days)
          ),
          batch_size
        )
    }
  end

  defp cutoff(now, config, key) do
    DateTime.add(now, -Keyword.fetch!(config, key), :day)
  end

  defp prune_resource(resource, account_id, actor, query, batch_size) do
    query
    |> Ash.Query.set_tenant(account_id)
    |> Ash.Query.limit(batch_size)
    |> Ash.bulk_destroy!(:prune, %{},
      actor: actor,
      domain: domain(resource),
      return_records?: true,
      strategy: [:stream]
    )
    |> Map.fetch!(:records)
    |> length()
  end

  defp domain(PipelineRun), do: MemHouse.Operations
  defp domain(UsageEvent), do: MemHouse.Operations
  defp domain(GateDecision), do: MemHouse.Governance
  defp domain(LifecycleEvent), do: MemHouse.Knowledge
end
