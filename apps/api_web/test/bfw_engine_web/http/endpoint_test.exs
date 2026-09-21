defmodule BfwEngineWeb.Http.EndpointTest do
  use ExUnit.Case, async: true

  test "endpoint module is declared" do
    assert Code.ensure_loaded?(BfwEngineWeb.Http.Endpoint)
  end

  test "router module is declared" do
    assert Code.ensure_loaded?(BfwEngineWeb.Http.Router)
  end
end
