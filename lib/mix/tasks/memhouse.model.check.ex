# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Model.Check do
  @moduledoc """
  Asks each generative role for one small object and prints what came back.

    Run it after changing a model role, a provider key, or an endpoint, and
    before a graded benchmark. One failing role here is the same failure that
    would otherwise appear as thinned memory hours into a run.

    Exits non-zero when a role fails. A role served by the offline deterministic
    stand-in is reported as skipped and does not fail the command, because there
    is no provider to reach.
  """

  use Mix.Task

  alias MemHouse.Model.Probe

  @shortdoc "Probes structured output for every generative model role"

  @doc """
  Probes the roles and prints one line each: status, provider, model, duration,
  and a content-free error class for a failure.

  `--json` prints the result map instead, for an operator collecting it.
  """
  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    # The probe resolves roles from application environment and makes a real
    # provider call, so the application has to be started first.
    Mix.Task.run("app.start")

    results = Probe.run()

    if Keyword.get(opts, :json, false) do
      results |> Jason.encode_to_iodata!(pretty: true) |> IO.puts()
    else
      Enum.each(Probe.generative_roles(), fn role ->
        Mix.shell().info(line(role, results[role]))
      end)
    end

    failed = Enum.filter(results, fn {_role, result} -> result.status == "error" end)

    if failed != [] do
      Mix.raise("structured output failed for: #{Enum.map_join(failed, ", ", &elem(&1, 0))}")
    end
  end

  defp line(role, result) do
    [
      "#{role}: #{result.status}",
      "#{result.provider}/#{result.model}@#{result.model_version}",
      result[:duration_ms] && "#{result.duration_ms} ms",
      result[:error_class]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ")
  end
end
