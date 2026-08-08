# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Plugs.RequireHumanIdentity do
  @moduledoc """
  Restricts a route to a caller who signed in as a person, rejecting machine
    credentials.

    MemHouse distinguishes two kinds of authenticated identity: a human who
    authenticated with a password (`:password`) and an agent presenting a long-lived API
    key (`:api_key`). Machine credentials are allowed to submit raw observations, read
    governed memory, and answer questions addressed to their own peer.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Plug callback. Options are unused; whatever is passed is returned unchanged.
  """
  @impl true
  def init(opts), do: opts

  @doc """
  Allows the request through unchanged for a password-authenticated human, and
  otherwise halts it with a `403` JSON body.

  The rejecting clause also covers the case where no actor was assigned at all,
  which is why the match on the human case is written as a head pattern rather
  than a conditional inside one clause.
  """
  @impl true
  def call(%{assigns: %{current_actor: %{identity_kind: :password}}} = conn, _opts),
    do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "Human identity required"}))
    |> halt()
  end
end
