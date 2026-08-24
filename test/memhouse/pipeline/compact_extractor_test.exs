# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.CompactExtractorTest do
  @moduledoc """
  Pins the reversible extractor contract selection used by evaluation runs.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Model.Schema.CompactExtraction
  alias MemHouse.Model.Schema.CompactExtractionBatch
  alias MemHouse.Model.Schema.Extraction
  alias MemHouse.Model.Schema.ExtractionBatch
  alias MemHouse.Pipeline.Extractor

  setup do
    original = Application.fetch_env!(:memhouse, :compact_extraction)
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    on_exit(fn ->
      Application.put_env(:memhouse, :compact_extraction, original)
      Application.put_env(:memhouse, :model_roles, original_roles)
    end)
  end

  test "keeps the accepted extraction contract as the default" do
    Application.put_env(:memhouse, :compact_extraction,
      enabled: false,
      experiment_identity: "compact-explicit-v1",
      prompt_version: "extract-compact-exp-1"
    )

    assert %{
             mode: :current,
             experiment_identity: nil,
             prompt_version: "extract-14",
             schema: Extraction,
             batch_schema: ExtractionBatch
           } = Extractor.extraction_contract()
  end

  test "selects the versioned compact contract only when explicitly enabled" do
    Application.put_env(:memhouse, :compact_extraction,
      enabled: true,
      experiment_identity: "compact-explicit-v1",
      prompt_version: "extract-compact-exp-1"
    )

    assert %{
             mode: :compact,
             experiment_identity: "compact-explicit-v1",
             prompt_version: "extract-compact-exp-1",
             schema: CompactExtraction,
             batch_schema: CompactExtractionBatch
           } = Extractor.extraction_contract()

    assert Extractor.prompt_version() == "extract-compact-exp-1"
    assert Extractor.batch_schema() == CompactExtractionBatch

    assert Extractor.admission_identity("utf8-bytes-v1:target=4096") ==
             "utf8-bytes-v1:target=4096:extractor=compact-explicit-v1"
  end

  test "runs the compact contract through the deterministic provider and stamps its version" do
    enable_compact!()

    message_id = Ecto.UUID.generate()

    assert {:ok, [candidate]} =
             Extractor.extract(%{
               "id" => message_id,
               "peer_id" => Ecto.UUID.generate(),
               "scope_id" => Ecto.UUID.generate(),
               "peer_key" => "avery",
               "scope_path" => "/compact",
               "content" => "Avery owns the release checklist."
             })

    assert candidate.kind == "fact"
    assert candidate.sensitivity == "restricted"
    assert candidate.target_level == "peer"
    assert candidate.prompt_version == "extract-compact-exp-1"
    assert candidate.pipeline_version == "f5-1"
  end

  defp enable_compact! do
    Application.put_env(:memhouse, :compact_extraction,
      enabled: true,
      experiment_identity: "compact-explicit-v1",
      prompt_version: "extract-compact-exp-1"
    )

    roles = Application.fetch_env!(:memhouse, :model_roles)

    Application.put_env(
      :memhouse,
      :model_roles,
      Keyword.update!(roles, :ingest_extractor, fn role ->
        Map.put(role, :prompt_version, "extract-compact-exp-1")
      end)
    )
  end
end
