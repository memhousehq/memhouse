# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Release do
  @moduledoc """
  Runs operator commands against a built release.

  Migration and other release tasks start only the applications they need, use the configured
  database mode, and raise on failure so shell exit status is reliable. They do not fork product
  behavior between embedded and external PostgreSQL.
  """

  @app :memhouse

  @doc """
  Runs all pending migrations for every configured repository, then stops
  anything it started.

  Loads the application without starting its supervision tree, validates the
  node's deployment configuration, and — in embedded-database mode — starts the
  database first. Each repository is started for the duration of its own
  migration run and stopped again afterwards.

  The embedded database is stopped in an `after` block, so a failing migration
  still leaves no orphaned database process holding the data directory.

  Raises on invalid configuration, on a database that will not start, and on any
  failing migration. Returns whatever the loop returns; callers use it for its
  effect and its exit status.
  """
  def migrate do
    load_app()
    MemHouse.RuntimeConfig.validate!()
    pg0 = start_pg0()

    try do
      for repo <- Application.fetch_env!(@app, :ecto_repos) do
        {:ok, _pid, _apps} =
          Ecto.Migrator.with_repo(repo, fn started ->
            Ecto.Migrator.run(started, :up, all: true)
            # The restricted role the running node connects as owns nothing and
            # is granted rights explicitly, so a table this run has just created
            # would be unreachable to it until these grants are re-applied. This
            # connection still holds the privileged role, which is what makes it
            # the right place to do that.
            MemHouse.Database.AppRole.provision!(started)
          end)
      end
    after
      stop_pg0(pg0)
    end
  end

  @doc """
  Migrates one repository back down to the given migration version.

  `repo` is the repository module and `version` is the numeric migration
  version to roll back to, including that migration itself.

  Unlike migrating up, this does not start an embedded database: rolling back is
  a deliberate recovery step an operator performs against a database that is
  already running and that they have already inspected.

  Raises if the repository cannot be started or a down-migration fails.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _pid, _apps} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Exports the node's Account to a portable archive at `output_path` and prints a
  JSON summary.

  Resolves the single community Account and runs the export under an internal
  actor inside one Account-scoped transaction, so the archive is a consistent
  snapshot rather than a series of independent reads.

  The printed summary describes the archive — identity, counts, checksums — and
  never its contents. Raises if no such Account exists or the export fails.
  """
  def export!(output_path) do
    result =
      MemHouse.DataLayer.with_existing_free_account(fn _account, actor ->
        {:ok, export} = MemHouse.Portability.export(actor, output_path)
        export
      end)

    IO.puts("portability export: #{Jason.encode!(result)}")
  end

  @doc """
  Inspects an archive without importing it and prints a JSON summary.

  Verifies the archive's structure, declared counts, checksums, and audit chain
  and writes nothing. Use it to confirm a backup is restorable before trusting
  it, and to check a received archive before pointing an import at it.

  Raises if the archive is unreadable or fails verification. The pattern match
  on the result is intentional: a partially verified archive is not a result
  worth printing.
  """
  def validate_archive!(input_path) do
    {:ok, result} = MemHouse.Portability.validate(input_path)
    IO.puts("portability archive: #{Jason.encode!(result)}")
  end

  @doc """
  Imports an archive into this node and prints a JSON summary.

  The archive is fully verified before any durable write begins, and the
  restoration itself happens in one Account-scoped transaction, so a rejected
  archive leaves no partial Account behind. Derived data — vectors, chunks,
  projections — is not in the archive and is rebuilt afterwards by ordinary
  background work.

  Requires a fresh target: importing into a node that already holds the Account
  raises rather than merging.
  """
  def import!(input_path) do
    {:ok, result} = MemHouse.Portability.import(input_path)
    IO.puts("portability import: #{Jason.encode!(result)}")
  end

  @doc """
  Enqueues the configured Account-wide embedding transition and prints JSON.

  The returned run id can be passed to `reembed_status!/1`. Repeating this call
  for the same embedding identity returns the same durable run.
  """
  def reembed! do
    result =
      MemHouse.DataLayer.with_existing_free_account(fn account, actor ->
        config = MemHouse.Model.Config.resolve(:embedder, %{account_id: account.id, actor: actor})

        identity =
          config
          |> MemHouse.Model.Config.embedding_identity()
          |> Map.new(fn {key, value} -> {to_string(key), value} end)

        {:ok, run} = MemHouse.Pipeline.enqueue_reembed(account.id, identity, actor)
        reembed_summary(run)
      end)

    IO.puts(Jason.encode!(result))
  end

  @doc """
  Prints content-free progress for a re-embed pipeline run.

  Raises when the id is not a re-embed operation or does not belong to the
  community Account.
  """
  def reembed_status!(run_id) do
    result =
      MemHouse.DataLayer.with_existing_free_account(fn account, actor ->
        run = Ash.get!(MemHouse.Operations.PipelineRun, run_id, tenant: account.id, actor: actor)

        if run.kind != "reembed" do
          raise ArgumentError, "pipeline run is not a re-embed operation"
        end

        reembed_summary(run)
      end)

    IO.puts(Jason.encode!(result))
  end

  defp reembed_summary(run) do
    %{
      id: run.id,
      status: run.status,
      attempt_count: run.attempt_count,
      last_error_class: run.last_error_class,
      progress: run.payload
    }
  end

  # Loads the application's configuration and modules without starting its
  # supervision tree. These entry points run in a bare node, and starting the
  # tree would open connections before the database is necessarily up.
  # Already-loaded is a normal outcome, not an error.
  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end

  # Returns nil in external-database mode, which the stop clauses below treat as
  # "nothing to stop". The operator's database is never started or stopped by
  # this node.
  defp start_pg0 do
    if MemHouse.RuntimeConfig.pg0?() do
      {:ok, pid} = MemHouse.Pg0.start_link()
      pid
    end
  end

  defp stop_pg0(nil), do: :ok

  # 35_000 ms (35 seconds) exceeds the shutdown timeout the database process
  # itself uses, so this waits for an orderly stop instead of racing it and
  # leaving a running server with no supervisor.
  defp stop_pg0(pid), do: GenServer.stop(pid, :normal, 35_000)
end

defmodule MemHouse.Release.Migrator do
  @moduledoc """
  Runs database migrations before the supervised application serves work.

  Startup fails if migration fails; later children must never observe a partially upgraded
  schema.
  """

  use GenServer

  @doc """
  Starts the migration step under the supervision tree.

  Registered under the module name. Options are accepted and ignored; the
  behaviour is driven entirely by the node's configuration.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if MemHouse.RuntimeConfig.auto_migrate?() do
      # Read from the release's own priv directory rather than a source path, so
      # this works identically in a packaged release and in development.
      migrations_path = Application.app_dir(:memhouse, "priv/repo/migrations")

      # Migrations issue DDL, and the application pool has already switched to a
      # role that owns nothing and may not. So this runs over its own short-lived
      # privileged instance rather than the pool beside it, and re-grants
      # afterwards so the restricted role can reach whatever was just created.
      MemHouse.Database.AppRole.with_privileged_repo(fn privileged ->
        Ecto.Migrator.run(MemHouse.Repo, migrations_path, :up,
          all: true,
          dynamic_repo: privileged
        )

        MemHouse.Database.AppRole.provision!(privileged)
      end)
    end

    {:ok, %{}}
  end
end
