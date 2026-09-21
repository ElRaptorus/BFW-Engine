defmodule BfwEngineWeb.Ws.EndpointTest do
  use ExUnit.Case, async: true

  alias BfwEngineWeb.Http.Endpoint

  test "UserSocket is mounted on the unified Http.Endpoint" do
    sockets = Endpoint.__sockets__()
    paths = Enum.map(sockets, fn {path, _module, _opts} -> path end)
    assert "/socket" in paths
  end
end
