# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.AuthController do
  @moduledoc """
  Exchanges a human's email and password for a JSON API bearer token.

  This unauthenticated route issues only password identities, never machine API keys.
  Authentication failures stay opaque to prevent account enumeration.
  """

  use MemHouseWeb, :controller

  alias MemHouse.Identity

  @doc """
  Signs a human in with email and password.

  Returns 200 with the bearer token and peer id, or an opaque 401 for malformed or invalid
  credentials. The token is secret and must not be logged or audited.
  """
  def password(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{peer: peer, token: token}} ->
        json(conn, %{data: %{token: token, token_type: "Bearer", peer_id: peer.id}})

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  def password(conn, _params), do: unauthorized(conn)

  # The single rejection response. Both the credential-mismatch path and the
  # malformed-request path funnel through here so they stay byte-identical; giving either
  # one its own message would turn this endpoint into an account oracle.
  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
  end
end
