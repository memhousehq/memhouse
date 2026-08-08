# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.DiagnosticTest do
  @moduledoc """
  Pins what the retrieval diagnostic may render and export.

  Two properties carry the risk. The exported request is built from an allowlist,
  so a field added to the form later cannot leak a credential or an Account into
  a copied payload. Highlighting returns segments rather than markup, so a
  statement containing angle brackets is escaped by the template like any other
  text and cannot inject anything into the page.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Retrieval.DiagnosticGrant
  alias MemHouseWeb.Console.Diagnostic

  describe "strategy_options/0" do
    test "names every registered strategy and whether it reads the query" do
      options = Diagnostic.strategy_options()

      assert {"lexical", true} in options
      assert {"salience_recency", false} in options
      assert length(options) == length(MemHouse.Retrieval.Profile.strategy_names())
    end
  end

  describe "request_json/4" do
    test "carries the run and nothing that could reproduce the caller" do
      json =
        Diagnostic.request_json(
          "/team",
          "release checklist",
          "balanced",
          %{
            "limit" => 50,
            "strategies" => ["lexical"],
            "deadline" => "disabled",
            "rerank" => false,
            "query_dependent_strategies" => ["lexical"]
          }
        )

      assert Jason.decode!(json) == %{
               "tool" => "search",
               "mode" => "diagnostic",
               "scope_path" => "/team",
               "query" => "release checklist",
               "profile" => "balanced",
               "limit" => 50,
               "strategies" => ["lexical"],
               "deadline" => "disabled",
               "rerank" => false
             }
    end

    test "ignores anything the diagnostic block carries beyond the request" do
      json =
        Diagnostic.request_json("/team", "q", "fast", %{
          "limit" => 12,
          "session_id" => "console-secret",
          "account_id" => "11111111-1111-1111-1111-111111111111",
          "_memhouse_actor" => "actor"
        })

      refute json =~ "console-secret"
      refute json =~ "account_id"
      refute json =~ "actor"
    end
  end

  describe "query_dependent_only/2" do
    test "keeps only candidates a query-reading strategy voted for" do
      candidates = [
        %{"id" => "a", "strategies" => ["lexical", "salience_recency"]},
        %{"id" => "b", "strategies" => ["salience_recency"]},
        %{"id" => "c", "strategies" => []}
      ]

      block = %{"query_dependent_strategies" => ["lexical"]}

      assert Enum.map(Diagnostic.query_dependent_only(candidates, block), & &1["id"]) == ["a"]
    end

    test "returns nothing when no query-reading strategy contributed" do
      candidates = [%{"id" => "a", "strategies" => ["salience_recency"]}]

      assert Diagnostic.query_dependent_only(candidates, %{"query_dependent_strategies" => []}) ==
               []
    end
  end

  describe "segments/2" do
    test "marks each query term and leaves the rest of the statement intact" do
      assert Diagnostic.segments("Avery maintains the release checklist.", "release checklist") ==
               [
                 {:plain, "Avery maintains the "},
                 {:match, "release"},
                 {:plain, " "},
                 {:match, "checklist"},
                 {:plain, "."}
               ]
    end

    test "matches case-insensitively and inside a longer word" do
      assert Diagnostic.segments("Standups are asynchronous.", "standup") ==
               [{:match, "Standup"}, {:plain, "s are asynchronous."}]
    end

    test "leaves markup in a statement as plain text for the template to escape" do
      statement = ~S|A <script>alert("release")</script> statement.|

      segments = Diagnostic.segments(statement, "release")

      assert {:match, "release"} in segments
      assert Enum.map_join(segments, "", fn {_kind, part} -> part end) == statement
      # No fragment is marked safe here; every one is ordinary text.
      assert Enum.all?(segments, fn {_kind, part} -> is_binary(part) end)
    end

    test "preserves multi-byte text around a match" do
      assert Diagnostic.segments("Café release notes", "release") ==
               [{:plain, "Café "}, {:match, "release"}, {:plain, " notes"}]
    end

    test "returns one plain segment when the query carries no usable term" do
      assert Diagnostic.segments("Anything at all.", "") == [{:plain, "Anything at all."}]
      assert Diagnostic.segments("Anything at all.", "a ?") == [{:plain, "Anything at all."}]
    end
  end

  describe "window_note/2" do
    test "warns only when the result filled its window" do
      assert Diagnostic.window_note(12, 12) =~ "deeper candidates may exist"
      assert is_nil(Diagnostic.window_note(11, 12))
    end

    test "names the limit that ran rather than the default" do
      assert Diagnostic.window_note(50, 50) =~ "full at 50 results"
    end
  end

  describe "limit_cap/0" do
    test "reports the operation layer's cap rather than a second one" do
      assert Diagnostic.limit_cap() == DiagnosticGrant.max_limit()
    end
  end
end
