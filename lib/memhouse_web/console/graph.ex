# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.Graph do
  @moduledoc """
  Turns the console's graph data into positioned nodes and edges for inline SVG.

    The browser pages are served under a Content-Security-Policy that permits scripts
    only from this origin and forbids inline script, and the project has no bundler —
    the whole client build is one small ES module that starts the LiveView socket.
    Pulling in a graph-drawing library would mean adding both a build step and a script
    exception.

    The picture is centred on one focus scope. Positions are relative to that focus,
    so the same scope draws the same way whether it is reached from its parent or
    from a link.
  """

  # The SVG coordinate space. Nothing renders outside it, so every computed
  # position is clamped into it; a node pushed past the edge by a deep tree is
  # pinned to the border rather than silently disappearing.
  @width 1000
  @height 720

  # Radius of the innermost ring, and the gap between successive depth rings,
  # both in SVG units. Together they decide how many depth levels fit below the
  # focus before the outer ring reaches the frame edge: (min(width, height) / 2
  # - margin - base) / step, which is two levels at these values. Deeper levels
  # are clamped onto the frame rather than lost.
  @ring_base 270
  @ring_step 55

  # Orbit geometry for the statements around a scope. Up to @orbit_capacity
  # statements share one orbit; beyond that a further orbit is added
  # @orbit_step further out, so a scope with many statements grows outward
  # instead of overlapping itself.
  @orbit_base 60
  @orbit_step 24
  @orbit_capacity 12

  # Nearest a cluster hub may sit to a scope centre. Hubs are placed at the
  # centroid of their members, which for a scope whose statements ring it evenly
  # is the scope itself; without this the hub would be buried under the node it
  # is meant to sit beside.
  @cluster_clearance 46

  @doc """
  Positions the focus scope, its drill-down targets, its statements, and the
  entity clusters, and returns the drawable model.

    Returns `%{width:, height:, nodes:, edges:}`. Each node is `%{id:, kind:, x:, y:,
    r:, label:, title:, class:, scope_id:}` where `kind` is `:scope`, `:knowledge`, or
    `:cluster`, and `class` is the CSS class naming its lifecycle state, its depth
    below the focus, or its role as the focus.

    A cluster node carries no entity id. Its label is the scope-local name the
    loader resolved from the cluster's entity card, truncated to fit, or an
    ordinal when the loader supplied no name. Its title carries the full label
    and the member count.
  """
  def build(data) do
    focus_path = focus_path(data)
    scope_positions = place_scopes(data.scopes, focus_path)
    knowledge_positions = place_knowledge(data.knowledge, scope_positions)
    cluster_positions = place_clusters(data.clusters, knowledge_positions, scope_positions)
    positions = scope_positions |> Map.merge(knowledge_positions) |> Map.merge(cluster_positions)

    nodes =
      scope_nodes(data, scope_positions, focus_path) ++
        knowledge_nodes(data, knowledge_positions) ++
        cluster_nodes(data, cluster_positions, knowledge_positions)

    %{width: @width, height: @height, nodes: nodes, edges: edges(data, positions)}
  end

  defp focus_path(%{focus: nil}), do: nil
  defp focus_path(%{focus: focus}), do: focus.path

  # Scopes are grouped by how far below the focus they sit and spread evenly
  # around their ring. The focus itself is the only scope at relative depth 0
  # and takes the centre. Within a ring the order is by path, so a scope does
  # not move when a sibling is added elsewhere in the tree.
  defp place_scopes(scopes, focus_path) do
    scopes
    |> Enum.group_by(&relative_depth(&1.path, focus_path))
    |> Enum.flat_map(fn {depth, ring} ->
      ring = Enum.sort_by(ring, & &1.path)
      count = length(ring)

      ring
      |> Enum.with_index()
      |> Enum.map(fn {scope, index} ->
        {scope.id, ring_position(depth, index, count)}
      end)
    end)
    |> Map.new()
  end

  # The focus sits dead centre; everything else is placed on its depth ring.
  # Angles start at the top of the circle and run clockwise, which is the
  # reading order people expect from a radial diagram.
  defp ring_position(0, 0, 1), do: {@width / 2, @height / 2}

  defp ring_position(depth, index, count) do
    radius = @ring_base + (depth - 1) * @ring_step
    angle = -:math.pi() / 2 + 2 * :math.pi() * index / max(count, 1)

    {clamp(@width / 2 + radius * :math.cos(angle), @width),
     clamp(@height / 2 + radius * :math.sin(angle), @height)}
  end

  # Each statement orbits the scope it lives in. Statements are ordered by id so
  # the picture is stable across reloads, and a scope whose statements exceed
  # one orbit's capacity gains further orbits rather than overlapping.
  #
  # A statement whose scope is not drawn — possible only if a caller hands in
  # inconsistent data — is dropped rather than placed at the origin, where it
  # would look like it belonged to the focus.
  defp place_knowledge(knowledge, scope_positions) do
    knowledge
    |> Enum.group_by(& &1.scope_id)
    |> Enum.flat_map(fn {scope_id, items} ->
      case Map.fetch(scope_positions, scope_id) do
        {:ok, {cx, cy}} ->
          items
          |> Enum.sort_by(& &1.id)
          |> Enum.with_index()
          |> Enum.map(fn {item, index} ->
            orbit = div(index, @orbit_capacity)
            slot = rem(index, @orbit_capacity)
            radius = @orbit_base + orbit * @orbit_step

            # Successive orbits are rotated by half a slot so a statement never
            # sits directly behind the one in the orbit inside it.
            angle =
              2 * :math.pi() * slot / @orbit_capacity +
                orbit * :math.pi() / @orbit_capacity

            {item.id,
             {clamp(cx + radius * :math.cos(angle), @width),
              clamp(cy + radius * :math.sin(angle), @height)}}
          end)

        :error ->
          []
      end
    end)
    |> Map.new()
  end

  # A cluster hub is drawn where its members already are — the centroid of their
  # positions — so its lines stay short and the group reads as a group. A
  # cluster whose members are all undrawn has nowhere to sit and is dropped.
  defp place_clusters(clusters, knowledge_positions, scope_positions) do
    clusters
    |> Enum.flat_map(fn cluster ->
      points =
        Enum.flat_map(cluster.knowledge_ids, fn id ->
          case Map.fetch(knowledge_positions, id) do
            {:ok, point} -> [point]
            :error -> []
          end
        end)

      case points do
        [] -> []
        _points -> [{cluster.id, points |> centroid() |> clear_of_scopes(scope_positions)}]
      end
    end)
    |> Map.new()
  end

  defp centroid(points) do
    count = length(points)
    {sum_x, sum_y} = Enum.reduce(points, {0.0, 0.0}, fn {x, y}, {ax, ay} -> {ax + x, ay + y} end)

    {sum_x / count, sum_y / count}
  end

  # Pushes a point radially out of any scope node it landed on. Scopes are
  # visited in id order and each push is a single step, which keeps the result a
  # pure function of the input rather than an iterated relaxation.
  defp clear_of_scopes(point, scope_positions) do
    scope_positions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(point, fn {_id, {sx, sy}}, {x, y} ->
      dx = x - sx
      dy = y - sy
      distance = :math.sqrt(dx * dx + dy * dy)

      if distance < @cluster_clearance do
        # A hub exactly on a scope centre has no direction to be pushed in;
        # straight up is chosen so the layout stays deterministic.
        {ux, uy} = if distance == 0.0, do: {0.0, -1.0}, else: {dx / distance, dy / distance}

        {clamp(sx + ux * @cluster_clearance, @width),
         clamp(sy + uy * @cluster_clearance, @height)}
      else
        {x, y}
      end
    end)
  end

  defp scope_nodes(data, positions, focus_path) do
    Enum.flat_map(data.scopes, fn scope ->
      case Map.fetch(positions, scope.id) do
        {:ok, {x, y}} ->
          depth = relative_depth(scope.path, focus_path)

          [
            %{
              id: scope.id,
              kind: :scope,
              x: x,
              y: y,
              # The focus is drawn larger than the scopes around it so the
              # centre of the picture reads as where the reader is standing.
              r: if(depth == 0, do: 24, else: 15),
              label: scope_label(scope),
              title: scope.path,
              class: "scope depth-#{min(depth, 4)}#{if depth == 0, do: " focus", else: ""}",
              scope_id: scope.id
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp knowledge_nodes(data, positions) do
    Enum.flat_map(data.knowledge, fn item ->
      case Map.fetch(positions, item.id) do
        {:ok, {x, y}} ->
          [
            %{
              id: item.id,
              kind: :knowledge,
              x: x,
              y: y,
              # Radius carries confidence, between 4 and 9 units, so a
              # weakly-held claim reads as a smaller dot without needing a
              # legend to decode a colour.
              r: 4.0 + 5.0 * min(max(item.confidence, 0.0), 1.0),
              label: nil,
              title: item.statement,
              class: "knowledge state-#{item.state}",
              scope_id: item.scope_id
            }
          ]

        :error ->
          []
      end
    end)
  end

  # Titles and labels come from the loader, which supplies a scope-local label only when the
  # group resolved to exactly one entity and that entity has a clean card in a drawn scope.
  # Everything else keeps the ordinal. Nothing here reads the entity cache directly.
  defp cluster_nodes(data, positions, knowledge_positions) do
    Enum.flat_map(data.clusters, fn cluster ->
      case Map.fetch(positions, cluster.id) do
        {:ok, {x, y}} ->
          drawn = Enum.count(cluster.knowledge_ids, &Map.has_key?(knowledge_positions, &1))

          [
            %{
              id: cluster.id,
              kind: :cluster,
              x: x,
              y: y,
              r: 11,
              label: cluster_node_label(cluster),
              title: "#{cluster.label} — #{drawn} statements",
              class: "cluster",
              scope_id: nil
            }
          ]

        :error ->
          []
      end
    end)
  end

  # Unit: characters. A node label sits under a 22px circle in a fixed-width diagram, so a long
  # name has to be cut here rather than left to overlap its neighbours. The full label stays in
  # the hover title and the side panel.
  @cluster_label_chars 18

  defp cluster_node_label(%{labelled?: true, label: label}) do
    if String.length(label) > @cluster_label_chars do
      String.slice(label, 0, @cluster_label_chars - 1) <> "…"
    else
      label
    end
  end

  defp cluster_node_label(cluster), do: "E#{cluster.index}"

  defp edges(data, positions) do
    containment =
      Enum.map(data.containment, fn {parent_id, child_id} ->
        {:containment, parent_id, child_id}
      end)

    membership = Enum.map(data.knowledge, &{:membership, &1.scope_id, &1.id})

    scope_relations =
      Enum.map(data.relations, &{:scope_relation, &1.source_scope_id, &1.target_scope_id})

    knowledge_relations =
      Enum.map(
        data.knowledge_edges,
        &{:knowledge_relation, &1.source_knowledge_id, &1.target_knowledge_id}
      )

    cluster_links =
      Enum.flat_map(data.clusters, fn cluster ->
        Enum.map(cluster.knowledge_ids, &{:cluster_link, cluster.id, &1})
      end)

    co_mentions =
      data
      |> Map.get(:cluster_edges, [])
      |> Enum.map(fn {source, target} -> {:co_mention, source, target} end)

    (containment ++
       membership ++ scope_relations ++ knowledge_relations ++ cluster_links ++ co_mentions)
    |> Enum.flat_map(fn {kind, from_id, to_id} ->
      with {:ok, {x1, y1}} <- Map.fetch(positions, from_id),
           {:ok, {x2, y2}} <- Map.fetch(positions, to_id) do
        [%{kind: kind, x1: x1, y1: y1, x2: x2, y2: y2}]
      else
        :error -> []
      end
    end)
  end

  # The last path segment is what distinguishes a scope from its siblings; the
  # full path is in the tooltip. The root has no last segment, so it is named.
  defp scope_label(%{path: "/"}), do: "root"
  defp scope_label(scope), do: scope.key

  # How far below the focus a path sits. Without a focus — an actor who can read
  # no scope, so nothing is drawn — absolute depth is the honest answer.
  defp relative_depth(path, nil), do: depth(path)
  defp relative_depth(path, focus_path), do: max(depth(path) - depth(focus_path), 0)

  defp depth("/"), do: 0
  defp depth(path), do: path |> String.split("/", trim: true) |> length()

  # Keeps a node inside the frame. A margin equal to the largest node radius
  # plus its stroke means a clamped node is still drawn whole rather than
  # sliced by the viewBox edge.
  defp clamp(value, extent) do
    value |> max(28.0) |> min(extent - 28.0)
  end
end
