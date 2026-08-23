# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.PublicOperationsTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.PublicOperations
  alias MemHouse.Identity
  alias MemHouse.Memory
  alias MemHouse.Operations.PipelineRun

  require Ash.Query

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

    other_actor =
      DataLayer.with_account_key("public-operations-other", fn _account, actor -> actor end)

    refute other_actor.account_id == context.admin.account_id

    assert {:ok, %{"outcome" => "ok", "data" => cross_account}} =
             run(
               :source_search,
               %{
                 query: "lives in Helsinki",
                 scope_path: "/contract/public-operations",
                 mode: "exact",
                 excerpt_chars: 80
               },
               other_actor
             )

    assert cross_account["results"] == []

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

    run = extraction_run!(context.admin.account_id, context.message_id)
    # Test-only fixture setup: the completed anchor has no live batch claim, so the
    # governed production transition correctly refuses to classify it.
    Ash.Seed.update!(
      run,
      %{
        status: "terminal",
        attempt_count: run.attempt_count,
        last_error_class: "structured_validation_exhausted",
        processed_at: MemHouse.Clock.utc_now(),
        payload: run.payload
      },
      tenant: context.admin.account_id
    )

    assert {:error, %Ash.Error.Forbidden{}} =
             run(:requeue_extraction, %{message_id: context.message_id}, context.member)

    assert extraction_run!(context.admin.account_id, context.message_id).status == "terminal"

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

  defp extraction_run!(account_id, message_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        PipelineRun
        |> Ash.Query.filter(kind == "extraction" and target_id == ^message_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)
      end
    )
  end
end
