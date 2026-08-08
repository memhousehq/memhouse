# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.Builder do
  @moduledoc """
  Rebuilds one scope's derived cards, peer-profile slices, and session summaries.

  Background refresh may use the model-backed `:thorough` profile; request-time context assembly
  remains model-free. Projections are rebuildable caches written by the internal pipeline.

  Refresh uses a short read transaction, performs ranking and summary calls without holding a
  database connection, then writes every projection in one short transaction. A model failure
  therefore leaves the prior projection set intact for job retry.

  A failed entity-card summary is the exception: it degrades that one card instead of failing the
  refresh, because the caller's rebuild has already committed embeddings and entity resolution
  that a raise here would force it to redo.

  Entity-card summaries run with bounded concurrency. One scope holds many qualifying entity
  clusters and each costs a separate provider call, so a serial pass makes the scope wait for the
  sum of those calls rather than the slowest one.

  `mark_dirty/3` must share the lifecycle-change transaction; otherwise stale content could remain
  readable. Both operations invalidate node-local copies cluster-wide. Incremental merges are
  capped and periodically compacted to bound growth and drift.
  """

  alias MemHouse.Clock
  alias MemHouse.Context.Cache
  alias MemHouse.Context.EntityLabel
  alias MemHouse.Context.ProjectionKey
  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.{EntityMention, KnowledgeItem, Projection}
  alias MemHouse.Model.Config
  alias MemHouse.Model.Gateway
  alias MemHouse.Observations.Session
  alias MemHouse.Retrieval.Query
  alias MemHouse.Topology.Scope

  require Ash.Query
  require Logger

  # Unit: distinct governed statements. A single mention identifies nothing a reader could not
  # get from the statement itself, so two sources is the point at which a card starts to say
  # something the sources do not say separately.
  @entity_card_min_sources 2

  # Unit: distinct governed statements. Held above the card threshold because a summary is the
  # only part of a card that can cost a model call, and a pair rarely yields a brief worth that
  # call. Applied whatever the provider: the deterministic path concatenates sources for free,
  # but exempting it would give offline nodes different content from the same release.
  @entity_card_summary_min_sources 3

  # Unit: Unicode characters. Entity cards prime a turn rather than replace search, so one short
  # paragraph leaves most of the context budget for governed statements and other projections.
  @entity_card_summary_chars 600

  @doc """
  Rebuilds every projection belonging to one scope and clears their dirty flags.

  Runs as the internal pipeline actor. Shared scope cards, entity cards, and session
  summaries contain active statements only. A subject's peer-profile slice additionally contains
  that subject's provisional statements. Soft-deleted rows are excluded from every projection.

  Returns `{:ok, map}` with the scope card's id, the number of entity card, peer profile, and
  session summary projections written, and `entity_card_summaries_unavailable`: cards that earned
  a summary but whose model call failed. Raises if the transaction fails or an underlying Ash call
  fails.

  Replays are safe because projections are upserted by cache key.
  """
  def refresh_scope(account_id, scope_id) do
    {scope, scope_knowledge, peer_knowledge, mentions, actor} =
      read_scope!(account_id, scope_id)

    scope_knowledge = dream_rank(scope_knowledge, scope, account_id, actor)
    peer_knowledge = dream_rank(peer_knowledge, scope, account_id, actor)

    entity_attrs =
      build_entity_card_attrs!(scope, scope_knowledge, mentions, account_id, actor)

    write_projections!(account_id, scope, scope_knowledge, peer_knowledge, entity_attrs)
  end

  # Phase one reads one consistent source snapshot and returns the plain actor for the model phase.
  # The actor is immutable authorization data and remains valid after this transaction closes.
  defp read_scope!(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        scope = read_one!(Scope, scope_id, account_id, actor)

        # Shared projections may only contain settled knowledge. Provisional rows are read
        # separately for the subject-keyed peer channel below.
        scope_knowledge =
          KnowledgeItem
          |> Ash.Query.filter(scope_id == ^scope_id and state == "active" and is_nil(deleted_at))
          |> Ash.Query.sort(confidence: :desc, updated_at: :desc)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        peer_knowledge =
          KnowledgeItem
          |> Ash.Query.filter(
            scope_id == ^scope_id and state in ["active", "provisional"] and
              not is_nil(subject_peer_id) and is_nil(deleted_at)
          )
          |> Ash.Query.sort(confidence: :desc, updated_at: :desc)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        mentions =
          EntityMention
          |> Ash.Query.filter(scope_id == ^scope.id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        {scope, scope_knowledge, peer_knowledge, mentions, actor}
      end
    )
  end

  # Phase three commits the projection set. No provider call may be added to this callback: a
  # slow external request here would hold a pooled connection and could discard billed work.
  defp write_projections!(account_id, scope, scope_knowledge, peer_knowledge, entity_attrs) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        entity_projections =
          Enum.map(entity_attrs, &upsert_projection!(account_id, actor, &1))

        retire_stale_entity_cards!(
          account_id,
          actor,
          scope.id,
          MapSet.new(entity_projections, & &1.entity_id)
        )

        scope_projection =
          upsert_projection!(
            account_id,
            actor,
            %{
              cache_key: ProjectionKey.scope(scope.id),
              scope_id: scope.id,
              kind: "scope_card",
              content: %{
                "scope_id" => scope.id,
                "path" => scope.path,
                "name" => scope.name,
                "knowledge" => Enum.map(scope_knowledge, &knowledge_map/1)
              },
              source_ids: Enum.map(scope_knowledge, & &1.id)
            }
          )

        # Group profiles by statement subject, not source.
        peer_projections =
          peer_knowledge
          |> Enum.group_by(& &1.subject_peer_id)
          |> Enum.map(fn {peer_id, items} ->
            upsert_projection!(
              account_id,
              actor,
              %{
                cache_key: ProjectionKey.peer(scope.id, peer_id),
                scope_id: scope.id,
                peer_id: peer_id,
                kind: "peer_profile",
                content: %{"knowledge" => Enum.map(items, &knowledge_map/1)},
                source_ids: Enum.map(items, & &1.id)
              }
            )
          end)

        # Session summaries are scope-level warm starts, not message-history summaries.
        session_projections =
          Session
          |> Ash.Query.filter(scope_id == ^scope.id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)
          |> Enum.map(fn session ->
            upsert_projection!(
              account_id,
              actor,
              %{
                cache_key: ProjectionKey.session(scope.id, session.id),
                scope_id: scope.id,
                peer_id: session.peer_id,
                session_id: session.id,
                kind: "session_summary",
                content: %{
                  "session_id" => session.id,
                  "status" => session.status,
                  "knowledge" => Enum.map(scope_knowledge, &knowledge_map/1)
                },
                source_ids: Enum.map(scope_knowledge, & &1.id)
              }
            )
          end)

        # Evict stale copies on every node.
        Cache.invalidate_scope(account_id, scope.id)

        {:ok,
         %{
           scope_card: scope_projection.id,
           entity_cards: length(entity_projections),
           entity_card_summaries_unavailable: count_unavailable_summaries(entity_attrs),
           peer_profiles: length(peer_projections),
           session_summaries: length(session_projections)
         }}
      end
    )
  end

  # EntityMention is only an internal grouping index. The card stores the id as a private cache
  # coordinate, while its visible content is built exclusively from governed statement fields.
  defp build_entity_card_attrs!(scope, knowledge, mentions, account_id, actor) do
    active_by_id =
      knowledge
      |> Enum.filter(&(&1.state == "active"))
      |> Map.new(&{&1.id, &1})

    mentions
    |> Enum.group_by(& &1.entity_id)
    |> Enum.flat_map(&entity_card_cluster(&1, active_by_id, knowledge))
    |> summarize_clusters(scope, account_id, actor)
    |> Enum.map(&entity_card_attrs(&1, scope))
  end

  # Everything a card needs that costs no provider call. Keeping this phase separate is what lets
  # the summary calls below overlap.
  defp entity_card_cluster({entity_id, mentions}, active_by_id, knowledge) do
    items =
      mentions
      |> Enum.map(&Map.get(active_by_id, &1.knowledge_item_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    if length(items) < @entity_card_min_sources do
      []
    else
      items = preserve_rank(items, knowledge)

      # Only forms carried by statements that became sources of this card. A mention whose
      # statement was dropped as inactive must not name the card.
      source_ids = MapSet.new(items, & &1.id)

      forms =
        mentions
        |> Enum.filter(&MapSet.member?(source_ids, &1.knowledge_item_id))
        |> Enum.map(& &1.surface_form)

      [%{entity_id: entity_id, items: items, forms: forms}]
    end
  end

  # `ordered: true` keeps the card order a serial pass produced, so a rebuild stays reproducible.
  # No deadline is imposed here: the model layer already caps each call, and a second deadline
  # would kill the task instead of letting the call degrade into a readable card. A summary call
  # that raises rather than degrades therefore reaches the caller as a task exit instead of the
  # original exception; both fail the refresh, and replay is the recovery path either way.
  defp summarize_clusters(clusters, scope, account_id, actor) do
    summarize = fn cluster ->
      Map.put(cluster, :summary, entity_summary!(cluster.items, scope.id, account_id, actor))
    end

    case summary_concurrency() do
      1 ->
        Enum.map(clusters, summarize)

      limit ->
        clusters
        |> Task.async_stream(summarize,
          ordered: true,
          max_concurrency: limit,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, cluster} -> cluster end)
    end
  end

  # Unit: provider calls in flight per scope rebuild. Bounded rather than unbounded because these
  # calls share one outbound connection pool with the ingest lane, and each also takes a database
  # connection of its own to resolve the role and append its usage row. `Governance.Erasure` calls
  # this refresh from inside its own transaction, so the limit must stay well under the database
  # pool or those tasks would wait on the caller that is waiting on them. One means serial, which
  # is what the single-connection test sandbox needs.
  defp summary_concurrency do
    Application.get_env(:memhouse, :entity_card_summary_concurrency, 4)
  end

  defp entity_card_attrs(cluster, scope) do
    {summary, provenance, mode} = cluster.summary
    sensitivity = strictest_sensitivity(cluster.items)

    %{
      cache_key: "entity:#{scope.id}:#{cluster.entity_id}",
      scope_id: scope.id,
      entity_id: cluster.entity_id,
      kind: "entity_card",
      sensitivity: sensitivity,
      content: %{
        "scope_id" => scope.id,
        "label" => EntityLabel.label(cluster.forms),
        "kind" => EntityLabel.kind(cluster.forms),
        "summary" => summary,
        "summary_mode" => mode,
        "summary_provenance" => provenance && stringify_keys(provenance),
        "sensitivity" => sensitivity,
        "knowledge" => Enum.map(cluster.items, &knowledge_map/1)
      },
      source_ids: Enum.map(cluster.items, & &1.id)
    }
  end

  # A merge, split, retraction, or erasure can leave a formerly useful card below
  # `@entity_card_min_sources`. Keep the rebuildable row for replay, but make it unreadable until
  # enough active sources exist again and a later upsert clears the flag.
  defp retire_stale_entity_cards!(account_id, actor, scope_id, current_entity_ids) do
    Projection
    |> Ash.Query.filter(scope_id == ^scope_id and kind == "entity_card")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.reject(&MapSet.member?(current_entity_ids, &1.entity_id))
    |> Enum.each(fn projection ->
      projection
      |> Ash.Changeset.for_update(:refresh_from_pipeline, %{dirty: true})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor, authorize?: false)
    end)
  end

  # A pair gets a card but no summary, so the caller must treat all three summary fields as
  # optional. The threshold is checked here rather than at the call site to keep the "when does a
  # provider get called" question answerable from one place.
  defp entity_summary!(items, _scope_id, _account_id, _actor)
       when length(items) < @entity_card_summary_min_sources,
       do: {nil, nil, "none"}

  defp entity_summary!(items, scope_id, account_id, actor) do
    context = %{account_id: account_id, actor: actor}
    config = MemHouse.Model.role_config(:dream_reasoner, context)

    if Gateway.provider_module(config, context) == MemHouse.Model.Providers.Deterministic do
      {grounded_summary(items), Config.provenance(config), "source_extract"}
    else
      messages = [
        %{
          role: "system",
          content:
            "Summarize only the governed statements supplied by the user. " <>
              "They concern one resolved referent. Preserve qualifications and disagreements, " <>
              "make no new claims, and return one concise paragraph of at most " <>
              "#{@entity_card_summary_chars} characters."
        },
        %{
          role: "user",
          content: Jason.encode!(%{"statements" => Enum.map(items, & &1.statement)})
        }
      ]

      case MemHouse.Model.chat(:dream_reasoner, messages, context, task: :entity_card) do
        {:ok, summary, provenance} when is_binary(summary) and summary != "" ->
          {String.slice(String.trim(summary), 0, @entity_card_summary_chars), provenance, "model"}

        {:ok, _summary, _provenance} ->
          unavailable_summary(account_id, scope_id, "empty_text")

        {:error, reason} ->
          unavailable_summary(account_id, scope_id, error_class(reason))
      end
    end
  end

  # One provider call per qualifying cluster means a scope with many entities is near-certain to
  # meet a timeout eventually. Raising here would discard the embeddings and entity resolution the
  # same rebuild already committed, so the card falls back to the shape a two-source card already
  # produces and the next refresh retries the call. The card stays readable rather than dirty: its
  # label and governed statements are unaffected by the missing brief, and hiding them would lose
  # more than the summary is worth. Content-safe fields only; the provider's own error detail is
  # already recorded by the model layer.
  defp unavailable_summary(account_id, scope_id, error_class) do
    Logger.warning("entity card summary unavailable",
      account_id: account_id,
      scope_id: scope_id,
      error_class: error_class
    )

    {nil, nil, "unavailable"}
  end

  defp count_unavailable_summaries(entity_attrs) do
    Enum.count(entity_attrs, &(&1.content["summary_mode"] == "unavailable"))
  end

  defp error_class(%module{}), do: inspect(module)
  defp error_class(error) when is_atom(error), do: Atom.to_string(error)
  defp error_class(_error), do: "model_error"

  defp grounded_summary(items) do
    items
    |> Enum.map_join(" ", & &1.statement)
    |> String.slice(0, @entity_card_summary_chars)
  end

  defp preserve_rank(items, ranked_knowledge) do
    ids = MapSet.new(items, & &1.id)
    Enum.filter(ranked_knowledge, &MapSet.member?(ids, &1.id))
  end

  defp strictest_sensitivity(items) do
    rank = %{"public" => 0, "internal" => 1, "personal" => 2, "restricted" => 3}
    items |> Enum.max_by(&Map.fetch!(rank, &1.sensitivity)) |> Map.fetch!(:sensitivity)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @doc """
  Marks every projection in a scope as unusable and evicts the in-memory copies.

  Leaves content unchanged because reads reject dirty rows. Call inside the lifecycle-change
  transaction with an internal pipeline actor so invalidation commits atomically.

  Returns `:ok`. Raises if a read or update fails.
  """
  def mark_dirty(account_id, actor, scope_id) do
    Projection
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn projection ->
      projection
      |> Ash.Changeset.for_update(:refresh_from_pipeline, %{dirty: true})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor, authorize?: false)
    end)

    Cache.invalidate_scope(account_id, scope_id)
  end

  # Compact when the merge budget expires. Pipeline writes bypass policy after authorized reads,
  # but every changeset remains Account-tenanted.
  defp upsert_projection!(account_id, actor, attrs) do
    existing =
      Projection
      |> Ash.Query.filter(cache_key == ^attrs.cache_key)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    compaction_every = retrieval_config(:projection_compaction_every)
    compact? = is_nil(existing) or existing.delta_count + 1 >= compaction_every

    {content, source_ids, delta_count} =
      if existing && not compact? do
        {
          merge_content(existing.content, attrs.content, attrs.source_ids),
          attrs.source_ids,
          existing.delta_count + 1
        }
      else
        {attrs.content, attrs.source_ids, 0}
      end

    create_attrs =
      attrs
      |> Map.merge(%{
        version: (existing && existing.version + 1) || 1,
        content: content,
        source_ids: source_ids,
        dirty: false,
        watermark: Clock.utc_now(),
        delta_count: delta_count
      })

    Projection
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:upsert_from_pipeline, create_attrs)
    |> Ash.create!(actor: actor, authorize?: false)
  end

  # Retain only current source ids, then append new items. The 100-statement cap bounds projection
  # growth between full compactions; larger reads belong in retrieval.
  defp merge_content(old, new, current_source_ids) do
    current_source_ids = MapSet.new(current_source_ids)

    Map.merge(old, new, fn
      "knowledge", old_items, new_items ->
        (Enum.filter(old_items, &MapSet.member?(current_source_ids, &1["id"])) ++ new_items)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.take(100)

      _key, _old_value, new_value ->
        new_value
    end)
  end

  # Allowlist projection fields; never expose vectors, entities, or internal bookkeeping.
  defp knowledge_map(item) do
    %{
      "id" => item.id,
      "scope_id" => item.scope_id,
      "statement" => item.statement,
      "kind" => item.kind,
      "confidence" => item.confidence,
      "sensitivity" => item.sensitivity,
      "state" => item.state,
      "source_message_ids" => item.source_message_ids,
      "extracting_model" => item.extracting_model,
      "pipeline_version" => item.pipeline_version
    }
  end

  # Background ranking has no deadline and stays serial outside the read and write transactions.
  # Append unranked statements so reranking never drops content.
  defp dream_rank([], _scope, _account_id, _actor), do: []

  defp dream_rank(knowledge, scope, account_id, actor) do
    query = %Query{
      account_id: account_id,
      actor: actor,
      scope_ids: [scope.id],
      text: "#{scope.name} context",
      target: :knowledge,
      max_candidates: max(length(knowledge), 1)
    }

    ranked_ids =
      query
      |> MemHouse.Retrieval.retrieve(:thorough,
        deadline?: false,
        concurrent?: false,
        internal?: true
      )
      |> Map.fetch!(:candidates)
      |> Enum.map(& &1["id"])

    by_id = Map.new(knowledge, &{&1.id, &1})
    ranked = Enum.map(ranked_ids, &Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
    ranked ++ Enum.reject(knowledge, &(&1.id in ranked_ids))
  end

  defp read_one!(resource, id, account_id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  # Missing compaction configuration is a deployment error; do not change drift bounds silently.
  defp retrieval_config(key) do
    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
