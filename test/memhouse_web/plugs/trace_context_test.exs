# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Plugs.TraceContextTest do
  @moduledoc """
  Covers the request-correlation header contract, end to end through a real request
    rather than by calling the plug directly.

    The route used is the unauthenticated liveness probe, chosen because it needs no
    credential and touches no database: a failure here then means the header behaviour
    is wrong, and cannot be authentication or data setup misfiring.
  """

  use MemHouseWeb.ConnCase, async: true

  describe "trace response headers" do
    test "adds a trace id when the request has no trace context", %{conn: conn} do
      conn = get(conn, ~p"/api/health")

      # 32 lowercase hex characters is the 128-bit trace-id width the W3C
      # trace-context format defines, so the value can be pasted straight into
      # a tracing backend.
      assert [trace_id] = get_resp_header(conn, "x-trace-id")
      assert trace_id =~ ~r/\A[0-9a-f]{32}\z/

      # An all-zero id is that format's explicit "invalid" sentinel, and it is
      # exactly what a disabled tracing SDK reports. Trusting it would stamp
      # every response in the fleet with one identical, useless id, so the plug
      # must reject it and generate a real random id instead. This assertion is
      # the guard against that regression.
      refute trace_id == String.duplicate("0", 32)
    end

    test "preserves the incoming W3C trace id", %{conn: conn} do
      trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"

      # Fields of a version-"00" traceparent: version, trace id, the caller's
      # span id, and sampling flags. Only the trace id is echoed back; the
      # caller's span id is deliberately not adopted, because this service
      # reports its own position in the trace, not its parent's.
      traceparent = "00-#{trace_id}-00f067aa0ba902b7-01"

      conn =
        conn
        |> put_req_header("traceparent", traceparent)
        |> get(~p"/api/health")

      assert get_resp_header(conn, "x-trace-id") == [trace_id]
    end
  end
end
