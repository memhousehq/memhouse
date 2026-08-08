# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.GovernanceSessionController do
  @moduledoc """
  Manages password-backed curator browser sessions.

  Requires email/password plus curator or account-admin role; machine credentials cannot enter.
  LiveView reverifies token, identity kind, and role on every mount and reconnect. All failures
  use one generic redirect to prevent account and curator enumeration.
  """

  use MemHouseWeb, :controller

  alias MemHouse.Identity

  @doc """
  Renders the curator sign-in form.

  `error=invalid` enables the generic rejection notice. Supplies the required CSRF token.
  """
  def new(conn, params) do
    render(conn, :new,
      invalid_credentials?: params["error"] == "invalid",
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  @doc """
  Authenticates the form and, on success, establishes the curator session.

  Requires form `email` and `password`, a password identity, and curator/admin role. Success renews
  the session id to prevent fixation. Every failure uses the same redirect.
  """
  def create(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{actor: actor, token: token}}
      when actor.role in [:account_admin, :curator] and actor.identity_kind == :password ->
        conn
        |> put_session(:governance_token, token)
        |> configure_session(renew: true)
        |> redirect(to: "/governance")

      _other ->
        redirect(conn, to: "/governance/sign-in?error=invalid")
    end
  end

  @doc """
  Signs the curator out and returns them to the form.

  Clears the whole browser session. Stateless copied tokens remain valid until expiry.
  """
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/governance/sign-in")
  end
end
