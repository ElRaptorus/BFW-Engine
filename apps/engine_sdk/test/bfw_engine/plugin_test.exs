defmodule BfwEngine.PluginTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(BfwEngine.Plugin)
  end
end
