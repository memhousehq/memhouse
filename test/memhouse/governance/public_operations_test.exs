# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.PublicOperationsTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Governance.PublicOperations
  alias MemHouse.Identity
  alias MemHouse.Memory
  alias MemHouse.Repo

  setup do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "public-operations@example.test",
        name: "Avery",
        password: "correct horse battery staple"
      })

    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => "public-operations",
                 "scope_path" => "/contract/public-operations",
                 "content" => "Avery lives in Helsinki."
               },
               bootstrap.actor
             )

    assert {:ok, [knowledge]} =
             Memory.extract_message_for_account(message["id"], bootstrap.actor.account_id)

    admin = Identity.refresh_actor(bootstrap.actor)

    member =
      Identity.provision_agent(admin, %{
        "key" => "public-operations-member",
        "scope_path" => "/",
        "role" => "member"
      })

    assert {:ok, member_actor} = Identity.authenticate_bearer(member.api_key)

    {:ok,
     admin: admin, member: member_actor, message_id: message["id"], knowledge_id: knowledge["id"]}
  end

  test "typed public read actions preserve governed return contracts", context do
    assert {:ok, %{"outcome" => "ok", "data" => source}} =
             run(
               :source_search,
               %{
                 query: "lives in Helsinki",
                 scope_path: "/contract/public-operations",
                 mode: "exact",
                 excerpt_chars: 80
               },
               context.member
             )

    assert [%{"id" => message_id}] = source["results"]
    assert message_id == context.message_id

    assert {:ok, %{"outcome" => "not_found"}} =
             run(
               :evidence_lineage,
               %{
                 target_id: context.knowledge_id,
                 scope_path: "/contract/public-operations",
                 max_depth: 1
               },
               context.member
             )

    assert {:ok, %{"outcome" => "ok", "data" => lineage}} =
             run(
               :evidence_lineage,
               %{
                 target_id: context.knowledge_id,
                 scope_path: "/contract/public-operations",
                 max_depth: 1
               },
               context.admin
             )

    assert lineage["target"] == %{"type" => "knowledge", "id" => context.knowledge_id}

    assert {:ok, %{"outcome" => "ok", "data" => profile}} =
             run(
               :stable_identity_profile,
               %{scope_path: "/contract/public-operations"},
               context.admin
             )

    assert profile["profile_version"] == "stable-identity-v1"
    assert Enum.any?(profile["items"], &(&1["knowledge_id"] == context.knowledge_id))

    assert {:ok, %{"outcome" => "not_found"}} =
             run(
               :evidence_lineage,
               %{target_id: "not-a-uuid", scope_path: "/contract/public-operations"},
               context.member
             )
  end

  test "public action policies reject anonymous reads and member extraction requeue", context do
    for {action, attrs} <- [
          source_search: %{
            query: "Helsinki",
            scope_path: "/contract/public-operations",
            mode: "exact"
          },
          evidence_lineage: %{
            target_id: context.knowledge_id,
            scope_path: "/contract/public-operations"
          },
          stable_identity_profile: %{scope_path: "/contract/public-operations"}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = run(action, attrs, nil)
    end

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE pipeline_runs
      SET status = 'terminal', last_error_class = 'structured_validation_exhausted'
      WHERE target_id = $1 AND kind = 'extraction'
      """,
      [Ecto.UUID.dump!(context.message_id)]
    )

    assert {:error, %Ash.Error.Forbidden{}} =
             run(:requeue_extraction, %{message_id: context.message_id}, context.member)

    assert %{rows: [["terminal"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT status FROM pipeline_runs WHERE target_id = $1 AND kind = 'extraction'",
               [Ecto.UUID.dump!(context.message_id)]
             )

    assert {:ok,
            %{
              "outcome" => "accepted",
              "data" => %{"run_id" => run_id, "status" => "accepted"}
            }} = run(:requeue_extraction, %{message_id: context.message_id}, context.admin)

    assert is_binary(run_id)
  end

  defp run(action, attrs, actor) do
    PublicOperations
    |> Ash.ActionInput.for_action(action, attrs)
    |> Ash.run_action(actor: actor)
  end
end
