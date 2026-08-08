# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Plugs.MeterUsage do
  @moduledoc """
  Records one content-safe usage entry per authenticated API request.

  The before-send callback captures final status, including rejections and failures; only `5xx` is
  classed as error. Metering opens its own Account transaction after controller work. Store only a
  coarse operation, numeric status, and status class—never bodies, parameters, content, ids, or
  credentials. This plug must run after authentication; anonymous requests are skipped.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Registers the before-send callback that writes the usage entry.

  Returns the connection immediately; the ledger write happens later, when the
  response is flushed, and the response itself is passed through unmodified.
  """
  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn response ->
      actor = response.assigns[:current_actor]

      # Never guess an Account for unauthenticated usage.
      if actor do
        MemHouse.Operations.Metering.record_api(actor, %{
          operation: operation(response),
          http_status: response.status,
          status: if(response.status < 500, do: "ok", else: "error")
        })
      end

      response
    end)
  end

  # The ingest budget keys on this exact operation identity.
  defp operation(%{method: "POST", request_path: "/api/v1/ingest"}), do: "api.ingest"

  # Status paths end in a message id, so use a bounded operation name rather
  # than recording one durable usage identity per observation.
  defp operation(%{method: "GET", path_info: ["api", "v1", "ingest", _message_id]}),
    do: "api.ingest_status"

  # Last-segment names bound cardinality and exclude record ids from durable usage.
  defp operation(%{request_path: path}),
    do: "api." <> (path |> Path.basename() |> String.downcase())
end
