# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.LineageIdentityProfileTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Accounts.Peer
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation}
  alias MemHouse.Memory
  alias MemHouse.Topology.Scope

  require Ash.Query

  test "lineage is deterministic, bounded, typed, cycle-safe, and reasoning-free" do
    first = seed_active!("lineage-cycle", "Avery lives in Helsinki.", "first")
    second = seed_active!("lineage-cycle", "Avery works as an engineer.", "second")

    relation!(first, second, "derived_from")
    relation!(second, first, "supports")

    attrs = %{
      "account_key" => "lineage-cycle",
      "peer_key" => "avery",
      "scope_path" => first.scope.path,
      "target_id" => first.knowledge.id,
      "max_depth" => 4,
      "max_fan_out" => 8,
      "max_nodes" => 20
    }

    assert {:ok, lineage} = Memory.evidence_lineage(attrs)
    assert {:ok, ^lineage} = Memory.evidence_lineage(attrs)

    assert lineage["lineage_version"] == "evidence-lineage-v1"
    assert lineage["terminations"]["cycle"] > 0
    assert hd(lineage["nodes"])["operation"] == "derivation"
    assert hd(lineage["nodes"])["derivation_level"] == 2
    assert Enum.any?(lineage["nodes"], &(&1["type"] == "knowledge"))
    assert Enum.any?(lineage["nodes"], &(&1["type"] == "message"))

    assert Enum.all?(lineage["nodes"], fn node ->
             is_binary(node["id"]) and is_integer(node["derivation_level"]) and
               is_binary(node["operation"]) and is_list(node["source_references"])
           end)

    encoded = Jason.encode!(lineage)
    refute encoded =~ "Helsinki"
    refute encoded =~ "engineer"
    refute encoded =~ "prompt"
    refute encoded =~ "rationale"

    assert {:ok, direct} =
             Memory.evidence_lineage(%{
               "account_key" => "lineage-cycle",
               "peer_key" => "avery",
               "scope_path" => first.scope.path,
               "target_type" => "message",
               "target_id" => first.message_id
             })

    assert [%{"type" => "message", "operation" => "observation", "derivation_level" => 0}] =
             Enum.map(direct["nodes"], &Map.take(&1, ~w(type operation derivation_level)))

    assert {:ok, depth_limited} =
             Memory.evidence_lineage(Map.put(attrs, "max_depth", 0))

    assert length(depth_limited["nodes"]) == 1
    assert depth_limited["terminations"]["depth"] > 0
    assert depth_limited["truncated"]

    assert {:ok, fanout_limited} =
             Memory.evidence_lineage(Map.put(attrs, "max_fan_out", 1))

    assert fanout_limited["terminations"]["fan_out"] > 0
    assert fanout_limited["truncated"]

    assert {:ok, node_limited} =
             Memory.evidence_lineage(Map.put(attrs, "max_nodes", 1))

    assert length(node_limited["nodes"]) == 1
    assert node_limited["terminations"]["total_nodes"] > 0
  end

  test "lineage distinguishes hidden lifecycle and missing evidence without exposing it" do
    root = seed_active!("lineage-hidden", "Avery works as an engineer.", "root")
    source = seed_active!("lineage-hidden", "Avery lives in Helsinki.", "source")

    private =
      seed_active!("lineage-hidden", "Blake lives in Oulu.", "private",
        peer_key: "blake",
        peer_name: "Blake",
        sensitivity: "restricted"
      )

    relation!(root, source, "supports")
    relation!(root, private, "contradicts")

    transition!(source, "superseded")

    assert {:ok, lineage} =
             Memory.evidence_lineage(%{
               "account_key" => "lineage-hidden",
               "peer_key" => "avery",
               "scope_path" => root.scope.path,
               "target_id" => root.knowledge.id
             })

    assert lineage["terminations"]["lifecycle_hidden"] == 1
    assert lineage["terminations"]["authorization_hidden"] == 1
    refute Enum.any?(lineage["nodes"], &(&1["id"] == source.knowledge.id))
    refute Enum.any?(lineage["nodes"], &(&1["id"] == private.knowledge.id))

    hidden_ref =
      lineage["nodes"]
      |> hd()
      |> Map.fetch!("source_references")
      |> Enum.find(&(&1["status"] == "lifecycle_hidden"))

    assert hidden_ref["id"] == nil

    authorization_ref =
      lineage["nodes"]
      |> hd()
      |> Map.fetch!("source_references")
      |> Enum.find(&(&1["status"] == "authorization_hidden"))

    assert authorization_ref["id"] == nil

    missing =
      create_active_knowledge!(root,
        statement: "Avery's name is Avery Jordan.",
        source_message_ids: [Ash.UUID.generate()]
      )

    assert {:ok, missing_lineage} =
             Memory.evidence_lineage(%{
               "account_key" => "lineage-hidden",
               "peer_key" => "avery",
               "scope_path" => root.scope.path,
               "target_id" => missing.id
             })

    assert missing_lineage["terminations"]["missing"] == 1

    assert Enum.any?(hd(missing_lineage["nodes"])["source_references"], fn ref ->
             ref["status"] == "missing" and is_nil(ref["id"])
           end)
  end

  test "lineage roots fail closed across Accounts, scopes, and lifecycle states" do
    alpha = seed_active!("lineage-alpha", "Avery lives in Helsinki.", "alpha")

    _other_scope =
      seed_active!("lineage-alpha", "Avery works as an engineer.", "other", scope_path: "/other")

    _beta = seed_active!("lineage-beta", "Avery lives in Tampere.", "beta")

    attrs = %{
      "account_key" => "lineage-beta",
      "peer_key" => "avery",
      "scope_path" => "/profile",
      "target_id" => alpha.knowledge.id
    }

    assert {:error, :not_found} = Memory.evidence_lineage(attrs)

    assert {:error, :not_found} =
             Memory.evidence_lineage(%{
               "account_key" => "lineage-alpha",
               "peer_key" => "avery",
               "scope_path" => "/other",
               "target_id" => alpha.knowledge.id
             })

    transition!(alpha, "expired")

    assert {:error, :not_found} =
             Memory.evidence_lineage(%{
               "account_key" => "lineage-alpha",
               "peer_key" => "avery",
               "scope_path" => alpha.scope.path,
               "target_id" => alpha.knowledge.id
             })
  end

  test "stable identity profile keeps evidence and conflicts but rejects unsafe categories" do
    helsinki = seed_active!("identity-profile", "Avery lives in Helsinki.", "helsinki")
    tampere = seed_active!("identity-profile", "Avery lives in Tampere.", "tampere")
    occupation = seed_active!("identity-profile", "Avery works as an engineer.", "occupation")
    _name = seed_active!("identity-profile", "Avery's name is Avery Jordan.", "name")
    _transient = seed_active!("identity-profile", "Avery currently lives in Turku.", "transient")

    _behavioral =
      seed_active!("identity-profile", "Avery usually prefers long walks.", "behavior")

    _sensitive =
      seed_active!(
        "identity-profile",
        "Avery's medical diagnosis means Avery lives in a clinic.",
        "sensitive"
      )

    _unsupported =
      create_active_knowledge!(helsinki,
        statement: "Avery lives in Tallinn.",
        evidence_level: "indirect",
        source_message_ids: [helsinki.message_id]
      )

    _other_subject =
      seed_active!("identity-profile", "Blake lives in Oulu.", "other",
        peer_key: "blake",
        peer_name: "Blake"
      )

    attrs = %{
      "account_key" => "identity-profile",
      "peer_key" => "avery",
      "scope_path" => helsinki.scope.path
    }

    profile = Memory.stable_identity_profile(attrs)
    assert profile == Memory.stable_identity_profile(attrs)
    assert profile["profile_version"] == "stable-identity-v1"
    assert profile["diagnostic"]["model_calls"] == 0
    assert profile["diagnostic"]["status"] == "ready"

    statements = Enum.map(profile["items"], & &1["statement"])
    assert "Avery lives in Helsinki." in statements
    assert "Avery lives in Tampere." in statements
    assert "Avery works as an engineer." in statements
    assert "Avery's name is Avery Jordan." in statements

    refute Enum.any?(
             statements,
             &String.contains?(&1, ["currently", "usually", "medical", "Blake", "Tallinn"])
           )

    location_items = Enum.filter(profile["items"], &(&1["category"] == "location"))
    assert length(location_items) == 2
    assert Enum.all?(location_items, & &1["conflict"])
    assert 1 == location_items |> Enum.map(& &1["conflict_group"]) |> Enum.uniq() |> length()

    assert Enum.all?(profile["items"], fn item ->
             item["knowledge_id"] &&
               item["lineage"]["target"] == %{
                 "type" => "knowledge",
                 "id" => item["knowledge_id"]
               } && item["lineage"]["source_references"] != []
           end)

    old_digest = profile["projection_digest"]
    transition!(tampere, "retracted")
    refreshed = Memory.stable_identity_profile(attrs)

    refute refreshed["projection_digest"] == old_digest
    refute Enum.any?(refreshed["items"], &(&1["knowledge_id"] == tampere.knowledge.id))

    refute Enum.find(refreshed["items"], &(&1["knowledge_id"] == helsinki.knowledge.id))[
             "conflict"
           ]

    erase!(occupation)
    refreshed = Memory.stable_identity_profile(attrs)
    refute Enum.any?(refreshed["items"], &(&1["knowledge_id"] == occupation.knowledge.id))
  end

  test "bounded Ask uses profile and lineage tools as cited governed evidence" do
    name = seed_active!("planner-facades", "Avery's name is Avery Jordan.", "name")

    profile_result =
      Memory.ask(%{
        "account_key" => "planner-facades",
        "peer_key" => "avery",
        "scope_path" => name.scope.path,
        "question" => "Who am I?",
        "profile" => "balanced",
        "effort" => "low"
      })

    assert Enum.any?(profile_result["recall_evidence"], fn evidence ->
             evidence["id"] == name.knowledge.id and
               evidence["evidence_type"] == "knowledge" and
               evidence["profile_category"] == "name"
           end)

    root =
      seed_active!(
        "planner-facades",
        "The Orchid release uses a cobalt token.",
        "root"
      )

    related =
      seed_active!(
        "planner-facades",
        "Morgan owns the approval step.",
        "related"
      )

    relation!(root, related, "supports")

    lineage_result =
      Memory.ask(%{
        "account_key" => "planner-facades",
        "peer_key" => "avery",
        "scope_path" => root.scope.path,
        "question" => "What token does the Orchid release use?",
        "profile" => "balanced",
        "effort" => "medium"
      })

    assert Enum.any?(lineage_result["recall"]["outcomes"], fn outcome ->
             outcome["tool"] == "lineage" and outcome["status"] == "completed"
           end)

    assert Enum.any?(lineage_result["recall_evidence"], fn evidence ->
             evidence["id"] == related.knowledge.id and
               evidence["evidence_type"] == "knowledge"
           end)
  end

  test "profile is optional and content-safe in retrieval diagnostics" do
    seed = seed_active!("identity-search", "Avery lives in Helsinki.", "search")

    base =
      Memory.search(%{
        "account_key" => "identity-search",
        "peer_key" => "avery",
        "scope_path" => seed.scope.path,
        "query" => "Helsinki",
        "deadline" => "disabled"
      })

    assert base["identity_profile_status"] == "not_requested"
    refute Map.has_key?(base, "identity_profile")

    included =
      Memory.search(%{
        "account_key" => "identity-search",
        "peer_key" => "avery",
        "scope_path" => seed.scope.path,
        "query" => "Helsinki",
        "deadline" => "disabled",
        "include_identity_profile" => true
      })

    assert included["identity_profile_status"] == "ready"
    assert included["identity_profile"]["diagnostic"]["model_calls"] == 0
    refute Map.has_key?(included["identity_profile"]["diagnostic"], "statements")
  end

  test "recall, answer, and live profile emit reconciliable content-free aggregates" do
    seed = seed_active!("operation-aggregates", "Avery lives in Helsinki.", "aggregate")
    handler = {__MODULE__, self(), :operation_aggregate}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, metadata, _config ->
          send(parent, {:operation_aggregate, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    attrs = %{
      "account_key" => "operation-aggregates",
      "peer_key" => "avery",
      "scope_path" => seed.scope.path,
      "query" => "Helsinki"
    }

    Memory.search(attrs)
    Memory.stable_identity_profile(attrs)
    Memory.ask(Map.put(attrs, "question", "Where does Avery live?"))

    aggregates =
      Enum.map(1..4, fn _index ->
        assert_receive {:operation_aggregate, measurements, metadata}
        {measurements, metadata}
      end)

    operations = MapSet.new(aggregates, fn {_measurements, metadata} -> metadata.operation end)
    assert MapSet.subset?(MapSet.new(~w(recall answer profile_refresh)), operations)

    assert Enum.all?(aggregates, fn {measurements, metadata} ->
             is_binary(metadata.run_id) and is_binary(to_string(metadata.version)) and
               is_number(measurements.elapsed_ms)
           end)

    refute inspect(aggregates) =~ "Avery lives in Helsinki"
    refute inspect(aggregates) =~ "Where does Avery live"
  end

  test "stable profile has bounded and Account-isolated empty states" do
    for index <- 1..5 do
      seed_active!(
        "identity-bounded",
        "Avery lives in Stable City #{index}.",
        "bounded-#{index}"
      )
    end

    _other_account =
      seed_active!("identity-other", "Avery lives in Secret City.", "other-account")

    profile =
      Memory.stable_identity_profile(%{
        "account_key" => "identity-bounded",
        "peer_key" => "avery",
        "scope_path" => "/profile"
      })

    assert length(profile["items"]) == 4
    assert profile["diagnostic"]["truncated"]
    refute Enum.any?(profile["items"], &String.contains?(&1["statement"], "Secret"))

    unavailable =
      Memory.stable_identity_profile(%{
        "account_key" => "identity-bounded",
        "scope_path" => "/profile"
      })

    assert unavailable["items"] == []
    assert unavailable["diagnostic"]["status"] == "unavailable"

    _behavior_only =
      seed_active!("identity-empty", "Avery usually prefers long walks.", "behavior-only")

    empty =
      Memory.stable_identity_profile(%{
        "account_key" => "identity-empty",
        "peer_key" => "avery",
        "scope_path" => "/profile"
      })

    assert empty["items"] == []
    assert empty["diagnostic"]["status"] == "empty"
    assert empty["diagnostic"]["excluded_count"] == 1
  end

  defp seed_active!(account_key, statement, session_id, opts \\ []) do
    peer_key = Keyword.get(opts, :peer_key, "avery")
    peer_name = Keyword.get(opts, :peer_name, "Avery")
    scope_path = Keyword.get(opts, :scope_path, "/profile")

    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => session_id,
               "scope_path" => scope_path,
               "peer_key" => peer_key,
               "peer_name" => peer_name,
               "content" => statement
             })

    assert {:ok, [knowledge]} = Memory.extract_message(message["id"], account_key)
    knowledge_id = knowledge["id"]

    DataLayer.with_account_key(account_key, fn account, actor ->
      pipeline = pipeline_actor(actor)

      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      peer =
        Peer
        |> Ash.Query.filter(key == ^peer_key)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)
        |> Engine.transition!(
          pipeline,
          %{
            state: "active",
            verification: "test",
            sensitivity: Keyword.get(opts, :sensitivity, "internal")
          },
          reason: "lineage_profile_test_activate",
          channel: "pipeline"
        )

      %{
        account: account,
        actor: %{actor | peer_id: peer.id},
        pipeline: pipeline,
        peer: peer,
        scope: scope,
        knowledge: knowledge,
        message_id: message["id"]
      }
    end)
  end

  defp create_active_knowledge!(seed, overrides) do
    attrs =
      %{
        scope_id: seed.scope.id,
        subject_peer_id: seed.peer.id,
        statement: "Avery lives in Espoo.",
        kind: "fact",
        confidence: 1.0,
        evidence_level: "direct",
        sensitivity: "internal",
        state: "proposed",
        target_level: "peer",
        verification: "test",
        source_message_ids: [],
        extracting_model: "test",
        pipeline_version: "f5-1"
      }
      |> Map.merge(Map.new(overrides))

    item =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(seed.account.id)
      |> Ash.Changeset.for_create(:create_from_pipeline, attrs)
      |> Ash.create!(actor: seed.pipeline)

    Engine.transition!(
      item,
      seed.pipeline,
      %{state: "active", verification: "test"},
      reason: "lineage_profile_test_activate",
      channel: "pipeline"
    )
  end

  defp relation!(source, target, kind) do
    KnowledgeRelation
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(source.account.id)
    |> Ash.Changeset.for_create(:create_from_pipeline, %{
      scope_id: source.scope.id,
      source_knowledge_id: source.knowledge.id,
      target_knowledge_id: target.knowledge.id,
      kind: kind,
      confidence: 1.0
    })
    |> Ash.create!(actor: source.pipeline)
  end

  defp transition!(seed, state) do
    DataLayer.with_account_key(seed.account.key, [role: :system, pipeline?: true], fn _account,
                                                                                      actor ->
      item =
        KnowledgeItem
        |> Ash.Query.filter(id == ^seed.knowledge.id)
        |> Ash.Query.set_tenant(seed.account.id)
        |> Ash.read_one!(actor: actor)

      Engine.transition!(
        item,
        actor,
        %{state: state, verification: "test"},
        reason: "lineage_profile_test_transition",
        channel: "pipeline"
      )
    end)
  end

  defp erase!(seed) do
    DataLayer.with_account_key(seed.account.key, [role: :system, pipeline?: true], fn _account,
                                                                                      actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^seed.knowledge.id)
      |> Ash.Query.set_tenant(seed.account.id)
      |> Ash.read_one!(actor: actor)
      |> Ash.destroy!(action: :erase, actor: actor)
    end)
  end

  defp pipeline_actor(actor),
    do: %{actor | role: :system, pipeline?: true, scope_ids: :all, scope_roles: %{}}
end
