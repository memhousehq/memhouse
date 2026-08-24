# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.Metering do
  @moduledoc """
  Records Account usage and builds operator summaries.

  UsageEvent is the exact retained ledger. Metadata is reduced to a reviewed content-safe allowlist,
  token and duration units remain explicit, and self-hosted cost estimates use operator-provided
  rates rather than hidden billing state.
  """

  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Operations.BudgetCounter
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Operations.UsageEvent

  require Ash.Query

  @token_metrics [:input_tokens, :output_tokens, :embedding_tokens]
  @model_health_window_seconds 86_400

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
  — this is exact within the configured retention horizon, not a sampled
  estimate.

  The returned map holds the recorded event count, API request and ingest
  counts, input/output/embedding token totals overall and per model role,
  durable and operational storage bytes, terminal extraction-failure count, an
  estimated model cost, and the currency that estimate is denominated in.

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

      ingests = metadata_sum(events, "ingest_count")

      storage = MemHouse.Retrieval.Store.storage_bytes(actor.account_id)

      %{
        account_id: actor.account_id,
        event_count: length(events),
        api_requests: metadata_sum(events, "request_count"),
        ingests: ingests,
        tokens: token_totals(events),
        tokens_by_role: by_role,
        logical_storage_bytes: storage.durable,
        storage: %{
          durable_bytes: storage.durable,
          operational_bytes: storage.operational,
          operational_to_durable_ratio: storage_ratio(storage),
          inverted?: storage.operational > storage.durable
        },
        estimated_model_cost: estimated_cost(by_role),
        model_cost_profile: Application.fetch_env!(:memhouse, :model_cost_profile),
        ingest_economics: ingest_economics(events, by_role, ingests),
        terminal_extraction_failures: terminal_extraction_failures(actor),
        model_calls: model_call_health(events),
        currency: "USD"
      }
    end)
  end

  defp terminal_extraction_failures(actor) do
    PipelineRun
    |> Ash.Query.filter(kind == "extraction" and status == "terminal")
    |> Ash.Query.set_tenant(actor.account_id)
    |> Ash.count!(actor: actor)
  end

  defp token_totals(events) do
    %{
      input: Enum.sum(Enum.map(events, & &1.input_tokens)),
      output: Enum.sum(Enum.map(events, & &1.output_tokens)),
      embedding: Enum.sum(Enum.map(events, & &1.embedding_tokens))
    }
  end

  # A zero token total is ambiguous on an error: a provider may have billed a
  # request but returned no usage object. Keep that uncertainty visible rather
  # than inventing token counts that would corrupt cost and budget reporting.
  defp model_call_health(events) do
    cutoff = DateTime.add(Clock.utc_now(), -@model_health_window_seconds, :second)

    events
    |> Enum.filter(&(&1.model_role != "edge" and DateTime.compare(&1.occurred_at, cutoff) != :lt))
    |> Enum.reduce(
      %{
        window_seconds: @model_health_window_seconds,
        attempts: 0,
        errors: 0,
        unmetered: 0,
        error_classes: %{}
      },
      fn event, health ->
        health = %{health | attempts: health.attempts + 1}

        if event.status == "error" do
          error_class = Map.get(event.metadata, "error_class", "unknown")

          %{
            health
            | errors: health.errors + 1,
              unmetered:
                health.unmetered +
                  if(Map.get(event.metadata, "metering_status") == "unmetered", do: 1, else: 0),
              error_classes: Map.update(health.error_classes, error_class, 1, &(&1 + 1))
          }
        else
          health
        end
      end
    )
    |> then(fn health -> Map.put(health, :error_rate, rate(health.errors, health.attempts)) end)
  end

  defp rate(_numerator, 0), do: 0.0
  defp rate(numerator, denominator), do: Float.round(numerator / denominator, 4)

  defp ingest_economics(events, by_role, ingests) do
    extractor_events = Enum.filter(events, &(&1.model_role == "ingest_extractor"))
    tokens = Map.get(by_role, "ingest_extractor", %{input: 0, output: 0, embedding: 0})
    token_count = tokens.input + tokens.output + tokens.embedding
    cost = estimated_role_cost("ingest_extractor", tokens)

    %{
      messages: ingests,
      calls: length(extractor_events),
      unmetered_calls:
        Enum.count(
          extractor_events,
          &(Map.get(&1.metadata, "metering_status") != "complete")
        ),
      calls_per_message: rate(length(extractor_events), ingests),
      tokens_per_message: rate(token_count, ingests),
      cost_per_message: per_message_cost(cost, ingests)
    }
  end

  defp per_message_cost(_cost, 0), do: 0.0
  defp per_message_cost(cost, messages), do: Float.round(cost / messages, 6)

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

  defp storage_ratio(%{durable: 0, operational: 0}), do: 0.0
  defp storage_ratio(%{durable: 0}), do: nil

  defp storage_ratio(%{durable: durable, operational: operational}) do
    Float.round(operational / durable, 2)
  end

  # Rates are price per one million tokens, per model role and token kind. The
  # shipped table is a clearly-labelled planning reference; an operator may
  # replace the whole table with contracted rates. An unconfigured role or kind
  # is still worth 0.0. Rounded to six decimal places because a single small
  # call can cost a fraction of a cent and truncating further would report it as
  # free.
  defp estimated_cost(by_role) do
    Enum.reduce(by_role, 0.0, fn {role, totals}, result ->
      result + estimated_role_cost(role, totals)
    end)
    |> Float.round(6)
  end

  defp estimated_role_cost(role, totals) do
    rates = Application.get_env(:memhouse, :model_cost_per_million, %{})
    role_rates = Map.get(rates, role, %{})

    totals.input / 1_000_000 * Map.get(role_rates, :input, 0.0) +
      totals.output / 1_000_000 * Map.get(role_rates, :output, 0.0) +
      totals.embedding / 1_000_000 * Map.get(role_rates, :embedding, 0.0)
  end
end
