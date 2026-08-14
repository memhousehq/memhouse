# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.EntityResolverTest do
  @moduledoc """
  Tests entity mention spotting and noise removal.
  """
  use ExUnit.Case, async: true

  alias MemHouse.Retrieval.EntityResolver

  test "mention spotting rejects closed-class hubs, timezones, and sentence artefacts" do
    statement = "In UTC, Caroline met Mel. She said Wow.\nOctober followed."

    assert EntityResolver.mention_surfaces(statement) == ["Caroline", "Mel", "October"]
  end

  test "mention spotting does not join capitalized forms across lines" do
    assert EntityResolver.mention_surfaces("Ada finished.\nMelanie started.") == [
             "Ada",
             "Melanie"
           ]
  end

  test "mention spotting reuses query boilerplate without removing names such as Will" do
    assert EntityResolver.mention_surfaces("What did Will tell Avery?") == ["Will", "Avery"]
  end

  test "mention spotting drops leading noise such as prepositions" do
    assert EntityResolver.mention_surfaces("In Ada Lovelace") == ["Ada Lovelace"]
  end
end
