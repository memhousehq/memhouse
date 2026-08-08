# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Eval.Release do
  @moduledoc """
  Runs the whole release evaluation matrix and emits one validated suite document.

    Only manifest entries flagged as release guardrails are threshold-checked. Strategy
    ablations (lexical-only, salience-and-recency-only, and similar) are executed and
    reported so regressions are visible, but they never gate a release.
  """

  use Mix.Task

  alias MemHouse.Eval.{ReleaseSuite, Runtime}

  @shortdoc "Runs the release/nightly evaluation matrix"

  @doc """
  Parses the switches described in the module documentation, runs every matrix entry, and
  emits the validated suite document to standard output or `--output`.

  Raises on invalid arguments, manifest or report contract violations, and guardrail
  threshold failures, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          thresholds: :string,
          output: :string,
          account: :string,
          run_id: :string,
          judge: :string,
          no_model: :boolean,
          assert_thresholds: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    # Ordering matters and is easy to "tidy" into a bug: switching to deterministic models
    # rewrites application environment. Job execution becomes manual. The reranker,
    # ingest-extractor, dream-reasoner, and dialectic-agent roles use the local fallback.
    # Provider keys are cleared. The embedder stays unchanged so vectors remain compatible
    # with installed indexes. The supervision tree reads that environment once at boot, so the
    # rewrite has to happen before app.start or the run will still reach a live provider.
    if Keyword.get(opts, :no_model, false), do: Runtime.use_deterministic_models()
    Mix.Task.run("app.start")

    report =
      ReleaseSuite.run(
        Keyword.get(opts, :manifest, "specs/eval/release-suite.json"),
        account_key: Keyword.get(opts, :account, "eval-release"),
        run_id: Keyword.get(opts, :run_id),
        thresholds: Keyword.get(opts, :thresholds),
        judge: Keyword.get(opts, :judge, "deterministic"),
        assert_thresholds: Keyword.get(opts, :assert_thresholds, false)
      )

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :output) do
      nil -> IO.puts(encoded)
      path -> File.write!(path, encoded)
    end
  end
end
