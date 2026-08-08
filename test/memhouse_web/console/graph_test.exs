# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.GraphTest do
  @moduledoc """
  Pins the graph layout's three load-bearing properties: it is a pure function of its
    input, it draws nothing it was not given, and it centres the scope the reader chose.

    Determinism matters because the picture is a navigation aid. A reader who finds a
    statement in the lower left and comes back to it must find it in the same place; a
    layout that moved on every render would make the graph decorative rather than
    useful.
  """

  use ExUnit.Case, async: true

  alias MemHouseWeb.Console.Graph

  describe "build/1" do
    test "is a pure function of its input" do
      data = sample()

      assert Graph.build(data) == Graph.build(data)
    end

    test "places the focus scope at the centre of the frame" do
      layout = Graph.build(sample())
      focus = Enum.find(layout.nodes, &(&1.title == "/team"))

      assert focus.x == layout.width / 2
      assert focus.y == layout.height / 2
    end

    test "positions a scope by its depth below the focus, not its absolute depth" do
      # `/team/ops` is two levels deep in the tree and one level below the
      # focus. Drawing it on its absolute ring would push it a whole ring
      # further out than the picture claims.
      shallow = Graph.build(sample())
      deep = Graph.build(deeper_sample())

      shallow_child = Enum.find(shallow.nodes, &(&1.title == "/team/ops"))
      deep_child = Enum.find(deep.nodes, &(&1.title == "/a/b/c/d"))

      assert {shallow_child.x, shallow_child.y} == {deep_child.x, deep_child.y}
    end

    test "keeps every node inside the frame" do
      layout = Graph.build(sample())

      for node <- layout.nodes do
        assert node.x >= 0 and node.x <= layout.width
        assert node.y >= 0 and node.y <= layout.height
      end
    end

    test "statement radius grows with confidence" do
      layout = Graph.build(sample())
      weak = Enum.find(layout.nodes, &(&1.id == "k-weak"))
      strong = Enum.find(layout.nodes, &(&1.id == "k-strong"))

      assert strong.r > weak.r
    end

    test "draws containment, membership, cluster links, and both relation kinds" do
      kinds =
        sample() |> Graph.build() |> Map.fetch!(:edges) |> Enum.map(& &1.kind) |> Enum.uniq()

      assert :containment in kinds
      assert :membership in kinds
      assert :scope_relation in kinds
      assert :knowledge_relation in kinds
      assert :cluster_link in kinds
    end

    test "drops an edge whose endpoint is not drawn" do
      # A line to a node that is not on the page would disclose that an unseen
      # node exists. The loader filters these already; this asserts the layout
      # refuses them too, so neither layer alone is the only guard.
      data = %{sample() | knowledge_edges: [relation("k-strong", "not-drawn")]}

      refute Enum.any?(Graph.build(data).edges, &(&1.kind == :knowledge_relation))
    end

    test "drops a cluster whose members are all undrawn" do
      data = %{sample() | clusters: [cluster(1, ["not-drawn-a", "not-drawn-b"])]}
      layout = Graph.build(data)

      refute Enum.any?(layout.nodes, &(&1.kind == :cluster))
      refute Enum.any?(layout.edges, &(&1.kind == :cluster_link))
    end

    test "keeps a cluster hub clear of the scope it would otherwise sit on" do
      # Two statements on opposite sides of a scope have that scope as their
      # centroid. Drawn there the hub would be buried under the node it is meant
      # to sit beside, and unclickable.
      layout = Graph.build(sample())
      hub = Enum.find(layout.nodes, &(&1.kind == :cluster))
      focus = Enum.find(layout.nodes, &(&1.title == "/team"))

      assert :math.sqrt(:math.pow(hub.x - focus.x, 2) + :math.pow(hub.y - focus.y, 2)) >= 40
    end

    test "names an unlabelled cluster by ordinal and member count only" do
      hub = sample() |> Graph.build() |> Map.fetch!(:nodes) |> Enum.find(&(&1.kind == :cluster))

      assert hub.title == "Shared entity 1 — 2 statements"
      assert hub.label == "E1"
      refute Map.has_key?(hub, :entity_id)
    end

    test "names a labelled cluster after its card, and still carries no entity id" do
      data =
        put_in(sample().clusters, [labelled_cluster(1, ["k-strong", "k-weak"], "billing service")])

      hub = data |> Graph.build() |> Map.fetch!(:nodes) |> Enum.find(&(&1.kind == :cluster))

      assert hub.label == "billing service"
      assert hub.title == "billing service — 2 statements"
      refute Map.has_key?(hub, :entity_id)
    end

    test "truncates a node label that would overlap its neighbours" do
      # The full label stays reachable through the hover title and the side panel.
      data =
        put_in(sample().clusters, [
          labelled_cluster(1, ["k-strong", "k-weak"], "Continental Reinsurance Group")
        ])

      hub = data |> Graph.build() |> Map.fetch!(:nodes) |> Enum.find(&(&1.kind == :cluster))

      assert hub.label == "Continental Reins…"
      assert hub.title == "Continental Reinsurance Group — 2 statements"
    end

    test "draws a co-mention edge between two named hubs" do
      data = %{
        sample()
        | clusters: [
            labelled_cluster(1, ["k-strong"], "Helix"),
            labelled_cluster(2, ["k-weak"], "Ada")
          ],
          cluster_edges: [{"cluster-1", "cluster-2"}]
      }

      assert Enum.any?(Graph.build(data).edges, &(&1.kind == :co_mention))
    end

    test "drops a co-mention edge whose hub is not drawn" do
      # The loader already refuses to emit one, but a line to a hub that is not on the page would
      # report that an undrawn group exists, so the layout refuses it too.
      data = %{sample() | cluster_edges: [{"cluster-1", "cluster-99"}]}

      refute Enum.any?(Graph.build(data).edges, &(&1.kind == :co_mention))
    end

    test "renders no entity node and no entity field" do
      layout = Graph.build(sample())

      refute Enum.any?(layout.nodes, &(&1.kind == :entity))
      refute Enum.any?(layout.nodes, &Map.has_key?(&1, :entity_id))
      assert Enum.all?(layout.nodes, &(&1.kind in [:scope, :knowledge, :cluster]))
    end

    test "draws nothing when the actor can read no scope" do
      data = %{
        sample()
        | focus: nil,
          scopes: [],
          knowledge: [],
          containment: [],
          relations: [],
          knowledge_edges: [],
          clusters: []
      }

      assert Graph.build(data).nodes == []
    end
  end

  # A focus scope with one child, two statements of differing confidence, a
  # relation between the statements, a scope relation, and one shared-entity
  # cluster — the smallest input that exercises every node and edge kind at
  # once.
  defp sample do
    %{
      focus: scope("s-team", "/team", "team"),
      ancestors: [scope("s-root", "/", "root")],
      parent: scope("s-root", "/", "root"),
      children: [scope("s-ops", "/team/ops", "ops")],
      descendants?: false,
      scopes: [scope("s-team", "/team", "team"), scope("s-ops", "/team/ops", "ops")],
      knowledge: [
        knowledge("k-weak", "s-team", 0.2, "active"),
        knowledge("k-strong", "s-team", 0.95, "proposed")
      ],
      containment: [{"s-team", "s-ops"}],
      relations: [%{source_scope_id: "s-team", target_scope_id: "s-ops", kind: "related"}],
      knowledge_edges: [relation("k-weak", "k-strong")],
      clusters: [cluster(1, ["k-strong", "k-weak"])],
      cluster_edges: [],
      clusters_truncated?: false,
      scope_paths: %{"s-team" => "/team", "s-ops" => "/team/ops"},
      all_scopes: [],
      shown: 2,
      total: 2,
      truncated?: false
    }
  end

  # The same shape one level deeper in the tree, for the relative-depth check.
  defp deeper_sample do
    %{
      sample()
      | focus: scope("s-team", "/a/b/c", "c"),
        scopes: [scope("s-team", "/a/b/c", "c"), scope("s-ops", "/a/b/c/d", "d")]
    }
  end

  defp scope(id, path, key) do
    %{id: id, path: path, key: key, name: key, state: "active", parent_id: nil}
  end

  defp knowledge(id, scope_id, confidence, state) do
    %{
      id: id,
      scope_id: scope_id,
      confidence: confidence,
      state: state,
      statement: "statement #{id}",
      kind: "fact",
      sensitivity: "internal",
      scope_path: "/team"
    }
  end

  defp cluster(index, knowledge_ids) do
    %{
      id: "cluster-#{index}",
      index: index,
      label: "Shared entity #{index}",
      labelled?: false,
      knowledge_ids: knowledge_ids
    }
  end

  defp labelled_cluster(index, knowledge_ids, label) do
    index
    |> cluster(knowledge_ids)
    |> Map.merge(%{label: label, labelled?: true, entity_kind: "concept"})
  end

  defp relation(source, target) do
    %{source_knowledge_id: source, target_knowledge_id: target, kind: "supports"}
  end
end
