# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.MinimalProfileTest do
  @moduledoc """
  Pins the default-off minimal recall gate and its lexical/semantic dual-lane strategy set.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Retrieval.{Profile, Query}

  setup do
    profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)
    on_exit(fn -> Application.put_env(:memhouse, :retrieval_profiles, profiles) end)
    {:ok, profiles: profiles}
  end

  test "minimal profile is explicit, reversible, and excludes every non-hybrid stage", %{
    profiles: profiles
  } do
    query = %Query{account_id: Ash.UUID.generate(), actor: %{}, scope_ids: []}

    assert_raise ArgumentError, ~r/experimental minimal retrieval is disabled/, fn ->
      Profile.resolve(:minimal, query, inherit?: false)
    end

    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(profiles, :minimal_enabled, true)
    )

    profile = Profile.resolve("minimal", query, inherit?: false)

    assert profile.name == :minimal
    assert profile.version == "minimal-exp-2"
    assert profile.strategies == [:semantic_dual_lane, :lexical]

    assert Enum.map(profile.strategy_modules, & &1.name()) == [
             :semantic_dual_lane,
             :lexical
           ]

    assert profile.rerank == false

    refute :temporal in profile.strategies
    refute :salience_recency in profile.strategies
    refute :entity_match in profile.strategies
    refute :relation_expand in profile.strategies
  end

  test "configuration introspection centralizes closed names without bypassing the gate" do
    query = %Query{account_id: Ash.UUID.generate(), actor: %{}, scope_ids: []}

    assert Profile.configuration!("balanced") == Profile.configuration!(:balanced)
    assert Profile.configuration!("minimal").name == :minimal

    assert_raise ArgumentError, ~r/unknown retrieval profile: "minimal-ish"/, fn ->
      Profile.configuration!("minimal-ish")
    end

    assert_raise ArgumentError, ~r/experimental minimal retrieval is disabled/, fn ->
      Profile.resolve("minimal", query, inherit?: false)
    end
  end
end
