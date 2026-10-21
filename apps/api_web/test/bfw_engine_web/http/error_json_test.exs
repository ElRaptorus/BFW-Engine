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

  for {template, code, message} <- [
        {"400.json", "bad_request", "Bad Request"},
        {"406.json", "not_acceptable", "Not Acceptable"},
        {"413.json", "payload_too_large", "Request Entity Too Large"},
        {"415.json", "unsupported_media_type", "Unsupported Media Type"}
      ] do
    test "renders #{template} with the specific error code" do
      assert ErrorJSON.render(unquote(template), %{}) ==
               %{error: unquote(code), message: unquote(message)}
    end
  end

  test "an unlisted status still falls back to internal_error" do
    assert %{error: "internal_error"} = ErrorJSON.render("503.json", %{})
  end
end
