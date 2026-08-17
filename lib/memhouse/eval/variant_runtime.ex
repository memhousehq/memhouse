# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.VariantRuntime do
  @moduledoc """
  Applies one experiment variant's feature switches for the duration of its run.

  Runtime configuration is process-global, so execute experiments run variants
  serially. Every touched value is restored in an `after` block, including when
  the runner or a provider raises.
  """

  @doc "Runs `fun` with the component feature switches installed, then restores them."
  def with_components(components, fun) when is_map(components) and is_function(fun, 0) do
    batching = Application.fetch_env!(:memhouse, :extraction_batching)
    dream_gates = Application.fetch_env!(:memhouse, :dream_time_gates)
    profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)

    Application.put_env(
      :memhouse,
      :extraction_batching,
      Keyword.put(batching, :enabled, components["extraction_batching"]["enabled"])
    )

    Application.put_env(
      :memhouse,
      :dream_time_gates,
      Keyword.put(
        dream_gates,
        :idle_scheduler_enabled,
        components["idle_dream_scheduling"]["enabled"]
      )
    )

    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(profiles, :minimal_enabled, components["retrieval_profile"] == "minimal")
    )

    try do
      fun.()
    after
      Application.put_env(:memhouse, :extraction_batching, batching)
      Application.put_env(:memhouse, :dream_time_gates, dream_gates)
      Application.put_env(:memhouse, :retrieval_profiles, profiles)
    end
  end
end
