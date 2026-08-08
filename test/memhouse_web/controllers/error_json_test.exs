# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ErrorJSONTest do
  @moduledoc """
  Pins the JSON body returned for any failed request.
  """

  use MemHouseWeb.ConnCase, async: true

  test "renders 404" do
    assert MemHouseWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  # The wording must not hint at what actually failed. It is derived from the
  # template name alone, so it is identical whether the cause was a database
  # outage, a bad query, or a bug in a controller.
  test "renders 500" do
    assert MemHouseWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
