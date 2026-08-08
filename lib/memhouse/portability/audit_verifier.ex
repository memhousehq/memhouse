# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Portability.AuditVerifier do
  @moduledoc """
  Verifies the archive's content-safe audit hash chain.

  It checks ordering, predecessor links, recomputed hashes, and the terminal head. Any missing,
  duplicate, reordered, or altered event rejects the archive before import writes begin.
  """

  alias MemHouse.Governance.Audit

  @doc """
  Verifies a list of archived audit events, in any order.

  Rows are string-keyed maps decoded from the archive. Returns
  `{:ok, %{count: n, last_hash: hash}}` on success — the caller compares those
  against the manifest, which is what catches an archive whose events were
  truncated *and* whose manifest was edited to match.

  An empty log verifies successfully with a nil head; a brand-new Account
  legitimately has no events yet.

  Returns `{:error, reason}` otherwise:
  `{:audit_event_hash_mismatch, id}`, `:audit_chain_root_invalid`,
  `{:audit_chain_branch, id}`, `:audit_chain_cycle`, or
  `:audit_chain_disconnected`. Raises `KeyError` if a row is missing a field the
  hash is computed over, which is itself a malformed archive.
  """
  def verify([]), do: {:ok, %{count: 0, last_hash: nil}}

  def verify(rows) when is_list(rows) do
    # Order matters: content is checked before structure, so a tampered event is
    # reported as tampering rather than as a broken link further along. The
    # final size comparison is what catches rows that verify individually but
    # hang off no reachable part of the chain.
    with :ok <- verify_event_hashes(rows),
         {:ok, root} <- single_root(rows),
         {:ok, last_hash, visited} <- walk_chain(root, rows, %{}),
         true <- map_size(visited) == length(rows) do
      {:ok, %{count: length(rows), last_hash: last_hash}}
    else
      false -> {:error, :audit_chain_disconnected}
      error -> error
    end
  end

  # Recomputes each event's hash from exactly the fields the original append
  # hashed, in the same shape, and stops at the first mismatch. The payload key
  # set is part of the durable hash definition: adding, renaming, or dropping one
  # here would invalidate every archive ever written.
  defp verify_event_hashes(rows) do
    Enum.reduce_while(rows, :ok, fn event, :ok ->
      payload = %{
        account_id: Map.fetch!(event, "account_id"),
        category: Map.fetch!(event, "category"),
        action: Map.fetch!(event, "action"),
        resource_type: Map.fetch!(event, "resource_type"),
        resource_id: Map.get(event, "resource_id"),
        content_hash: Map.get(event, "content_hash"),
        metadata: Map.get(event, "metadata", %{}),
        occurred_at: iso8601(Map.fetch!(event, "occurred_at")),
        previous_hash: Map.get(event, "previous_hash")
      }

      expected = Audit.content_hash(payload)

      if Map.get(event, "event_hash") == expected do
        {:cont, :ok}
      else
        {:halt, {:error, {:audit_event_hash_mismatch, Map.fetch!(event, "id")}}}
      end
    end)
  end

  # The chain has exactly one event with no predecessor. Zero means the start
  # was removed (or every event points at something outside the archive); more
  # than one means unrelated histories were merged into one file.
  defp single_root(rows) do
    case Enum.filter(rows, &is_nil(Map.get(&1, "previous_hash"))) do
      [root] -> {:ok, root}
      _other -> {:error, :audit_chain_root_invalid}
    end
  end

  # Follows the chain forward one link at a time, from the root to the head,
  # recording every event it reaches. The visited set both detects a cycle —
  # impossible in an honest chain, possible in a forged one — and lets the
  # caller prove that no row was left unreachable. Two successors mean the chain
  # forks, which makes the real order ambiguous, so it is rejected rather than
  # guessed at.
  defp walk_chain(event, rows, visited) do
    event_hash = Map.fetch!(event, "event_hash")

    if Map.has_key?(visited, event_hash) do
      {:error, :audit_chain_cycle}
    else
      visited = Map.put(visited, event_hash, true)

      case Enum.filter(rows, &(Map.get(&1, "previous_hash") == event_hash)) do
        [] -> {:ok, event_hash, visited}
        [next] -> walk_chain(next, rows, visited)
        _branches -> {:error, {:audit_chain_branch, Map.fetch!(event, "id")}}
      end
    end
  end

  # Timestamps must be hashed in the exact textual form the original append
  # used, so a value that survived a JSON round trip as a string is passed
  # through untouched rather than being parsed and re-rendered.
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
end
