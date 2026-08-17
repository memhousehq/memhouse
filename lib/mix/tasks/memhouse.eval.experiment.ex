# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Eval.Experiment do
  @moduledoc """
  Produces a resolved experiment manifest and matched comparison bundle.

  Fixture definitions are fully offline. Execute definitions use deterministic local model
  roles unless `--live-model` is deliberately supplied; live execution may incur provider cost.
  Gates are asserted by default. `--report-only` writes failing evidence without a non-zero exit.
  """

  use Mix.Task

  alias MemHouse.Eval.{Experiment, Preflight, Runtime}

  @shortdoc "Runs a matched current/experimental memory evaluation"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          definition: :string,
          output: :string,
          manifest_output: :string,
          account: :string,
          run_id: :string,
          live_model: :boolean,
          report_only: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    definition_path =
      Keyword.get(opts, :definition) || Mix.raise("--definition is required")

    output_path = Keyword.get(opts, :output) || Mix.raise("--output is required")

    manifest_path =
      Keyword.get(opts, :manifest_output) || Mix.raise("--manifest-output is required")

    if Experiment.mode!(definition_path) == "execute" do
      if Keyword.get(opts, :live_model, false) do
        Mix.Task.run("app.start")
        Preflight.assert_generative_roles!()
      else
        Runtime.use_deterministic_models()
        Mix.Task.run("app.start")
      end
    end

    {manifest, bundle} =
      Experiment.run(definition_path,
        account_key: Keyword.get(opts, :account, "eval-experiment"),
        run_id: Keyword.get(opts, :run_id)
      )

    write_json!(manifest_path, manifest)
    write_json!(output_path, bundle)

    unless Keyword.get(opts, :report_only, false), do: Experiment.assert_gates!(bundle)
  end

  defp write_json!(path, value) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode_to_iodata!(value, pretty: true))
  end
end
