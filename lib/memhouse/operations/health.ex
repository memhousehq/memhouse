# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.Health do
  @moduledoc """
  Builds liveness, readiness, and queue-depth results.

  Readiness reports component state, counts, versions, model identities, and error classes only.
  It never exposes content or credentials and is unhealthy when required database, queue, or
  model components cannot serve.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Repo

  # Oban job states that represent outstanding work. `completed`, `discarded`,
  # and `cancelled` are excluded deliberately: they are history, and counting
  # them would make queue depth grow forever instead of tracking backlog.
  @queue_states ~w(available scheduled retryable executing)
  @lifecycle_kinds ~w(revalidation expiry)

  @doc """
  Minimal liveness payload: the process is up and answering.

  Runs no checks and touches no dependency, which is the point — liveness must
  stay true while a dependency is down, so an orchestrator does not restart a
  node that is merely waiting for its database. Nothing in this repository
  currently calls it; the `GET /api/health` route builds its own payload.
  """
  def liveness do
    %{status: "ok", app: "memhouse", version: "f10-1"}
  end

  @doc """
  Runs every component check and returns the aggregate readiness payload.

  The result is `%{status:, app:, version:, checks:, governance:}`, where
  `checks` maps each component name to its own map carrying an `"ok"` or
  `"error"` status, plus an error class when it failed and queue depths or
  model identities when it did not. Overall status is `"ready"` only when
  every component is `"ok"`; one failure makes it `"not_ready"`. `governance`
  is disclosure rather than a check — it never affects `status` — and today
  carries only `unattended`, whether this process has
  `MEMHOUSE_GOVERNANCE_UNATTENDED` set.

  Never raises, and never blocks indefinitely: the database-backed checks carry
  their own timeouts so a hung connection surfaces as an error instead of
  hanging the probe.
  """
  def readiness do
    checks = %{
      app: %{status: "ok"},
      database: database_check(),
      oban: oban_check(),
      queues: queue_check(),
      lifecycle_sweeps: lifecycle_sweeps_check(),
      pipeline_runs: pipeline_runs_check(),
      model_roles: model_roles_check(),
      model_calls: model_calls_check(),
      embedding_index: embedding_index_check()
    }

    status =
      if Enum.all?(checks, fn {_name, check} -> check.status == "ok" end),
        do: "ready",
        else: "not_ready"

    %{
      status: status,
      app: "memhouse",
      version: "f10-1",
      checks: checks,
      update: MemHouse.Update.status(),
      # Not a pass/fail check like the others above: this is disclosure, not a readiness
      # gate, so it never affects `status`. An operator or auditor can tell whether subject
      # consent is being auto-granted for this whole process without reading source.
      governance: %{unattended: MemHouse.Governance.UnattendedMode.enabled?()}
    }
  end

  @doc """
  Whether a readiness payload means "serve traffic".

  Matches only the exact ready status, so any unexpected or malformed payload
  is treated as not ready. Callers use this to pick the HTTP status code; a
  probe should never conclude "ready" by failing to recognise a failure.
  """
  def ready?(%{status: "ready"}), do: true
  def ready?(_result), do: false

  @doc """
  Samples current queue depth and emits one telemetry measurement per queue and
  state.

  Queue depth has no natural event to hook — nothing "happens" while jobs sit
  waiting — so it must be polled. Events are
  `[:memhouse, :operations, :queue]` with a `depth` measurement and `queue`
  and `state` tags; no Account, payload, or job argument is included.

  Returns `:ok` and emits nothing when the queue query fails, so a database
  blip cannot take down the periodic-measurement poller and with it every other
  metric it collects.
  """
  def emit_queue_metrics do
    case queue_check() do
      %{status: "ok", depths: depths} ->
        Enum.each(depths, fn {queue, states} ->
          Enum.each(states, fn {state, depth} ->
            :telemetry.execute(
              [:memhouse, :operations, :queue],
              %{depth: depth},
              %{queue: queue, state: state}
            )
          end)
        end)

      _error ->
        :ok
    end
  end

  # A trivial round trip proves the pool can hand out a working connection,
  # which is what readiness needs; querying real data would make the probe
  # depend on the size of the database. The 2000 ms (2 second) timeout is short
  # enough that a probe interval is not exceeded by a hung connection, and long
  # enough to survive an ordinary pool checkout under load.
  defp database_check do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> %{status: "ok"}
      {:error, error} -> %{status: "error", error_class: error_class(error)}
    end
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  # The job supervisor being absent means background work silently stops: raw
  # observations would still be accepted but never processed. That is a
  # not-ready condition, not a degraded one.
  defp oban_check do
    case Oban.whereis(Oban) do
      pid when is_pid(pid) -> %{status: "ok"}
      _other -> %{status: "error", error_class: "not_running"}
    end
  end

  # Raw SQL rather than an Ash read because the job table is infrastructure
  # owned by the queue library, not a domain resource. The statement is a fixed
  # literal, the only bound parameter is the module-level state list, and it
  # writes nothing.
  #
  # This doubles as a readiness signal: it confirms the queue table itself is
  # reachable, which the plain connection check above does not.
  # sobelow_skip ["SQL.Query"]
  defp queue_check do
    sql = """
    SELECT queue, state, count(*)
    FROM oban_jobs
    WHERE state = ANY($1)
    GROUP BY queue, state
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [@queue_states], timeout: 2_000) do
      {:ok, %{rows: rows}} ->
        depths =
          Enum.reduce(rows, %{}, fn [queue, state, count], result ->
            Map.update(result, queue, %{state => count}, &Map.put(&1, state, count))
          end)

        %{status: "ok", depths: depths}

      {:error, error} ->
        %{status: "error", error_class: error_class(error)}
    end
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  # PipelineRun is the durable record of completed sweep work. The fixed query
  # exposes only lane names and timestamps, never Account ids or job payloads.
  # "never" is useful operator state: no row has completed since this Account
  # was provisioned or this release first started scheduling lifecycle work.
  defp lifecycle_sweeps_check do
    DataLayer.with_existing_free_account(fn _account, _actor -> lifecycle_sweeps_query() end)
  rescue
    Ecto.NoResultsError -> %{status: "ok", last_completed_at: never_completed()}
    error -> %{status: "error", error_class: error_class(error)}
  end

  # SQL is static and its only value is a fixed module attribute passed as a parameter.
  # sobelow_skip ["SQL.Query"]
  defp lifecycle_sweeps_query do
    sql = """
    SELECT kind, max(processed_at)
    FROM pipeline_runs
    WHERE kind = ANY($1) AND status = 'completed'
    GROUP BY kind
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [@lifecycle_kinds], timeout: 2_000) do
      {:ok, %{rows: rows}} ->
        last_completed_at =
          Enum.reduce(rows, never_completed(), fn [kind, processed_at], acc ->
            Map.put(acc, kind, DateTime.to_iso8601(processed_at))
          end)

        %{status: "ok", last_completed_at: last_completed_at}

      {:error, error} ->
        %{status: "error", error_class: error_class(error)}
    end
  end

  defp never_completed, do: Map.new(@lifecycle_kinds, &{&1, "never"})

  # Pipeline runs contain content-safe operational identities only. Counts and
  # oldest age show stranded work without exposing targets, payloads, or Accounts.
  defp pipeline_runs_check do
    DataLayer.with_existing_free_account(fn _account, _actor -> pipeline_runs_query() end)
  rescue
    Ecto.NoResultsError -> %{status: "ok", unfinished: %{}}
    error -> %{status: "error", error_class: error_class(error)}
  end

  # SQL is static. The Account is fixed by the transaction-local RLS setting.
  # sobelow_skip ["SQL.Query"]
  defp pipeline_runs_query do
    sql = """
    SELECT kind,
           count(*),
           floor(extract(epoch FROM (now() - min(inserted_at))))::bigint
    FROM pipeline_runs
    WHERE status <> 'completed'
    GROUP BY kind
    ORDER BY kind
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [], timeout: 2_000) do
      {:ok, %{rows: rows}} ->
        unfinished =
          Map.new(rows, fn [kind, count, oldest_age_seconds] ->
            {kind, %{count: count, oldest_age_seconds: oldest_age_seconds}}
          end)

        %{status: "ok", unfinished: unfinished}

      {:error, error} ->
        %{status: "error", error_class: error_class(error)}
    end
  end

  # Reports which provider, model, and model version each Account-level role is
  # pointing at. Only the identities are exposed; API keys and endpoint
  # credentials live elsewhere in the same configuration and must never be
  # echoed here, since this payload is unauthenticated.
  #
  # Missing or malformed configuration is a readiness failure rather than a
  # warning: a node whose roles are not configured will fail every model call
  # it accepts. Individual entries are reported as they are found, so a role
  # present but blank still reports "ok" here — this checks that the
  # configuration is readable, not that every provider is reachable.
  defp model_roles_check do
    roles =
      :memhouse
      |> Application.fetch_env!(:model_roles)
      |> Map.new(fn {role, config} ->
        config = Map.new(config)

        {role,
         %{
           provider: Map.get(config, :provider),
           model: Map.get(config, :model),
           version: Map.get(config, :model_version)
         }}
      end)

    %{status: "ok", configured: roles}
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  # Model-call health is informational. A recent provider outage must not make
  # readiness flap while durable work remains queued for retry. The community
  # build has one configured Account, so the aggregate is content-safe and does
  # not cross an Account boundary.
  defp model_calls_check do
    DataLayer.with_existing_free_account(fn _account, actor ->
      %{status: "ok"} |> Map.merge(MemHouse.Operations.Metering.summary(actor).model_calls)
    end)
  rescue
    Ecto.NoResultsError ->
      %{
        status: "ok",
        attempts: 0,
        errors: 0,
        error_rate: 0.0,
        unmetered: 0,
        error_classes: %{},
        window_seconds: 86_400
      }

    error ->
      %{status: "error", error_class: error_class(error)}
  end

  # The index contract is configuration-only so it remains available before a
  # database connection exists. It names the configured identity, never vectors,
  # index definitions, or credentials.
  defp embedding_index_check do
    MemHouse.RuntimeConfig.embedding_index_check()
  rescue
    error -> %{status: "error", error_class: error_class(error)}
  end

  # Reports the exception's type and nothing else. Exception messages routinely
  # embed connection strings, credentials, SQL, and parameter values, and this
  # payload is served unauthenticated, so the message must never be included.
  #
  # There is deliberately no fallback clause: every value reaching here is an
  # exception struct, and a non-struct would be a bug worth surfacing rather
  # than stringifying into an unauthenticated response.
  defp error_class(%module{}), do: inspect(module)
end
