defmodule EvilEngineWeb.Http.EndpointTest do
  use ExUnit.Case, async: true

  test "endpoint module is declared" do
    assert Code.ensure_loaded?(EvilEngineWeb.Http.Endpoint)
  end

  test "router module is declared" do
    assert Code.ensure_loaded?(EvilEngineWeb.Http.Router)
  end
end
