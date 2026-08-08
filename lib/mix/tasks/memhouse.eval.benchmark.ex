# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Eval.Benchmark do
  @moduledoc """
  Runs one public or local memory benchmark fixture end to end and prints a scored
    report.

    Durable rows in the configured database, under the given Account key and a scope
    root derived from the benchmark name and run id. Nothing is cleaned up afterwards.
  """

  use Mix.Task

  alias MemHouse.Eval.{Adapter, Runner, Runtime}

  @shortdoc "Runs full MemHouse benchmark ingestion/scoring"

  @doc """
  Parses the switches described in the module documentation, runs the benchmark, and emits
  the report to standard output or `--output`.

  Raises on invalid arguments, unusable fixtures, and unwritable output, which surfaces as
  a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          benchmark: :string,
          dataset: :string,
          profile: :string,
          account: :string,
          run_id: :string,
          output: :string,
          limit_cases: :integer,
          limit_messages: :integer,
          limit_questions: :integer,
          no_model: :boolean
        ],
        aliases: [
          b: :benchmark,
          d: :dataset,
          p: :profile,
          o: :output
        ]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    dataset_path = Keyword.get(opts, :dataset) || Mix.raise("--dataset is required")

    # Ordering matters and is easy to "tidy" into a bug: switching to deterministic models
    # rewrites application environment (job execution becomes manual, the ingest-extractor,
    # dream-reasoner, and dialectic-agent roles point at the local fallback, and provider
    # keys are cleared; the embedder role is left alone so vectors stay compatible with the
    # installed indexes). The supervision tree reads that environment once, at boot, so the
    # rewrite has to happen before app.start or the run will still reach a live provider.
    if Keyword.get(opts, :no_model, false), do: Runtime.use_deterministic_models()
    Mix.Task.run("app.start")

    dataset =
      Adapter.load!(dataset_path,
        benchmark: Keyword.get(opts, :benchmark)
      )

    Mix.shell().info(
      "running #{dataset.benchmark} from #{dataset.source_format}: #{length(dataset.cases)} case(s)"
    )

    report =
      Runner.run(dataset,
        profile: Keyword.get(opts, :profile, "balanced"),
        account_key: Keyword.get(opts, :account, "eval-benchmark"),
        run_id: Keyword.get(opts, :run_id),
        limit_cases: Keyword.get(opts, :limit_cases),
        limit_messages: Keyword.get(opts, :limit_messages),
        limit_questions: Keyword.get(opts, :limit_questions)
      )

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :output) do
      nil ->
        IO.puts(encoded)

      path ->
        File.write!(path, encoded)
        Mix.shell().info("wrote #{path}")
    end
  end
end
