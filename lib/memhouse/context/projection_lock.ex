# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionLock do
  @moduledoc """
  Serializes one scope's projection commit and lifecycle invalidation boundary.

  Projection refresh performs model work outside transactions, then revalidates and commits in a
  short transaction. Lifecycle changes take the same lock before marking projections dirty, so
  either the refreshed snapshot commits first and is then invalidated, or the lifecycle change
  commits first and the refresh rejects its stale snapshot.
  """

  alias MemHouse.Pipeline.Lock

  @doc """
  Acquires the Account/scope projection lock for the current transaction.

  Call only inside a transaction. Blocks until the lock is available and returns `:ok`; raises
  when PostgreSQL cannot acquire the transaction-scoped advisory lock.
  """
  @spec acquire!(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def acquire!(account_id, scope_id) do
    Lock.acquire!(account_id, "projection-write:#{scope_id}")
  end
end
