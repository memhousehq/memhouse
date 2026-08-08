# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ExtractorTest do
  @moduledoc """
  Covers structured extraction when no model credential is configured.

  Extraction turns one raw observation into candidate knowledge items. This
  file exercises the offline path: with no provider credential present, the
  local deterministic extractor stands in, and the install still produces
  usable proposals rather than failing. That keeps a fresh clone, an air-gapped
  machine, and CI able to run the whole pipeline without a network call, an
  account, or a bill.

  What is asserted, and why each part matters:

  - **Statements stay natural language.** Knowledge is stored as sentences, not
    as subject-predicate-object triples, so a statement can be read and
    curated by a human without a decoder.
  - **Each item carries its provenance.** Which pipeline produced it and which
    provider answered travel with the item, because a later reader has to be
    able to tell a real model extraction from this local stand-in.
  - **Extraction alone produces no knowledge.** The function returns
    candidates; it writes no knowledge row and grants nothing. Whether any of
    these items ever becomes visible beyond the submitting peer is decided
    later, by the governance gate.

  Important limit on what this proves: the deterministic provider is a
  test-and-local convenience only. Production must never silently fall back to
  it after a configured provider fails, because its output is pattern matching,
  not a model answer — a failed provider call has to leave the observation and
  its job retryable instead. This test asserts that the offline path exists,
  not that substituting it for a real provider is acceptable.

  Runs with `async: false` because the setup mutates OS environment variables
  and application environment, both of which are global to the node.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Pipeline.Extractor

  # Removes any model credential the developer's shell or the loaded config may
  # supply, so nothing below can reach a live endpoint. The deterministic
  # extractor identity asserted in the test comes from the boot-time role
  # configuration, not from this setup. Both the environment variable and the
  # application key are restored afterwards, so the next test sees the machine
  # it expected.
  setup do
    original = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:memhouse, :models)
    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:memhouse, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original, do: System.put_env("OPENROUTER_API_KEY", original)
      Application.put_env(:memhouse, :models, original_models)
    end)
  end

  test "fallback extractor emits natural-language proposed knowledge" do
    # A plain map stands in for a stored observation; nothing here touches the
    # database, and the generated ids only satisfy the shape the extractor
    # reads. The content is two sentences on purpose: one that should be
    # classified by what it expresses, one that should be classified by what it
    # discloses.
    assert {:ok, items} =
             Extractor.extract(%{
               "id" => Ecto.UUID.generate(),
               "peer_id" => Ecto.UUID.generate(),
               "scope_id" => Ecto.UUID.generate(),
               "peer_key" => "alice",
               "scope_path" => "/test/extractor",
               "content" =>
                 "Alice prefers concise status updates. Her phone number should not be shared."
             })

    # One item per sentence, each statement kept as the readable sentence it
    # came from. The first is labelled a preference; the second is labelled
    # personal because it concerns a phone number, and that sensitivity label
    # is what later restricts how widely the item may ever be exposed.
    assert [
             %{statement: "Alice prefers concise status updates.", kind: "preference"},
             %{statement: "Her phone number should not be shared.", sensitivity: "personal"}
           ] = items

    # "f5-1" is a contract identity value stamped on every extracted item: it
    # names the extraction and pipeline behaviour that produced the item, and
    # it is the same identity the health probe reports so a client can tell
    # which extractor it is talking to. It is not the application's semantic
    # version and does not move with releases; changing it is a declared
    # contract transition owing a changelog entry and refreshed evidence.
    assert Enum.all?(items, &(&1.pipeline_version == "f5-1"))

    # Recording the provider on the item is what makes a locally-derived
    # proposal distinguishable from a model-derived one after the fact. Seeing
    # it here also proves no network provider was reached.
    assert Enum.all?(items, &(&1.provider == "deterministic"))
  end
end
