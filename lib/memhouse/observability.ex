# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Observability do
  @moduledoc """
  Provides content-safe tracing and telemetry helpers.

  Spans may record ids, counts, names, versions, timings, token totals, and error classes, never
  messages, prompts, answers, credentials, or secrets. Incoming W3C trace ids are preserved and
  new requests receive a trace id.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @operation_measurements [
    :anchors,
    :attempts,
    :batch_requests,
    :calls,
    :provider_attempts,
    :input_tokens,
    :output_tokens,
    :items,
    :candidates,
    :components,
    :accepted,
    :rejected,
    :deduplicated,
    :cache_hits,
    :cache_misses,
    :failures,
    :stale_claims,
    :elapsed_ms
  ]
  @operation_metadata [
    :run_id,
    :version,
    :status,
    :failure_class,
    :profile,
    :account_id,
    :scope_id,
    :cache_status
  ]
  @operation_names ~w(answer dream ingest_batch profile_refresh reasoning_synthesis reasoning_update recall)
  @operation_statuses ~w(abstained completed degraded delegated empty failed ok partial ready repairable stale_extraction_claim terminal)
  @operation_cache_statuses ~w(hit live_projection miss stale)
  @operation_failure_classes ~w(
    configuration
    dream_failed
    missing_structured_object
    mixed_anchor_outcomes
    model_error
    oversized
    prompt_version_mismatch
    provider_circuit_open
    provider_configuration
    provider_content_filtered
    provider_output_truncated
    provider_transient
    provider_upstream_error
    reasoning_failed
    request_timeout
    stale_extraction_claim
    structured_validation_exhausted
    structured_validation_failed
    transport_error
  )
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9_.:\/=\-]{0,159}\z/u

  @doc """
  Attaches log correlation and the framework instrumentation handlers.

  Called once during application startup, before anything that could emit a
  span. Log metadata is correlated first so that log lines written during
  startup already carry trace ids.

  Each framework handler is attached only when its category is enabled, which
  is why disabling a category costs nothing at runtime: the handler is never
  attached rather than attached and ignored.
  """
  def setup do
    OpentelemetryLoggerMetadata.setup()
    setup_http()
    setup_phoenix()
    setup_ecto()
    setup_oban()
  end

  @doc """
  Runs `fun` inside a span named `span_name`, or runs it directly when
  `category` is disabled.

  `category` selects the configuration switch; `span_name` should be a stable,
  low-cardinality string, since a name built from a request value fragments
  traces and can itself leak content.

  Returns whatever `fun` returns, and lets exceptions propagate unchanged, so
  wrapping a call in a span can never alter its result or its failure
  behaviour.
  """
  def with_span(category, span_name, fun) when is_function(fun, 0) do
    if span_enabled?(category) do
      Tracer.with_span span_name do
        fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  Records one attribute on the current span, or does nothing when `category` is
  disabled.

  Only content-safe values belong here: ids, counts, names, versions, timings,
  and error classes. Attaching an attribute outside an active span is a no-op
  rather than an error.
  """
  def set_attribute(category, key, value) do
    if span_enabled?(category) do
      Tracer.set_attribute(key, value)
    end
  end

  @doc """
  Records a map of attributes on the current span in one call, subject to the
  same content-safety rule and the same category gate as the single-attribute
  form.
  """
  def set_attributes(category, attributes) when is_map(attributes) do
    if span_enabled?(category) do
      Tracer.set_attributes(attributes)
    end
  end

  @doc """
  Emits one unsampled, content-safe aggregate for a completed logical operation.

  The event name is `[:memhouse, :operation, :completed]`. Measurements are a
  fixed set of non-negative counters and timings; omitted values become zero.
  Metadata is reduced to identifiers, versions, short states, and failure
  classes. Unknown keys are discarded, so a caller cannot accidentally attach
  a query, prompt, message, answer, or credential.

  This event is an operational reconciliation signal, not a billing record.
  Exact model usage remains in the durable usage ledger.
  """
  def emit_operation(operation, measurements \\ %{}, metadata \\ %{})
      when (is_atom(operation) or is_binary(operation)) and is_map(measurements) and
             is_map(metadata) do
    measurements =
      Map.new(@operation_measurements, fn key ->
        value = Map.get(measurements, key, Map.get(measurements, Atom.to_string(key), 0))
        {key, non_negative(value)}
      end)

    metadata =
      metadata
      |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
      |> Map.take(@operation_metadata)
      |> Map.put_new(:run_id, Ecto.UUID.generate())
      |> Map.put_new(:version, "unknown")
      |> Map.put_new(:status, "ok")
      |> normalize_operation_metadata()
      |> Map.put(:operation, normalize_operation(operation))

    :telemetry.execute([:memhouse, :operation, :completed], measurements, metadata)
    :ok
  end

  @doc """
  Whether spans for `category` are currently being recorded.

  Defaults to true for any category with no configuration entry, so a new span
  category is visible until someone deliberately turns it off.
  """
  def span_enabled?(category) do
    category
    |> span_config_key()
    |> enabled?(true)
  end

  # The server span is the root of every request trace. Only the request-id
  # header is captured in each direction — it is the correlation handle a
  # support conversation uses. Do not add the authorization header here.
  defp setup_http do
    if enabled?(:http_spans, true) do
      OpentelemetryBandit.setup(
        request_headers: ["x-request-id"],
        response_headers: ["x-request-id"]
      )
    end
  end

  # Adds route and controller naming on top of the raw server span. The runtime
  # configuration enables this category, so the `false` here only applies when
  # no observability configuration is present at all.
  defp setup_phoenix do
    if enabled?(:phoenix_spans, false) do
      OpentelemetryPhoenix.setup(adapter: :bandit)
    end
  end

  # Off by default: one span per query buries the workflow spans that actually
  # explain behaviour. Enable it for latency debugging, and note that including
  # the statement text also risks including its parameters.
  defp setup_ecto do
    if enabled?(:ecto_spans, false) do
      OpentelemetryEcto.setup([:memhouse, :repo], db_statement: db_statement_config())
    end
  end

  # Job spans are instrumented; the queue library's internal plugin spans are
  # not, because they are periodic housekeeping that would swamp the trace view
  # without explaining any request.
  defp setup_oban do
    if enabled?(:oban_spans, true) do
      OpentelemetryOban.setup(
        job: [span_relationship: oban_span_relationship()],
        plugin: :disabled
      )
    end
  end

  # Defaults to disabled: a SQL statement carries the values bound into it, and
  # those values are message content, statements, and identifiers.
  defp db_statement_config do
    :memhouse
    |> Application.get_env(:observability, [])
    |> Keyword.get(:db_statement, :disabled)
  end

  # How a background job's span relates to the request that enqueued it.
  # Defaulting to a child span keeps asynchronous extraction visible inside the
  # trace of the request that caused it, which is usually what someone
  # debugging ingest wants to see.
  defp oban_span_relationship do
    :memhouse
    |> Application.get_env(:observability, [])
    |> Keyword.get(:oban_span_relationship, :child)
  end

  # Each caller passes its own default, so a category is enabled or disabled by
  # the policy at its call site rather than by one global default here.
  defp enabled?(key, default) do
    :memhouse
    |> Application.get_env(:observability, [])
    |> Keyword.get(key, default)
  end

  # Maps a caller-facing category to its configuration key. The catch-all
  # returns the category unchanged, so a category with no mapping falls through
  # to the enabled-by-default branch: a new span type is visible immediately and
  # becomes switchable once a mapping and a configuration entry are added.
  defp span_config_key(:memory), do: :memory_spans
  defp span_config_key(:model), do: :model_spans
  defp span_config_key(:documents), do: :document_spans
  defp span_config_key(category), do: category

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@operation_metadata, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(_key), do: nil

  defp normalize_operation(operation) do
    operation = to_string(operation)
    if operation in @operation_names, do: operation, else: "unknown"
  end

  defp normalize_operation_metadata(metadata) do
    metadata
    |> Map.update(:run_id, Ecto.UUID.generate(), &safe_identifier(&1, Ecto.UUID.generate()))
    |> Map.update(:version, "unknown", &safe_identifier(&1, "unknown"))
    |> Map.update(:status, "unknown", &safe_enum(&1, @operation_statuses, "unknown"))
    |> Map.update(:failure_class, nil, &safe_failure_class/1)
    |> Map.update(:profile, nil, &safe_identifier(&1, "unknown"))
    |> Map.update(:account_id, nil, &safe_uuid/1)
    |> Map.update(:scope_id, nil, &safe_uuid/1)
    |> Map.update(:cache_status, nil, &safe_enum(&1, @operation_cache_statuses, "unknown"))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_identifier(value, fallback) when is_atom(value),
    do: safe_identifier(Atom.to_string(value), fallback)

  defp safe_identifier(value, fallback) when is_binary(value) do
    if String.match?(value, @identifier), do: value, else: fallback
  end

  defp safe_identifier(_value, fallback), do: fallback

  defp safe_enum(value, allowed, fallback) when is_atom(value),
    do: safe_enum(Atom.to_string(value), allowed, fallback)

  defp safe_enum(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp safe_enum(_value, _allowed, fallback), do: fallback

  defp safe_failure_class(nil), do: nil

  defp safe_failure_class(value),
    do: safe_enum(value, @operation_failure_classes, "unknown_failure")

  defp safe_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_float(value) and value >= 0, do: value
  defp non_negative(_value), do: 0
end
