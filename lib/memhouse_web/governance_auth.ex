# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.GovernanceAuth do
  @moduledoc """
  Mount-time authentication and authorization for the curator governance console
    LiveView.

    The governance console is where a person approves, edits, rejects, merges, or defers
    proposed knowledge.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias MemHouse.Identity

  @doc """
  LiveView `on_mount` hook wired into the governance live session.

  Returns `{:cont, socket}` with `current_actor` assigned when the session's
  sign-in token belongs to a human curator or account admin, and
  `{:halt, socket}` redirecting to the sign-in page in every other case,
  including a session that carries no token at all.
  """
  def on_mount(:default, _params, %{"governance_token" => token}, socket) do
    with {:ok, actor} <- Identity.authenticate_bearer(token),
         true <- actor.identity_kind == :password,
         true <- actor.role in [:account_admin, :curator] do
      {:cont, assign(socket, :current_actor, actor)}
    else
      # Expired token, machine credential, insufficient role, and unknown
      # credential all end the same way on purpose: a distinguishable failure
      # would tell an unauthenticated visitor which part they got right.
      _other -> {:halt, redirect(socket, to: "/governance/sign-in")}
    end
  end

  # Reached when the browser session holds no sign-in token: signed out, session
  # expired, or the console was opened directly. Fails closed like every other
  # rejection above.
  def on_mount(:default, _params, _session, socket),
    do: {:halt, redirect(socket, to: "/governance/sign-in")}
end
