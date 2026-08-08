# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.GovernanceLive.IndexTest do
  @moduledoc """
  Pins curator queue rendering and feedback at `/governance`.

  Tests exercise real governance operations through LiveView while broader gate behavior
  remains covered by the governance contract suite.
  """

  use MemHouseWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Topology.Scope

  require Ash.Query

  @password "correct horse battery staple"

  test "approving a personal item still awaiting consent says so, and the item stays queued" do
    %{actor: actor, token: token} = bootstrap_human!("consent")

    knowledge =
      ingest!(
        actor,
        "consent-session",
        "/private/consent",
        "Avery has a medical appointment scheduled for next Thursday."
      )

    assert knowledge.sensitivity == "personal"
    root = scope_by_path!(actor, "/")
    promotion = Engine.request_promotion(actor, knowledge.id, root.id)

    {:ok, view, html} = live(sign_in(build_conn(), token), "/governance")
    assert html =~ knowledge.statement

    html =
      render_click(view, "decide", %{"id" => promotion.validation.id, "action" => "approve"})

    assert html =~ "still needs"
    assert html =~ "consent"
    assert html =~ knowledge.statement
  end

  test "approving an ordinary pending item says approved and clears the card" do
    %{actor: actor, token: token} = bootstrap_human!("plain")

    knowledge = ingest!(actor, "plain-session", "/plain", "Avery prefers asynchronous standups.")
    validation = validation_for!(actor, knowledge.id)

    {:ok, view, html} = live(sign_in(build_conn(), token), "/governance")
    assert html =~ knowledge.statement

    html = render_click(view, "decide", %{"id" => validation.id, "action" => "approve"})

    assert html =~ "Approved."
    assert html =~ "0 item(s) awaiting a decision"
    refute html =~ knowledge.statement
  end

  test "select all checks every row, deselect all clears them, and one toggle checks only one" do
    %{actor: actor, token: token} = bootstrap_human!("bulk")

    first = ingest!(actor, "bulk-session-1", "/plain", "Avery prefers asynchronous standups.")

    second =
      ingest!(actor, "bulk-session-2", "/plain", "Avery reviews pull requests every morning.")

    first_id = validation_for!(actor, first.id).id
    second_id = validation_for!(actor, second.id).id

    {:ok, view, html} = live(sign_in(build_conn(), token), "/governance")
    refute checkbox_checked?(html, first_id)
    refute checkbox_checked?(html, second_id)

    html = render_click(view, "select_all")
    assert checkbox_checked?(html, first_id)
    assert checkbox_checked?(html, second_id)

    html = render_click(view, "deselect_all")
    refute checkbox_checked?(html, first_id)
    refute checkbox_checked?(html, second_id)

    html = render_click(view, "toggle_select", %{"id" => first_id})
    assert checkbox_checked?(html, first_id)
    refute checkbox_checked?(html, second_id)
  end

  test "a card shows the statement it conflicts with, not just the bare id" do
    %{actor: actor, token: token} = bootstrap_human!("conflict")

    first = ingest!(actor, "conflict-session-1", "/plain", "Avery prefers asynchronous standups.")
    second = ingest!(actor, "conflict-session-2", "/plain", "Avery prefers synchronous standups.")
    validation = validation_for!(actor, first.id)

    attach_conflict!(actor, validation, second.id)

    # Reject the second item's own queue row so its statement can only reach the page through
    # the first card's resolved conflict, never through its own — otherwise this test would
    # pass even if conflicts were never resolved, since the second item is independently queued.
    Engine.decide(actor, validation_for!(actor, second.id).id, "reject")

    {:ok, _view, html} = live(sign_in(build_conn(), token), "/governance")

    assert html =~ second.statement
  end

  # ----------------------------------------------------------------------------
  # World
  # ----------------------------------------------------------------------------

  defp bootstrap_human!(suffix) do
    MemHouse.Identity.bootstrap_human(%{
      email: "governance-live-#{suffix}@example.test",
      name: "Governance Live #{suffix}",
      password: @password
    })
  end

  defp ingest!(actor, session_id, scope_path, content) do
    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => session_id,
          "scope_path" => scope_path,
          "role" => "user",
          "content" => content
        },
        actor
      )

    {:ok, [knowledge]} =
      Memory.extract_message_for_account(message["id"], actor.account_id)

    knowledge |> Map.fetch!("id") |> knowledge_for!(actor)
  end

  defp knowledge_for!(id, actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline_actor(current_actor))
    end)
  end

  defp validation_for!(actor, knowledge_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      ValidationItem
      |> Ash.Query.filter(knowledge_id == ^knowledge_id and kind == "gate_a_b")
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: current_actor)
    end)
  end

  defp scope_by_path!(actor, path) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      Scope
      |> Ash.Query.filter(path == ^path)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: current_actor)
    end)
  end

  # Sets one queue row's conflict list directly through the same upsert action the pipeline
  # uses, rather than a real conflict-detection pass: the queue's rendering only cares that the
  # id is on the row, not how it got there.
  defp attach_conflict!(actor, %ValidationItem{} = validation, conflict_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      ValidationItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:enqueue, %{
        knowledge_id: validation.knowledge_id,
        scope_id: validation.scope_id,
        subject_peer_id: validation.subject_peer_id,
        target_scope_id: validation.target_scope_id,
        target_level: validation.target_level,
        kind: validation.kind,
        state: validation.state,
        statement_hash: validation.statement_hash,
        confidence: validation.confidence,
        sensitivity: validation.sensitivity,
        provenance_ids: validation.provenance_ids,
        conflict_knowledge_ids: [conflict_id],
        due_at: validation.due_at
      })
      |> Ash.create!(actor: pipeline_actor(current_actor))
    end)
  end

  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp sign_in(conn, token), do: init_test_session(conn, governance_token: token)

  defp checkbox_checked?(html, id) do
    case Regex.run(~r/<input[^>]*name="ids\[#{Regex.escape(id)}\]"[^>]*>/, html) do
      [tag] -> tag =~ "checked"
      nil -> flunk("checkbox for #{id} not found in rendered HTML")
    end
  end
end
