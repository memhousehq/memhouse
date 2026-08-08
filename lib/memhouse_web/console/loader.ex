# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.Loader do
  @moduledoc """
  Performs every browser-console database read.

  LiveViews render and dispatch events but do not query directly. Each load runs in one
  Account-scoped transaction, applies console visibility rules, and excludes secret or
  derived internals from returned data.
  """

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Documents.ConnectorConfig
  alias MemHouse.Governance.Consent
  alias MemHouse.Governance.ErasureRequest
  alias MemHouse.Governance.GateDecision
  alias MemHouse.Governance.GateRule
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.Attribution
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.KnowledgeRelation
  alias MemHouse.Knowledge.LifecycleEvent
  alias MemHouse.Knowledge.Projection
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Model.Config, as: ModelConfig
  alias MemHouse.Observations.Document
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Observations.Message
  alias MemHouse.Observations.Session
  alias MemHouse.Retrieval.Profile
  alias MemHouse.Retrieval.RetrievalProfile
  alias MemHouse.Retrieval.Store
  alias MemHouse.Skills.SkillRequirementCard
  alias MemHouse.Topology.RoleGrant
  alias MemHouse.Topology.Scope
  alias MemHouse.Topology.ScopeRelation
  alias MemHouseWeb.Console.Access

  require Ash.Query

  # Rows per page in the knowledge explorer. Chosen so a page fits one screen
  # of a laptop without scrolling the filter controls out of view; raising it
  # costs nothing but readability.
  @page_size 25

  # Page sizes the explorer offers. Bounded because the console is a browsing
  # surface: a reader who needs every row wants the portability archive.
  @page_sizes [25, 50, 100]

  # Upper bound on rows any single list panel loads — recent activity, sessions,
  # messages, documents. The console is a browsing surface, not an export: a
  # panel that would need more than this should be reached through the filtered
  # explorer instead. Exports go through the portability archive.
  @panel_limit 50

  # Statement nodes the graph draws for one scope, and the ceiling a caller may
  # raise that to. Past the ceiling the picture is unreadable before it is slow:
  # a few hundred dots in one frame carry less than the explorer's table does.
  @graph_limit 90
  @graph_limit_max 150

  # Anonymous entity clusters drawn per graph. Every additional hub crosses the
  # frame with more lines, so the tail is reported as truncated rather than
  # drawn.
  @graph_cluster_limit 12

  @doc """
  Default rows per page in the knowledge explorer.

  `knowledge_list/2` reports the size it actually used, which may be a larger
  offered size; this is what it falls back to.
  """
  def page_size, do: @page_size

  @doc """
  Page sizes the knowledge explorer offers, smallest first.
  """
  def page_sizes, do: @page_sizes

  @doc """
  Everything the dashboard shows.

    Returns a map with the Account, the actor's visible scope count, the knowledge
    totals broken down by lifecycle state and by sensitivity, counts of documents,
    sessions and raw observations, the open governance queue depth, the number of
    statements about the viewer personally, the count of cached context projections
    currently marked dirty, and the most recent lifecycle events.
  """
  def overview(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      scopes = scopes(account.id, current_actor)
      states = Access.visible_states(actor)

      state_counts =
        Map.new(states, fn state ->
          {state, count(knowledge_base_query(actor, state: state), account.id, current_actor)}
        end)

      sensitivity_counts =
        Map.new(~w(public internal personal restricted), fn sensitivity ->
          {sensitivity,
           count(
             knowledge_base_query(actor, sensitivity: sensitivity),
             account.id,
             current_actor
           )}
        end)

      recent =
        LifecycleEvent
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      %{
        account: account,
        scope_paths: scope_paths(scopes),
        scope_count: length(scopes),
        knowledge_total: count(knowledge_base_query(actor), account.id, current_actor),
        state_counts: state_counts,
        sensitivity_counts: sensitivity_counts,
        document_count: count(Document, account.id, current_actor),
        session_count: count(Session, account.id, current_actor),
        message_count: count(Message, account.id, current_actor),
        about_me_count: about_me_count(account.id, current_actor),
        dirty_projection_count: dirty_projection_count(account.id, current_actor),
        queue_depth: queue_depth(account.id, actor, current_actor),
        recent_events: Enum.take(recent, 12)
      }
    end)
  end

  @doc """
  Returns one filtered page of the knowledge explorer.

  Beyond the rows themselves the result carries what the page needs to describe
  its own state honestly: the effective `page_size` and `sort` after clamping,
  `page_count`, whether any filter narrowed the result (`filtered?`), and how
  many scopes a selected scope contains (`descendant_count`).

  It applies the lifecycle and provisional visibility rules from
  `MemHouseWeb.Console.Access`.
  """
  def knowledge_list(%Actor{} = actor, filters) when is_map(filters) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      scopes = scopes(account.id, current_actor)
      paths = scope_paths(scopes)
      scope_path = blank_to_nil(filters["scope"])
      scope_ids = subtree_scope_ids(scopes, scope_path)
      page_size = effective_page_size(filters)
      sort = sort_order(filters)

      query =
        actor
        |> knowledge_base_query(
          state: blank_to_nil(filters["state"]),
          kind: blank_to_nil(filters["kind"]),
          sensitivity: blank_to_nil(filters["sensitivity"]),
          target_level: blank_to_nil(filters["target_level"]),
          subject_self?: filters["subject"] == "me",
          scope_ids: scope_ids
        )

      total = count(query, account.id, current_actor)
      page_count = max(ceil(total / page_size), 1)
      # A deep link outlives the filters it was written against, so a page past
      # the end must land on real rows rather than on a blank that reads as
      # "nothing matches".
      page = min(page_number(filters), page_count)

      items =
        query
        |> Ash.Query.sort(sort_terms(sort))
        |> Ash.Query.limit(page_size)
        |> Ash.Query.offset((page - 1) * page_size)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
        |> Enum.map(&with_scope_path(&1, paths))

      %{
        items: items,
        scopes: scopes,
        scope_paths: paths,
        page: page,
        page_size: page_size,
        page_count: page_count,
        sort: sort,
        total: total,
        filtered?: filtered?(filters),
        descendant_count: descendant_count(scope_ids, scope_path)
      }
    end)
  end

  @doc """
  Everything the knowledge detail page shows for one statement, or `nil` when the id
    names nothing this actor may see.

    Returns a map holding the knowledge row (with `:scope_path`), its provenance rows,
    its attributions, its outgoing and incoming relations, other readable statements
    that share a resolved entity, the source messages and document versions named by
    its provenance, its lifecycle timeline, the open queue entry if one exists, its
    gate decisions when the viewer is a curator, the statement it supersedes and the
    statements that supersede it, and the scope path lookup.
  """
  def knowledge_detail(%Actor{} = actor, knowledge_id) when is_binary(knowledge_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      item =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)

      if is_nil(item) or not Access.visible_knowledge?(actor, item) do
        nil
      else
        detail_bundle(account, actor, current_actor, item)
      end
    end)
  end

  @doc """
  The scope containment tree, as a flat list in path order.

  Each row also carries index coverage — statement, embedded, and mention counts
  — because a scope whose projection refresh never ran looks identical to a
  healthy one from every other panel.
  """
  def scope_directory(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      scopes = scopes(account.id, current_actor)
      paths = scope_paths(scopes)

      # Vectors and mentions are written by the projection refresh alone, so a
      # scope can hold every statement and answer nothing semantically. Reading
      # coverage here is what makes that state visible to an operator.
      coverage =
        MemHouse.Retrieval.index_coverage(
          account.id,
          Enum.map(scopes, & &1.id),
          actor.peer_id
        )

      rows =
        Enum.map(scopes, fn scope ->
          %{
            scope: scope,
            depth: depth(scope.path),
            role: Access.scope_role(actor, scope.id),
            coverage: Map.fetch!(coverage, scope.id),
            knowledge_count:
              count(
                knowledge_base_query(actor, scope_ids: [scope.id]),
                account.id,
                current_actor
              ),
            document_count:
              count(
                Ash.Query.filter(Document, scope_id == ^scope.id),
                account.id,
                current_actor
              ),
            session_count:
              count(
                Ash.Query.filter(Session, scope_id == ^scope.id),
                account.id,
                current_actor
              )
          }
        end)

      relations =
        ScopeRelation
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      grants =
        RoleGrant
        |> Ash.Query.sort(granted_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      %{rows: rows, relations: relations, grants: grants, scope_paths: paths}
    end)
  end

  @doc """
  One scope's neighbourhood, drawn as nodes and edges, narrowed to what this actor may see.

  The graph is deliberately local: it shows one focus scope, that scope's
  statements, the anonymous entity clusters linking them, and the readable
  scopes immediately below as drill-down targets. Drawing the whole authorized
  tree is available through `:descendants?` but is not the default, because on a
  real Account it is unreadable.

  `opts` may carry `:scope` (the focus scope's path), `:descendants?` (draw the
  whole subtree rather than the focus alone), and `:limit` (how many statement
  nodes to draw, capped at #{@graph_limit_max}).

  An unknown or unauthorized `:scope` falls back to the shallowest readable
  scope rather than widening to everything. Ancestors, parents, and children are
  the *readable* ones: an unreadable scope in the middle of the tree is skipped,
  never named.

  Returns `%{focus:, ancestors:, parent:, children:, descendants?:, scopes:,
  knowledge:, containment:, relations:, knowledge_edges:, clusters:,
  clusters_truncated?:, scope_paths:, all_scopes:, shown:, total:, truncated?:}`.
  `focus` is `nil` only when the actor can read no scope at all.
  """
  def graph(%Actor{} = actor, opts \\ []) do
    limit = min(Keyword.get(opts, :limit, @graph_limit), @graph_limit_max)
    descendants? = Keyword.get(opts, :descendants?, false)

    DataLayer.with_actor(actor, fn account, current_actor ->
      scopes = scopes(account.id, current_actor)
      paths = scope_paths(scopes)
      focus = focus_scope(scopes, Keyword.get(opts, :scope))

      ancestors = readable_ancestors(scopes, focus)
      children = nearest_readable_descendants(scopes, focus)
      drawn_scopes = drawn_scopes(scopes, focus, children, descendants?)
      drawn_scope_ids = MapSet.new(drawn_scopes, & &1.id)

      # Child scopes are drawn as navigation targets, not as containers of
      # statements: pulling their contents in is what `descendants?` asks for.
      statement_scope_ids =
        if descendants?, do: MapSet.to_list(drawn_scope_ids), else: focus_ids(focus)

      base = knowledge_base_query(actor, scope_ids: statement_scope_ids)
      total = count(base, account.id, current_actor)

      knowledge =
        base
        |> Ash.Query.sort(confidence: :desc, inserted_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
        |> Enum.map(&with_scope_path(&1, paths))

      knowledge_ids = MapSet.new(knowledge, & &1.id)

      # Only edges whose *both* endpoints are drawn are returned. A relation to
      # a statement outside the current view would otherwise render as a line
      # to nowhere, and worse, would disclose that an unseen statement exists.
      knowledge_edges =
        KnowledgeRelation
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
        |> Enum.filter(
          &(MapSet.member?(knowledge_ids, &1.source_knowledge_id) and
              MapSet.member?(knowledge_ids, &1.target_knowledge_id))
        )

      relations =
        ScopeRelation
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
        |> Enum.filter(
          &(MapSet.member?(drawn_scope_ids, &1.source_scope_id) and
              MapSet.member?(drawn_scope_ids, &1.target_scope_id))
        )

      shared =
        Store.shared_entity_clusters(
          account.id,
          Enum.map(knowledge, & &1.id),
          @graph_cluster_limit
        )

      cards = entity_cards(account.id, current_actor, drawn_scope_ids)
      member_scopes = Map.new(knowledge, &{&1.id, &1.scope_id})

      indexed = Enum.with_index(shared.clusters, 1)
      clusters = Enum.map(indexed, &cluster(&1, cards, focus_ids(focus), member_scopes))

      %{
        focus: focus,
        ancestors: ancestors,
        parent: List.last(ancestors),
        children: children,
        descendants?: descendants?,
        scopes: drawn_scopes,
        knowledge: knowledge,
        containment: containment_edges(drawn_scopes),
        relations: relations,
        knowledge_edges: knowledge_edges,
        clusters: clusters,
        cluster_edges: cluster_edges(account.id, knowledge, indexed, clusters),
        clusters_truncated?: shared.count > length(clusters),
        scope_paths: paths,
        all_scopes: scopes,
        shown: length(knowledge),
        total: total,
        truncated?: total > length(knowledge)
      }
    end)
  end

  # Entity cards for every drawn scope, keyed by scope and entity.
  #
  # The `kind` filter is load-bearing, not tidiness. `Knowledge.Projection` authorizes reads on
  # `scope_id` alone and filters neither kind nor peer, so dropping it would return peer-profile
  # rows — another subject's provisional content — to anyone who can read the scope. Dirty rows
  # are excluded for the same reason every other reader excludes them: their content predates a
  # lifecycle change.
  defp entity_cards(account_id, actor, scope_ids) do
    Projection
    |> Ash.Query.filter(
      scope_id in ^MapSet.to_list(scope_ids) and kind == "entity_card" and dirty == false
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Map.new(&{{&1.scope_id, &1.entity_id}, &1})
  end

  # A cluster is a membership set, not an entity: `shared_entity_clusters/3` collapses groups that
  # share identical membership so the graph never reports how many entities resolved. Naming a
  # collapsed group would undo that, so only a single-entity group is named, and the entity id
  # itself stays out of the returned map — the ordinal remains the whole public identity.
  defp cluster({%{members: members, entity_ids: entity_ids}, index}, cards, focus_ids, scopes) do
    base = %{
      id: "cluster-#{index}",
      index: index,
      label: "Shared entity #{index}",
      labelled?: false,
      knowledge_ids: members
    }

    case entity_ids do
      [entity_id] ->
        Map.merge(base, card_facts(cards, card_order(members, focus_ids, scopes), entity_id))

      _collapsed ->
        base
    end
  end

  # Edges between hubs whose entities were named in the same statement.
  #
  # Only named hubs take part. An unnamed hub is either a collapsed group or a group with no
  # usable card, and both stay anonymous on purpose: joining them would let a reader count the
  # entities inside a collapsed group by counting the lines leaving it, which is the disclosure
  # the collapse exists to prevent.
  #
  # The entity id stays inside this function. What leaves is a pair of cluster ids, which are the
  # ordinals the graph already shows.
  defp cluster_edges(account_id, knowledge, indexed, clusters) do
    labelled = MapSet.new(Enum.filter(clusters, & &1.labelled?), & &1.id)

    cluster_by_entity =
      for {%{entity_ids: [entity_id]}, index} <- indexed,
          MapSet.member?(labelled, "cluster-#{index}"),
          into: %{},
          do: {entity_id, "cluster-#{index}"}

    account_id
    |> Store.co_mentioned_entity_pairs(
      Enum.map(knowledge, & &1.id),
      Map.keys(cluster_by_entity)
    )
    |> Enum.flat_map(fn {left, right} ->
      case {Map.fetch(cluster_by_entity, left), Map.fetch(cluster_by_entity, right)} do
        {{:ok, source}, {:ok, target}} when source != target -> [{source, target}]
        _unresolved -> []
      end
    end)
    |> Enum.uniq()
  end

  # Cards exist per scope, and a cluster's members can span the focus and the child scopes drawn
  # with it. Prefer the scope the reader chose, then the scope holding most of the members, so the
  # description comes from where the statements actually live. Ancestors are deliberately absent:
  # they are never in the drawn set, so a card is never loaded for one.
  defp card_order(members, focus_ids, scopes) do
    ranked =
      members
      |> Enum.flat_map(&List.wrap(Map.get(scopes, &1)))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {scope_id, count} -> {-count, scope_id} end)
      |> Enum.map(&elem(&1, 0))

    Enum.uniq(focus_ids ++ ranked)
  end

  defp card_facts(cards, card_order, entity_id) do
    card_order
    |> Enum.find_value(&Map.get(cards, {&1, entity_id}))
    |> case do
      nil ->
        %{}

      card ->
        facts = %{
          label: card.content["label"],
          entity_kind: card.content["kind"],
          summary: card.content["summary"],
          summary_mode: card.content["summary_mode"],
          sensitivity: card.content["sensitivity"],
          card_knowledge_ids: Enum.map(card.content["knowledge"] || [], & &1["id"])
        }

        # Every candidate form can be rejected, which leaves a card with no label. Dropping the
        # key rather than merging nil keeps the ordinal the caller already set.
        if is_nil(facts.label),
          do: Map.delete(facts, :label),
          else: Map.put(facts, :labelled?, true)
    end
  end

  # The focus falls back to the shallowest readable scope — the root when the
  # actor holds it — so a first visit lands somewhere meaningful and an
  # unauthorized path in the URL narrows to a default rather than widening to
  # the whole tree.
  defp focus_scope([], _path), do: nil

  defp focus_scope(scopes, path) do
    Enum.find(scopes, &(&1.path == path)) ||
      Enum.min_by(scopes, &{depth(&1.path), &1.path})
  end

  defp focus_ids(nil), do: []
  defp focus_ids(focus), do: [focus.id]

  defp drawn_scopes(_scopes, nil, _children, _descendants?), do: []

  defp drawn_scopes(scopes, focus, _children, true) do
    [focus | Enum.filter(scopes, &contained_in?(&1.path, focus.path))]
    |> Enum.sort_by(& &1.path)
  end

  defp drawn_scopes(_scopes, focus, children, false), do: [focus | children]

  # Readable proper ancestors, shallowest first. An unreadable scope between two
  # readable ones is simply absent: the breadcrumb it would occupy is a name the
  # actor has no grant to learn.
  defp readable_ancestors(_scopes, nil), do: []

  defp readable_ancestors(scopes, focus) do
    scopes
    |> Enum.filter(&contained_in?(focus.path, &1.path))
    |> Enum.sort_by(&depth(&1.path))
  end

  # The readable scopes closest below the focus: a readable scope with no other
  # readable scope between it and the focus. Skipping an unreadable middle scope
  # keeps a readable grandchild reachable without ever naming its parent.
  defp nearest_readable_descendants(_scopes, nil), do: []

  defp nearest_readable_descendants(scopes, focus) do
    below = Enum.filter(scopes, &contained_in?(&1.path, focus.path))

    below
    |> Enum.reject(fn candidate ->
      Enum.any?(below, &(&1.id != candidate.id and contained_in?(candidate.path, &1.path)))
    end)
    |> Enum.sort_by(& &1.path)
  end

  # Containment is derived from the drawn set rather than from `parent_id`, so a
  # child whose real parent is unreadable still hangs off the nearest drawn
  # ancestor instead of floating unconnected.
  defp containment_edges(drawn) do
    Enum.flat_map(drawn, fn scope ->
      drawn
      |> Enum.filter(&contained_in?(scope.path, &1.path))
      |> Enum.max_by(&depth(&1.path), fn -> nil end)
      |> case do
        nil -> []
        parent -> [{parent.id, scope.id}]
      end
    end)
  end

  # Strict containment: `/a/b` is inside `/a` and inside `/`, and nothing is
  # inside itself. Path prefix is how containment is decided everywhere in this
  # system, because a path is written once and never rewritten.
  defp contained_in?(path, path), do: false
  defp contained_in?(path, "/"), do: path != "/"
  defp contained_in?(path, ancestor), do: String.starts_with?(path, ancestor <> "/")

  @doc """
  The provenance surface: documents with their versions, and sessions with their raw
    observations.

    Returns `%{documents:, versions_by_document:, sessions:, messages:, connectors:,
    scope_paths:}`. Lists are capped at a panel's worth of rows and ordered newest
    first.
  """
  def sources(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      paths = scope_paths(scopes(account.id, current_actor))

      documents =
        Document
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      document_ids = Enum.map(documents, & &1.id)

      versions =
        DocumentVersion
        |> Ash.Query.filter(document_id in ^document_ids)
        |> Ash.Query.sort(version: :desc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
        |> Enum.group_by(& &1.document_id)

      sessions =
        Session
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      messages =
        Message
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      connectors =
        ConnectorConfig
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      %{
        documents: documents,
        versions_by_document: versions,
        sessions: sessions,
        messages: messages,
        connectors: connectors,
        scope_paths: paths
      }
    end)
  end

  @doc """
  Published skill requirement cards, newest version first within each skill.

  Every version is returned, not only the active one, because a retired version
  is the record of what a skill used to demand and is what makes an old
  readiness result readable after the fact.

  Returns `%{cards:, scopes:, scope_paths:}` with each card carrying a
  `:scope_path` for display.
  """
  def skills(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      scopes = scopes(account.id, current_actor)
      paths = scope_paths(scopes)

      cards =
        SkillRequirementCard
        |> Ash.Query.sort(skill_key: :asc, version: :desc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
        |> Enum.map(&Map.put(&1, :scope_path, Map.get(paths, &1.scope_id)))

      %{cards: cards, scopes: scopes, scope_paths: paths}
    end)
  end

  @doc """
  Reports content-safe derived-index health for one authorized scope.

  The selected path must be among the actor's readable scopes. The result
  contains counts and embedding identities only; it never returns statements,
  entity-cache rows, or other derived content.
  """
  def retrieval_health(actor, scope_path, query_text \\ nil)

  def retrieval_health(%Actor{} = actor, scope_path, query_text) when is_binary(scope_path) do
    retrieval_health(actor, scope_path, "balanced", query_text)
  end

  def retrieval_health(%Actor{}, _scope_path, _query_text), do: nil

  def retrieval_health(%Actor{} = actor, scope_path, profile_name, query_text)
      when is_binary(scope_path) do
    profile_name =
      if profile_name in ~w(fast balanced thorough), do: profile_name, else: "balanced"

    result =
      DataLayer.with_actor(actor, fn account, current_actor ->
        readable_scopes = scopes(account.id, current_actor)
        scope = Enum.find(readable_scopes, &(&1.path == scope_path))

        if scope do
          coverage =
            MemHouse.Retrieval.index_coverage(account.id, [scope.id], actor.peer_id)
            |> Map.fetch!(scope.id)

          chain =
            readable_scopes
            |> Enum.filter(fn candidate ->
              candidate.path == scope.path or
                (candidate.path == "/" or String.starts_with?(scope.path, candidate.path <> "/"))
            end)
            |> Enum.sort_by(&String.length(&1.path), :desc)
            |> Enum.map(& &1.id)

          reason =
            if Access.can?(actor, :administer) do
              entity_match_reason(account.id, scope.id, current_actor, query_text)
            end

          {coverage, chain, reason}
        end
      end)

    if result do
      {coverage, scope_chain, entity_match_reason} = result

      configured_identity =
        :embedder
        |> ModelConfig.resolve(%{account_id: actor.account_id, actor: actor})
        |> ModelConfig.embedding_identity()

      effective_profile =
        Profile.resolve(profile_name, %{
          account_id: actor.account_id,
          actor: actor,
          scope_ids: scope_chain
        })

      Map.merge(coverage, %{
        configured_identity: configured_identity,
        effective_profile: %{
          name: effective_profile.name,
          version: effective_profile.version,
          deadline_ms: effective_profile.deadline_ms,
          rerank: effective_profile.rerank,
          strategies: effective_profile.strategies,
          disabled_strategies: effective_profile.disabled_strategies
        },
        probe: %{model_calls: 0, content_read: false},
        state: retrieval_health_state(coverage, configured_identity, effective_profile),
        next_action: retrieval_health_action(coverage, configured_identity, effective_profile),
        entity_match_reason: entity_match_reason
      })
    end
  end

  def retrieval_health(%Actor{}, _scope_path, _profile_name, _query_text), do: nil

  @doc """
  The viewer's own governance position: consent requests awaiting their answer,
  their erasure requests, and the scope path lookup.

  The statements about the viewer are *not* loaded here. They come from
  `MemHouse.Governance.Engine.self_view/1`, which deliberately ignores scope
  membership — a person may read what is recorded about them even in a scope
  they hold no role on — and that exception belongs in the operation layer
  rather than being re-implemented in the web layer.
  """
  def self_governance(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      consents =
        Consent
        |> Ash.Query.filter(subject_peer_id == ^current_actor.peer_id)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      erasures =
        ErasureRequest
        |> Ash.Query.filter(peer_id == ^current_actor.peer_id)
        |> Ash.Query.sort(requested_at: :desc)
        |> Ash.Query.limit(@panel_limit)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      %{
        consents: consents,
        erasures: erasures,
        scope_paths: scope_paths(scopes(account.id, current_actor))
      }
    end)
  end

  @doc """
  The administrator's operations view: gate rules, stored and runtime retrieval
  profiles, the latest content-free retrieval outcome, and aggregate
  entity-resolution quality signals.

  Raises `Ash.Error.Forbidden` if called by anyone who is not a
  password-authenticated account administrator. That is deliberate: gate rules
  and the usage ledger have plain role checks with no filter behind them, so
  there is no meaningful "empty" answer to give a member. Callers gate on
  `MemHouseWeb.Console.Access.can?(actor, :administer)` first.
  """
  def operations(%Actor{} = actor) do
    unless Access.can?(actor, :administer), do: raise(Ash.Error.Forbidden, errors: [])

    DataLayer.with_actor(actor, fn account, current_actor ->
      paths = scope_paths(scopes(account.id, current_actor))

      gate_rules =
        GateRule
        |> Ash.Query.sort(priority: :desc, version: :desc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      profiles =
        RetrievalProfile
        |> Ash.Query.sort(name: :asc, version: :desc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)

      %{
        gate_rules: gate_rules,
        retrieval_profiles: profiles,
        retrieval_runtime: retrieval_runtime(),
        latest_retrieval: MemHouse.Retrieval.Diagnostics.latest(account.id),
        entity_resolution: Store.entity_resolution_metrics(account.id),
        scope_paths: paths
      }
    end)
  end

  defp retrieval_runtime do
    config = Application.fetch_env!(:memhouse, :retrieval_profiles)

    %{
      enabled_strategies: Keyword.fetch!(config, :enabled_strategies),
      rerank_timeout_ms: Keyword.fetch!(config, :rerank_timeout_ms),
      profiles:
        for name <- [:fast, :balanced, :thorough], into: %{} do
          profile = Keyword.fetch!(config, name)
          {name, %{deadline_ms: profile.deadline_ms, rerank: profile.rerank}}
        end
    }
  end

  # ----------------------------------------------------------------------------
  # Query construction
  # ----------------------------------------------------------------------------

  # The single place the console's two visibility rules are turned into SQL.
  #
  # Every knowledge query in this module starts here, so neither rule can be
  # forgotten by a caller. The two `or subject_peer_id == ...` branches are the
  # self-view exemption: a person always sees statements about themselves,
  # whatever their state and whatever role the viewer holds on the scope.
  #
  # When the actor has no peer id those branches are dropped rather than
  # compared against nil, because `= NULL` becomes `IS NULL` in SQL and would
  # match every statement about nobody — widening instead of narrowing.
  defp knowledge_base_query(%Actor{} = actor, opts \\ []) do
    {states, peer_id} = Access.knowledge_filter_terms(actor)

    query =
      if is_binary(peer_id) do
        KnowledgeItem
        |> Ash.Query.filter(state in ^states or subject_peer_id == ^peer_id)
        |> Ash.Query.filter(state != "provisional" or subject_peer_id == ^peer_id)
      else
        KnowledgeItem
        |> Ash.Query.filter(state in ^states)
        |> Ash.Query.filter(state != "provisional")
      end

    # Soft-deleted rows are erased content that survived only as a tombstone.
    # They are never shown, to anyone.
    query = Ash.Query.filter(query, is_nil(deleted_at))

    query
    |> maybe_filter_state(Keyword.get(opts, :state))
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> maybe_filter_sensitivity(Keyword.get(opts, :sensitivity))
    |> maybe_filter_target_level(Keyword.get(opts, :target_level))
    |> maybe_filter_scopes(Keyword.get(opts, :scope_ids))
    |> maybe_filter_subject(Keyword.get(opts, :subject_self?), peer_id)
  end

  defp maybe_filter_state(query, nil), do: query
  defp maybe_filter_state(query, state), do: Ash.Query.filter(query, state == ^state)

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: Ash.Query.filter(query, kind == ^kind)

  defp maybe_filter_sensitivity(query, nil), do: query

  defp maybe_filter_sensitivity(query, sensitivity),
    do: Ash.Query.filter(query, sensitivity == ^sensitivity)

  defp maybe_filter_target_level(query, nil), do: query

  defp maybe_filter_target_level(query, level),
    do: Ash.Query.filter(query, target_level == ^level)

  defp maybe_filter_scopes(query, nil), do: query
  defp maybe_filter_scopes(query, ids), do: Ash.Query.filter(query, scope_id in ^ids)

  defp maybe_filter_subject(query, true, peer_id) when is_binary(peer_id),
    do: Ash.Query.filter(query, subject_peer_id == ^peer_id)

  defp maybe_filter_subject(query, _flag, _peer_id), do: query

  # ----------------------------------------------------------------------------
  # Detail assembly
  # ----------------------------------------------------------------------------

  defp detail_bundle(account, %Actor{} = actor, current_actor, item) do
    paths = scope_paths(scopes(account.id, current_actor))

    provenance =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^item.id)
      |> Ash.Query.sort(occurred_at: :asc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)

    attributions =
      Attribution
      |> Ash.Query.filter(knowledge_item_id == ^item.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)

    lifecycle =
      LifecycleEvent
      |> Ash.Query.filter(knowledge_item_id == ^item.id)
      |> Ash.Query.sort(occurred_at: :asc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)

    relations =
      KnowledgeRelation
      |> Ash.Query.filter(source_knowledge_id == ^item.id or target_knowledge_id == ^item.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)

    message_ids =
      provenance
      |> Enum.map(& &1.message_id)
      |> Enum.concat(item.source_message_ids)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    messages =
      Message
      |> Ash.Query.filter(id in ^message_ids)
      |> Ash.Query.sort(occurred_at: :asc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)

    version_ids = provenance |> Enum.map(& &1.document_version_id) |> Enum.reject(&is_nil/1)

    document_versions =
      DocumentVersion
      |> Ash.Query.filter(id in ^version_ids)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)

    # The open queue entry, if any, is what makes the curator decision controls
    # meaningful: approve, reject, defer, edit, and merge all act on a queue
    # row, not directly on the statement.
    validation =
      ValidationItem
      |> Ash.Query.filter(
        knowledge_id == ^item.id and
          state in ["pending", "deferred", "awaiting_consent", "escalated"]
      )
      |> Ash.Query.sort(due_at: :asc)
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)
      |> List.first()

    # Curator-only. The read policy behind gate decisions is a plain role check
    # with no filter, so asking as a member raises rather than returning [].
    gate_decisions =
      if Access.can?(actor, :curate) do
        GateDecision
        |> Ash.Query.filter(knowledge_id == ^item.id)
        |> Ash.Query.sort(decided_at: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: current_actor)
      else
        []
      end

    superseded = related_knowledge(account.id, actor, current_actor, [item.supersedes_id], paths)

    successors =
      KnowledgeItem
      |> Ash.Query.filter(supersedes_id == ^item.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)
      |> Enum.filter(&Access.visible_knowledge?(actor, &1))
      |> Enum.map(&with_scope_path(&1, paths))

    related_ids =
      relations
      |> Enum.flat_map(&[&1.source_knowledge_id, &1.target_knowledge_id])
      |> Enum.reject(&(&1 == item.id))

    co_mentioned =
      Store.co_mentioned_knowledge(
        account.id,
        item.id,
        authorized_scope_ids(actor),
        Access.visible_states(actor),
        actor.peer_id,
        @panel_limit
      )

    co_mentions =
      account.id
      |> related_knowledge(actor, current_actor, co_mentioned.ids, paths)
      |> Enum.sort_by(& &1.id)

    %{
      item: with_scope_path(item, paths),
      provenance: provenance,
      attributions: attributions,
      lifecycle: lifecycle,
      relations: relations,
      related: related_knowledge(account.id, actor, current_actor, related_ids, paths),
      co_mentions: co_mentions,
      co_mentions_count: co_mentioned.count,
      co_mentions_truncated?: co_mentioned.count > length(co_mentions),
      messages: messages,
      document_versions: document_versions,
      validation: validation,
      gate_decisions: gate_decisions,
      superseded: List.first(superseded),
      successors: successors,
      scopes: scopes(account.id, current_actor),
      scope_paths: paths
    }
  end

  # Loads the statements a relation or a supersession link points at, dropping
  # any the viewer may not see. A cross-reference to an invisible statement is
  # omitted entirely rather than rendered as a dead id, because the presence of
  # the link would itself disclose that the hidden statement exists.
  defp related_knowledge(_account_id, _actor, _current_actor, [], _paths), do: []

  defp related_knowledge(account_id, actor, current_actor, ids, paths) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      []
    else
      KnowledgeItem
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: current_actor)
      |> Enum.filter(&Access.visible_knowledge?(actor, &1))
      |> Enum.map(&with_scope_path(&1, paths))
    end
  end

  # ----------------------------------------------------------------------------
  # Small shared helpers
  # ----------------------------------------------------------------------------

  defp scopes(account_id, current_actor) do
    Scope
    |> Ash.Query.sort(path: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: current_actor)
  end

  defp scope_paths(scopes), do: Map.new(scopes, &{&1.id, &1.path})

  defp retrieval_health_state(%{statement_count: 0}, _identity, _profile), do: :ready

  defp retrieval_health_state(coverage, identity, profile) do
    cond do
      Enum.any?(coverage.embedding_identities, &(&1 != identity)) -> :identity_mismatch
      coverage.embedded_count < coverage.statement_count -> :missing_embeddings
      coverage.mentioned_statement_count == 0 -> :no_mentions_indexed
      coverage.mentioned_statement_count < coverage.statement_count -> :partial_mention_coverage
      profile.disabled_strategies != [] -> :disabled_strategies
      true -> :ready
    end
  end

  defp entity_match_reason(_account_id, _scope_id, _actor, query_text)
       when query_text in [nil, ""],
       do: nil

  defp entity_match_reason(account_id, scope_id, actor, query_text) do
    MemHouse.Retrieval.Store.entity_match_status(%MemHouse.Retrieval.Query{
      account_id: account_id,
      scope_ids: [scope_id],
      actor: actor,
      text: query_text,
      target: :knowledge
    })
  end

  defp retrieval_health_action(coverage, identity, profile) do
    case retrieval_health_state(coverage, identity, profile) do
      :ready -> nil
      :disabled_strategies -> "enable the disabled retrieval strategies or choose another profile"
      _gap -> "rebuild scope derived data"
    end
  end

  # `:all` is an internal capability, never authority for a browser read. A
  # malformed or widened human actor therefore produces no co-mention ids.
  defp authorized_scope_ids(%Actor{scope_ids: scope_ids}) when is_list(scope_ids), do: scope_ids
  defp authorized_scope_ids(%Actor{}), do: []

  defp with_scope_path(item, paths), do: Map.put(item, :scope_path, Map.get(paths, item.scope_id))

  # Counts with a SQL aggregate rather than by loading rows, so a dashboard tile
  # costs the same on an Account with ten statements and one with ten million.
  # `query` may be a resource module or an already-filtered query; the Ash query
  # functions coerce a module for us.
  defp count(query, account_id, current_actor) do
    query
    |> Ash.Query.set_tenant(account_id)
    |> Ash.count!(actor: current_actor)
  end

  defp about_me_count(account_id, current_actor) do
    if is_binary(current_actor.peer_id) do
      KnowledgeItem
      |> Ash.Query.filter(subject_peer_id == ^current_actor.peer_id and is_nil(deleted_at))
      |> count(account_id, current_actor)
    else
      0
    end
  end

  defp dirty_projection_count(account_id, current_actor) do
    Projection
    |> Ash.Query.filter(dirty == true)
    |> count(account_id, current_actor)
  end

  # Queue depth is shown to curators as the amount of work waiting, and to
  # everyone else as the number of items waiting on *them* — the validation
  # read policy filters a non-curator down to their own subject rows, so the
  # same query answers both questions honestly without a branch.
  defp queue_depth(account_id, %Actor{} = actor, current_actor) do
    if Access.can?(actor, :self_govern) or Access.can?(actor, :curate) do
      ValidationItem
      |> Ash.Query.filter(state in ["pending", "deferred", "awaiting_consent", "escalated"])
      |> count(account_id, current_actor)
    else
      0
    end
  end

  # Turns a scope path into the ids of that scope and everything contained in
  # it, using string prefix on the path — which is how containment is decided
  # everywhere in this system, because a path is written once and never
  # rewritten. `nil` means "no scope filter"; an unknown or unauthorized path
  # yields an empty list, which narrows to nothing rather than widening to
  # everything.
  defp subtree_scope_ids(_scopes, nil), do: nil

  defp subtree_scope_ids(scopes, path) do
    scopes
    |> Enum.filter(
      &(&1.path == path or String.starts_with?(&1.path, ensure_trailing_slash(path)))
    )
    |> Enum.map(& &1.id)
  end

  defp ensure_trailing_slash("/"), do: "/"
  defp ensure_trailing_slash(path), do: path <> "/"

  # Depth of a path in the containment tree: the root "/" is 0, "/team" is 1.
  defp depth("/"), do: 0

  defp depth(path) do
    path |> String.split("/", trim: true) |> length()
  end

  defp page_number(filters) do
    case Integer.parse(to_string(filters["page"] || "1")) do
      {page, _rest} when page > 0 -> page
      _other -> 1
    end
  end

  # Offered sizes only. A hand-typed size is a way to ask the database for the
  # whole table through a browsing surface, and export belongs to the
  # portability archive.
  defp effective_page_size(filters) do
    case Integer.parse(to_string(filters["per_page"] || "")) do
      {size, _rest} when size in @page_sizes -> size
      _other -> @page_size
    end
  end

  defp sort_order(%{"sort" => "recorded"}), do: "recorded"
  defp sort_order(_filters), do: "confidence"

  # Confidence first, then recency: the most strongly held statements lead, and
  # equally confident ones are ordered newest first so a fresh observation is
  # not buried under an old one it agrees with. Sorting by recency inverts the
  # pair rather than dropping confidence, so the order stays total.
  defp sort_terms("recorded"), do: [inserted_at: :desc, confidence: :desc]
  defp sort_terms(_confidence), do: [confidence: :desc, inserted_at: :desc]

  # Paging and sorting change the view, not the population, so neither counts as
  # a filter for the purpose of explaining an empty result.
  defp filtered?(filters) do
    Enum.any?(~w(scope state kind sensitivity target_level subject), fn key ->
      blank_to_nil(filters[key]) != nil
    end)
  end

  # Scopes contained by the selection, excluding the selection itself.
  defp descendant_count(nil, _path), do: nil
  defp descendant_count(_ids, nil), do: nil
  defp descendant_count(ids, _path), do: max(length(ids) - 1, 0)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
