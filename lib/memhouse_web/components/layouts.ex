# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Layouts do
  @moduledoc """
  The single HTML document shell wrapped around every browser page.

    The JSON API never reaches this module. API responses are rendered without a layout.
  """

  use MemHouseWeb, :html

  @doc """
  Renders the outer HTML document for the curator browser pages.
  """
  attr :inner_content, :any, required: true

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>MemHouse</title>
        <link rel="stylesheet" href="/assets/console.css" />
      </head>
      <body>
        {@inner_content}
        <script type="module" src="/assets/governance.js"></script>
      </body>
    </html>
    """
  end
end
