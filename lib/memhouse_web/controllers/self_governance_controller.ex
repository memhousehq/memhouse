# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.SelfGovernanceController do
  @moduledoc """
  Implements a person's rights over knowledge about them.

  The password-backed caller may read, dispute, redact, or erase only their own subject knowledge;
  peer identity always comes from the credential. These actions never approve or edit knowledge.
  Responses use resource-public attributes, and erasure returns only request id, mode, and state.
  """

  use MemHouseWeb, :controller

  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.Erasure

  @doc """
  Lists the knowledge whose subject is the calling peer.

  Takes no subject parameter. Returns newest non-deleted rows through public attributes.

  This is the person's view of their own record, including items that are still
  provisional or held and therefore invisible to ordinary retrieval. Seeing an item here
  does not mean anyone else can see it.
  """
  def index(conn, _params) do
    knowledge =
      conn.assigns.current_actor
      |> Engine.self_view()
      |> Enum.map(&public_map/1)

    json(conn, %{data: knowledge})
  end

  @doc """
  Disputes one item of knowledge about the calling peer.

  Moves the item to contested, audits it, and queues human review with a 24-hour deadline.

  Returns the public updated row. Missing and other-subject ids are indistinguishable.

  Contesting states an objection. It does not delete or rewrite the claim, and only a
  human curator can resolve it.
  """
  def contest(conn, %{"id" => id}) do
    knowledge = Engine.contest(conn.assigns.current_actor, id, "contest")
    json(conn, %{data: public_map(knowledge)})
  end

  @doc """
  Withdraws one item of knowledge about the calling peer from use.

  Moves the item to subject-redacted and audits it without curator review.

  Returns `%{"data" => item}`. Raises not-found for an unknown id or for knowledge about
  another peer, with no distinction between the two.

  Redaction is not erasure. The row survives in a redacted state so history and audit stay
  intact; use `erase/2` when the subject wants the content itself gone.
  """
  def redact(conn, %{"id" => id}) do
    knowledge = Engine.contest(conn.assigns.current_actor, id, "redact")
    json(conn, %{data: public_map(knowledge)})
  end

  @doc """
  Erases the calling peer's data, running the erasure immediately.

  Body: `mode` is `"proportionate"` (the default) or `"strict"`. Any other value raises.

  Proportionate mode removes subject content and scrubs shared provenance. Strict also removes
  peer-exclusive sourced knowledge. Independent provenance survives.

  Derived caches are rebuilt or dirtied; content-safe audit evidence survives.

  The response carries only the erasure request's id, mode, and state. The target peer is
  the authenticated caller: it is read from the credential and cannot be supplied by the
  request, so this route can never erase somebody else.
  """
  def erase(conn, params) do
    mode = Map.get(params, "mode", "proportionate")

    request =
      Erasure.request(conn.assigns.current_actor, conn.assigns.current_actor.peer_id, mode)

    json(conn, %{data: %{id: request.id, mode: request.mode, state: request.state}})
  end

  # Resource-public attributes are the response allowlist; never serialize the struct directly.
  defp public_map(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attribute -> {attribute.name, Map.get(record, attribute.name)} end)
  end
end
