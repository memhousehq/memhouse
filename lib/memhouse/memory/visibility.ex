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

  alias MemHouse.Clock
  alias MemHouse.Knowledge.{KnowledgeItem, Lifecycle}

  require Ash.Query

  @doc """
  Applies the fail-closed read boundary for a derived projection.

  The validity marker must match the content generation, the projection must be clean, and its
  earliest source expiry must still be later than the caller's captured decision time. Lifecycle
  reconciliation deliberately queries projections without this filter so it can repair hidden
  generations.
  """
  def projection_query(query, now) do
    Ash.Query.filter(
      query,
      dirty == false and validity_version == version and
        (is_nil(valid_until) or valid_until > ^now)
    )
  end

  @doc """
  Loads undeleted, unexpired readable knowledge in the supplied scopes and active view.

  The Ash tenant and actor remain mandatory even for an internal reader.
  """
  def readable_knowledge(account_id, actor, scope_ids, internal_reader?) do
    now = Clock.utc_now()

    scope_ids
    |> knowledge_query("active", actor, internal_reader?, now)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  @doc """
  Builds the lifecycle and audience-filtered knowledge query for a state.

  The caller must still set the Account tenant and execute the query with the
  same actor. The public `"active"` view includes only a peer's own provisional
  items and excludes rows whose expiry has passed; an internal reader may
  inspect all unexpired provisional items in that view. An explicitly requested
  non-active state remains an exact historical-state query.
  """
  def knowledge_query(scope_ids, state, actor, internal_reader?) do
    knowledge_query(scope_ids, state, actor, internal_reader?, Clock.utc_now())
  end

  @doc """
  Builds a lifecycle and audience-filtered knowledge query at a captured decision time.

  `now` must be captured once by the caller and reused for every query and
  loaded-item visibility check in the same projection. The caller must set the
  Account tenant and execute the returned `Ash.Query` with the same actor.
  Authorization failures are reported by Ash when that query is executed.
  """
  def knowledge_query(scope_ids, "active", _actor, true, now) do
    states = Lifecycle.retrievable_states()

    KnowledgeItem
    |> Ash.Query.filter(
      scope_id in ^scope_ids and state in ^states and
        is_nil(deleted_at) and (is_nil(expires_at) or expires_at > ^now)
    )
  end

  def knowledge_query(scope_ids, state, _actor, true, _now) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state and is_nil(deleted_at))
  end

  def knowledge_query(scope_ids, "active", %{peer_id: peer_id}, false, now)
      when is_binary(peer_id) do
    shared_states = Lifecycle.shared_projection_states()
    subject_states = Lifecycle.retrievable_states() -- shared_states

    KnowledgeItem
    |> Ash.Query.filter(
      scope_id in ^scope_ids and
        (state in ^shared_states or (state in ^subject_states and subject_peer_id == ^peer_id)) and
        is_nil(deleted_at) and (is_nil(expires_at) or expires_at > ^now)
    )
    |> readable_by_peer(peer_id)
  end

  def knowledge_query(scope_ids, state, %{peer_id: peer_id}, false, _now)
      when is_binary(peer_id) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state and is_nil(deleted_at))
    |> readable_by_peer(peer_id)
  end

  def knowledge_query(scope_ids, "active", _actor, false, now) do
    states = Lifecycle.shared_projection_states()

    KnowledgeItem
    |> Ash.Query.filter(
      scope_id in ^scope_ids and state in ^states and sensitivity == "public" and
        is_nil(deleted_at) and (is_nil(expires_at) or expires_at > ^now)
    )
  end

  def knowledge_query(scope_ids, state, _actor, false, _now) do
    KnowledgeItem
    |> Ash.Query.filter(
      scope_id in ^scope_ids and state == ^state and sensitivity == "public" and
        is_nil(deleted_at)
    )
  end

  @doc "Returns whether one loaded item is visible to the actor under the selected reader mode."
  def visible?(item, actor, internal_reader?),
    do: visibility_status(item, actor, internal_reader?) == :visible

  @doc """
  Returns whether one loaded item is visible at a captured decision time.

  `now` must be shared across every check in the same projection. The result is
  a boolean; hidden lifecycle and authorization reasons are intentionally
  collapsed. Use `visibility_status/4` when the content-free reason is needed.
  """
  def visible?(item, actor, internal_reader?, now),
    do: visibility_status(item, actor, internal_reader?, now) == :visible

  @doc """
  Classifies one loaded item as visible, lifecycle-hidden, or authorization-hidden.

  The classification is content-free so lineage and diagnostics can report why
  traversal stopped without exposing the hidden statement. An item whose expiry
  is not later than the captured decision time is lifecycle-hidden.
  """
  def visibility_status(item, actor, internal_reader?),
    do: visibility_status(item, actor, internal_reader?, Clock.utc_now())

  @doc """
  Classifies one loaded item at a captured decision time.

  `now` must be shared across every check in the same projection. Returns
  `:visible`, `:lifecycle_hidden`, or `:authorization_hidden` without returning
  hidden content. The function performs no data access and raises no
  authorization errors.
  """
  def visibility_status(item, actor, internal_reader?, now) do
    if expired?(item, now) do
      :lifecycle_hidden
    else
      do_visibility_status(item, actor, internal_reader?)
    end
  end

  defp do_visibility_status(item, actor, true) do
    if Lifecycle.retrievable?(item.state, item.subject_peer_id, actor.peer_id, true),
      do: :visible,
      else: :lifecycle_hidden
  end

  defp do_visibility_status(item, %{peer_id: nil}, false) do
    if Lifecycle.retrievable?(item.state, item.subject_peer_id, nil, false) do
      if item.sensitivity == "public", do: :visible, else: :authorization_hidden
    else
      :lifecycle_hidden
    end
  end

  defp do_visibility_status(item, %{peer_id: peer_id}, false) when is_binary(peer_id) do
    lifecycle_visible? =
      Lifecycle.retrievable?(item.state, item.subject_peer_id, peer_id, false)

    content_visible? =
      item.sensitivity in ["public", "internal"] or is_nil(item.subject_peer_id) or
        item.subject_peer_id == peer_id or item.target_level in ["scope", "account"]

    cond do
      not lifecycle_visible? -> :lifecycle_hidden
      content_visible? -> :visible
      true -> :authorization_hidden
    end
  end

  defp do_visibility_status(_item, _actor, _internal_reader?), do: :authorization_hidden

  defp expired?(item, now) do
    case Map.get(item, :expires_at) do
      %DateTime{} = expires_at -> DateTime.compare(expires_at, now) != :gt
      _ -> false
    end
  end

  defp readable_by_peer(query, peer_id) do
    Ash.Query.filter(
      query,
      sensitivity in ["public", "internal"] or is_nil(subject_peer_id) or
        subject_peer_id == ^peer_id or target_level in ["scope", "account"]
    )
  end
end
