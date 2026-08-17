# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ProfileLineageTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Accounts.Peer
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Eval.{Adapter, Runner}
  alias MemHouse.Governance.Engine
  alias MemHouse.Knowledge.{KnowledgeItem, Provenance}
  alias MemHouse.Model.GroundedAnswerProvider
  alias MemHouse.Observations.{Document, DocumentVersion}
  alias MemHouse.Topology.Scope

  require Ash.Query

  test "runner scores profile-only answer evidence through its source lineage" do
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

    dataset =
      Adapter.normalize(%{
        "benchmark" => "memhouse",
        "id" => "profile-lineage",
        "messages" => [
          %{
            "id" => "profile-source",
            "session_id" => "profile-session",
            "peer_key" => "avery",
            "role" => "user",
            "content" => "Avery's name is Avery Jordan."
          }
        ],
        "questions" => [
          %{
            "id" => "profile-question",
            "question" => "Who am I?",
            "expected" => "Avery Jordan",
            "evidence" => ["profile-source"],
            "metadata" => %{"peer_key" => "avery"}
          }
        ]
      })

    report =
      Runner.run(dataset,
        account_key: "eval-profile-lineage",
        run_id: "profile-lineage",
        profile: "balanced",
        strategies: ["lexical"],
        recall_effort: "low",
        retrieval_cutoffs: [1]
      )

    assert report["evaluated"] == 1
    assert [question] = get_in(report, ["cases", Access.at(0), "questions"])
    assert question["recall"]["answer_context_adaptive_items"] == 1
    assert question["citation_hit"]
    assert question["cited_refs"] == ["profile-source"]
    assert question["first_supporting_rank"] == 1
    assert question["recall_at_k"] == %{"1" => 1.0}
    assert question["isolation_candidates_checked"] == 1
    assert question["isolation_leaks"] == 0
    assert [prompt] = GroundedAnswerProvider.prompts()
    assert prompt =~ "Avery's name is Avery Jordan."
  end

  test "runner counts document-backed profile evidence outside the case as a typed source leak" do
    account_key = "eval-profile-document-contamination"
    document_version_id = seed_document_profile!(account_key)

    dataset =
      Adapter.normalize(%{
        "benchmark" => "memhouse",
        "id" => "profile-document-contamination",
        "messages" => [
          %{
            "id" => "case-source",
            "session_id" => "case-session",
            "peer_key" => "avery",
            "role" => "user",
            "content" => "The case marker is cobalt."
          }
        ],
        "questions" => [
          %{
            "id" => "profile-question",
            "question" => "Who am I?",
            "expected" => "Avery Jordan",
            "evidence" => [],
            "metadata" => %{"peer_key" => "avery"}
          }
        ]
      })

    report =
      Runner.run(dataset,
        account_key: account_key,
        run_id: "document-contamination",
        profile: "balanced",
        strategies: ["lexical"],
        recall_effort: "low",
        retrieval_cutoffs: [1]
      )

    assert report["evaluated"] == 1
    assert [question] = get_in(report, ["cases", Access.at(0), "questions"])
    assert question["isolation_candidates_checked"] == 1
    assert question["isolation_leaks"] == 1
    refute Jason.encode!(question) =~ document_version_id
  end

  defp seed_document_profile!(account_key) do
    assert {:ok, _message} =
             MemHouse.Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "document-profile-setup",
               "scope_path" => "/bench/memhouse",
               "peer_key" => "avery",
               "peer_name" => "Avery",
               "content" => "Set up the document profile fixture."
             })

    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      peer =
        Peer
        |> Ash.Query.filter(key == "avery")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      scope =
        Scope
        |> Ash.Query.filter(path == "/bench/memhouse")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      document =
        Document
        |> Ash.Changeset.for_create(:create, %{
          scope_id: scope.id,
          owner_peer_id: peer.id,
          external_id: "profile-document",
          title: "Profile document",
          source_kind: "upload",
          status: "active"
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.create!(actor: actor)

      version =
        DocumentVersion
        |> Ash.Changeset.for_create(:create, %{
          document_id: document.id,
          scope_id: scope.id,
          version: 1,
          content: "Avery's name is Avery Jordan.",
          content_hash: String.duplicate("a", 64),
          byte_size: 30,
          blob_ref: "local://fixture/profile-document",
          media_type: "text/plain",
          occurred_at: Clock.utc_now()
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.create!(actor: actor)

      knowledge =
        KnowledgeItem
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          scope_id: scope.id,
          subject_peer_id: peer.id,
          statement: "Avery's name is Avery Jordan.",
          kind: "fact",
          confidence: 1.0,
          evidence_level: "direct",
          sensitivity: "internal",
          state: "proposed",
          target_level: "peer",
          verification: "test",
          source_message_ids: [],
          extracting_model: "test",
          pipeline_version: "f5-1",
          observed_at: version.occurred_at
        })
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.create!(actor: actor)
        |> Engine.transition!(
          actor,
          %{state: "active", verification: "test"},
          reason: "eval_document_profile_activate",
          channel: "pipeline"
        )

      Provenance
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        knowledge_item_id: knowledge.id,
        scope_id: scope.id,
        source_type: "document",
        document_version_id: version.id,
        extracting_model: "test",
        pipeline_version: "f5-1",
        occurred_at: version.occurred_at
      })
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.create!(actor: actor)

      version.id
    end)
  end
end
