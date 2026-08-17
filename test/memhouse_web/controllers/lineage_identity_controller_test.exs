# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.LineageIdentityControllerTest do
  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.Identity
  alias MemHouse.Memory

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

  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")
end
