# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ErrorJSON do
  @moduledoc """
  Renders the body for any JSON request that ends in an error status.

    Configured as the endpoint's only `render_errors` format, so it is reached whenever
    a request raises or halts with an error status and no controller produced a body: an
    unmatched route, a malformed request, or an unhandled exception. Domain errors
    raised by the controllers land here too; nothing gives them a status of their own,
    so they arrive as a 500 unless the exception itself declares otherwise.
  """

  @doc """
  Builds the error body for a rendered error template.
  """
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
