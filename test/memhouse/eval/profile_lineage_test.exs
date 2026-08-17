# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ProfileLineageTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Eval.{Adapter, Runner}
  alias MemHouse.Model.GroundedAnswerProvider

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
end
