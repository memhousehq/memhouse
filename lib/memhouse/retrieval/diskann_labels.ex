# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.DiskannLabels do
  @moduledoc """
  Allocates internal DiskANN labels for scope-filtered vector search.

  A label is dense only within one Account. The same signed-smallint value can
  occur in another Account because every retrieval query still filters Account
  and authorized scope ids in SQL. Labels are index data: they are never
  returned, audited, exported, or included in job arguments.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Repo
  alias MemHouse.Topology.Scope

  require Ash.Query

  @first_label -32_768
  @last_label 32_767

  @doc """
  Returns the internal label for one scope, allocating the lowest free value.

  Allocation is serialized per Account. A released scope clears its label, so
  its value is eligible for reuse. There are exactly 65,536 usable values; an
  Account that reaches that limit fails closed rather than sharing a label.
  """
  def ensure_scope!(account_id, scope_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      lock_account!(account_id)

      scope =
        Scope
        |> Ash.Query.filter(id == ^scope_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)

      case scope.diskann_label do
        label when is_integer(label) -> label
        nil -> assign_label!(scope, account_id, actor)
      end
    end)
  end

  @doc """
  Returns labels for already-authorized scope ids.

  Missing labels are an invariant failure: a row without one must be rebuilt
  before it can enter a label-filtered DiskANN index.
  """
  def for_scope_ids!(account_id, scope_ids) when is_list(scope_ids) do
    # A caller can inherit access to an ancestor that has no vectors yet. Give
    # every authorized scope a label before forming the overlap filter, rather
    # than treating that harmless cache miss as a retrieval failure.
    Enum.map(scope_ids, &ensure_scope!(account_id, &1))
  end

  @doc """
  Releases a scope label before a future scope deletion.

  Scope deletion is not an application action today. Keeping release explicit
  makes that future erase path clear: clear vectors or delete the scope first,
  then this function makes the label reusable inside the same Account.
  """
  def release_scope!(account_id, scope_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      lock_account!(account_id)

      scope =
        Scope
        |> Ash.Query.filter(id == ^scope_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)

      scope
      |> Ash.Changeset.for_update(:assign_diskann_label, %{diskann_label: nil})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

      :ok
    end)
  end

  defp assign_label!(scope, account_id, actor) do
    label = next_free_label!(account_id)

    scope
    |> Ash.Changeset.for_update(:assign_diskann_label, %{diskann_label: label})
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.update!(actor: actor)
    |> Map.fetch!(:diskann_label)
  end

  # SQL is static and every value is a UUID or a fixed label bound passed as a parameter.
  # sobelow_skip ["SQL.Query"]
  defp next_free_label!(account_id) do
    sql = """
    SELECT candidate::smallint
    FROM generate_series($2::integer, $3::integer) AS candidate
    WHERE NOT EXISTS (
      SELECT 1
      FROM scopes
      WHERE account_id = $1 AND diskann_label = candidate::smallint
    )
    LIMIT 1
    """

    case Ecto.Adapters.SQL.query!(Repo, sql, [
           Ecto.UUID.dump!(account_id),
           @first_label,
           @last_label
         ]) do
      %{rows: [[label]]} -> label
      %{rows: []} -> raise "DiskANN label capacity exhausted for Account"
    end
  end

  defp lock_account!(account_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 187))",
      [account_id]
    )
  end
end
