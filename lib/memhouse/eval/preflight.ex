# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Preflight do
  @moduledoc """
  Refuses to start a graded run whose generative roles cannot return an object.

  A benchmark cannot tell a weak answer from an answer that was never
  generated. It ingests, scores, and reports a number either way, so a broken
  structured-output path is recorded as a quality result and published as one.
  Probing first turns hours of unusable run into one failed command.

  A role served by the offline deterministic stand-in fails this check too. Its
  output is schema-valid and non-intelligent, so a graded run against it
  measures nothing; `--no-model` is how an offline run is asked for, and it
  skips the check rather than passing it.
  """

  alias MemHouse.Model.Probe

  @doc """
  Probes the generative roles and raises unless every one returned an object.

  Returns the probe results on success so a caller can report what it verified.
  The message names each failing role and its content-free error class.
  """
  def assert_generative_roles!(opts \\ []) do
    results = Probe.run(opts)

    if Probe.ok?(results) do
      results
    else
      raise """
      structured output is not working for every generative role:

      #{Enum.map_join(results, "\n", &describe/1)}

      Fix the model configuration, or pass --no-model for an offline run.
      """
    end
  end

  defp describe({role, %{status: "ok", duration_ms: duration_ms}}),
    do: "  #{role}: ok (#{duration_ms} ms)"

  defp describe({role, %{status: "skipped", provider: provider}}),
    do: "  #{role}: skipped, role uses the #{provider} provider"

  defp describe({role, result}),
    do: "  #{role}: #{result.status}, #{Map.get(result, :error_class, "unknown")}"
end
