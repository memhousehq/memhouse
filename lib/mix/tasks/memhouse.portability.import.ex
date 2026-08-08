# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Portability.Import do
  @moduledoc """
  Loads a previously exported Account archive into a fresh installation, or verifies
    one without touching the database.

    mix memhouse.
  """

  use Mix.Task

  @shortdoc "Import an Account archive"

  @switches [input: :string, validate_only: :boolean]
  @aliases [i: :input]

  @doc """
  Parses the switches described in the module documentation and either validates the
  archive or imports it.

  Raises when the switches are invalid, `--input` is absent, verification fails, or the
  target is not fresh, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input = Keyword.get(opts, :input) || Mix.raise("--input is required")
    Mix.Task.run("app.start")

    # Both branches match strictly on `{:ok, _}`: an unexpected result must abort loudly
    # rather than print a success line over a partially applied import.
    if Keyword.get(opts, :validate_only, false) do
      {:ok, result} = MemHouse.Portability.validate(input)
      Mix.shell().info("Archive valid: #{result.account_id} (#{result.manifest_hash})")
    else
      {:ok, result} = MemHouse.Portability.import(input)
      Mix.shell().info("Imported #{result.account_id}; derived rebuilds enqueued")
    end
  end
end
