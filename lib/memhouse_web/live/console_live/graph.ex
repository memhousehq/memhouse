# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.Graph do
  @moduledoc """
  Read-only `/console/graph` explorer for one scope at a time.

  The view is focused rather than global: one scope, its statements, the entity
  clusters linking them, and the readable scopes below it as drill-down targets.
  The focus and the descendants option live in the URL, so a view is linkable and
  survives reload.

  Entity caches, canonical names, aliases, and ids must never appear. A hub shows
  a name only when the loader supplies one from that cluster's entity card, drawn
  from the card's own sources in its own scope; otherwise the identity is an
  ordinal assigned per render. Geometry is deterministic server-side SVG: no
  inline scripts, randomness, or wall clock.

  The page reports when statement or cluster limits truncate the graph.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouseWeb.Console.Graph
  alias MemHouseWeb.Console.Loader

  @doc """
  Mounts with no selected node; `handle_params/3` loads the focused graph.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :selected, nil)}
  end

  @doc """
  Loads and lays out the focused scope, or the shallowest readable scope when
  the URL names none.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    descendants? = params["descendants"] == "1"

    data =
      Loader.graph(socket.assigns.current_actor,
        scope: blank_to_nil(params["scope"]),
        descendants?: descendants?
      )

    {:noreply,
     socket
     |> assign(:descendants?, descendants?)
     |> assign(:data, data)
     # Phoenix reserves the `:layout` assign.
     |> assign(:diagram, Graph.build(data))
     |> assign(:selected, nil)}
  end

  @doc """
  Moves the focus, toggles the descendants option, and selects nodes.

  The focus and the option go through the URL so the view stays linkable. A
  focus the actor may not read is not rejected here: the loader falls back to a
  readable scope, which keeps a stale or hand-edited link usable without
  disclosing whether the requested path exists.

  Selection resolves ids against the authorized loaded set only; an unknown
  client-supplied id selects nothing and is never queried directly.
  """
  @impl true
  def handle_event("focus", %{"scope" => path}, socket) do
    {:noreply, push_patch(socket, to: view_path(path, socket.assigns.descendants?))}
  end

  def handle_event("view", params, socket) do
    path = blank_to_nil(params["scope"]) || current_path(socket)
    {:noreply, push_patch(socket, to: view_path(path, params["descendants"] == "true"))}
  end

  def handle_event("select", %{"id" => id, "kind" => "scope"}, socket) do
    scope = Enum.find(socket.assigns.data.scopes, &(&1.id == id))
    {:noreply, assign(socket, :selected, scope && {:scope, scope})}
  end

  def handle_event("select", %{"id" => id, "kind" => "knowledge"}, socket) do
    item = Enum.find(socket.assigns.data.knowledge, &(&1.id == id))
    {:noreply, assign(socket, :selected, item && {:knowledge, item})}
  end

  def handle_event("select", %{"id" => id, "kind" => "cluster"}, socket) do
    cluster = Enum.find(socket.assigns.data.clusters, &(&1.id == id))
    {:noreply, assign(socket, :selected, cluster && {:cluster, cluster})}
  end

  def handle_event("deselect", _params, socket), do: {:noreply, assign(socket, :selected, nil)}

  @doc """
  Renders the breadcrumb, the drill-down controls, the SVG, the legend, and the
  selection panel.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:graph} title="Graph" flash={@flash}>
      <:subtitle>
        One scope at a time. Statements orbit the scope they live in, and a shared-entity hub
        joins the statements that resolved to the same thing.
      </:subtitle>

      <.panel title="Where you are" description="Move up to a parent or down into a child scope.">
        <nav :if={@data.focus} class="crumbs" aria-label="Scope breadcrumb">
          <button
            :for={ancestor <- @data.ancestors}
            type="button"
            class="crumb"
            phx-click="focus"
            phx-value-scope={ancestor.path}
          >
            {ancestor.path}
          </button>
          <span class="crumb current" aria-current="page">{@data.focus.path}</span>
        </nav>

        <p :if={is_nil(@data.focus)} class="hint">
          You hold no grant on any scope, so there is nothing to explore yet.
        </p>

        <div :if={@data.focus} class="graph-controls">
          <button
            :if={@data.parent}
            type="button"
            class="ghost"
            phx-click="focus"
            phx-value-scope={@data.parent.path}
          >
            Up to {@data.parent.path}
          </button>
          <span :if={is_nil(@data.parent)} class="hint">This is the highest scope you can read.</span>

          <form id="graph-view" phx-change="view" class="filters">
            <label class="grow">
              Scope
              <select name="scope">
                <option
                  :for={scope <- @data.all_scopes}
                  value={scope.path}
                  selected={@data.focus.path == scope.path}
                >
                  {scope.path}
                </option>
              </select>
            </label>
            <label class="check">
              <input type="hidden" name="descendants" value="false" />
              <input type="checkbox" name="descendants" value="true" checked={@descendants?} />
              Include descendant scopes
            </label>
          </form>
        </div>

        <div :if={@data.children != []} class="graph-children">
          <span class="hint">Inside this scope:</span>
          <button
            :for={child <- @data.children}
            type="button"
            class="chip-button"
            phx-click="focus"
            phx-value-scope={child.path}
          >
            {child.path}
          </button>
        </div>

        <p :if={@data.focus && @data.children == []} class="hint">
          No scope below this one is readable with your current grants.
        </p>

        <p :if={@data.truncated?} class="hint">
          Showing {@data.shown} of {@data.total} statements, most confident first.
        </p>

        <p :if={@data.clusters_truncated?} class="hint">
          More shared-entity groups link these statements than are drawn.
        </p>

        <p :if={@data.focus} class="hint">
          <.link navigate={~p"/console/knowledge?#{knowledge_query(@data)}"}>
            Open this scope in the explorer
          </.link>
          for the complete list, filters, and paging.
        </p>
      </.panel>

      <div class="graph-layout">
        <div class="graph-frame">
          <.empty
            :if={@diagram.nodes == []}
            message="Nothing to draw: no scope is reachable with your current grants."
          />

          <svg
            :if={@diagram.nodes != []}
            class="graph"
            viewBox={"0 0 #{@diagram.width} #{@diagram.height}"}
            role="group"
            aria-label={"Graph of #{@data.focus.path}"}
          >
            <%!--
              Edges are drawn before nodes so that nodes sit on top of the lines
              rather than being crossed by them. SVG has no z-index; document
              order is the stacking order.
            --%>
            <line
              :for={edge <- @diagram.edges}
              class={"edge edge-#{edge.kind}"}
              x1={edge.x1}
              y1={edge.y1}
              x2={edge.x2}
              y2={edge.y2}
            />

            <%!--
              Every node is focusable and answers Enter, so the picture is
              reachable without a pointer. Breadcrumb, parent, and child
              controls are ordinary buttons, so navigation itself never depends
              on reaching a node.
            --%>
            <g
              :for={node <- @diagram.nodes}
              class={["node", "node-#{node.kind}", node.class]}
              role="button"
              tabindex="0"
              aria-label={node.title}
              phx-click="select"
              phx-keydown="select"
              phx-key="Enter"
              phx-value-id={node.id}
              phx-value-kind={node.kind}
            >
              <circle cx={node.x} cy={node.y} r={node.r} />
              <title>{node.title}</title>
              <text :if={node.label} x={node.x} y={node.y + node.r + 14} text-anchor="middle">
                {node.label}
              </text>
            </g>
          </svg>
        </div>

        <aside class="graph-panel">
          <div :if={is_nil(@selected)} class="graph-hint">
            <h3>Legend</h3>
            <ul class="legend">
              <li><span class="swatch node-scope focus"></span> The scope you are in</li>
              <li><span class="swatch node-scope"></span> A scope you can drill into</li>
              <li>
                <span class="swatch node-knowledge"></span>
                Statement — size is confidence, colour is lifecycle state
              </li>
              <li>
                <span class="swatch node-cluster"></span>
                Shared entity — statements that resolved to the same thing. Named after a form
                used in this scope when one referent explains the whole group
              </li>
              <li><span class="swatch edge-containment"></span> Containment</li>
              <li><span class="swatch edge-membership"></span> Statement lives in scope</li>
              <li><span class="swatch edge-cluster_link"></span> Statement shares that entity</li>
              <li>
                <span class="swatch edge-co_mention"></span>
                Named together — both were mentioned in one statement. Not a stated relation
              </li>
              <li><span class="swatch edge-scope_relation"></span> Scope relation</li>
              <li><span class="swatch edge-knowledge_relation"></span> Statement relation</li>
            </ul>
            <p class="hint">Select a node to see what it is.</p>
          </div>

          <div :if={match?({:scope, _scope}, @selected)} class="graph-selection">
            <h3>Scope</h3>
            <p class="statement">{elem(@selected, 1).path}</p>
            <dl class="pairs">
              <dt>Name</dt>
              <dd>{elem(@selected, 1).name}</dd>
              <dt>State</dt>
              <dd><.badge family="state" value={elem(@selected, 1).state} /></dd>
            </dl>
            <p>
              <button
                :if={@data.focus.id != elem(@selected, 1).id}
                type="button"
                class="ghost"
                phx-click="focus"
                phx-value-scope={elem(@selected, 1).path}
              >
                Focus this scope
              </button>
            </p>
            <p>
              <.link navigate={~p"/console/knowledge?#{[scope: elem(@selected, 1).path]}"}>
                Browse its statements
              </.link>
            </p>
            <button type="button" class="ghost" phx-click="deselect">Clear selection</button>
          </div>

          <div :if={match?({:knowledge, _item}, @selected)} class="graph-selection">
            <h3>Statement</h3>
            <p class="statement">{elem(@selected, 1).statement}</p>
            <div class="badge-row">
              <.badge family="state" value={elem(@selected, 1).state} />
              <.badge family="kind" value={elem(@selected, 1).kind} />
              <.badge family="sensitivity" value={elem(@selected, 1).sensitivity} />
            </div>
            <p class="muted">{elem(@selected, 1).scope_path || "(unreadable scope)"}</p>
            <p>
              <.link navigate={~p"/console/knowledge/#{elem(@selected, 1).id}"}>
                Open the full record
              </.link>
            </p>
            <button type="button" class="ghost" phx-click="deselect">Clear selection</button>
          </div>

          <div :if={match?({:cluster, _cluster}, @selected)} class="graph-selection">
            <h3>{elem(@selected, 1).label}</h3>

            <div :if={Map.get(elem(@selected, 1), :entity_kind)} class="badge-row">
              <.badge family="kind" value={elem(@selected, 1).entity_kind} />
              <.badge
                :if={Map.get(elem(@selected, 1), :sensitivity)}
                family="sensitivity"
                value={elem(@selected, 1).sensitivity}
              />
            </div>

            <%!--
              Three reasons a hub stays unnamed, and they are not interchangeable. A card that
              exists but yielded no usable form is a different situation from having no card at
              all, and saying "waiting to be rebuilt" there would be wrong.
            --%>
            <p :if={not elem(@selected, 1).labelled?} class="hint">
              {unlabelled_reason(elem(@selected, 1))}
            </p>

            <%!--
              The summary is written by a model from the statements below it. Governed statements
              and derived prose must not read alike, so this follows the left-border-plus-word
              pattern the write-capable tool cards and the retrieval diagnostic already use.
            --%>
            <div :if={Map.get(elem(@selected, 1), :summary)} class="derived-summary">
              <p class="muted">
                Summary · {summary_mode_label(elem(@selected, 1).summary_mode)}
              </p>
              <p><.expandable text={elem(@selected, 1).summary} length={220} /></p>
            </div>

            <p :if={summary_unavailable?(elem(@selected, 1))} class="hint">
              The brief for these statements could not be written. A later rebuild retries it.
            </p>

            <%!--
              Two lists once a card exists, because a card is built from active statements only
              while the drawn set also holds the viewer's own provisional ones. A cluster can
              therefore carry members its summary never read, and one merged list would imply
              coverage the card does not have. With no card there is nothing to be outside of, so
              the split would be noise.
            --%>
            <ul :if={not carded?(elem(@selected, 1))} class="cluster-members">
              <li :for={item <- cluster_members(@data, elem(@selected, 1))}>
                <.link navigate={~p"/console/knowledge/#{item.id}"}>
                  <.expandable text={item.statement} length={110} />
                </.link>
              </li>
            </ul>

            <div :if={carded?(elem(@selected, 1))}>
              <h4 :if={cluster_summarised(@data, elem(@selected, 1)) != []}>Summarised</h4>
              <ul :if={cluster_summarised(@data, elem(@selected, 1)) != []} class="cluster-members">
                <li :for={item <- cluster_summarised(@data, elem(@selected, 1))}>
                  <.link navigate={~p"/console/knowledge/#{item.id}"}>
                    <.expandable text={item.statement} length={110} />
                  </.link>
                </li>
              </ul>

              <h4 :if={cluster_unsummarised(@data, elem(@selected, 1)) != []}>Not in the summary</h4>
              <ul
                :if={cluster_unsummarised(@data, elem(@selected, 1)) != []}
                class="cluster-members"
              >
                <li :for={item <- cluster_unsummarised(@data, elem(@selected, 1))}>
                  <.link navigate={~p"/console/knowledge/#{item.id}"}>
                    <.expandable text={item.statement} length={110} />
                  </.link>
                </li>
              </ul>
            </div>

            <button type="button" class="ghost" phx-click="deselect">Clear selection</button>
          </div>
        </aside>
      </div>
    </.shell>
    """
  end

  # Cluster membership is resolved against the loaded statements rather than
  # re-queried, so a member the actor may not read cannot appear even if the
  # cluster still lists it.
  defp cluster_members(data, cluster) do
    by_id = Map.new(data.knowledge, &{&1.id, &1})

    cluster.knowledge_ids
    |> Enum.flat_map(&List.wrap(Map.get(by_id, &1)))
    |> Enum.sort_by(& &1.id)
  end

  defp cluster_summarised(data, cluster) do
    covered = MapSet.new(Map.get(cluster, :card_knowledge_ids) || [])
    Enum.filter(cluster_members(data, cluster), &MapSet.member?(covered, &1.id))
  end

  defp cluster_unsummarised(data, cluster) do
    covered = MapSet.new(Map.get(cluster, :card_knowledge_ids) || [])
    Enum.reject(cluster_members(data, cluster), &MapSet.member?(covered, &1.id))
  end

  # A cluster the loader matched to a clean entity card. Distinct from `labelled?`: a card can
  # exist and still yield no usable name.
  defp carded?(cluster), do: Map.has_key?(cluster, :summary_mode)

  defp unlabelled_reason(cluster) do
    if carded?(cluster) do
      "These statements resolved to the same thing. No wording used in this scope reads as a " <>
        "name for it."
    else
      "These statements resolved to the same thing. It has no name here: either more than one " <>
        "referent shares this exact set of statements, or its card is waiting to be rebuilt."
    end
  end

  defp summary_mode_label("model"), do: "written by a model"
  defp summary_mode_label("source_extract"), do: "extracted from the sources"
  defp summary_mode_label(_mode), do: "derived"

  # A card whose summary call failed carries no summary text, so it never reaches
  # `summary_mode_label/1`. Say so, because the alternative reading — too few statements to earn a
  # brief — is a different and permanent condition.
  defp summary_unavailable?(cluster), do: Map.get(cluster, :summary_mode) == "unavailable"

  defp knowledge_query(%{focus: focus}), do: [scope: focus.path]

  defp current_path(socket) do
    case socket.assigns.data.focus do
      nil -> nil
      focus -> focus.path
    end
  end

  defp view_path(nil, descendants?), do: view_path_query(%{}, descendants?)
  defp view_path(path, descendants?), do: view_path_query(%{"scope" => path}, descendants?)

  defp view_path_query(query, true), do: ~p"/console/graph?#{Map.put(query, "descendants", "1")}"
  defp view_path_query(query, false), do: ~p"/console/graph?#{query}"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
