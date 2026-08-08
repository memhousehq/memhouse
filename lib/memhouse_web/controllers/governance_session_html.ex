# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.GovernanceSessionHTML do
  @moduledoc """
  The rendered pages for curator sign-in.

    These pages are served before anyone is authenticated. They must therefore show no
    memory, no knowledge, no peer or account details, and nothing about why a sign-in
    attempt failed beyond a generic notice — everything rendered here is visible to
    whoever loads the URL.
  """

  use MemHouseWeb, :html

  embed_templates "governance_session_html/*"
end
