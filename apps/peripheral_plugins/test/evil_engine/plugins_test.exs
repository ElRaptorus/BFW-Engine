defmodule EvilEngine.PluginsTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(EvilEngine.Plugins.Supervisor)
  end
end
