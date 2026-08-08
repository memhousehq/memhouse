# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionKey do
  @moduledoc """
  Owns the private, versioned identities of context projections.

  Persisted projections are derived caches, but a deployment may read them before a rebuild.
  The namespace therefore changes whenever stored content gains a stricter audience rule. Old
  rows remain harmless and rebuildable because context assembly no longer addresses their keys.
  """

  # A clean row written before bounded summaries can contain an entire knowledge dump. Changing
  # this namespace makes that row a cache miss until the pipeline rebuilds it under this contract.
  @namespace "summary-v3"

  @doc "Returns the cache identity for one scope card."
  @spec scope(Ecto.UUID.t()) :: String.t()
  def scope(scope_id), do: "#{@namespace}:scope:#{scope_id}"

  @doc "Returns the cache identity for one subject's peer-profile slice in a scope."
  @spec peer(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def peer(scope_id, peer_id), do: "#{@namespace}:peer:#{scope_id}:#{peer_id}"

  @doc "Returns the cache identity for one session summary in a scope."
  @spec session(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def session(scope_id, session_id), do: "#{@namespace}:session:#{scope_id}:#{session_id}"
end
