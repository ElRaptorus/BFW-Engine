defmodule BfwEngine.PluginsTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(BfwEngine.Plugins.Supervisor)
  end
end
