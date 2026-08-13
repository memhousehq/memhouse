# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context do
  @moduledoc """
  Assembles the context payload an agent reads at the start of a turn, without calling a model.

  For authorized scopes, it combines session summary, scope cards, entity cards, the caller's
  peer-profile slice, and governed knowledge within a character budget.

  ## Reasoning-free by construction

  Normal assembly performs no generation, reranking, or adjudication. When projections contain
  no pinned facts, it may run the `:fast` retrieval profile without reranking and reports
  `"fast_fallback" => true`.

  ## What can be read

  Database reads use the actor and Account tenant. Cache keys include Account; scope ids were
  already authorized. Dirty projections are excluded because they may retain rejected,
  superseded, or erased statements.

  ## Budget

  The character budget is spent in a fixed order — session summary, peer profile slices, scope
  cards, entity cards, then knowledge. The order preserves the established conversation, person,
  and place guarantees before adding entity briefs; individual statements remain last.

  ## Mistakes to avoid

  * Do not add a model call, a rerank, or an entity lookup to this path.
  * Do not relax the `dirty == false` filter to raise the cache hit rate.
  * Do not expose entity rows, canonical names, aliases, or entity ids here. A card's `label` and
    `kind` are precomputed by the pipeline from that card's own in-scope sources; this module
    passes them through and must never derive them from the entity cache.
  """

  alias MemHouse.Context.Cache
  alias MemHouse.Context.ProjectionKey
  alias MemHouse.Knowledge.Projection
  alias MemHouse.Observations.Session
  alias MemHouse.Retrieval.Query

  require Ash.Query

  # Unit: cards per authorized scope. Entity cards are spent before governed statements, and the
  # budget stops at the first value that does not fit, so an unbounded list of cheap cards would
  # push ranked knowledge out of the payload entirely. The mention spotter fires on every
  # capitalised token, which makes that a real shape rather than a worst case.
  @entity_cards_per_scope 8

  @doc """
  Builds one context payload for an already-authenticated caller.

  `account` is the resolved Account, `actor` the resolved caller, and `scopes` the Scope structs
  the caller may read, nearest first. The actor's `peer_id` is the reader: it selects which peer
  profile slice is included and which statements the live fallback may return.
  `internal_reader?` lifts that reader restriction for server-side work that must see the whole
  corpus; it is never derived from `attrs`. `attrs` is the string-keyed request map and may carry `"session_id"`
  (either the internal id or the caller-supplied external id), `"query"` and `"limit"` which are
  used only if the live fallback runs, and `"budget_chars"` to override the configured default
  budget.

  Returns a string-keyed map with `"profile_version"`, `"session_summary"`, `"scope_cards"`,
  `"entity_cards"`, `"peer_profile"`, `"knowledge"`, `"projection_cache_hit"`, and
  `"fast_fallback"`.
  `"projection_cache_hit"` reports whether at least one projection was served from the
  node-local in-memory cache rather than re-read from the database; `"fast_fallback"` reports
  whether no projection carried knowledge and a live retrieval pass filled the gap.

  Raises if an underlying Ash read fails. Authorization is applied as a read filter, so an
  Account or scope the caller may not read yields no row rather than an error.

  `"profile_version"` is the identity of the retrieval-and-context contract, currently `f7-1`.
  It versions the shape and semantics of search, ask, and context payloads. Changing the string
  is a deliberate contract transition: callers key off it, the HTTP controller tests pin it,
  and a change needs a changelog entry alongside the updated baseline evidence.
  """
  def get(account, actor, scopes, attrs, internal_reader?) do
    scope_ids = Enum.map(scopes, & &1.id)
    session_id = resolve_session_id(account.id, actor, scope_ids, attrs["session_id"])

    # Peerless non-internal readers should not receive cached projections that contain internal
    # content. Skip projection reads for them and use the live fallback instead.
    public_only? = not internal_reader? and not is_binary(actor.peer_id)

    {scope_cards, scope_hits} =
      if public_only?, do: {[], 0}, else: scope_cards(account.id, actor, scopes)

    {peer_profiles, peer_hits} =
      if public_only?, do: {[], 0}, else: peer_profiles(account.id, actor, scopes)

    {entity_cards, entity_hits} =
      if public_only?, do: {[], 0}, else: entity_cards(account.id, actor, scopes)

    {session_summary, session_hit} =
      if public_only?,
        do: {nil, false},
        else: session_summary(account.id, actor, scopes, session_id)

    projection_knowledge =
      projection_knowledge(scope_cards, peer_profiles, entity_cards)

    {knowledge, fallback?} =
      knowledge(account.id, actor, scope_ids, attrs, projection_knowledge, internal_reader?)

    budget = parse_int(Map.get(attrs, "budget_chars"), retrieval_config(:context_budget_chars))

    {summary, profiles, cards, entity_cards, knowledge} =
      fit_budget(
        session_summary,
        List.flatten(peer_profiles),
        Enum.reject(scope_cards, &is_nil/1),
        List.flatten(entity_cards),
        knowledge,
        budget
      )

    %{
      "profile_version" => "f7-1",
      "session_summary" => summary,
      "scope_cards" => cards,
      "entity_cards" => entity_cards,
      "peer_profile" => profiles,
      "knowledge" => knowledge,
      "projection_cache_hit" =>
        scope_hits + peer_hits + entity_hits + if(session_hit, do: 1, else: 0) > 0,
      "fast_fallback" => fallback?
    }
  end

  # The grouping coordinate remains private. Context reads all clean cards for one authorized
  # scope and returns only their content, ordered by source coverage and confidence. The list is
  # cached under a synthetic scope key so repeated requests do not enumerate projection rows.
  defp entity_cards(account_id, actor, scopes) do
    Enum.map_reduce(scopes, 0, fn scope, hits ->
      cache_key = {account_id, scope.id, "entity_cards"}

      case Cache.fetch(cache_key) do
        {:ok, cards} ->
          {cards, hits + if(cards == [], do: 0, else: 1)}

        :error ->
          cards =
            Projection
            |> Ash.Query.filter(
              scope_id == ^scope.id and kind == "entity_card" and dirty == false
            )
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.sort_by(&entity_card_order/1, :desc)
            |> Enum.take(@entity_cards_per_scope)
            |> Enum.map(& &1.content)

          Cache.put(cache_key, cards)
          {cards, hits}
      end
    end)
  end

  # Ordered by source coverage, then by label so equally-supported cards keep a stable order.
  # Label before cache key matters: the key holds the
  # entity UUID, which re-resolution can change, and the per-scope cap would otherwise make that
  # churn visible as cards appearing and disappearing between requests.
  defp entity_card_order(projection) do
    {length(projection.source_ids), projection.content["label"] || "", projection.cache_key}
  end

  # One card per authorized scope, in the order the caller's scopes were resolved (nearest
  # first). A scope with no clean projection contributes `nil`, which is filtered out later; it
  # is not an error, it means the refresh job has not built that card yet or the card is dirty.
  defp scope_cards(account_id, actor, scopes) do
    Enum.map_reduce(scopes, 0, fn scope, hits ->
      {projection, hit?} = projection(account_id, actor, scope.id, ProjectionKey.scope(scope.id))
      content = projection && projection.content
      {content, hits + if(hit?, do: 1, else: 0)}
    end)
  end

  # A peer profile slice is only ever the *calling* peer's own slice: the cache key is built
  # from `actor.peer_id`, never from a request parameter. An actor without a peer id (a machine
  # or system caller acting for no one) gets no profile rather than someone else's.
  defp peer_profiles(_account_id, %{peer_id: peer_id}, _scopes)
       when not is_binary(peer_id),
       do: {[], 0}

  defp peer_profiles(account_id, actor, scopes) do
    Enum.map_reduce(scopes, 0, fn scope, hits ->
      {projection, hit?} =
        projection(account_id, actor, scope.id, ProjectionKey.peer(scope.id, actor.peer_id))

      content = projection && projection.content
      {content || [], hits + if(hit?, do: 1, else: 0)}
    end)
  end

  # At most one session summary is returned: the nearest scope that has a summary for this
  # session wins, because the scopes arrive nearest-first and `find_value` stops there.
  defp session_summary(_account_id, _actor, _scopes, nil), do: {nil, false}

  defp session_summary(account_id, actor, scopes, session_id) do
    Enum.find_value(scopes, {nil, false}, fn scope ->
      case projection(account_id, actor, scope.id, ProjectionKey.session(scope.id, session_id)) do
        {nil, false} -> nil
        {projection, hit?} -> {projection.content, hit?}
      end
    end)
  end

  # Pinned facts make a projection inspectable without duplicating its full governed source set.
  # Deduplicate them by statement id so a claim in several summaries is not billed twice.
  defp projection_knowledge(scope_cards, peer_profiles, entity_cards) do
    (Enum.flat_map(scope_cards, &Map.get(&1 || %{}, "pinned_facts", [])) ++
       (peer_profiles
        |> List.flatten()
        |> Enum.flat_map(&Map.get(&1 || %{}, "pinned_facts", []))) ++
       (entity_cards
        |> List.flatten()
        |> Enum.flat_map(&Map.get(&1, "pinned_facts", []))))
    |> Enum.uniq_by(& &1["id"])
  end

  # The live fallback is entered only when the projections yielded no statement at all. Any
  # projection knowledge, however small, is preferred over a fresh retrieval pass, because the
  # point of this call is to stay off the retrieval path on the per-turn latency budget.
  defp knowledge(
         _account_id,
         _actor,
         _scope_ids,
         _attrs,
         [_ | _] = projection_knowledge,
         _internal?
       ),
       do: {projection_knowledge, false}

  defp knowledge(account_id, actor, scope_ids, attrs, [], internal_reader?) do
    query = %Query{
      account_id: account_id,
      actor: actor,
      scope_ids: scope_ids,
      text: Map.get(attrs, "query", ""),
      target: :knowledge,
      # Unit: candidate statements. A deliberately small default: this is a warm-start context
      # payload, not a search result, and it still has to fit the character budget below.
      max_candidates: parse_int(Map.get(attrs, "limit"), 8),
      internal_reader?: internal_reader?
    }

    # `:fast` is the only profile named on this path. As shipped it runs no rerank and
    # therefore makes no model call, which keeps the "context assembly never reasons" guarantee
    # true even on a projection miss; a stored profile override that switched reranking on for
    # `:fast` would break that. Restricting the target to knowledge keeps document chunks out
    # of a payload whose consumers treat every entry as a governed statement.
    result = MemHouse.Retrieval.retrieve(query, :fast)
    {result.candidates, true}
  end

  # Two-level read: the node-local in-memory cache first, then the database. The database query
  # excludes `dirty` rows, so a projection invalidated by a lifecycle change reads as absent
  # rather than as slightly out of date, and only clean rows are ever placed in the cache. The
  # boolean in the return says "served from memory", which is what the caller reports as
  # `projection_cache_hit`.
  defp projection(account_id, actor, scope_id, cache_key) do
    ets_key = {account_id, scope_id, cache_key}

    case Cache.fetch(ets_key) do
      {:ok, projection} ->
        {projection, true}

      :error ->
        projection =
          Projection
          |> Ash.Query.filter(cache_key == ^cache_key and dirty == false)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read_one!(actor: actor)

        if projection, do: Cache.put(ets_key, projection)
        {projection, false}
    end
  end

  # Callers may name a session either by its internal id or by the external id they chose. A
  # value that parses as a UUID is tried as both, since an external id is free-form text and
  # could legitimately look like one. The lookup is always constrained to the caller's
  # authorized scopes, so naming a session in a scope the caller cannot read yields nil.
  defp resolve_session_id(_account_id, _actor, _scope_ids, nil), do: nil

  defp resolve_session_id(account_id, actor, scope_ids, external_or_id) do
    query =
      case Ecto.UUID.cast(external_or_id) do
        {:ok, id} ->
          Ash.Query.filter(
            Session,
            scope_id in ^scope_ids and (id == ^id or external_id == ^external_or_id)
          )

        :error ->
          Ash.Query.filter(Session, scope_id in ^scope_ids and external_id == ^external_or_id)
      end

    query
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> nil
      session -> session.id
    end
  end

  # Spending order is the priority order and must not be rearranged: the session summary is
  # reserved first, then the caller's profile slices, scope cards, entity cards, and individual
  # statements. A tight budget therefore keeps the conversation, person, and place before the
  # newer entity briefs and least-specific material.
  defp fit_budget(summary, profiles, cards, entity_cards, knowledge, budget) do
    {summary, remaining} = reserve(summary, budget)
    {profiles, remaining} = take_values(profiles, remaining)
    {cards, remaining} = take_values(cards, remaining)
    {entity_cards, remaining} = take_values(entity_cards, remaining)
    {knowledge, _remaining} = take_values(knowledge, remaining)
    {summary, profiles, cards, entity_cards, knowledge}
  end

  defp reserve(nil, budget), do: {nil, budget}

  defp reserve(value, budget) do
    size = encoded_size(value)
    if size <= budget, do: {value, budget - size}, else: {nil, budget}
  end

  # Stops at the first value that does not fit rather than skipping it and trying the next one.
  # The lists arrive in relevance order, so a contiguous prefix is a truthful "top N"; cherry
  # picking whichever later entries happened to be small would silently reorder relevance.
  defp take_values(values, budget) do
    {kept, remaining} =
      Enum.reduce_while(values, {[], budget}, fn value, {kept, remaining} ->
        size = encoded_size(value)

        if size <= remaining do
          {:cont, {[value | kept], remaining - size}}
        else
          {:halt, {kept, remaining}}
        end
      end)

    {Enum.reverse(kept), remaining}
  end

  # The budget is expressed in characters but measured as the byte size of the JSON encoding of
  # the value, including its keys and punctuation. For multi-byte text that over-counts
  # characters, so the budget is never overspent in the unit it is named in. The response
  # envelope's own keys are not counted against it.
  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  # Budget and limit arrive from an HTTP request, so a string is normal and garbage is
  # expected. Anything that is not a positive integer falls back to the default instead of
  # raising: a malformed hint should not fail an agent's turn.
  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp parse_int(_value, default), do: default

  # Deliberately `fetch!` on both levels: a missing retrieval configuration key is a deployment
  # error that should surface at the first request, not be papered over with a silent default
  # that changes how much context every caller receives.
  defp retrieval_config(key) do
    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
