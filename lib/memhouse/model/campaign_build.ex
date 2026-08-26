# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.CampaignBuild do
  @moduledoc """
  Immutable source revision attested when the campaign executable is compiled.

  A normal build records `unknown` and cannot activate paid campaign admission.
  The campaign build must set `MEMHOUSE_CAMPAIGN_BUILD_SHA` to its exact full
  Git revision before compilation.
  """

  @revision Application.compile_env(:memhouse, :campaign_build_sha, "unknown")

  @doc "Returns the revision embedded in this compiled application."
  def revision, do: @revision
end
