# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Coverage do
  @moduledoc """
  Reports how much of a scope's retrievable corpus carries derived indexes.

  Statements are durable; embeddings and entity mentions are not. They are
  written only by the projection refresh, so a cancelled or never-enqueued
  refresh leaves a scope holding every statement and answering nothing
  semantically — full-text search keeps working, because `search_vector` is a
  generated column that no queue can lose. Coverage is the read that tells those
  two states apart.

  Counts only. Entity ids, canonical names, aliases, and surface forms stay
  inside retrieval, so the mention figure is a number and never a list.
  """

  alias MemHouse.Retrieval.Store

  @empty %{
    statement_count: 0,
    embedded_count: 0,
    mention_count: 0,
    mentioned_statement_count: 0,
    mention_coverage: 1.0,
    coverage: 1.0,
    embedding_identities: []
  }

  @doc """
  Reads index coverage for several scopes at once.

  `scope_ids` must already be the scopes the caller may read; this function
  filters by them, it does not derive them. `peer_id` is the reader and should
  be the caller's peer id on any peer-facing path. `internal_reader?` counts the
  whole corpus and belongs to the rebuild that has to cover it; a peer-facing
  caller passes false, and with a nil peer that counts public statements only.

  Returns a map keyed by scope id. Every requested scope is present, so a scope
  with no statements reads as zeros rather than as a missing key.
  """
  def scopes(account_id, scope_ids, peer_id, internal_reader?) do
    measured =
      account_id
      |> Store.index_coverage(scope_ids, peer_id, internal_reader?)
      |> Map.new(fn row ->
        statements = row["statement_count"]
        embedded = row["embedded_count"]

        {row["scope_id"],
         %{
           statement_count: statements,
           embedded_count: embedded,
           mention_count: row["mention_count"],
           mentioned_statement_count: row["mentioned_statement_count"],
           mention_coverage: ratio(row["mentioned_statement_count"], statements),
           coverage: ratio(embedded, statements),
           embedding_identities: identities(row["embedding_identities"])
         }}
      end)

    Map.new(scope_ids, &{&1, Map.get(measured, &1, @empty)})
  end

  @doc """
  Reads index coverage for one scope, zero-filled when the scope holds nothing.
  """
  def scope(account_id, scope_id, peer_id, internal_reader?) do
    account_id |> scopes([scope_id], peer_id, internal_reader?) |> Map.fetch!(scope_id)
  end

  # A scope with nothing to index is fully indexed, so an alert on a low ratio
  # fires for a scope that lost its vectors and not for one that never had any.
  defp ratio(_embedded, 0), do: 1.0
  defp ratio(embedded, statements), do: embedded / statements

  # More than one identity in a scope means part of it predates a model change
  # and takes the re-embed path; the list is what makes that visible.
  defp identities(rows) do
    Enum.map(rows, fn row ->
      %{
        provider: row["provider"],
        model: row["model"],
        version: row["version"],
        dimensions: row["dimensions"]
      }
    end)
  end
end
