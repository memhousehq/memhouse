# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ReleaseSuite do
  @moduledoc """
  Runs the evaluation matrix declared by a release manifest.

  Every result retains application, profile, model-role, dataset, deadline, strategy, date, and
  run-limit provenance. The returned envelope is validated before it can support a release claim.
  """

  alias MemHouse.Clock
  alias MemHouse.Eval.{Adapter, Report, Runner}

  @doc """
  Runs every entry in the manifest at `manifest_path` and returns the validated envelope.

  Options select the Account and run id, override the thresholds file, choose the
  deterministic or model judge, and optionally assert guardrail floors. The result includes
  suite identity, generation time, tuning policy, and all validated reports.

  Invalid manifests, judges, provenance, files, or guardrail results raise immediately; a
  missing envelope always means the matrix failed.
  """
  def run(manifest_path, opts \\ []) do
    manifest = manifest_path |> read_local!() |> Jason.decode!()
    assert_manifest!(manifest)
    root = Path.dirname(manifest_path)
    run_id = Keyword.get(opts, :run_id) || default_run_id()
    account_key = Keyword.get(opts, :account_key, "eval-release")
    thresholds = load_thresholds(root, manifest, opts)
    judge = Keyword.get(opts, :judge, "deterministic")

    unless judge in ["deterministic", "model"] do
      raise ArgumentError, "eval judge must be deterministic or model"
    end

    # Runs execute in manifest order, one at a time. Their data is already separated by
    # scope, but they share a database, so overlapping them would make every run contend
    # with the others and turn the recorded latencies into noise. Sequential execution also
    # means the first failing run aborts the matrix before the rest waste time.
    reports =
      Enum.map(manifest["runs"], fn run ->
        dataset_path = resolve(root, Map.fetch!(run, "dataset"))
        dataset = Adapter.load!(dataset_path, benchmark: Map.fetch!(run, "benchmark"))

        report =
          Runner.run(dataset,
            profile: Map.fetch!(run, "profile"),
            strategies: Map.get(run, "strategies"),
            deadline: Map.get(run, "deadline", "disabled"),
            judge: judge,
            split: Map.fetch!(run, "split"),
            account_key: account_key,
            run_id: "#{run_id}-#{Map.fetch!(run, "id")}",
            limit_cases: Map.get(run, "limit_cases"),
            limit_messages: Map.get(run, "limit_messages"),
            limit_questions: Map.get(run, "limit_questions"),
            dream_time: Map.get(run, "dream_time", false)
          )
          # The matrix id ties a report back to the manifest entry that configured it,
          # which is the only way to tell two runs over the same fixture apart.
          |> Map.put("matrix_id", Map.fetch!(run, "id"))
          # Validate immediately rather than at the end, so a report missing provenance is
          # caught next to the run that produced it.
          |> Report.validate!()

        # Ablations are executed and reported but never gated: they measure a component in
        # isolation and are expected to score below the product configuration. Only entries
        # the manifest marks as guardrails carry a floor, and only when asked to assert.
        if Keyword.get(opts, :assert_thresholds, false) and
             Map.get(run, "release_guardrail", false) do
          Report.assert_thresholds!(report, thresholds)
        end

        report
      end)

    %{
      "report_schema" => "f11-suite-1",
      "suite_version" => Map.fetch!(manifest, "suite_version"),
      "generated_at" => Clock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "run_id" => run_id,
      "tuning_policy" => Map.fetch!(manifest, "tuning_policy"),
      "reports" => reports
    }
    |> Report.validate_suite!()
  end

  # Structural gate on the manifest, checked before anything is executed. The version must
  # match exactly, the tuning and published splits must be different strings so tuned
  # weights are never validated on the rows they were fitted to, and there must be at least
  # one run — an empty matrix would otherwise report success without measuring anything.
  defp assert_manifest!(%{
         "suite_version" => "f11-1",
         "tuning_policy" => %{"published_split" => published, "tuning_split" => tuning},
         "runs" => runs
       })
       when is_binary(published) and is_binary(tuning) and published != tuning and is_list(runs) and
              runs != [] do
    :ok
  end

  defp assert_manifest!(_manifest) do
    raise ArgumentError,
          "release eval manifest must be f11-1 with distinct tuning/published splits and runs"
  end

  # Loaded up front, before any run executes, so a missing or malformed floors document
  # fails in seconds rather than after the whole matrix has been written to the database.
  defp load_thresholds(root, manifest, opts) do
    path = Keyword.get(opts, :thresholds) || Map.fetch!(manifest, "thresholds")
    root |> resolve(path) |> read_local!() |> Jason.decode!()
  end

  # Relative paths in a manifest are relative to the manifest, not to the working
  # directory, so a matrix runs the same from anywhere it is invoked.
  defp resolve(root, path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  # Paths are operator-owned Mix task inputs, never HTTP request values.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local!(path), do: File.read!(path)

  # A second-resolution UTC timestamp reduced to digits and the date/zone separators, so it
  # is safe as a scope path segment. Two matrices started in the same second would collide;
  # pass an explicit run id when running them concurrently.
  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end
end
