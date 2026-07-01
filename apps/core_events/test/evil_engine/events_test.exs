defmodule EvilEngine.EventsTest do
  use ExUnit.Case, async: true

  test "pubsub server is running" do
    assert Process.whereis(EvilEngine.Events.pubsub_name())
  end
end
