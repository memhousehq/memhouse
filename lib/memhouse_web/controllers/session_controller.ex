# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.SessionController do
  @moduledoc """
  Manages password-backed browser console sessions.

  Admits any human role by email/password, never machine credentials. All failures use one generic
  redirect. LiveViews reverify tokens on mount and reconnect. This controller and curator sign-in
  must keep the same session key so authorized curators authenticate once.
  """

  use MemHouseWeb, :controller

  alias MemHouse.Identity

  @doc """
  Sends a visitor arriving at the bare origin to the console.

  Redirects unconditionally; the console mount hook owns authentication.
  """
  def home(conn, _params), do: redirect(conn, to: "/console")

  @doc """
  Renders the console sign-in form.

  `error=invalid` enables the generic notice. Supplies the required CSRF token.
  """
  def new(conn, params) do
    render(conn, :new,
      invalid_credentials?: params["error"] == "invalid",
      csrf_token: Plug.CSRFProtection.get_csrf_token()
    )
  end

  @doc """
  Authenticates the form and, on success, establishes the console session.

  Requires form `email` and `password` and a password identity. Success renews the session id to
  prevent fixation. Every failure uses the same redirect.
  """
  def create(conn, %{"email" => email, "password" => password}) do
    case Identity.sign_in_password(email, password) do
      {:ok, %{actor: actor, token: token}} when actor.identity_kind == :password ->
        conn
        |> put_session(:governance_token, token)
        |> configure_session(renew: true)
        |> redirect(to: "/console")

      _other ->
        redirect(conn, to: "/sign-in?error=invalid")
    end
  end

  @doc """
  Signs the reader out and returns them to the form.

  Clears the whole browser session. Stateless copied tokens remain valid until expiry.
  """
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/sign-in")
  end
end
