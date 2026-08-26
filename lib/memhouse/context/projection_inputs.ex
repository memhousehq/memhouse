# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionInputs do
  @moduledoc """
  Owns transactional invalidation for inputs that shape context projections.

  Source resources call this seam from Ash after-action hooks. It advances the scope generation,
  marks durable projections dirty through their pipeline action, and broadcasts cache eviction in
  the same transaction as the source write. No provider work occurs here.
  """

  alias MemHouse.Context.Builder
  alias MemHouse.Knowledge.EntityMention
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory.Visibility
  alias MemHouse.Pipeline.Lock
  alias MemHouse.Topology.Scope

  require Ash.Query

  @account_lock "projection-input-write"

  @doc """
  Serializes Account-wide projection inputs for the current transaction.

  Returns `:ok` after acquiring the shared Account advisory lock. Callers must already be inside
  an Account-scoped transaction. Source actions take this before their durable write; derived
  writers take it before final revalidation so no competing mutation can cross that boundary.
  """
  @spec serialize_account!(Ecto.UUID.t()) :: :ok
  def serialize_account!(account_id), do: Lock.acquire!(account_id, @account_lock)

  @doc """
  Advances one scope's projection-input generation and invalidates its derived projections.

  `actor` must belong to `account_id`; this function elevates only the pipeline flag needed by the
  derived-cache actions. Returns `:ok` and raises when the scope or an Ash write is unavailable.
  Call inside the source mutation's Account-scoped transaction.
  """
  @spec invalidate!(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: :ok
  def invalidate!(account_id, scope_id, actor) do
    pipeline_actor = pipeline_actor(actor)

    scope =
      Scope
      |> Ash.Query.filter(id == ^scope_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: pipeline_actor, authorize?: false)

    if scope do
      scope
      |> Ash.Changeset.for_update(:advance_projection_input_generation, %{})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: pipeline_actor, authorize?: false)

      Builder.mark_dirty(account_id, pipeline_actor, scope_id)
    end

    :ok
  end

  @doc """
  Removes mentions that a lifecycle or scope change made ineligible for entity resolution.

  Returns `:ok`. Mention deletion uses the pipeline Ash action and therefore participates in the
  caller's transaction and projection invalidation. A future expiry remains eligible until the
  shared clock boundary passes.
  """
  @spec remove_ineligible_mentions!(struct(), Ecto.UUID.t() | nil, map()) :: :ok
  def remove_ineligible_mentions!(knowledge, previous_scope_id, actor) do
    account_id = actor.account_id
    now = MemHouse.Clock.utc_now()

    current =
      KnowledgeItem
      |> Ash.Query.filter(id == ^knowledge.id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: pipeline_actor(actor), authorize?: false)

    if is_nil(current) or current.state != "active" or not is_nil(current.deleted_at) or
         not Visibility.boundary_visible?(current.expires_at, now) or
         moved_scopes?(previous_scope_id, current.scope_id) do
      pipeline_actor = pipeline_actor(actor)

      EntityMention
      |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: pipeline_actor)
      |> Enum.each(fn mention ->
        mention
        |> Ash.Changeset.for_destroy(:erase)
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.destroy!(actor: pipeline_actor, authorize?: false)
      end)
    end

    :ok
  end

  defp moved_scopes?(%Ash.NotLoaded{}, _current_scope_id), do: false

  defp moved_scopes?(previous_scope_id, current_scope_id),
    do: previous_scope_id != current_scope_id

  defp pipeline_actor(actor), do: %{actor | role: :system, pipeline?: true}
end

defmodule MemHouse.Context.Changes.InvalidateProjectionInputs do
  @moduledoc """
  Ash after-action change that routes projection-shaping writes through `ProjectionInputs`.

  `scope_attribute` names the resource field containing the scope id. Set `knowledge?: true` for
  governed knowledge so lifecycle-ineligible mentions are removed before invalidation completes.
  """

  use Ash.Resource.Change

  alias MemHouse.Context.ProjectionInputs

  @doc """
  Registers transactional cleanup and invalidation after a successful source action.

  Returns the changeset with the hook attached. The hook returns `{:ok, result}` or raises when
  invalidation fails, rolling back the source action with it.
  """
  @impl true
  def change(changeset, opts, context) do
    changeset
    |> MemHouse.Context.Changes.SerializeProjectionInputs.change([], context)
    |> Ash.Changeset.after_action(fn changeset, result ->
      actor =
        context.actor || changeset.context[:memhouse_actor] ||
          get_in(changeset.context, [:private, :actor])

      attribute = opts[:scope_attribute] || :scope_id
      previous_scope_id = Map.get(changeset.data, attribute)
      current_scope_id = loaded_attribute(result, changeset, attribute)
      account_id = actor.account_id

      if opts[:knowledge?] do
        ProjectionInputs.remove_ineligible_mentions!(result, previous_scope_id, actor)
      end

      [previous_scope_id, current_scope_id]
      |> Enum.reject(&(is_nil(&1) or match?(%Ash.NotLoaded{}, &1)))
      |> Enum.uniq()
      |> Enum.each(&ProjectionInputs.invalidate!(account_id, &1, actor))

      {:ok, result}
    end)
  end

  defp loaded_attribute(result, changeset, attribute) do
    case Map.get(result, attribute) do
      %Ash.NotLoaded{} -> Ash.Changeset.get_attribute(changeset, attribute)
      value -> value
    end
  end
end

defmodule MemHouse.Context.Changes.SerializeProjectionInputs do
  @moduledoc """
  Ash change that serializes Account-wide projection-shaping mutations before their durable write.

  Entity rows span scopes, while lifecycle and observation inputs can invalidate scope-derived
  output. Sharing one Account lock with EntityResolver closes the interval between its final
  revalidation and commit without introducing source-row/scope-row lock inversion.
  """

  use Ash.Resource.Change

  alias MemHouse.Context.ProjectionInputs

  @doc """
  Registers the transaction-scoped Account lock before a resource action runs.

  Returns the changeset with the hook attached. The action raises if no authenticated Account
  actor is available or the advisory lock cannot be acquired.
  """
  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      actor =
        context.actor || changeset.context[:memhouse_actor] ||
          get_in(changeset.context, [:private, :actor])

      :ok = ProjectionInputs.serialize_account!(actor.account_id)
      changeset
    end)
  end
end
