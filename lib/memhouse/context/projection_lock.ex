# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionLock do
  @moduledoc """
  Serializes one scope's projection input snapshot, commit, and invalidation boundary.

  Projection-shaping Ash actions advance a per-scope generation in their transaction. Readers
  capture it without locking source rows; a later generation check rejects any mixed or stale
  snapshot. Projection writers take the exclusive scope-row lock only after model work, so their
  final version read and commit serialize without reversing the source-write lock order.
  """

  alias MemHouse.Repo

  @doc """
  Reads a scope's projection-input generation without locking source rows.

  Call before reading projection-shaping inputs and compare it again before using the snapshot.
  Returns the non-negative generation and raises when the scope is absent or PostgreSQL cannot
  read it.
  """
  @spec capture!(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def capture!(account_id, scope_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT projection_input_generation
        FROM scopes
        WHERE account_id = $1 AND id = $2
        """,
        dump_ids(account_id, scope_id)
      )

    generation!(result)
  end

  @doc """
  Acquires the exclusive Account/scope projection lock for the current transaction.

  Call only inside a transaction. Blocks until the scope row is available, returns its current
  non-negative projection-input generation, and raises when the scope is absent or PostgreSQL
  cannot acquire the row lock. The lock is released with the transaction.
  """
  @spec acquire!(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def acquire!(account_id, scope_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT projection_input_generation
        FROM scopes
        WHERE account_id = $1 AND id = $2
        FOR UPDATE
        """,
        dump_ids(account_id, scope_id)
      )

    generation!(result)
  end

  defp dump_ids(account_id, scope_id) do
    [Ecto.UUID.dump!(account_id), Ecto.UUID.dump!(scope_id)]
  end

  defp generation!(result) do
    case result do
      %{rows: [[generation]]} -> generation
      %{rows: []} -> raise Ecto.NoResultsError, queryable: MemHouse.Topology.Scope
    end
  end
end
