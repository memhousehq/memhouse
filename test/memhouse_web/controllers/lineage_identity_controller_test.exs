# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.LineageIdentityControllerTest do
  @moduledoc "Covers the HTTP lineage and stable identity projection contracts."

  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory

  require Ash.Query

  setup do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "lineage-profile@example.test",
        name: "Avery",
        password: "correct horse battery staple"
      })

    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => "lineage-profile-http",
                 "scope_path" => "/contract/lineage-profile",
                 "content" => "Avery lives in Helsinki."
               },
               bootstrap.actor
             )

    assert {:ok, [knowledge]} =
             Memory.extract_message_for_account(message["id"], bootstrap.actor.account_id)

    {:ok,
     actor: bootstrap.actor,
     token: bootstrap.token,
     message_id: message["id"],
     knowledge_id: knowledge["id"]}
  end

  test "authenticated lineage and stable profile routes expose bounded governed projections", %{
    conn: conn,
    token: token,
    message_id: message_id,
    knowledge_id: knowledge_id
  } do
    profile =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/stable-profile", %{
        "scope_path" => "/contract/lineage-profile"
      })

    assert %{
             "data" => %{
               "profile_version" => "stable-identity-v1",
               "items" => [
                 %{
                   "knowledge_id" => ^knowledge_id,
                   "category" => "location",
                   "lineage" => %{
                     "source_references" => [%{"type" => "message", "id" => ^message_id}]
                   }
                 }
               ],
               "diagnostic" => %{"model_calls" => 0, "status" => "ready"}
             }
           } = json_response(profile, 200)

    lineage =
      profile
      |> recycle()
      |> with_identity(token)
      |> post(~p"/api/v1/lineage", %{
        "scope_path" => "/contract/lineage-profile",
        "target_id" => knowledge_id,
        "max_depth" => 1
      })

    assert %{
             "data" => %{
               "lineage_version" => "evidence-lineage-v1",
               "target" => %{"type" => "knowledge", "id" => ^knowledge_id},
               "nodes" => nodes
             }
           } = json_response(lineage, 200)

    assert Enum.map(nodes, & &1["type"]) == ["knowledge", "message"]
  end

  test "lineage gives invalid and unavailable targets the same opaque 404", %{
    conn: conn,
    token: token
  } do
    for target_id <- ["not-a-uuid", Ash.UUID.generate()] do
      response =
        conn
        |> recycle()
        |> with_identity(token)
        |> post(~p"/api/v1/lineage", %{
          "scope_path" => "/contract/lineage-profile",
          "target_id" => target_id
        })

      assert %{"error" => "Not found"} = json_response(response, 404)
    end
  end

  test "public projection routes reject invalid typed arguments", %{conn: conn, token: token} do
    lineage =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/lineage", %{
        "target_id" => Ash.UUID.generate(),
        "max_depth" => "deep"
      })

    assert %{"error" => "Invalid request"} = json_response(lineage, 422)

    profile =
      lineage
      |> recycle()
      |> with_identity(token)
      |> post(~p"/api/v1/stable-profile", %{"scope_path" => ["invalid"]})

    assert %{"error" => "Invalid request"} = json_response(profile, 422)
  end

  test "expired active knowledge is omitted from profile and opaque to lineage", %{
    conn: conn,
    token: token,
    knowledge_id: knowledge_id
  } do
    expire_active!(token, knowledge_id)

    profile =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/stable-profile", %{
        "scope_path" => "/contract/lineage-profile"
      })

    assert %{
             "data" => %{
               "items" => [],
               "diagnostic" => %{"status" => "empty"}
             }
           } = json_response(profile, 200)

    lineage =
      profile
      |> recycle()
      |> with_identity(token)
      |> post(~p"/api/v1/lineage", %{
        "scope_path" => "/contract/lineage-profile",
        "target_id" => knowledge_id
      })

    assert %{"error" => "Not found"} = json_response(lineage, 404)
  end

  defp expire_active!(token, knowledge_id) do
    assert {:ok, actor} = Identity.authenticate_bearer(token)

    MemHouse.DataLayer.with_actor(actor, fn account, actor ->
      pipeline = %{actor | role: :system, pipeline?: true, scope_ids: :all, scope_roles: %{}}

      KnowledgeItem
      |> Ash.Query.filter(id == ^knowledge_id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline)
      |> MemHouse.Governance.Engine.transition!(
        pipeline,
        %{state: "active", expires_at: DateTime.add(MemHouse.Clock.utc_now(), -1, :second)},
        reason: "lineage_profile_http_test_expire_active",
        channel: "pipeline"
      )
    end)
  end

  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")
end
