# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Runtime do
  @moduledoc """
  Enables deterministic, offline evaluation configuration.

  It replaces live model roles and volatile settings only for the evaluation run, then restores
  the prior runtime state.
  """

  @doc """
  Repoints the node at local deterministic models and disables queue-driven job execution.

  It makes jobs manual, removes live credentials, and replaces generation roles with local
  fallbacks. The local embedder remains unchanged so vector identity stays valid.

  Call before application startup. Returns `:ok`; missing queue or role configuration
  raises `ArgumentError`.
  """
  def use_deterministic_models do
    oban = Application.fetch_env!(:memhouse, Oban)
    Application.put_env(:memhouse, Oban, Keyword.put(oban, :testing, :manual))

    models = Application.get_env(:memhouse, :models, [])
    Application.put_env(:memhouse, :models, Keyword.put(models, :api_key, nil))

    roles =
      :memhouse
      |> Application.fetch_env!(:model_roles)
      |> Enum.map(fn
        # The embedder is absent from this list on purpose. Its provider, model, version,
        # and dimension identity has to keep matching the installed vector indexes, so
        # swapping it for a stub would break retrieval rather than make the run offline.
        {role, config} when role in [:ingest_extractor, :dream_reasoner, :dialectic_agent] ->
          {role,
           config
           |> Map.put(:provider, "deterministic")
           |> Map.put(:model, "local-structured-fallback")
           |> Map.put(:model_version, "1")}

        role_config ->
          role_config
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    # Clearing the configured key is not enough on its own: the credential is configured as
    # a reference to this variable, so the variable itself has to go too.
    System.delete_env("OPENROUTER_API_KEY")
    :ok
  end
end
