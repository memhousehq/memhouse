# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Database.ExtensionGuard do
  @moduledoc """
  Refuses to start an external deployment without pgvectorscale available.

  The migration creates the extension in each database. This guard checks that
  the server has the extension files before migration or traffic can continue.
  """

  use GenServer

  alias MemHouse.Repo

  @required_version "0.9.0"

  @doc """
  Starts the extension availability check.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    if MemHouse.RuntimeConfig.database_mode() == "external" do
      case Ecto.Adapters.SQL.query(
             Repo,
             """
             SELECT available.default_version, installed.extversion
             FROM pg_available_extensions AS available
             LEFT JOIN pg_extension AS installed ON installed.extname = available.name
             WHERE available.name = 'vectorscale'
             """,
             []
           ) do
        {:ok, %{rows: [[@required_version, installed_version]]}}
        when installed_version in [nil, @required_version] ->
          :ok

        {:ok, _result} ->
          raise "PostgreSQL is missing the required vectorscale #{@required_version} extension; install or upgrade pgvectorscale for PostgreSQL 18 before starting MemHouse"

        {:error, error} ->
          raise "cannot verify the required vectorscale extension: #{Exception.message(error)}"
      end
    end

    {:ok, %{}}
  end
end
