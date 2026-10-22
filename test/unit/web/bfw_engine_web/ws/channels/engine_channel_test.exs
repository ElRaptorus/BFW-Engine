defmodule BfwEngineWeb.Ws.EngineChannelTest do
  use ExUnit.Case, async: true

  import Phoenix.ChannelTest

  @endpoint BfwEngineWeb.Http.Endpoint

  test "EngineChannel module is loadable" do
    assert Code.ensure_loaded?(BfwEngineWeb.Ws.EngineChannel)
  end

  test "join/3 succeeds for engine:events topic" do
    assert {:ok, _, socket} =
             socket(BfwEngineWeb.Ws.UserSocket, "test_join", %{})
             |> subscribe_and_join(BfwEngineWeb.Ws.EngineChannel, "engine:events", %{})

    assert socket.topic == "engine:events"
  end

  test "join/3 rejects process_instance:<id> topic without identity/visible process instance" do
    topic = "process_instance:test-instance-#{System.unique_integer([:positive])}"

    assert {:error, %{reason: "not_found"}} =
             socket(BfwEngineWeb.Ws.UserSocket, "test_join_pi", %{})
             |> subscribe_and_join(BfwEngineWeb.Ws.EngineChannel, topic, %{})
  end
end
