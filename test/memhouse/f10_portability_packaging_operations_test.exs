# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F10PortabilityPackagingOperationsTest do
  @moduledoc """
  Pins Account portability, audit verification, readiness, exact metering, log
  safety, and packaging parity.

  Archives exclude credentials, secrets, and rebuildable caches by construction;
  imports verify checksums and the audit chain before writing. Readiness remains
  content-safe, usage comes from the durable ledger, and production logs allow
  only reviewed metadata. pg0 assets are pinned while containers use stock
  Postgres with the same release.

  `memhouse-account-1` is the external archive schema identity. Changing it
  requires a changelog entry and updated evidence. Treat archive leakage, log
  redaction, and unverified packaging failures as security issues.

  Runs synchronously because it writes temporary archives and reads repository
  files.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Memory
  alias MemHouse.Model.Config
  alias MemHouse.Model.Usage
  alias MemHouse.Operations.Health
  alias MemHouse.Operations.Metering
  alias MemHouse.Pipeline
  alias MemHouse.Portability
  alias MemHouse.Portability.AuditVerifier
  alias MemHouse.Portability.Registry
  alias MemHouse.Repo
  alias MemHouse.RuntimeConfig

  test "logical export is self-describing, checksum verified, and excludes secrets and caches" do
    # Unique account key per run so a leftover archive or account from an earlier run cannot
    # satisfy the assertions below.
    account_key = "f10-export-#{System.unique_integer([:positive])}"

    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "portable-session",
               "scope_path" => "/f10/portable",
               "peer_key" => "portable-peer",
               "role" => "user",
               "content" => "Avery prefers portable weekly summaries."
             })

    assert {:ok, [_knowledge]} = Memory.extract_message(message["id"], account_key)

    {_account, actor} =
      DataLayer.with_account_key(
        account_key,
        [role: :system, pipeline?: true],
        fn account, actor -> {account, actor} end
      )

    path = temp_path("account.tar.gz")
    on_exit(fn -> File.rm(path) end)

    # The export runs in one account-scoped transaction, so the manifest counts describe a
    # single consistent snapshot rather than a moving target.
    assert {:ok, exported} = Portability.export(actor, path)
    assert exported.schema == "memhouse-account-1"
    assert exported.resource_counts["messages"] == 1
    # At least four audit events: ingest alone produces several chained entries. A lower
    # bound rather than an exact number, because adding an audited step is normal evolution
    # while *losing* audit entries is not.
    assert exported.resource_counts["audit_events"] >= 4
    # No documents were ingested, so there are no blobs to carry.
    assert exported.blob_count == 0
    assert File.regular?(path)

    # Validation reads the archive back without importing it. An operator must be able to
    # check an archive before committing it to a destination, and the audit head hash must
    # match what the export recorded — that is what proves nothing changed in transit.
    assert {:ok, validated} = Portability.validate(path)
    assert validated.account_id == actor.account_id
    assert validated.audit["last_hash"] == exported.audit["last_hash"]

    # Exclusions asserted against the inventory itself, not against one archive's contents.
    # A resource absent from the inventory can never be exported by any code path, whereas
    # a filter applied at write time can be forgotten on the next code path added.
    #
    # API keys: credentials never travel. Projections: rebuildable, and rebuilding them at
    # the destination is cheaper and safer than trusting a stale copy. Password hashes:
    # credentials again. Embeddings: tied to the exporting account's model identity and
    # meaningless — silently wrong, not obviously wrong — under a different one.
    refute MemHouse.Accounts.ApiKey in Enum.map(Registry.resources(), &elem(&1, 1))
    assert MemHouse.Knowledge.Projection in Registry.derived_resources()
    assert MemHouse.Retrieval.RecallDocument in Registry.derived_resources()
    assert MemHouse.Operations.PipelineRun in Registry.operational_resources()

    refute Enum.any?(Registry.resources(), fn {_name, resource} ->
             resource in Registry.operational_resources()
           end)

    assert :hashed_password in Registry.excluded_attributes(MemHouse.Accounts.Peer)
    assert :embedding in Registry.excluded_attributes(MemHouse.Knowledge.KnowledgeItem)

    for attribute <-
          ~w(diskann_labels embedding embedding_provider embedding_model embedding_version embedding_dimensions source_indexed_at)a do
      assert attribute in Registry.excluded_attributes(MemHouse.Observations.Message)
    end
  end

  test "audit verification rejects any changed event" do
    # Build a two-event chain by hand so the tampering is unambiguous. The first event has no
    # predecessor; the second commits to the first's hash, which is what links them.
    events = [
      audit_row(nil, "one", "2026-07-28T10:00:00.000000Z"),
      audit_row(:previous, "two", "2026-07-28T10:00:01.000000Z")
    ]

    [first, second] = events
    first_hash = event_hash(first)
    first = Map.put(first, "event_hash", first_hash)

    # Order matters: the predecessor hash must be set before the event's own hash is
    # computed, because the hash covers it. Doing it the other way round produces a chain
    # that looks valid but proves nothing.
    second =
      second
      |> Map.put("previous_hash", first_hash)
      |> then(&Map.put(&1, "event_hash", event_hash(&1)))

    assert {:ok, %{count: 2}} = AuditVerifier.verify([first, second])

    # Change one metadata value and nothing else. The verifier must name the offending event
    # and refuse the whole chain. Import calls this before opening its write transaction, so
    # a tampered history can never be partially written to a destination.
    changed = Map.put(second, "metadata", %{"count" => 999})
    assert {:error, {:audit_event_hash_mismatch, "two"}} = AuditVerifier.verify([first, changed])
  end

  test "readiness covers database, Oban, queues, model roles, and the embedding index" do
    result = Health.readiness()

    # Readiness is a deployment gate, so it must check everything the app needs to actually
    # serve: the database connection, the job supervisor, the ability to query queue depth,
    # and that all five model roles resolve. A readiness check that only pings the web
    # process reports "ready" for an instance that cannot process a single ingest.
    assert result.status == "ready"
    assert result.checks.database.status == "ok"
    assert result.checks.oban.status == "ok"
    assert result.checks.queues.status == "ok"
    assert result.checks.lifecycle_sweeps.status == "ok"
    assert result.checks.pipeline_runs.status == "ok"
    assert is_map(result.checks.pipeline_runs.unfinished)

    assert Map.keys(result.checks.lifecycle_sweeps.last_completed_at) |> Enum.sort() == [
             "expiry",
             "revalidation"
           ]

    assert result.checks.model_roles.status == "ok"
    assert result.checks.embedding_index.status == "ok"
    assert result.checks.embedding_index.configured_dimensions == 1024
    assert result.checks.embedding_index.indexed_dimensions == [1024]

    {Oban.Plugins.Cron, cron_options} =
      Application.fetch_env!(:memhouse, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _options} -> plugin == Oban.Plugins.Cron end)

    assert {"0 * * * *", MemHouse.Operations.LifecycleScheduler} in Keyword.fetch!(
             cron_options,
             :crontab
           )

    assert {"15 2 * * *", MemHouse.Operations.Retention} in Keyword.fetch!(
             cron_options,
             :crontab
           )

    {Oban.Plugins.Pruner, pruner_options} =
      Application.fetch_env!(:memhouse, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _options} -> plugin == Oban.Plugins.Pruner end)

    assert Keyword.fetch!(pruner_options, :max_age) == 7 * 24 * 60 * 60

    # All five roles, and their identities only — never their credentials.
    assert map_size(result.checks.model_roles.configured) == 5
  end

  test "readiness formats completed lifecycle sweep timestamps" do
    expected = complete_lifecycle_runs!()

    result = Health.readiness()

    assert result.status == "ready"
    assert result.checks.lifecycle_sweeps.status == "ok"
    assert result.checks.lifecycle_sweeps.last_completed_at == expected

    assert {:ok, _expiry} = NaiveDateTime.from_iso8601(expected["expiry"])
    assert {:ok, _revalidation} = NaiveDateTime.from_iso8601(expected["revalidation"])
  end

  test "readiness reports never when no lifecycle sweep has completed" do
    DataLayer.with_free_account(fn _account, _actor -> :ok end)

    result = Health.readiness()

    assert result.status == "ready"

    assert result.checks.lifecycle_sweeps == %{
             status: "ok",
             last_completed_at: %{"expiry" => "never", "revalidation" => "never"}
           }
  end

  test "embedding index rejects an embedder width without an installed index" do
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      Keyword.update!(original_roles, :embedder, fn config ->
        Map.put(config, :embedding_dimensions, 384)
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    on_exit(fn -> Application.put_env(:memhouse, :model_roles, original_roles) end)

    assert %{status: "error", configured_dimensions: 384, indexed_dimensions: [1024]} =
             RuntimeConfig.embedding_index_check()

    assert_raise RuntimeError,
                 "MEMHOUSE_EMBEDDING_DIMENSIONS must match an installed vector index; " <>
                   "configured dimensions: 384; indexed dimensions: 1024",
                 fn -> RuntimeConfig.validate!() end
  end

  test "readiness is not ready when the configured embedder has no index" do
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      Keyword.update!(original_roles, :embedder, fn config ->
        Map.put(config, :embedding_dimensions, 384)
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    on_exit(fn -> Application.put_env(:memhouse, :model_roles, original_roles) end)

    result = Health.readiness()

    assert result.status == "not_ready"

    assert %{status: "error", configured_dimensions: 384, indexed_dimensions: [1024]} =
             result.checks.embedding_index
  end

  test "readiness reports unattended governance diagnostics" do
    previous = Application.get_env(:memhouse, :governance, [])

    Application.put_env(:memhouse, :governance, Keyword.put(previous, :unattended, true))

    assert %{
             unattended: true,
             status: "ok",
             pending_human_reviews: 0,
             restricted_withheld: 0
           } = Health.readiness().governance

    Application.put_env(:memhouse, :governance, Keyword.put(previous, :unattended, false))

    assert %{
             unattended: false,
             status: "ok",
             pending_human_reviews: 0,
             restricted_withheld: 0
           } = Health.readiness().governance

    Application.put_env(:memhouse, :governance, previous)
  end

  test "exact API metering feeds self-host cost and budget visibility" do
    account_key = "f10-metering-#{System.unique_integer([:positive])}"

    {_account, actor} =
      DataLayer.with_account_key(
        account_key,
        [role: :account_admin, pipeline?: true],
        fn account, actor -> {account, actor} end
      )

    assert :ok =
             Metering.record_api(actor, %{
               operation: "api.ingest",
               http_status: 200,
               status: "ok"
             })

    summary = Metering.summary(actor)
    # One recorded request, counted once as an event, once as an API request, and once as an
    # ingest. The overlapping counters are intentional: an operator asks both "how many
    # requests?" and "how many ingests?" and both must come from the same durable ledger.
    assert summary.event_count == 1
    assert summary.api_requests == 1
    assert summary.ingests == 1
    # No model was called, so no tokens. Token counts come only from real provider calls;
    # they are never estimated from request counts.
    assert summary.tokens == %{input: 0, output: 0, embedding: 0}

    assert summary.ingest_economics == %{
             messages: 1,
             calls: 0,
             calls_per_message: 0.0,
             tokens_per_message: 0.0,
             cost_per_message: 0.0
           }

    assert summary.model_calls == %{
             window_seconds: 86_400,
             attempts: 0,
             errors: 0,
             error_rate: 0.0,
             unmetered: 0,
             error_classes: %{}
           }

    assert is_integer(summary.logical_storage_bytes)
    assert summary.storage.durable_bytes == summary.logical_storage_bytes
    assert is_integer(summary.storage.operational_bytes)
    assert is_boolean(summary.storage.inverted?)
    # No model tokens means zero cost under either the shipped planning profile
    # or an operator override. The profile identity keeps that distinction
    # visible instead of silently treating an absent table as free usage.
    assert summary.estimated_model_cost == 0.0
    assert %{id: profile_id, kind: profile_kind} = summary.model_cost_profile
    assert is_binary(profile_id)
    assert profile_kind in ["planning_reference", "operator_override"]
  end

  test "the shipped cost profile is versioned and non-zero before an operator override" do
    rates = Application.fetch_env!(:memhouse, :model_cost_per_million)
    profile = Application.fetch_env!(:memhouse, :model_cost_profile)

    assert profile == %{id: "planning-reference-v1", kind: "planning_reference"}
    assert get_in(rates, ["ingest_extractor", :input]) > 0.0
    assert get_in(rates, ["ingest_extractor", :output]) > 0.0
    assert get_in(rates, ["dream_reasoner", :input]) > 0.0
    assert get_in(rates, ["dialectic_agent", :output]) > 0.0
    assert get_in(rates, ["embedder", :embedding]) > 0.0
    assert get_in(rates, ["reranker", :input]) > 0.0
  end

  test "metering declares its own Account, so the database wall admits the ledger write" do
    account_key = "f10-metering-wall-#{System.unique_integer([:positive])}"

    {_account, actor} =
      DataLayer.with_account_key(
        account_key,
        [role: :account_admin, pipeline?: true],
        fn account, actor -> {account, actor} end
      )

    # Metering runs from a before-send callback and from an operator page, both of which
    # execute after every transaction the request opened has already ended. In production
    # each therefore starts on a pooled connection with no Account declared on it at all,
    # and the row-level-security policies compare every row against that declaration.
    #
    # Under the SQL sandbox the seeding above leaves its Account settings installed for the
    # rest of this test, which would hide exactly that condition. Clearing them is what
    # reproduces the connection state metering actually meets.
    clear_account_declaration!()

    # Without its own Account-scoped transaction this write is refused outright: the policy's
    # check clause compares the new row's account against an undeclared setting, which is
    # never equal, and PostgreSQL rejects the insert.
    assert :ok =
             Metering.record_api(actor, %{
               operation: "api.search",
               http_status: 200,
               status: "ok"
             })

    clear_account_declaration!()

    # The read side carries the same requirement and fails far more quietly: with no Account
    # declared the policy filters every row away, so an operator is told the Account consumed
    # nothing instead of being told the question could not be answered.
    summary = Metering.summary(actor)
    assert summary.event_count == 1
    assert summary.api_requests == 1
  end

  test "model-call health keeps unknown failed-call cost visible" do
    account_key = "f10-unmetered-model-#{System.unique_integer([:positive])}"

    {_account, actor, config} =
      DataLayer.with_account_key(
        account_key,
        [role: :account_admin, pipeline?: true],
        fn account, actor ->
          {account, actor,
           Config.resolve(:ingest_extractor, %{account_id: account.id, actor: actor})}
        end
      )

    assert :ok =
             Usage.emit(
               %{account_id: actor.account_id, actor: actor},
               config,
               %{
                 operation: :structured,
                 status: :error,
                 duration_ms: 50,
                 usage: %{},
                 metadata: %{error_class: "request_timeout", metering_status: :unmetered}
               }
             )

    assert Metering.summary(actor).model_calls == %{
             window_seconds: 86_400,
             attempts: 1,
             errors: 1,
             error_rate: 1.0,
             unmetered: 1,
             error_classes: %{"request_timeout" => 1}
           }
  end

  test "ingest economics include every extractor call and operator-supplied cost" do
    account_key = "f10-ingest-economics-#{System.unique_integer([:positive])}"

    {_account, actor, config} =
      DataLayer.with_account_key(
        account_key,
        [role: :account_admin, pipeline?: true],
        fn account, actor ->
          {account, actor,
           Config.resolve(:ingest_extractor, %{account_id: account.id, actor: actor})}
        end
      )

    original_rates = Application.get_env(:memhouse, :model_cost_per_million, %{})
    original_profile = Application.fetch_env!(:memhouse, :model_cost_profile)

    Application.put_env(:memhouse, :model_cost_per_million, %{
      "ingest_extractor" => %{input: 1.0, output: 2.0}
    })

    Application.put_env(:memhouse, :model_cost_profile, %{
      id: "contract-test-v1",
      kind: "operator_override"
    })

    on_exit(fn ->
      Application.put_env(:memhouse, :model_cost_per_million, original_rates)
      Application.put_env(:memhouse, :model_cost_profile, original_profile)
    end)

    assert :ok = Metering.record_api(actor, %{operation: "api.ingest", status: "ok"})

    assert :ok =
             Usage.emit(
               %{account_id: actor.account_id, actor: actor},
               config,
               %{
                 operation: :structured,
                 status: :ok,
                 duration_ms: 50,
                 usage: %{input_tokens: 600, output_tokens: 400},
                 metadata: %{}
               }
             )

    summary = Metering.summary(actor)

    assert summary.ingest_economics == %{
             messages: 1,
             calls: 1,
             calls_per_message: 1.0,
             tokens_per_message: 1000.0,
             cost_per_message: 0.0014
           }

    assert summary.model_cost_profile == %{
             id: "contract-test-v1",
             kind: "operator_override"
           }
  end

  test "production JSON logs redact credentials and drop unreviewed metadata" do
    # A deliberately hostile log line: three credential shapes in the message, and a metadata
    # key holding user content. Logs are shipped off-box and retained, so anything that
    # survives here has effectively escaped the system's other content-safety boundaries.
    line =
      MemHouse.Observability.JSONFormatter.format(
        %{
          level: :info,
          msg:
            {:string,
             "authorization=Bearer secret-token password=hunter2 api_key=provider-secret"},
          meta: %{
            time: System.system_time(:microsecond),
            request_id: "request-1",
            account_id: "account-1",
            error_class: "RuntimeError",
            content: "private knowledge"
          }
        },
        %{}
      )
      |> IO.iodata_to_binary()
      |> Jason.decode!()

    # Metadata is an allowlist, asserted by equality rather than by checking the bad key is
    # absent: only reviewed keys survive, so a field added anywhere in the system cannot
    # start appearing in logs merely because nobody thought to exclude it.
    assert line["metadata"] == %{
             "request_id" => "request-1",
             "account_id" => "account-1",
             "error_class" => "RuntimeError"
           }

    assert line["message"] =~ "[REDACTED]"
    refute line["message"] =~ "secret-token"
    refute line["message"] =~ "hunter2"
    refute line["message"] =~ "provider-secret"
    refute line["metadata"] |> Map.has_key?("content")
  end

  test "packaging pins pg0 and pgvectorscale for supported platforms" do
    # The embedded database launcher is pinned to an exact version, and every supported
    # platform's download has a reviewed SHA-256 digest. Unpinning it, or shipping a platform
    # without a digest, turns a release build into an unverified download.
    assert File.read!("rel/pg0/VERSION") == "0.14.2\n"

    checksums = File.read!("rel/pg0/checksums.txt")
    assert checksums =~ "pg0-darwin-aarch64"
    assert checksums =~ "pg0-linux-x86_64-gnu"

    assert File.read!("rel/pgvectorscale/VERSION") == "0.9.0\n"
    vectorscale_checksums = File.read!("rel/pgvectorscale/checksums.txt")
    assert vectorscale_checksums =~ "darwin-aarch64.tar.gz"
    assert vectorscale_checksums =~ "linux-aarch64-gnu.tar.gz"
    assert vectorscale_checksums =~ "linux-x86_64-gnu.tar.gz"
    vectorscale_build = File.read!("scripts/build-pgvectorscale")
    assert vectorscale_build =~ "rust_toolchain=1.88.0"
    assert vectorscale_build =~ "Linux:x86_64|Linux:amd64"
    assert vectorscale_build =~ "target-feature=+avx2,+fma"
    assert File.read!("config/runtime.exs") =~ ~s("linux-arm64")
    package_script = File.read!("scripts/package-release")
    assert package_script =~ "scripts/build-pgvectorscale"
    assert package_script =~ "Intel macOS requires external PostgreSQL"
    assert package_script =~ "musl requires external PostgreSQL"

    dockerfile = File.read!("Dockerfile")
    # The native-extension build stage is pinned to an exact toolchain image.
    assert dockerfile =~ "RUST_IMAGE=rust:1.85-slim-bookworm"
    # The runtime never runs as root.
    assert dockerfile =~ "USER memhouse"
    # The container must not launch the embedded database. Containerised deployments use an
    # operator-run Postgres; a container that quietly started its own would put durable data
    # inside an ephemeral layer.
    refute dockerfile =~ "pg0 start"

    compose = File.read!("compose.yml")
    assert compose =~ "timescale/timescaledb-ha:pg18-all-oss"
    # Tracing and metrics are opt-in through a profile, not always-on.
    assert compose =~ "profiles: [observability]"
    # No Redis, and no second worker runtime. Jobs run on Postgres in every deployment mode;
    # introducing another datastore would fork the guarantees between the two modes.
    refute compose =~ "redis"
  end

  test "pg0 stages verified pgvectorscale files without rewriting a match" do
    root = temp_path("vectorscale-stage")
    source = Path.join(root, "source")
    installation = Path.join(root, "installation")
    library = "lib/vectorscale.dylib"
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, library), "verified-extension")
    File.write!(Path.join(source, "VERSION"), "0.9.0\n")

    digest =
      :crypto.hash(:sha256, "verified-extension")
      |> Base.encode16(case: :lower)

    File.write!(Path.join(source, "manifest.sha256"), "#{digest}  #{library}\n")

    config = [
      vectorscale_dir: source,
      installation_root: installation,
      postgres_version: "18.1.0"
    ]

    assert :ok = MemHouse.Pg0.stage_vectorscale!(config)
    target = Path.join([installation, "18.1.0", library])
    assert File.read!(target) == "verified-extension"
    first = File.stat!(target).mtime
    assert :ok = MemHouse.Pg0.stage_vectorscale!(config)
    assert File.stat!(target).mtime == first
  end

  defp complete_lifecycle_runs! do
    {runs, actor} =
      DataLayer.with_free_account(fn account, actor ->
        assert {:ok, runs} =
                 Pipeline.enqueue_lifecycle_sweeps(account.id, actor, DateTime.utc_now())

        {runs, actor}
      end)

    [expiry: runs.expiry, revalidation: runs.revalidation]
    |> Map.new(fn {kind, run} ->
      completed =
        run
        |> Ash.Changeset.for_update(:execute)
        |> Ash.Changeset.set_context(%{warn_on_transaction_hooks?: false})
        |> Ash.update!(actor: actor)

      timestamp =
        completed.processed_at
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()

      {Atom.to_string(kind), timestamp}
    end)
  end

  # A minimal audit event in the shape the verifier reads from an archive. Every field here
  # is covered by the hash, so none of them may be omitted or reordered when constructing a
  # test chain. Metadata is a plain counter: audit records carry ids, actions, and counts,
  # never message text, statements, prompts, or secrets.
  defp audit_row(previous_hash, id, occurred_at) do
    %{
      "id" => id,
      "account_id" => "018fc0a0-0000-7000-8000-000000000001",
      "category" => "configuration",
      "action" => "test",
      "resource_type" => "test",
      "resource_id" => nil,
      "content_hash" => nil,
      "metadata" => %{"count" => 1},
      "occurred_at" => occurred_at,
      "inserted_at" => occurred_at,
      "previous_hash" => previous_hash,
      "event_hash" => nil
    }
  end

  # Computes an event's hash with the same function the writer uses, so the fixture chain is
  # verifiable for the same reason a real one is. Deliberately not a reimplementation: a
  # second copy of the hashing rule could drift and would then verify nothing.
  defp event_hash(event) do
    MemHouse.Governance.Audit.content_hash(%{
      account_id: event["account_id"],
      category: event["category"],
      action: event["action"],
      resource_type: event["resource_type"],
      resource_id: event["resource_id"],
      content_hash: event["content_hash"],
      metadata: event["metadata"],
      occurred_at: event["occurred_at"],
      previous_hash: event["previous_hash"]
    })
  end

  # Puts this connection back into the state a freshly checked-out one is in: no Account
  # declared, so every row-level-security policy on a tenant table denies until a caller
  # declares one. The settings are transaction-local, so this only affects the running test.
  defp clear_account_declaration! do
    Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('memhouse.account_id', '', true)", [])
    Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('memhouse.account_key', '', true)", [])
  end

  # Unique path per call so concurrent or repeated runs never share an archive file. The
  # caller is responsible for removing it in on_exit.
  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "memhouse-f10-#{System.unique_integer([:positive])}-#{name}"
    )
  end
end
