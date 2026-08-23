# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.LineageIdentityProfileTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Accounts.Peer
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.Erasure
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation, Provenance}
  alias MemHouse.Lineage
  alias MemHouse.Memory
  alias MemHouse.Model.GroundedAnswerProvider
  alias MemHouse.Observations.{Document, DocumentVersion}
  alias MemHouse.Pipeline.DeductionEffects
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

  test "expired active knowledge is absent from live profiles and lineage but remains available to an exact historical state read" do
    root = seed_active!("lineage-expiry", "Avery works as an engineer.", "root")
    expired = seed_active!("lineage-expiry", "Avery lives in Helsinki.", "expired")

    relation!(root, expired, "supports")
    expire_active!(expired)

    attrs = %{
      "account_key" => "lineage-expiry",
      "peer_key" => "avery",
      "scope_path" => root.scope.path
    }

    profile = Memory.stable_identity_profile(attrs)
    refute Enum.any?(profile["items"], &(&1["knowledge_id"] == expired.knowledge.id))

    assert {:error, :not_found} =
             Memory.evidence_lineage(Map.put(attrs, "target_id", expired.knowledge.id))

    assert {:ok, lineage} =
             Memory.evidence_lineage(Map.put(attrs, "target_id", root.knowledge.id))

    assert lineage["terminations"]["lifecycle_hidden"] == 1

    assert Enum.any?(hd(lineage["nodes"])["source_references"], fn reference ->
             reference["status"] == "lifecycle_hidden" and is_nil(reference["id"])
           end)

    refute Enum.any?(lineage["nodes"], &(&1["id"] == expired.knowledge.id))

    refute Enum.any?(Memory.query_knowledge(attrs), &(&1["id"] == expired.knowledge.id))

    transition!(expired, "superseded")

    assert Enum.any?(Memory.query_knowledge(Map.put(attrs, "state", "superseded")), fn item ->
             item["id"] == expired.knowledge.id
           end)
  end

  test "synthesis prompt identity survives persistence and drives typed lineage" do
    first = seed_active!("lineage-synthesis", "Avery prefers concise updates.", "first")
    second = seed_active!("lineage-synthesis", "Avery asks for short weekly summaries.", "second")

    deduction =
      DeductionEffects.apply!(
        %{
          statement: "Avery prefers concise weekly updates.",
          kind: "preference",
          subject_type: "peer",
          subject_ref: "avery",
          confidence: 0.9,
          sensitivity: "internal",
          target_level: "peer",
          contributor_ids: [first.knowledge.id, second.knowledge.id],
          expires_at: nil,
          revalidate_after: nil,
          relevant_from: nil,
          relevant_until: nil,
          provider: "deterministic",
          model: "fixture-reasoner",
          model_version: "1",
          prompt_version: "reason-1",
          operation_prompt_version: "reason-synthesis-1",
          pipeline_version: "f5-1"
        },
        first.account.id,
        first.scope.id,
        first.pipeline
      )

    assert deduction.prompt_version == "reason-synthesis-1"

    deduction =
      deduction
      |> Engine.transition!(
        first.pipeline,
        %{state: "active", verification: "test"},
        reason: "lineage_synthesis_test_activate",
        channel: "pipeline"
      )

    reloaded =
      KnowledgeItem
      |> Ash.Query.filter(id == ^deduction.id)
      |> Ash.Query.set_tenant(first.account.id)
      |> Ash.read_one!(actor: first.pipeline)

    assert reloaded.prompt_version == "reason-synthesis-1"

    assert {:ok, lineage} =
             Memory.evidence_lineage(%{
               "account_key" => "lineage-synthesis",
               "peer_key" => "avery",
               "scope_path" => first.scope.path,
               "target_id" => reloaded.id
             })

    assert hd(lineage["nodes"])["operation"] == "reasoning_synthesis"
    refute Jason.encode!(lineage) =~ "reason-synthesis-1"
  end

  test "synthesis persistence rejects two knowledge rows from one durable observation" do
    first =
      seed_active!("lineage-synthesis-source-fence", "Avery prefers concise updates.", "first")

    second =
      create_active_knowledge!(first,
        statement: "Avery prefers weekly updates.",
        source_message_ids: [first.message_id]
      )

    original_provenance =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^first.knowledge.id)
      |> Ash.Query.set_tenant(first.account.id)
      |> Ash.read_one!(actor: first.pipeline)

    Provenance
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(first.account.id)
    |> Ash.Changeset.for_create(:create_from_pipeline, %{
      knowledge_item_id: second.id,
      scope_id: second.scope_id,
      source_type: original_provenance.source_type,
      message_id: original_provenance.message_id,
      document_version_id: original_provenance.document_version_id,
      extracting_provider: original_provenance.extracting_provider,
      extracting_model: original_provenance.extracting_model,
      extracting_model_version: original_provenance.extracting_model_version,
      prompt_version: original_provenance.prompt_version,
      pipeline_version: original_provenance.pipeline_version,
      occurred_at: original_provenance.occurred_at
    })
    |> Ash.create!(actor: first.pipeline)

    error =
      assert_raise ArgumentError, "invalid synthesis contributor sources", fn ->
        DeductionEffects.apply!(
          %{
            statement: "Avery prefers concise weekly updates.",
            kind: "preference",
            subject_type: "peer",
            subject_ref: "avery",
            confidence: 0.9,
            sensitivity: "internal",
            target_level: "peer",
            contributor_ids: [first.knowledge.id, second.id],
            expires_at: nil,
            revalidate_after: nil,
            relevant_from: nil,
            relevant_until: nil,
            provider: "deterministic",
            model: "fixture-reasoner",
            model_version: "1",
            prompt_version: "reason-1",
            operation_prompt_version: "reason-synthesis-1",
            pipeline_version: "f5-1"
          },
          first.account.id,
          first.scope.id,
          first.pipeline
        )
      end

    refute Exception.message(error) =~ first.message_id
    refute Exception.message(error) =~ "concise"
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

  test "profile-only Ask preserves authorized source lineage in its grounded answer evidence" do
    name = seed_active!("planner-profile-lineage", "Avery's name is Avery Jordan.", "name")
    original_provider = Application.get_env(:memhouse, :model_provider)
    GroundedAnswerProvider.start!(:confident_inference)
    Application.put_env(:memhouse, :model_provider, GroundedAnswerProvider)

    on_exit(fn ->
      GroundedAnswerProvider.stop()

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    result =
      Memory.ask(%{
        "account_key" => "planner-profile-lineage",
        "peer_key" => "avery",
        "scope_path" => name.scope.path,
        "question" => "Who am I?",
        "profile" => "balanced",
        "strategies" => ["lexical"],
        "deadline" => "disabled",
        "effort" => "low"
      })

    assert result["candidates"] == []
    assert [evidence] = result["recall_evidence"]
    assert evidence["id"] == name.knowledge.id
    assert evidence["scope_id"] == name.scope.id
    assert evidence["source_message_ids"] == [name.message_id]

    assert evidence["source_references"] == [
             %{"type" => "message", "id" => name.message_id}
           ]

    assert result["citations"] == [name.knowledge.id]
    assert [prompt] = GroundedAnswerProvider.prompts()
    assert prompt =~ "[#{name.knowledge.id}] Avery's name is Avery Jordan."
  end

  test "profile Ask does not reintroduce a source erased inside the exact-read callback" do
    name = seed_active!("planner-profile-erasure-race", "Avery's name is Avery Jordan.", "name")

    assert {:ok, blake_message} =
             Memory.ingest_message(%{
               "account_key" => name.account.key,
               "session_id" => "blake-source",
               "scope_path" => name.scope.path,
               "peer_key" => "blake",
               "peer_name" => "Blake",
               "content" => "Avery's name is Avery Jordan."
             })

    erasure_actor = add_message_source!(name, blake_message["id"], "blake")

    before_profile =
      Memory.stable_identity_profile(%{
        "account_key" => name.account.key,
        "peer_key" => "avery",
        "scope_path" => name.scope.path
      })

    assert [before_item] = before_profile["items"]
    assert length(before_item["lineage"]["source_references"]) == 2

    original_provider = Application.get_env(:memhouse, :model_provider)
    GroundedAnswerProvider.start!(:confident_inference)
    Application.put_env(:memhouse, :model_provider, GroundedAnswerProvider)

    handler = {__MODULE__, self(), :profile_source_erasure}
    erased? = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :memory, :visible_knowledge, :knowledge_read],
        fn _event, _measurements, _metadata, _config ->
          if :atomics.exchange(erased?, 1, 1) == 0 do
            Erasure.request(erasure_actor, erasure_actor.peer_id, "proportionate")
          end
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      GroundedAnswerProvider.stop()

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    result =
      Memory.ask(%{
        "account_key" => name.account.key,
        "peer_key" => "avery",
        "scope_path" => name.scope.path,
        "question" => "Who am I?",
        "profile" => "balanced",
        "strategies" => ["lexical"],
        "deadline" => "disabled",
        "effort" => "low"
      })

    assert :atomics.get(erased?, 1) == 1
    assert [evidence] = result["recall_evidence"]
    assert evidence["source_message_ids"] == [name.message_id]

    assert evidence["source_references"] == [
             %{"type" => "message", "id" => name.message_id}
           ]

    refute Jason.encode!(result) =~ blake_message["id"]

    after_profile =
      Memory.stable_identity_profile(%{
        "account_key" => name.account.key,
        "peer_key" => "avery",
        "scope_path" => name.scope.path
      })

    refute after_profile["projection_digest"] == before_profile["projection_digest"]
    assert [after_item] = after_profile["items"]
    assert after_item["lineage"]["source_references"] == evidence["source_references"]
  end

  test "direct source projection reauthorizes cross-scope and cross-account document versions" do
    seed = seed_active!("profile-document-source-auth", "Avery's name is Avery Jordan.", "name")

    cross_scope_id =
      create_document_version!(seed.account.key, "/private-document", "cross-scope")

    cross_account_id =
      create_document_version!("profile-document-source-foreign", "/profile", "cross-account")

    DataLayer.with_account_key(seed.account.key, [role: :system, pipeline?: true], fn account,
                                                                                      actor ->
      Enum.each([cross_scope_id, cross_account_id], fn version_id ->
        Provenance
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          knowledge_item_id: seed.knowledge.id,
          scope_id: seed.scope.id,
          source_type: "document",
          document_version_id: version_id,
          extracting_model: "test",
          pipeline_version: "f5-1",
          occurred_at: Clock.utc_now()
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.create!(actor: actor)
      end)
    end)

    refs =
      DataLayer.with_account_key(seed.account.key, fn account, actor ->
        Lineage.visible_source_references(seed.knowledge, account, actor, [seed.scope])
      end)

    assert refs == [%{"type" => "message", "id" => seed.message_id}]
    refute Jason.encode!(refs) =~ cross_scope_id
    refute Jason.encode!(refs) =~ cross_account_id

    profile =
      Memory.stable_identity_profile(%{
        "account_key" => seed.account.key,
        "peer_key" => "avery",
        "scope_path" => seed.scope.path
      })

    assert [item] = profile["items"]
    assert item["lineage"]["source_references"] == refs
    refute Jason.encode!(profile) =~ cross_scope_id
    refute Jason.encode!(profile) =~ cross_account_id
  end

  test "stable profile rejects an identity fact backed only by unauthorized document provenance" do
    seed =
      seed_active!(
        "profile-document-source-invalid-only",
        "The fixture marker is blue.",
        "setup"
      )

    unsupported =
      create_active_knowledge!(seed,
        statement: "Avery's name is Avery Jordan.",
        source_message_ids: []
      )

    hidden_version_id =
      create_document_version!(seed.account.key, "/private-document", "invalid-only")

    foreign_version_id =
      create_document_version!(
        "profile-document-source-invalid-only-foreign",
        "/profile",
        "invalid-only-foreign"
      )

    DataLayer.with_account_key(seed.account.key, [role: :system, pipeline?: true], fn account,
                                                                                      actor ->
      Enum.each([hidden_version_id, foreign_version_id], fn version_id ->
        Provenance
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          knowledge_item_id: unsupported.id,
          scope_id: seed.scope.id,
          source_type: "document",
          document_version_id: version_id,
          extracting_model: "test",
          pipeline_version: "f5-1",
          occurred_at: Clock.utc_now()
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.create!(actor: actor)
      end)
    end)

    profile =
      Memory.stable_identity_profile(%{
        "account_key" => seed.account.key,
        "peer_key" => "avery",
        "scope_path" => seed.scope.path
      })

    assert profile["items"] == []
    assert profile["diagnostic"]["status"] == "empty"
    assert profile["diagnostic"]["eligible_count"] == 0
    assert profile["diagnostic"]["excluded_by_reason"]["unsupported"] == 1
    refute Jason.encode!(profile) =~ hidden_version_id
    refute Jason.encode!(profile) =~ foreign_version_id
  end

  test "adaptive Ask admits lineage evidence ahead of a full base page and preserves profile" do
    seeds =
      Enum.map(1..12, fn index ->
        seed_active!(
          "planner-headroom",
          "Orchid base fact number #{index}.",
          "base-#{index}"
        )
      end)

    attrs = %{
      "account_key" => "planner-headroom",
      "peer_key" => "avery",
      "scope_path" => "/profile",
      "query" => "Orchid base fact",
      "profile" => "fast",
      "strategies" => ["lexical"],
      "deadline" => "disabled"
    }

    initial = Memory.search(attrs)
    assert length(initial["candidates"]) == 12

    root_id = initial["candidates"] |> hd() |> Map.fetch!("id")
    root = Enum.find(seeds, &(&1.knowledge.id == root_id))
    related = seed_active!("planner-headroom", "Morgan owns the approval step.", "related")
    relation!(root, related, "supports")

    original_provider = Application.get_env(:memhouse, :model_provider)
    GroundedAnswerProvider.start!(:grounded_abstention)
    Application.put_env(:memhouse, :model_provider, GroundedAnswerProvider)

    on_exit(fn ->
      GroundedAnswerProvider.stop()

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    handler = {__MODULE__, self(), :planner_profile}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:planner_profile_operation, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    high_result =
      attrs
      |> Map.drop(["query"])
      |> Map.merge(%{
        "question" => "Orchid base fact",
        "effort" => "high"
      })
      |> Memory.ask()

    medium_result =
      attrs
      |> Map.drop(["query"])
      |> Map.merge(%{
        "question" => "Orchid base fact",
        "effort" => "medium"
      })
      |> Memory.ask()

    base_ids = Enum.map(high_result["candidates"], & &1["id"])
    assert Enum.map(medium_result["candidates"], & &1["id"]) == base_ids

    high_recall_ids = Enum.map(high_result["recall_evidence"], & &1["id"])
    medium_recall_ids = Enum.map(medium_result["recall_evidence"], & &1["id"])
    high_answer_context_ids = Enum.take(high_recall_ids, 12)
    medium_answer_context_ids = Enum.take(medium_recall_ids, 12)

    refute related.knowledge.id in base_ids

    assert high_recall_ids ==
             Enum.take(base_ids, 6) ++ [related.knowledge.id] ++ Enum.drop(base_ids, 6)

    assert medium_recall_ids ==
             Enum.take(base_ids, 8) ++ [related.knowledge.id] ++ Enum.drop(base_ids, 8)

    assert related.knowledge.id in high_answer_context_ids
    assert related.knowledge.id in medium_answer_context_ids
    refute List.last(base_ids) in high_answer_context_ids
    refute List.last(base_ids) in medium_answer_context_ids

    assert [high_prompt, medium_prompt] = GroundedAnswerProvider.prompts()
    assert high_prompt =~ "[#{related.knowledge.id}] Morgan owns the approval step."
    assert medium_prompt =~ "[#{related.knowledge.id}] Morgan owns the approval step."
    refute high_prompt =~ "[#{List.last(base_ids)}]"
    refute medium_prompt =~ "[#{List.last(base_ids)}]"

    for result <- [high_result, medium_result] do
      assert result["recall"]["answer_context_adaptive_items"] >= 1
      assert result["recall"]["retrieval_profile"] == "fast"
      assert result["recall"]["retrieval_profile_version"] == result["profile_version"]
    end

    recall_profiles =
      drain_profile_operations([])
      |> Enum.filter(&(&1.operation == "recall"))
      |> Enum.map(&to_string(&1.profile))

    # One event is the base pass and at least one more is a rewritten knowledge
    # tool call. Every pass must retain the profile the caller selected.
    assert length(recall_profiles) >= 2
    assert Enum.uniq(recall_profiles) == ["fast"]
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

  defp add_message_source!(seed, message_id, peer_key) do
    DataLayer.with_account_key(seed.account.key, [role: :system, pipeline?: true], fn account,
                                                                                      actor ->
      peer =
        Peer
        |> Ash.Query.filter(key == ^peer_key)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^seed.knowledge.id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)
        |> Ash.Changeset.for_update(:merge_from_pipeline, %{
          source_message_ids: Enum.uniq([message_id | seed.knowledge.source_message_ids]),
          confidence: seed.knowledge.confidence,
          corroboration_count: seed.knowledge.corroboration_count + 1
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.update!(actor: actor)

      source =
        Provenance
        |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
        |> Ash.Query.limit(1)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      Provenance
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        knowledge_item_id: knowledge.id,
        scope_id: knowledge.scope_id,
        source_type: "message",
        message_id: message_id,
        extracting_provider: source.extracting_provider,
        extracting_model: source.extracting_model,
        extracting_model_version: source.extracting_model_version,
        prompt_version: source.prompt_version,
        embedding_provider: source.embedding_provider,
        embedding_model: source.embedding_model,
        embedding_version: source.embedding_version,
        pipeline_version: source.pipeline_version,
        occurred_at: source.occurred_at
      })
      |> Ash.create!(actor: actor)

      %{actor | peer_id: peer.id}
    end)
  end

  defp create_document_version!(account_key, scope_path, suffix) do
    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "document-source-#{suffix}",
               "scope_path" => scope_path,
               "peer_key" => "avery",
               "peer_name" => "Avery",
               "content" => "Create a document source fixture."
             })

    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      peer =
        Peer
        |> Ash.Query.filter(key == "avery")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      document =
        Document
        |> Ash.Changeset.for_create(:create, %{
          scope_id: scope.id,
          owner_peer_id: peer.id,
          external_id: "profile-source-#{suffix}",
          title: "Profile source #{suffix}",
          source_kind: "upload",
          status: "active"
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.create!(actor: actor)

      DocumentVersion
      |> Ash.Changeset.for_create(:create, %{
        document_id: document.id,
        scope_id: scope.id,
        version: 1,
        content: "Avery's name is Avery Jordan.",
        content_hash: :crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower),
        byte_size: 30,
        blob_ref: "local://fixture/#{suffix}",
        media_type: "text/plain",
        occurred_at: Clock.utc_now()
      })
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.create!(actor: actor)
      |> Map.fetch!(:id)
    end)
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

  defp expire_active!(seed) do
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
        %{state: "active", expires_at: DateTime.add(Clock.utc_now(), -1, :second)},
        reason: "lineage_profile_test_expire_active",
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

  defp drain_profile_operations(acc) do
    receive do
      {:planner_profile_operation, metadata} -> drain_profile_operations([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
