# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Portability.Export do
  @moduledoc """
  Writes the configured community Account out as a self-contained, checksum-verified
    archive.

    The archive is what moves an installation between machines, deployment modes, or
    blob storage adapters: a gzip-compressed tar holding a manifest, one JSON-lines file
    per durable resource, and content-addressed original document blobs. It is read
    inside a single Account-scoped database transaction, so the snapshot is internally
    consistent.
  """

  use Mix.Task

  @shortdoc "Export the free Account"

  @switches [output: :string]
  @aliases [o: :output]

  @doc """
  Parses `--output`, exports the community Account, and prints the account id and archive
  path.

  Raises when the switches are invalid, when no community Account exists, or when the
  archive cannot be produced, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    output =
      Keyword.get(opts, :output) ||
        "memhouse-export-#{Date.utc_today() |> Date.to_iso8601()}.tar.gz"

    Mix.Task.run("app.start")

    # The wrapper looks up the community Account that already exists rather than creating
    # one, sets the tenant for the surrounding transaction, and hands back an actor whose
    # authority is scoped to that Account. Export therefore cannot read across tenants, and
    # running this against an empty database fails instead of emitting an empty archive.
    result =
      MemHouse.DataLayer.with_existing_free_account(fn _account, actor ->
        {:ok, result} = MemHouse.Portability.export(actor, output)
        result
      end)

    Mix.shell().info("Exported #{result.account_id} to #{result.path}")
  end
end
