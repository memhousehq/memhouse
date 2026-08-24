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
    dream_operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)
    profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)
    maintenance_profile = Application.get_env(:memhouse, :retrieval_maintenance_profile)

    try do
      Application.put_env(
        :memhouse,
        :extraction_batching,
        Keyword.put(batching, :enabled, switch!(components, "extraction_batching", "enabled"))
      )

      Application.put_env(
        :memhouse,
        :dream_time_gates,
        Keyword.put(
          dream_gates,
          :idle_scheduler_enabled,
          switch!(components, "idle_dream_scheduling", "enabled")
        )
      )

      Application.put_env(
        :memhouse,
        :retrieval_profiles,
        Keyword.put(profiles, :minimal_enabled, minimal_profile!(components))
      )

      Application.put_env(
        :memhouse,
        :retrieval_maintenance_profile,
        maintenance_profile!(components)
      )

      Application.put_env(
        :memhouse,
        :dream_reasoning_operations,
        Keyword.put(
          dream_operations,
          :split_enabled,
          switch!(components, "dream_reasoning_operations", "split_enabled")
        )
      )

      fun.()
    after
      Application.put_env(:memhouse, :extraction_batching, batching)
      Application.put_env(:memhouse, :dream_time_gates, dream_gates)
      Application.put_env(:memhouse, :dream_reasoning_operations, dream_operations)
      Application.put_env(:memhouse, :retrieval_profiles, profiles)
      restore_optional(:retrieval_maintenance_profile, maintenance_profile)
    end
  end

  defp switch!(components, component, key) do
    case components[component] do
      %{^key => value} when is_boolean(value) ->
        value

      _other ->
        raise ArgumentError, "component #{component} must declare a boolean #{key}"
    end
  end

  defp minimal_profile!(%{"retrieval_profile" => profile}) when is_binary(profile),
    do: profile == "minimal"

  defp minimal_profile!(_components),
    do: raise(ArgumentError, "component retrieval_profile must declare a profile name")

  defp maintenance_profile!(%{"retrieval_profile" => "minimal"}), do: :minimal

  defp maintenance_profile!(%{"retrieval_profile" => profile})
       when profile in ["fast", "balanced", "thorough"],
       do: :current

  defp maintenance_profile!(_components),
    do: raise(ArgumentError, "component retrieval_profile must declare a profile name")

  defp restore_optional(key, nil), do: Application.delete_env(:memhouse, key)
  defp restore_optional(key, value), do: Application.put_env(:memhouse, key, value)
end
