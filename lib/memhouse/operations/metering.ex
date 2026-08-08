# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.Metering do
  @moduledoc """
  Records Account usage and builds operator summaries.

  UsageEvent is the only durable ledger. Metadata is reduced to a reviewed content-safe allowlist,
  token and duration units remain explicit, and self-hosted cost estimates use operator-provided
  rates rather than hidden billing state.
  """

  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Operations.BudgetCounter
  alias MemHouse.Operations.UsageEvent
  alias MemHouse.Repo

  @token_metrics [:input_tokens, :output_tokens, :embedding_tokens]

  @doc """
  Writes one authenticated HTTP usage event and updates daily counters.

  `attrs` requires a coarse `:operation`; scope, HTTP status, and outcome are optional.
  Attribution comes from the actor, never request content. `"f10-1"` is the versioned
  operational payload identity, and ingest requests also increment the ingest counter.

  Returns `:ok`. Ledger failures raise; unavailable rebuildable counters are skipped.
  """
  def record_api(%Actor{} = actor, attrs) do
    operation = Map.fetch!(attrs, :operation)
    scope_id = Map.get(attrs, :scope_id)

    # The write needs its own Account-scoped transaction. This runs from a
    # before-send callback, so the request's own transactions have already ended
    # and the connection it lands on has no Account declared: the row-level
    # security policy on the ledger compares the new row against that
    # declaration and refuses the insert without one. Opening the transaction
    # here is also what keeps the ledger row independent of the request's
    # outcome — a request that rolled its own work back still consumed capacity.
    DataLayer.in_account_transaction(actor.account_id, fn ->
      UsageEvent
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(actor.account_id)
      |> Ash.Changeset.for_create(:record, %{
        call_id: Ecto.UUID.generate(),
        scope_id: scope_id,
        peer_id: actor.peer_id,
        operation: operation,
        model_role: "edge",
        provider: "none",
        model_name: "none",
        model_version: "none",
        prompt_version: "none",
        pipeline_version: "f10-1",
        status: Map.get(attrs, :status, "ok"),
        metadata: %{
          "http_status" => Map.get(attrs, :http_status),
          "request_count" => 1,
          "ingest_count" => if(operation == "api.ingest", do: 1, else: 0)
        },
        occurred_at: Clock.utc_now()
      })
      # The caller's own role must not decide whether its usage is recorded, so
      # the write is escalated to the internal writer that the ledger's create
      # policy admits. The Account is still the caller's.
      |> Ash.create!(actor: %{actor | role: :system, pipeline?: true})
    end)

    # Counters follow the durable write, never precede it.
    BudgetCounter.increment(actor.account_id, scope_id, :api_requests, 1)

    if operation == "api.ingest",
      do: BudgetCounter.increment(actor.account_id, scope_id, :ingest, 1)

    :ok
  end

  @doc """
  Folds one model call's token usage into the daily counters.

  Called by the model layer's usage emission point after it has written the
  durable row, so this function deliberately writes nothing durable itself.
  `usage` is a map that may carry any of `:input_tokens`, `:output_tokens`, and
  `:embedding_tokens`; a missing metric counts as zero.

  Always returns `:ok`. A failure to update a rebuildable counter must never
  fail the model call that produced the tokens.
  """
  def record_model(account_id, scope_id, usage) do
    Enum.each(@token_metrics, fn metric ->
      BudgetCounter.increment(account_id, scope_id, metric, Map.get(usage, metric, 0))
    end)
  end

  @doc """
  Builds the Account-wide usage, storage, and estimated-cost summary.

  Reads the whole ledger for the actor's Account under that actor's own
  authorization, so an actor without administrator rights gets an error rather
  than a redacted answer. Totals are computed in memory from every recorded row
  — this is exact history, not a sampled or windowed estimate — which means the
  cost of the call grows with the ledger.

  The returned map holds the recorded event count, API request and ingest
  counts, input/output/embedding token totals overall and per model role,
  logical storage bytes, an estimated model cost, and the currency that
  estimate is denominated in.

  Raises if the actor may not read the ledger.
  """
  def summary(%Actor{} = actor) do
    # Both reads happen inside one Account-scoped transaction. Callers — an
    # operator page and a controller action — hold no transaction of their own,
    # so without this the connection has no Account declared and the row-level
    # security policies filter every row away. That failure is silent: the
    # summary would report an Account with real spend as having consumed
    # nothing, which is worse than refusing to answer.
    DataLayer.in_account_transaction(actor.account_id, fn ->
      events =
        UsageEvent
        |> Ash.Query.set_tenant(actor.account_id)
        |> Ash.read!(actor: actor)

      by_role =
        events
        |> Enum.group_by(& &1.model_role)
        |> Map.new(fn {role, role_events} -> {role, token_totals(role_events)} end)

      %{
        account_id: actor.account_id,
        event_count: length(events),
        api_requests: metadata_sum(events, "request_count"),
        ingests: metadata_sum(events, "ingest_count"),
        tokens: token_totals(events),
        tokens_by_role: by_role,
        logical_storage_bytes: logical_storage_bytes(actor.account_id),
        estimated_model_cost: estimated_cost(by_role),
        currency: "USD"
      }
    end)
  end

  defp token_totals(events) do
    %{
      input: Enum.sum(Enum.map(events, & &1.input_tokens)),
      output: Enum.sum(Enum.map(events, & &1.output_tokens)),
      embedding: Enum.sum(Enum.map(events, & &1.embedding_tokens))
    }
  end

  # Metadata is a free-form map on the ledger row, so a value written by an
  # older build may be any shape. Non-integers are dropped rather than crashing
  # the summary: a malformed historical row must not make the operator view
  # permanently unreadable.
  defp metadata_sum(events, key) do
    events
    |> Enum.map(&Map.get(&1.metadata, key, 0))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  # Raw SQL rather than an Ash aggregate because this sums byte lengths across
  # three unrelated tables in one round trip. It is read-only, the statement is
  # a fixed literal, and the Account id is the one bound parameter — and it is
  # the filter on each of the three subqueries.
  #
  # "Logical" means the size of the durable content itself — message text,
  # knowledge statements, and stored document bytes — not the on-disk size of
  # the database. Rebuildable derivations (vectors, chunks, projections) are
  # excluded on purpose, so the number reflects what an export would carry.
  #
  # A failed query yields zero rather than raising: storage size is an
  # informational field and must not take down the whole summary. That
  # forgiveness is why this must stay inside the summary's Account-scoped
  # transaction: run with no Account declared, the row-level security policies
  # on all three tables filter every row away and the honest-looking zero it
  # returns would be indistinguishable from an empty Account.
  # sobelow_skip ["SQL.Query"]
  defp logical_storage_bytes(account_id) do
    sql = """
    SELECT
      COALESCE((SELECT sum(octet_length(content)) FROM messages WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(octet_length(statement)) FROM knowledge_items WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(byte_size) FROM document_versions WHERE account_id = $1), 0)
    """

    # Postgres returns a sum of bigints as numeric, which the driver decodes as
    # a Decimal; the plain-integer clause covers drivers or plans that do not.
    case Ecto.Adapters.SQL.query(Repo, sql, [Ecto.UUID.dump!(account_id)]) do
      {:ok, %{rows: [[%Decimal{} = bytes]]}} -> Decimal.to_integer(bytes)
      {:ok, %{rows: [[bytes]]}} -> bytes
      _other -> 0
    end
  end

  # Rates are operator-configured price per one million tokens, per model role
  # and per token kind. An unconfigured role or kind is worth 0.0, so a
  # self-hoster who sets nothing sees an honest zero instead of a fabricated
  # number. Rounded to six decimal places because a single small call can cost
  # a fraction of a cent and truncating further would report it as free.
  defp estimated_cost(by_role) do
    rates = Application.get_env(:memhouse, :model_cost_per_million, %{})

    Enum.reduce(by_role, 0.0, fn {role, totals}, result ->
      role_rates = Map.get(rates, role, %{})

      result +
        totals.input / 1_000_000 * Map.get(role_rates, :input, 0.0) +
        totals.output / 1_000_000 * Map.get(role_rates, :output, 0.0) +
        totals.embedding / 1_000_000 * Map.get(role_rates, :embedding, 0.0)
    end)
    |> Float.round(6)
  end
end
