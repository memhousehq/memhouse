# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Plugs.TraceContext do
  @moduledoc """
  Correlates every HTTP response and request log with a trace id.

  Every response gets `x-trace-id`: preserve a valid W3C inbound id or generate one. Emit
  `x-span-id` only for an active exported span. Headers and log metadata contain opaque ids only,
  never identity or request content. The endpoint runs this before routing; it observes but does
  not create spans.
  """

  import Plug.Conn

  @trace_id_header "x-trace-id"
  @span_id_header "x-span-id"
  @traceparent_header "traceparent"

  # W3C trace ids are 16 bytes (128 bits), encoded as 32 lowercase hex characters.
  @trace_id_bytes 16

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  def init(opts), do: opts

  @doc """
  Sets the request's log metadata and arranges for the trace headers to be
  written when the response is sent.

  Always returns the connection unchanged apart from one assign and the
  registered callback; a malformed inbound `traceparent` is treated as absent
  and never fails the request.
  """
  def call(conn, _opts) do
    # Resolve once so fallback log and response ids match.
    fallback_trace_id = trace_id_from_traceparent(conn) || random_trace_id()

    case current_trace_context() do
      {:ok, trace_id, span_id} -> Logger.metadata(trace_id: trace_id, span_id: span_id)
      :error -> Logger.metadata(trace_id: fallback_trace_id)
    end

    assign(conn, :memhouse_fallback_trace_id, fallback_trace_id)
    |> register_before_send(&put_trace_headers/1)
  end

  # Request instrumentation creates the span after this plug, so inspect it at send time.
  defp put_trace_headers(conn) do
    case current_trace_context() do
      # Active exported span ids override fallback correlation ids.
      {:ok, trace_id, span_id} ->
        conn
        |> put_resp_header(@trace_id_header, trace_id)
        |> put_resp_header(@span_id_header, span_id)

      # Never invent a span id when no span exists.
      :error ->
        put_resp_header(conn, @trace_id_header, conn.assigns.memhouse_fallback_trace_id)
    end
  end

  # OpenTelemetry may return all-zero invalid ids when tracing is disabled.
  defp current_trace_context do
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    with true <- span_ctx != :undefined,
         trace_id when is_binary(trace_id) <- OpenTelemetry.Span.hex_trace_id(span_ctx),
         span_id when is_binary(span_id) <- OpenTelemetry.Span.hex_span_id(span_ctx),
         true <- valid_trace_id?(trace_id),
         true <- valid_span_id?(span_id) do
      {:ok, trace_id, span_id}
    else
      _ -> :error
    end
  end

  defp trace_id_from_traceparent(conn) do
    conn
    |> get_req_header(@traceparent_header)
    |> List.first()
    |> parse_traceparent()
  end

  # Accept exact W3C version 00 widths; preserve only trace identity, not parent span or flags.
  defp parse_traceparent(
         <<"00-", trace_id::binary-size(32), "-", _span_id::binary-size(16), "-",
           _flags::binary-size(2)>>
       ) do
    if valid_trace_id?(trace_id), do: trace_id
  end

  # Invalid or absent inbound context degrades to a fresh id.
  defp parse_traceparent(_traceparent), do: nil

  # All-zero is the format's invalid sentinel.
  defp valid_trace_id?(trace_id) do
    String.match?(trace_id, ~r/\A[0-9a-f]{32}\z/) and trace_id != String.duplicate("0", 32)
  end

  # Span ids are 8 bytes: 16 lowercase hex characters.
  defp valid_span_id?(span_id) do
    String.match?(span_id, ~r/\A[0-9a-f]{16}\z/) and span_id != String.duplicate("0", 16)
  end

  # Strong random ids avoid collisions across nodes and runs.
  defp random_trace_id do
    @trace_id_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
