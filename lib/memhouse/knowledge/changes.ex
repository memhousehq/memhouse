# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge.Changes.NormalizeStatement do
  @moduledoc """
  Ash change that puts statement text into its canonical form before it is hashed.

  Invisible padding and irregular whitespace are not part of a claim, but they do change the
  hash. Left alone they split one statement into several rows that never corroborate each other.
  Ordering matters: this must run before `MemHouse.Knowledge.Changes.HashStatement`.
  """

  use Ash.Resource.Change

  alias MemHouse.Knowledge.Statement

  @doc """
  Replaces `statement` with its normalized text.

  Returns the changeset unchanged when no binary statement is present. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :statement) do
      statement when is_binary(statement) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :statement,
          Statement.normalize(statement)
        )

      _other ->
        changeset
    end
  end
end

defmodule MemHouse.Knowledge.Changes.HashStatement do
  @moduledoc """
  Ash change that stores a statement's SHA-256 hash.

  The hash is derived from statement text during creation; callers cannot supply a conflicting
  value.
  """

  use Ash.Resource.Change

  alias MemHouse.Pipeline.Idempotency

  @doc """
  Sets `statement_hash` to the lowercase hex SHA-256 of the changeset's `statement`.

  Returns the changeset unchanged when no binary statement is present. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :statement) do
      statement when is_binary(statement) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :statement_hash,
          Idempotency.content_hash(statement)
        )

      _other ->
        changeset
    end
  end
end
