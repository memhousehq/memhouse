# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleAuth do
  @moduledoc """
  Authenticates every `/console` LiveView mount and reconnect.

  Only valid password identities may establish browser sessions; machine API
  keys are rejected. Each mount resolves fresh roles and authorized scopes into
  `current_actor`, the authorization context for all console reads and events.
  Never replace it from client-controlled params.

  This hook and `MemHouseWeb.GovernanceAuth` must keep the same session token
  key. Governance adds its stricter curator or account-admin role check.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias MemHouse.Identity

  @doc """
  Assigns a password-authenticated `current_actor` and continues.

  Missing, expired, unknown, or machine credentials halt and redirect to
  `/sign-in`.
  """
  def on_mount(:default, _params, %{"governance_token" => token}, socket) do
    with {:ok, actor} <- Identity.authenticate_bearer(token),
         true <- actor.identity_kind == :password do
      {:cont, assign(socket, :current_actor, actor)}
    else
      # Keep all failures indistinguishable to prevent credential probing.
      _other -> {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  # Missing tokens fail closed like invalid tokens.
  def on_mount(:default, _params, _session, socket),
    do: {:halt, redirect(socket, to: "/sign-in")}
end
