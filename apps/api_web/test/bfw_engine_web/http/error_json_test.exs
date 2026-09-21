defmodule BfwEngineWeb.Http.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias BfwEngineWeb.Http.ErrorJSON

  test "renders 404 template" do
    result = ErrorJSON.render("404.json", %{})
    assert result == %{error: "not_found", message: "Not Found"}
  end

  test "renders 500 template" do
    result = ErrorJSON.render("500.json", %{})
    assert result == %{error: "internal_error", message: "Internal Server Error"}
  end
end
