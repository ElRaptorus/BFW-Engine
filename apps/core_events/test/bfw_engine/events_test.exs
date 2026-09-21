defmodule BfwEngine.EventsTest do
  use ExUnit.Case, async: true

  test "pubsub server is running" do
    assert Process.whereis(BfwEngine.Events.pubsub_name())
  end
end
