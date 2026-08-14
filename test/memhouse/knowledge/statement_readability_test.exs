# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge.StatementReadabilityTest do
  @moduledoc """
  Pins the readability rule that keeps a degenerate model generation out of
  knowledge.

  A decoding collapse produces text that is syntactically a string but carries
  almost no words — runs of ellipsis, zero-width spaces, and a leaked field
  name. Blank and `min_length: 1` checks accept it, so the rule is a ratio of
  real characters, enforced both in the extraction cast (which gives the model
  a repair message) and on the resource (which gives every write path a gate).
  """

  use ExUnit.Case, async: true

  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.Statement
  alias MemHouse.Model.Schema.Extraction

  # The statement that reached the console: real words diluted by a repetition
  # collapse, including a zero-width space and the schema's own field name.
  @degenerate "Melanie told the         ​        …………  ……  … … … … … … … ... … … …… … … …… … statement………… ... ..."

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()

  defp context do
    %{
      account_id: @account_id,
      scope_id: @scope_id,
      known_peer_keys: ["avery"],
      source_peer_key: "avery"
    }
  end

  defp item(statement) do
    %{
      "statement" => statement,
      "kind" => "fact",
      "subject_type" => "peer",
      "subject_ref" => "avery",
      "confidence_level" => "stated_explicitly",
      "sensitivity" => "internal",
      "target_level" => "peer"
    }
  end

  defp cast(statement), do: Extraction.cast(%{"items" => [item(statement)]}, context())

  defp changeset(statement) do
    KnowledgeItem
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(@account_id)
    |> Ash.Changeset.for_create(:create_from_pipeline, %{
      scope_id: @scope_id,
      statement: statement,
      kind: "fact",
      confidence: 0.9,
      sensitivity: "internal",
      target_level: "peer",
      state: "proposed",
      extracting_provider: "test",
      extracting_model: "test",
      extracting_model_version: "test",
      prompt_version: "test",
      pipeline_version: "f5-1"
    })
  end

  describe "extraction cast" do
    test "rejects a statement diluted by repeated filler characters" do
      assert {:error, [message]} = cast(@degenerate)
      assert message =~ "statement"
      refute message =~ "Melanie"
    end

    test "rejects a statement made only of ellipsis" do
      assert {:error, [_message]} = cast("……………… … … … … … … … … … … … … … …")
    end

    test "keeps ordinary prose, including dates, currency, and a quoted value" do
      for statement <- [
            "Avery prefers weekly release summaries.",
            "On 2026-03-14 Avery moved the release to Q3 (pending legal sign-off).",
            "Avery's recorded preference is \"drop the Redis dependency\" as of 2026-01-02.",
            "Avery reports hosting costs of $1,200/month; the owner is platform-team."
          ] do
        assert {:ok, [candidate]} = cast(statement)
        assert candidate.statement == statement
      end
    end

    test "normalizes stray whitespace and zero-width characters it accepts" do
      assert {:ok, [candidate]} =
               cast("Avery   prefers​ weekly\n\nrelease summaries.")

      assert candidate.statement == "Avery prefers weekly release summaries."
    end
  end

  describe "create_from_pipeline" do
    test "refuses a degenerate statement on every write path" do
      refute changeset(@degenerate).valid?
    end

    test "stores the normalized statement and hashes that text" do
      changeset = changeset("Avery   prefers​ weekly\n\nrelease summaries.")

      assert changeset.valid?

      assert Ash.Changeset.get_attribute(changeset, :statement) ==
               "Avery prefers weekly release summaries."

      assert Ash.Changeset.get_attribute(changeset, :statement_hash) ==
               MemHouse.Pipeline.Idempotency.content_hash(
                 "Avery prefers weekly release summaries."
               )
    end
  end

  describe "Statement" do
    test "normalize strips zero-width characters and collapses whitespace" do
      assert Statement.normalize("  a​  b\tc\n") == "a b c"
    end

    test "prose? leaves a short punctuation-heavy fragment alone" do
      assert Statement.prose?("R&D — 40%.")
    end

    test "prose? rejects empty text" do
      refute Statement.prose?("   ​ ")
    end

    test "renders valid time separately from the stored statement" do
      assert Statement.with_validity(
               "Avery joined the release review.",
               ~U[2026-08-07 13:14:15Z],
               ~U[2026-08-09 13:14:15Z]
             ) ==
               "Avery joined the release review. (true from 2026-08-07 until 2026-08-09)"
    end

    test "leaves an undated statement unchanged" do
      assert Statement.with_validity("Avery prefers concise summaries.", nil, nil) ==
               "Avery prefers concise summaries."
    end
  end
end
