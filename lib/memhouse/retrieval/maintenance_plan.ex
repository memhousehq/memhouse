# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.MaintenancePlan do
  @moduledoc """
  Captures the rebuild stages selected when derived work is enqueued.

  Plans are content-free and travel in the durable pipeline payload so delayed
  workers and retries do not consult mutable runtime configuration. Payloads
  written before plans existed retain the full current behavior.
  """

  @stages ~w(sources index recall_documents entities context_projections)
  @scheduled Map.new(@stages, &{&1, "scheduled"})
  @minimal Map.merge(@scheduled, %{
             "entities" => "skipped",
             "context_projections" => "skipped"
           })

  @doc "Returns the current runtime plan used by newly enqueued derived work."
  def current do
    :memhouse
    |> Application.get_env(:retrieval_maintenance_profile, :current)
    |> for_profile()
  end

  @doc "Returns the closed maintenance plan for a retrieval profile."
  def for_profile(profile) when profile in [:minimal, "minimal"] do
    %{id: "minimal-v1", profile: "minimal", stages: @minimal}
  end

  def for_profile(profile)
      when profile in [
             :current,
             "current",
             :fast,
             "fast",
             :balanced,
             "balanced",
             :thorough,
             "thorough"
           ] do
    %{id: "current-v1", profile: "current", stages: @scheduled}
  end

  def for_profile(profile),
    do: raise(ArgumentError, "unknown retrieval maintenance profile: #{inspect(profile)}")

  @doc "Encodes a plan in a coalesced refresh payload."
  def payload(plan) do
    %{
      "maintenance_profile" => plan.id,
      "mode" => "coalesced",
      "stages" => plan.stages
    }
  end

  @doc "Decodes a durable payload, defaulting legacy work to the full plan."
  def from_payload(%{"maintenance_profile" => id, "stages" => stages})
      when id in ["current-v1", "minimal-v1"] and is_map(stages) do
    expected = if id == "minimal-v1", do: @minimal, else: @scheduled

    if stages == expected do
      %{id: id, profile: if(id == "minimal-v1", do: "minimal", else: "current"), stages: stages}
    else
      raise ArgumentError, "invalid durable retrieval maintenance plan"
    end
  end

  def from_payload(%{"maintenance_profile" => id}),
    do: raise(ArgumentError, "unknown durable retrieval maintenance plan: #{inspect(id)}")

  def from_payload(_legacy_payload), do: for_profile(:current)

  @doc "Reports whether one named stage is scheduled in a plan."
  def scheduled?(plan, stage) when stage in @stages,
    do: Map.fetch!(plan.stages, stage) == "scheduled"

  @doc "Aggregates explicit durable stage decisions for evaluation accounting."
  def accounting(runs) when is_list(runs) do
    Enum.reduce(runs, empty_accounting(), fn run, totals ->
      plan = from_payload(run.payload || %{})

      Map.new(totals, fn {stage, counts} ->
        decision = Map.fetch!(plan.stages, stage)
        {stage, Map.update!(counts, decision, &(&1 + 1))}
      end)
    end)
  end

  defp empty_accounting do
    Map.new(@stages, &{&1, %{"scheduled" => 0, "skipped" => 0}})
  end
end
