# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.SessionHTML do
  @moduledoc """
  The rendered pages for console sign-in.

    These pages are served to anonymous visitors. They must therefore show no memory, no
    account or peer details, and nothing about why an attempt failed beyond a generic
    notice — everything rendered here is visible to whoever loads the URL.
  """

  use MemHouseWeb, :html

  embed_templates "session_html/*"
end
