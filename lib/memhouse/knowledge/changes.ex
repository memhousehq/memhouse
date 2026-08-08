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

defmodule MemHouse.Knowledge.Changes.AnchorEventValidity do
  @moduledoc """
  Ash change that dates an event the caller left undated.

  An event is a claim that something happened at a time, so a row that records one must be
  datable. Extraction often produces the claim without the date: the observation says "last
  weekend", and a model that resolves it into the statement text may still leave
  `relevant_from` empty.

  The `observed_at` argument fills that gap with when the observation was made. That is the
  weaker of the two claims — "no later than this" rather than "on this day" — but it is a real
  bound, and the alternative is an occurrence a reader can only date against their own clock.

  Only events are anchored. A preference or a standing fact has no validity start, and
  inventing one would make `relevant_from` useless as a signal.
  """

  use Ash.Resource.Change

  @doc """
  Sets `relevant_from` from the `observed_at` argument when the changeset is an
  event that has none.

  Returns the changeset untouched for any other kind, for an event that already
  carries a start, and when no `observed_at` was supplied. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    with "event" <- Ash.Changeset.get_attribute(changeset, :kind),
         nil <- Ash.Changeset.get_attribute(changeset, :relevant_from),
         %DateTime{} = observed_at <- Ash.Changeset.get_argument(changeset, :observed_at) do
      Ash.Changeset.force_change_attribute(changeset, :relevant_from, observed_at)
    else
      _other -> changeset
    end
  end
end
