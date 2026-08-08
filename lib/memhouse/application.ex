# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Application do
  @moduledoc """
  Validates runtime configuration and starts MemHouse in dependency order.

  Supervised pg0, when enabled, starts before Repo; migrations finish before services use the
  schema. Both database modes start the same application behavior.
  """

  use Application

  @impl true
  def start(_type, _args) do
    MemHouse.RuntimeConfig.validate!()
    MemHouse.Observability.setup()

    infrastructure_children =
      if MemHouse.RuntimeConfig.pg0?() do
        [MemHouse.Pg0]
      else
        []
      end

    children =
      infrastructure_children ++
        [
          MemHouseWeb.Telemetry,
          MemHouse.Database.RoleProvisioner,
          # Every pooled connection switches to the restricted role as it is
          # opened. That switch is what makes the row-level security policies on
          # the tenant tables apply at all: PostgreSQL exempts superusers from
          # them unconditionally, and it evaluates that exemption against the
          # connection's current role. Passing the callback here rather than in
          # configuration is what keeps migration and provisioning connections —
          # which start the repository with its plain configuration — privileged.
          {MemHouse.Repo, after_connect: {MemHouse.Database.AppRole, :set_role, []}},
          MemHouse.Database.ExtensionGuard,
          MemHouse.Release.Migrator,
          MemHouse.Database.RoleGuard,
          {AshAuthentication.Supervisor, otp_app: :memhouse},
          MemHouse.Operations.BudgetCounter,
          MemHouse.Retrieval.Diagnostics,
          # Queues run on the Postgres engine in every deployment mode, driven by
          # the triggers declared on the Ash domains. There is no second broker
          # and no separate worker fleet to keep in sync.
          {Oban, oban_config()},
          {DNSCluster, query: Application.get_env(:memhouse, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: MemHouse.PubSub},
          MemHouse.Context.Cache,
          MemHouse.Update.Checker,
          MemHouseWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: MemHouse.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Phoenix keeps endpoint settings in its own configuration store, so a
  # configuration reload has to be handed to the endpoint explicitly.
  @impl true
  def config_change(changed, _new, removed) do
    MemHouseWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Runs before the supervision tree is torn down, which is the only reliable
  # place to stop a self-supervised database. The manager process does not trap
  # exits, so the shutdown signal a supervisor sends would kill it without
  # running its own cleanup, leaving an orphaned PostgreSQL server behind. The
  # `whereis` guard covers the case where that process already died.
  @impl true
  def prep_stop(state) do
    if MemHouse.RuntimeConfig.pg0?() and Process.whereis(MemHouse.Pg0) do
      MemHouse.Pg0.stop_database()
    end

    state
  end

  @doc """
  Builds the Oban configuration this node starts its Oban supervisor with.

  `AshOban.config/2` forces `peer: false` onto the base Oban config whenever `:plugins`
  is not already a non-empty list — which it deliberately is not, per the comment on
  `config :memhouse, Oban`. Oban then folds that literal `false` into
  `{Oban.Peers.Isolated, [leader?: false]}`: a peer that can never win leadership, on any
  node, ever. Oban's stager is core supervision infrastructure in this Oban version (not
  a plugin, so the empty plugin list does not remove it), but it still only promotes
  `scheduled`/`retryable` jobs past their `scheduled_at` time while its node holds
  leadership. Without a winnable leadership, a job that fails once and is scheduled for
  backoff retry never gets a second attempt — nothing raises, it simply never comes back.
  Restoring the ordinary database-backed peer here, after `AshOban.config/2` has already
  run, keeps every other consequence of the empty plugin list (no Cron, no Pruner) while
  letting this node actually become leader and stage its own delayed jobs.

  Public so regression tests can assert on the merged config without starting a
  supervision tree.
  """
  @spec oban_config() :: keyword()
  def oban_config do
    Keyword.put(
      AshOban.config(
        Application.fetch_env!(:memhouse, :ash_domains),
        Application.fetch_env!(:memhouse, Oban)
      ),
      :peer,
      Oban.Peers.Database
    )
  end
end
