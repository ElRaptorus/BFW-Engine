defmodule EvilEngine.PluginTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(EvilEngine.Plugin)
  end
end
