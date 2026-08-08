# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Plugs.RequireIdentity do
  @moduledoc """
  Turns an HTTP bearer credential into the request's authenticated actor.

  This is the only place an HTTP request acquires an Account. Both human tokens and
  machine API keys resolve through `MemHouse.Identity`; caller-supplied Account values
  are ignored. Failures return the same opaque 401.
  """

  @behaviour Plug

  import Plug.Conn

  alias MemHouse.Identity

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Authenticates the bearer credential and installs the actor, tenant, and Ash
  context, or halts the connection with an opaque `401`.

  Returns the connection either way; callers downstream may assume
  `conn.assigns.current_actor` is present because the unauthenticated branch
  halts.
  """
  @impl true
  def call(conn, _opts) do
    # A single "Bearer <credential>" header is the only accepted shape. Repeated
    # or differently framed Authorization headers fall through to the 401 branch
    # rather than being merged, so a smuggled second header cannot win.
    with ["Bearer " <> credential] <- get_req_header(conn, "authorization"),
         {:ok, actor} <- Identity.authenticate_bearer(credential) do
      conn
      |> assign(:current_actor, actor)
      |> Ash.PlugHelpers.set_actor(actor)
      |> Ash.PlugHelpers.set_tenant(actor.account_id)
      |> Ash.PlugHelpers.set_context(%{memhouse_actor: actor})
    else
      # One indistinguishable rejection for every authentication failure mode,
      # and no echo of the presented credential into the response or logs.
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end
end
