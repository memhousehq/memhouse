# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.Scopes do
  @moduledoc """
  Read-only `/console/scopes` directory of authorized scopes, relations, and
  role grants.

  Context inherits downward, nearest overrides win, and any applicable deny
  removes access. Missing scopes remain indistinguishable from nonexistent
  ones; authorized children retain path depth even when parents are hidden.
  Relations never grant access and require authorization at both ends.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouseWeb.Console.Loader

  @doc """
  Loads the tree, the lateral relations, and the recent role grants.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :directory, Loader.scope_directory(socket.assigns.current_actor))}
  end

  @doc """
  Renders the directory, the relations, and the grants that produced the
  reader's access.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:scopes} title="Scopes" flash={@flash}>
      <:subtitle>
        The containment tree. Context flows down it, the nearest scope wins where two
        disagree, and any applicable deny removes a scope outright.
      </:subtitle>

      <.panel
        title="Directory"
        description="Counts are of what is attached directly to each scope, not to its descendants. A scope you cannot read is absent rather than shown empty. Indexed and Mentions are derived caches rebuilt in the background: fewer indexed than statements means semantic and entity recall are degraded for that scope until its refresh runs again."
      >
        <.empty
          :if={@directory.rows == []}
          message="No scope is reachable with your current grants."
        />

        <table :if={@directory.rows != []} class="grid tree">
          <thead>
            <tr>
              <th>Scope</th>
              <th>Your role</th>
              <th>State</th>
              <th>Statements</th>
              <th>Indexed</th>
              <th>Mentions</th>
              <th>Documents</th>
              <th>Sessions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @directory.rows}>
              <td>
                <span class={"indent-#{min(row.depth, 6)}"}>
                  <span class="tree-glyph" aria-hidden="true">{tree_glyph(row.depth)}</span>
                  <.link navigate={~p"/console/knowledge?#{[scope: row.scope.path]}"}>
                    {row.scope.path}
                  </.link>
                </span>
                <span :if={row.scope.name != row.scope.key} class="muted">{row.scope.name}</span>
              </td>
              <td>
                <.badge :if={row.role} family="kind" value={row.role} />
                <span :if={is_nil(row.role)} class="muted">inherited</span>
              </td>
              <td><.badge family="state" value={row.scope.state} /></td>
              <td class="nowrap">{row.knowledge_count}</td>
              <td class={["nowrap", index_gap?(row.coverage) && "coverage-gap"]}>
                {row.coverage.embedded_count}
                <span class="muted">{embedding_identity(row.coverage)}</span>
              </td>
              <td class="nowrap">{row.coverage.mention_count}</td>
              <td class="nowrap">{row.document_count}</td>
              <td class="nowrap">{row.session_count}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Relations"
        description="Lateral links between scopes that are not in a parent-child line. A relation can widen what retrieval considers; it never widens what you may see."
      >
        <.empty :if={@directory.relations == []} message="No scope relations are defined." />
        <table :if={@directory.relations != []} class="grid">
          <thead>
            <tr>
              <th>From</th>
              <th>To</th>
              <th>Kind</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={relation <- @directory.relations}>
              <td>{scope_path(@directory.scope_paths, relation.source_scope_id)}</td>
              <td>{scope_path(@directory.scope_paths, relation.target_scope_id)}</td>
              <td><.badge family="kind" value={relation.kind} /></td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        title="Role grants"
        description="One peer's role at one scope. A propagating grant reaches every scope contained in it; a deny removes access wherever it applies, whatever else was granted."
      >
        <.empty :if={@directory.grants == []} message="No role grants are visible to you." />
        <table :if={@directory.grants != []} class="grid">
          <thead>
            <tr>
              <th>Scope</th>
              <th>Peer</th>
              <th>Role</th>
              <th>Effect</th>
              <th>Propagates</th>
              <th>Granted</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={grant <- @directory.grants}>
              <td>{scope_path(@directory.scope_paths, grant.scope_id)}</td>
              <td><.id_chip value={grant.peer_id} /></td>
              <td><.badge family="kind" value={grant.role} /></td>
              <td><.badge family="decision" value={grant.effect} /></td>
              <td>{if grant.propagate, do: "yes", else: "no"}</td>
              <td class="nowrap muted">{timestamp(grant.granted_at)}</td>
            </tr>
          </tbody>
        </table>
      </.panel>
    </.shell>
    """
  end

  # Distinguish the root when narrow layouts compress indentation.
  defp tree_glyph(0), do: "●"
  defp tree_glyph(_depth), do: "└"

  # Any shortfall is worth colouring: a partially indexed scope answers some
  # questions and silently misses others, which is harder to notice than none.
  defp index_gap?(coverage), do: coverage.coverage < 1.0

  # Two identities in one scope mean an embedder change left part of it in the
  # old space, where it cannot be compared and needs re-embedding.
  defp embedding_identity(%{embedding_identities: []}), do: ""

  defp embedding_identity(%{embedding_identities: [identity]}) do
    "#{identity.model}@#{identity.version} (#{identity.dimensions}d)"
  end

  defp embedding_identity(%{embedding_identities: identities}) do
    "#{length(identities)} embedding identities — re-embed needed"
  end
end
