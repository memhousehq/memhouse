# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Skills.Readiness do
  @moduledoc """
  Checks a peer's governed memory against inherited skill requirements.

  The nearest requirement key wins along the root-to-target path. Evaluation uses authorized
  metadata and provenance only: no model, text search, or statement wording.

  Active knowledge and the checked peer's own provisional knowledge may satisfy requirements.
  Expired, due-for-revalidation, and `needs_revalidation` items are stale immediately, independent
  of sweeper timing. Required gaps and missing cards block; preferred gaps warn.

  Elicitation answers must return through raw ingestion and governance. Telemetry is limited to
  report identity, counts, and readiness; never add skill or content fields.
  """

  alias MemHouse.Accounts.Peer
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.LifecycleEvent
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Observability
  alias MemHouse.Observations.Message
  alias MemHouse.Skills.SkillRequirementCard
  alias MemHouse.Topology.Scope

  require Ash.Query

  # Client-facing report contract; changing it requires a documented contract transition.
  @report_version "f9-1"

  # Load unusable states only to distinguish stale knowledge from missing knowledge.
  @readable_states ~w(active provisional needs_revalidation expired)

  @doc """
  Evaluates one skill's requirements for one peer at one scope and returns the gap report.

  `actor` must be a resolved, authenticated actor; the Account comes from that identity and is
  never taken from `attrs`. `attrs` may use string or atom keys and must carry:

  * `"skill"` — the skill key to check. Required.
  * `"scope_id"` or `"scope_path"` — the target scope. Required.
  * `"peer_id"` or `"peer_key"` — who is being checked. Optional when the actor is itself a
    peer, in which case that peer is used.

  Returns a string-keyed report with card versions, effective requirements, satisfied/stale/
  missing statuses, evidence ids, blockers, warnings, readiness, and timestamp. No visible card
  adds a synthetic blocker.

  Raises `ArgumentError` when the skill, the scope, or the peer cannot be determined from
  `attrs`. Raises if an underlying Ash read fails; a scope or peer the caller may not read
  resolves to `nil` and then fails on the subsequent field access rather than silently widening
  the check.
  """
  def check_readiness(actor, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    Observability.with_span(:skills, "memhouse.skills.check_readiness", fn ->
      report =
        DataLayer.with_actor(actor, fn account, current_actor ->
          # Pin all reads to one Account connection; default isolation is not a snapshot.
          scope = scope!(account.id, current_actor, attrs)
          peer = peer!(account.id, current_actor, attrs)
          scopes = ancestor_scopes(account.id, current_actor, scope.path)

          cards =
            account.id
            |> active_cards(current_actor, Enum.map(scopes, & &1.id), attrs)
            |> order_cards(scopes)

          requirements = effective_requirements(cards, scopes)

          knowledge =
            knowledge_candidates(
              account.id,
              current_actor,
              Enum.map(scopes, & &1.id),
              peer.id
            )

          evidence = evidence(account.id, current_actor, knowledge, peer.id)
          build_report(attrs, peer, scope, cards, requirements, knowledge, evidence)
        end)

      # Content-safe telemetry only; never add skill, requirement, prompt, or statement fields.
      Observability.set_attributes(:skills, %{
        "memhouse.readiness.report_version" => @report_version,
        "memhouse.readiness.requirement_count" => length(report["requirements"]),
        "memhouse.readiness.blocker_count" => length(report["blockers"]),
        "memhouse.readiness.warning_count" => length(report["warnings"]),
        "memhouse.readiness.ready" => report["ready"]
      })

      report
    end)
  end

  # Blockers and warnings are views over the same evaluated requirements.
  defp build_report(attrs, peer, scope, cards, requirements, knowledge, evidence) do
    results =
      Enum.map(requirements, fn requirement ->
        evaluate(requirement, knowledge, evidence, peer.id)
      end)

    {blockers, warnings} =
      Enum.reduce(results, {[], []}, fn result, {blockers, warnings} ->
        cond do
          result["status"] == "satisfied" -> {blockers, warnings}
          result["level"] == "required" -> {[result | blockers], warnings}
          true -> {blockers, [result | warnings]}
        end
      end)

    # Missing or invisible contracts fail closed; the reserved key cannot collide with a slug.
    blockers =
      if cards == [] do
        [
          %{
            "key" => "__skill_card__",
            "level" => "required",
            "source_policy" => "from-memory",
            "status" => "missing_card",
            "blocking" => true,
            "message" => "No active skill requirement card is visible for this scope.",
            "elicitation" => %{"allowed" => false}
          }
          | blockers
        ]
      else
        blockers
      end
      |> Enum.reverse()

    warnings = Enum.reverse(warnings)

    %{
      "report_version" => @report_version,
      "skill" => attrs["skill"],
      "peer_id" => peer.id,
      "scope_id" => scope.id,
      "scope_path" => scope.path,
      "ready" => blockers == [],
      "blocked" => blockers != [],
      "cards" => Enum.map(cards, &card_result/1),
      "requirements" => results,
      "blockers" => blockers,
      "warnings" => warnings,
      "checked_at" => DateTime.to_iso8601(Clock.utc_now())
    }
  end

  # Separate metadata matches from freshness so stale differs from missing and may be re-asked.
  defp evaluate(requirement, knowledge, evidence, peer_id) do
    selector = requirement["selector"]

    metadata_matches =
      Enum.filter(
        knowledge,
        &metadata_match?(&1, selector, requirement["source_policy"], evidence, peer_id)
      )

    {fresh, stale} =
      Enum.split_with(
        metadata_matches,
        &fresh?(&1, requirement["freshness"], evidence)
      )

    status =
      cond do
        fresh != [] -> "satisfied"
        stale != [] -> "stale"
        true -> "missing"
      end

    result = %{
      "key" => requirement["key"],
      "description" => requirement["description"],
      "level" => requirement["level"],
      "source_policy" => requirement["source_policy"],
      "selector" => selector,
      "freshness" => requirement["freshness"],
      "status" => status,
      "blocking" => status != "satisfied" and requirement["level"] == "required",
      "matched_knowledge_ids" => Enum.map(fresh, & &1.id),
      "stale_knowledge_ids" => Enum.map(stale, & &1.id),
      "source_scope_id" => requirement["_source_scope_id"],
      "source_scope_path" => requirement["_source_scope_path"],
      "card_version" => requirement["_card_version"]
    }

    if status == "satisfied" do
      Map.put(result, "elicitation", %{"allowed" => false})
    else
      Map.put(result, "elicitation", elicitation(requirement))
    end
  end

  # Clauses are conjunctive; absent clauses match all. Match metadata and provenance, never text.
  defp metadata_match?(item, selector, source_policy, evidence, peer_id) do
    value_match?(item.kind, selector["kind"]) and
      subject_match?(item, selector["subject"], peer_id) and
      value_match?(item.sensitivity, selector["sensitivity"]) and
      value_match?(item.target_level, selector["target_level"]) and
      value_match?(item.verification, selector["verification"]) and
      minimum?(item.confidence, selector["minimum_confidence"]) and
      minimum?(item.corroboration_count, selector["minimum_corroboration"]) and
      source_types_match?(item.id, selector["source_types"], evidence) and
      source_policy_match?(item.id, source_policy, evidence)
  end

  # `ask-peer` requires message provenance from the checked peer.
  defp source_policy_match?(knowledge_id, "ask-peer", evidence),
    do: MapSet.member?(evidence.peer_sourced_ids, knowledge_id)

  defp source_policy_match?(_knowledge_id, _source_policy, _evidence), do: true

  # Recheck lifecycle timestamps at read time. Recency uses the last validation transition, not
  # `updated_at`, so cache maintenance cannot refresh knowledge.
  defp fresh?(item, freshness, evidence) do
    now = Clock.utc_now()

    lifecycle_fresh? =
      item.state in ["active", "provisional"] and
        (is_nil(item.expires_at) or DateTime.compare(item.expires_at, now) == :gt) and
        (is_nil(item.revalidate_after) or DateTime.compare(item.revalidate_after, now) == :gt)

    within_window? =
      case freshness do
        %{"revalidated_within_seconds" => seconds} ->
          cutoff = DateTime.add(now, -seconds, :second)

          case evidence.last_validated_at[item.id] do
            %DateTime{} = validated_at -> DateTime.compare(validated_at, cutoff) in [:gt, :eq]
            nil -> false
          end

        _ ->
          true
      end

    lifecycle_fresh? and within_window?
  end

  # Subject identifies who the claim is about, not who supplied it.
  defp subject_match?(item, "peer", peer_id), do: item.subject_peer_id == peer_id

  defp subject_match?(item, "scope", _peer_id),
    do: is_binary(item.subject_scope_id)

  defp subject_match?(item, "either", peer_id),
    do: item.subject_peer_id == peer_id or is_binary(item.subject_scope_id)

  # Omitted clauses do not constrain; normalized values are lists.
  defp value_match?(_value, nil), do: true
  defp value_match?(value, allowed), do: value in allowed

  defp minimum?(_value, nil), do: true
  defp minimum?(value, minimum), do: value >= minimum

  # Trust durable provenance, not statement fields; any matching source qualifies.
  defp source_types_match?(_knowledge_id, nil, _evidence), do: true

  defp source_types_match?(knowledge_id, source_types, evidence) do
    evidence.source_types
    |> Map.get(knowledge_id, MapSet.new())
    |> MapSet.disjoint?(MapSet.new(source_types))
    |> Kernel.not()
  end

  # This descriptor never writes. Answers must use ingestion and governance before rechecking.
  defp elicitation(%{"source_policy" => source_policy} = requirement)
       when source_policy in ["ask-peer", "either"] do
    %{
      "allowed" => true,
      "prompt" => requirement["prompt"],
      "submit_via" => "ingest",
      "then" => "check_readiness"
    }
  end

  defp elicitation(_requirement), do: %{"allowed" => false}

  # Apply cards root-to-target: nearest keys win, disabled keys tombstone inherited rules, and
  # first-seen order stays stable.
  defp effective_requirements(cards, scopes) do
    scope_paths = Map.new(scopes, &{&1.id, &1.path})

    cards
    |> Enum.sort_by(&String.length(Map.fetch!(scope_paths, &1.scope_id)))
    |> Enum.reduce({%{}, []}, fn card, {requirements, order} ->
      Enum.reduce(card.requirements, {requirements, order}, fn requirement, {merged, keys} ->
        key = requirement["key"]

        if requirement["enabled"] do
          decorated =
            requirement
            |> Map.put("_source_scope_id", card.scope_id)
            |> Map.put("_source_scope_path", Map.fetch!(scope_paths, card.scope_id))
            |> Map.put("_card_version", card.version)

          {Map.put(merged, key, decorated), append_once(keys, key)}
        else
          {Map.delete(merged, key), List.delete(keys, key)}
        end
      end)
    end)
    |> then(fn {requirements, order} -> Enum.map(order, &Map.fetch!(requirements, &1)) end)
  end

  # Use the highest active version per authorized scope; missing visibility eventually fails closed.
  defp active_cards(account_id, actor, scope_ids, %{"skill" => skill}) when is_binary(skill) do
    SkillRequirementCard
    |> Ash.Query.filter(scope_id in ^scope_ids and skill_key == ^skill and active == true)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.scope_id)
    |> Enum.map(fn {_scope_id, cards} -> Enum.max_by(cards, & &1.version) end)
  end

  defp active_cards(_account_id, _actor, _scope_ids, _attrs),
    do: raise(ArgumentError, "skill is required")

  # Authorization runs before matching; only the subject may use provisional knowledge.
  defp knowledge_candidates(account_id, actor, scope_ids, peer_id) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state in ^@readable_states)
    |> Ash.Query.sort(inserted_at: :desc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.filter(fn item ->
      item.state != "provisional" or item.subject_peer_id == peer_id
    end)
  end

  # Batch durable source types, peer authorship, and validation timestamps for all candidates.
  defp evidence(_account_id, _actor, [], _peer_id),
    do: %{source_types: %{}, peer_sourced_ids: MapSet.new(), last_validated_at: %{}}

  defp evidence(account_id, actor, knowledge, peer_id) do
    knowledge_ids = Enum.map(knowledge, & &1.id)

    provenances =
      Provenance
      |> Ash.Query.filter(knowledge_item_id in ^knowledge_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    last_validated_at =
      LifecycleEvent
      |> Ash.Query.filter(
        knowledge_item_id in ^knowledge_ids and to_state in ["active", "provisional"]
      )
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)
      |> Enum.group_by(& &1.knowledge_item_id, & &1.occurred_at)
      |> Map.new(fn {knowledge_id, timestamps} ->
        {knowledge_id, Enum.max(timestamps, DateTime)}
      end)

    message_ids =
      provenances
      |> Enum.map(& &1.message_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    peer_message_ids =
      if message_ids == [] do
        MapSet.new()
      else
        Message
        |> Ash.Query.filter(id in ^message_ids and peer_id == ^peer_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.id)
        |> MapSet.new()
      end

    source_types =
      provenances
      |> Enum.group_by(& &1.knowledge_item_id, & &1.source_type)
      |> Map.new(fn {knowledge_id, types} -> {knowledge_id, MapSet.new(types)} end)

    peer_sourced_ids =
      provenances
      |> Enum.filter(&MapSet.member?(peer_message_ids, &1.message_id))
      |> Enum.map(& &1.knowledge_item_id)
      |> MapSet.new()

    %{
      source_types: source_types,
      peer_sourced_ids: peer_sourced_ids,
      last_validated_at: last_validated_at
    }
  end

  # Return authorized ancestors root-to-target for inheritance.
  defp ancestor_scopes(account_id, actor, path) do
    paths = ancestor_paths(path)

    Scope
    |> Ash.Query.filter(path in ^paths)
    |> Ash.Query.sort(path: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Account-scoped actor reads prevent cross-tenant or unauthorized scope resolution.
  defp scope!(account_id, actor, %{"scope_id" => id}) when is_binary(id) do
    Scope
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope!(account_id, actor, %{"scope_path" => path}) when is_binary(path) do
    Scope
    |> Ash.Query.filter(path == ^normalize_path(path))
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope!(_account_id, _actor, _attrs),
    do: raise(ArgumentError, "scope_id or scope_path is required")

  # Resolve explicit peer id, then key, then actor; provisional access depends on this identity.
  defp peer!(account_id, actor, %{"peer_id" => id}) when is_binary(id) do
    Peer
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp peer!(account_id, actor, %{"peer_key" => key}) when is_binary(key) do
    Peer
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp peer!(account_id, %{peer_id: peer_id} = actor, _attrs) when is_binary(peer_id) do
    peer!(account_id, actor, %{"peer_id" => peer_id})
  end

  defp peer!(_account_id, _actor, _attrs),
    do: raise(ArgumentError, "peer_id or peer_key is required")

  # Return card identity only; effective requirements are reported separately.
  defp card_result(card) do
    %{
      "id" => card.id,
      "scope_id" => card.scope_id,
      "version" => card.version,
      "requirement_schema_version" => card.requirement_schema_version
    }
  end

  # Report cards root-first along the inheritance path.
  defp order_cards(cards, scopes) do
    order =
      scopes
      |> Enum.with_index()
      |> Map.new(fn {scope, index} -> {scope.id, index} end)

    Enum.sort_by(cards, &Map.fetch!(order, &1.scope_id))
  end

  # Include root explicitly because path splitting discards it.
  defp ancestor_paths(path) do
    path
    |> normalize_path()
    |> String.split("/", trim: true)
    |> Enum.scan("", fn segment, prefix -> prefix <> "/" <> segment end)
    |> then(&["/" | &1])
  end

  # Canonical path: one leading slash, no trailing slash, root unchanged.
  defp normalize_path(path) do
    normalized = "/" <> (path |> to_string() |> String.trim() |> String.trim("/"))
    if normalized == "/", do: "/", else: normalized
  end

  # Overrides retain the key's first report position.
  defp append_once(keys, key), do: if(key in keys, do: keys, else: keys ++ [key])
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
