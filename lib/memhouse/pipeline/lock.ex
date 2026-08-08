# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Lock do
  @moduledoc """
  Transaction-scoped mutual exclusion for pipeline writes that must not race.

  Idempotency does not prevent distinct runs from racing through a read-then-write. This lock
  serializes the check and write so later callers see the first result.

  Account plus caller key identifies the locked operation; unrelated work does not block.

  The same primitive protects anything with a read-then-write window: appending
  to an Account's audit chain (where two concurrent appends could otherwise read
  the same chain tip and fork it), applying a governance decision to one
  validation item, and versioning one skill card.

  ## Rules for callers

  - Take it inside a transaction. The lock is released when that transaction
    ends, not by an explicit unlock; outside a transaction it is meaningless.
  - Take it *before* the existence check, not between the check and the write.
    Locking after the read reintroduces exactly the race it exists to prevent.
  - Keep the work under it short. It is held for the rest of the transaction.

  This module writes nothing. It uses parameterized SQL because Ash has no transaction-scoped
  advisory-lock equivalent; durable state still uses resource actions.
  """

  alias MemHouse.Repo

  @doc """
  Takes the Account/key advisory lock for the rest of the current transaction.

  `key` names the thing being serialised — a scope, subject and statement digest
  for a knowledge merge, a fixed name for the Account's audit chain, an item id
  for a governance decision. Any string works, but callers that want mutual
  exclusion must agree on the same string; two spellings of the same intent are
  two different locks and provide no protection.

  Blocks until the lock is available, then returns `:ok`. Raises if the query
  fails. Note that the name is hashed to a 64-bit integer, so distinct keys can
  in principle collide — a collision costs unnecessary waiting, never
  correctness.
  """
  @spec acquire!(Ecto.UUID.t(), String.t()) :: :ok
  def acquire!(account_id, key) do
    # Account-prefixed so one Account's merges can never block another's, and
    # transaction-scoped (`_xact_`) so the lock is always released on commit or
    # rollback — no unlock path can be forgotten or skipped by an exception.
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["#{account_id}:#{key}"]
    )

    :ok
  end
end
