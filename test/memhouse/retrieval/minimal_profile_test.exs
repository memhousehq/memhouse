# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.MinimalProfileTest do
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
    assert profile.version == "minimal-exp-1"
    assert profile.strategies == [:semantic, :lexical]
    assert Enum.map(profile.strategy_modules, & &1.name()) == [:semantic, :lexical]
    assert profile.rerank == false

    refute :temporal in profile.strategies
    refute :salience_recency in profile.strategies
    refute :entity_match in profile.strategies
    refute :relation_expand in profile.strategies
  end
end
