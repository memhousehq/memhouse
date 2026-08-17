# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Memory.Visibility do
  @moduledoc """
  Owns the lifecycle and audience visibility boundary for memory reads.

  Query builders and post-load checks share these rules so retrieval, lineage,
  and exact-id reads cannot drift into different interpretations of active,
  provisional, public, or peer-scoped knowledge. `internal_reader?` is reserved
  for server-side Account-scoped work; it bypasses audience filtering but not
  lifecycle filtering or the tenant and Ash authorization boundaries.
  """

  alias MemHouse.Knowledge.KnowledgeItem

  require Ash.Query

  @visible_states ~w(active provisional)

  @doc """
  Loads undeleted readable knowledge in the supplied scopes and active view.

  The Ash tenant and actor remain mandatory even for an internal reader.
  """
  def readable_knowledge(account_id, actor, scope_ids, internal_reader?) do
    scope_ids
    |> knowledge_query("active", actor, internal_reader?)
    |> Ash.Query.filter(is_nil(deleted_at))
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  @doc """
  Builds the lifecycle and audience-filtered knowledge query for a state.

  The caller must still set the Account tenant and execute the query with the
  same actor. The public `"active"` view includes only a peer's own provisional
  items; an internal reader may inspect all provisional items in that view.
  """
  def knowledge_query(scope_ids, "active", _actor, true) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state in ["active", "provisional"])
  end

  def knowledge_query(scope_ids, state, _actor, true) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state)
  end

  def knowledge_query(scope_ids, "active", %{peer_id: peer_id}, false)
      when is_binary(peer_id) do
    KnowledgeItem
    |> Ash.Query.filter(
      scope_id in ^scope_ids and
        (state == "active" or (state == "provisional" and subject_peer_id == ^peer_id))
    )
    |> readable_by_peer(peer_id)
  end

  def knowledge_query(scope_ids, state, %{peer_id: peer_id}, false)
      when is_binary(peer_id) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state)
    |> readable_by_peer(peer_id)
  end

  def knowledge_query(scope_ids, "active", _actor, false) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == "active" and sensitivity == "public")
  end

  def knowledge_query(scope_ids, state, _actor, false) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state and sensitivity == "public")
  end

  @doc "Returns whether one loaded item is visible to the actor under the selected reader mode."
  def visible?(item, actor, internal_reader?),
    do: visibility_status(item, actor, internal_reader?) == :visible

  @doc """
  Classifies one loaded item as visible, lifecycle-hidden, or authorization-hidden.

  The classification is content-free so lineage and diagnostics can report why
  traversal stopped without exposing the hidden statement.
  """
  def visibility_status(%{state: state}, _actor, true) when state in @visible_states,
    do: :visible

  def visibility_status(_item, _actor, true), do: :lifecycle_hidden

  def visibility_status(%{state: state}, %{peer_id: nil}, false) when state != "active",
    do: :lifecycle_hidden

  def visibility_status(%{sensitivity: "public"}, %{peer_id: nil}, false), do: :visible
  def visibility_status(_item, %{peer_id: nil}, false), do: :authorization_hidden

  def visibility_status(item, %{peer_id: peer_id}, false) when is_binary(peer_id) do
    lifecycle_visible? =
      item.state == "active" or
        (item.state == "provisional" and item.subject_peer_id == peer_id)

    content_visible? =
      item.sensitivity in ["public", "internal"] or is_nil(item.subject_peer_id) or
        item.subject_peer_id == peer_id or item.target_level in ["scope", "account"]

    cond do
      not lifecycle_visible? -> :lifecycle_hidden
      content_visible? -> :visible
      true -> :authorization_hidden
    end
  end

  def visibility_status(_item, _actor, _internal_reader?), do: :authorization_hidden

  defp readable_by_peer(query, peer_id) do
    Ash.Query.filter(
      query,
      sensitivity in ["public", "internal"] or is_nil(subject_peer_id) or
        subject_peer_id == ^peer_id or target_level in ["scope", "account"]
    )
  end
end
