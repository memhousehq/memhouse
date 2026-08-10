# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Probe do
  @moduledoc """
  Asks each generative role for one tiny object and reports whether it arrived.

  The usage ledger reports what already failed. It cannot report a role that has
  never been called: a node whose structured-output path is misconfigured shows
  zero attempts and a zero error rate until it has already lost work. This is
  the forward-looking half — one real call per role, before traffic.

  A structured-output regression is invisible to a failure rate. An endpoint
  that answers in prose instead of returning the requested object still
  returns HTTP 200, and only asking for an object shows the difference.

  ## What is probed

  The roles resolved from deployment configuration, not from a per-Account
  `ModelRoleConfig` override, and no usage row is written: the probe passes no
  Account and no actor, so it neither meters itself nor moves an Account's
  budget counters. An Account that overrides a role therefore runs something
  this probe did not check.

  Nothing is overridden for the call. The probe sends the configured timeouts,
  output cap, and reasoning effort exactly as ordinary generation does, because
  a probe that relaxes a limit cannot detect that limit being wrong.

  ## Content safety

  The prompt is a fixed constant and the schema holds one boolean, so no
  Account content reaches a provider. Results carry role identity, a duration,
  and a content-free error class.
  """

  alias MemHouse.Model.Config
  alias MemHouse.Model.Gateway

  @generative_roles [:ingest_extractor, :dream_reasoner, :dialectic_agent]

  # The smallest object a provider can be asked for. The required key is the
  # assertion: a schema-enforced response carries it, while a model that
  # declines a forced tool call returns no object at all.
  @schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"],
    "additionalProperties" => false
  }

  @messages [
    %{role: "system", content: "Return only the requested object."},
    %{role: "user", content: "Set ok to true."}
  ]

  @doc """
  Probes every generative role and returns one result per role.

  Each result is `%{status:, provider:, model:, model_version:}` plus
  `duration_ms` for a role that was called and `error_class` for one that
  failed. `status` is `"ok"`, `"error"`, or `"skipped"` — the last for a role
  resolving to the offline deterministic stand-in, which has no provider to
  reach and whose `provider` field names it.

  `opts[:roles]` narrows the set. Never raises: a role that cannot be resolved
  at all reports an error like any other failure, because a probe that crashes
  tells an operator less than one that reports.
  """
  def run(opts \\ []) do
    opts
    |> Keyword.get(:roles, @generative_roles)
    |> Map.new(fn role -> {role, probe(role)} end)
  end

  @doc """
  True only when every probed role returned an object.

  A skipped role is not a pass. A caller asking this question is deciding
  whether live generation works, and a role pointed at the deterministic
  stand-in cannot answer it either way.
  """
  def ok?(results) when is_map(results) do
    results != %{} and Enum.all?(results, fn {_role, result} -> result.status == "ok" end)
  end

  @doc """
  The roles this probe covers.
  """
  def generative_roles, do: @generative_roles

  defp probe(role) do
    config = Config.resolve(role, %{})

    if Config.local_fallback?(config) do
      Map.put(identity(config), :status, "skipped")
    else
      call(role, config)
    end
  rescue
    error -> %{status: "error", error_class: Gateway.error_class(error)}
  end

  defp call(role, config) do
    started_at = System.monotonic_time(:millisecond)
    result = Gateway.structured_once(role, @messages, @schema, %{})
    duration_ms = System.monotonic_time(:millisecond) - started_at

    config
    |> identity()
    |> Map.put(:duration_ms, duration_ms)
    |> Map.merge(outcome(result))
  end

  # An object missing the one key it was required to carry is a failure of the
  # schema-enforced path, not a smaller success: it is what a forced tool call
  # degrades into, which is the failure this probe exists to catch.
  defp outcome({:ok, %{"ok" => _value}, _config}), do: %{status: "ok"}

  defp outcome({:ok, _object, _config}),
    do: %{status: "error", error_class: "schema_not_enforced"}

  defp outcome({:error, error}),
    do: %{status: "error", error_class: Gateway.error_class(error)}

  defp identity(config) do
    %{provider: config.provider, model: config.model, model_version: config.model_version}
  end
end
