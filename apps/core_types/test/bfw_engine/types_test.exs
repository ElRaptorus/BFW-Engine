defmodule BfwEngine.TypesTest do
  use ExUnit.Case, async: true

  doctest BfwEngine.Types

  test "module exists" do
    assert Code.ensure_loaded?(BfwEngine.Types)
  end
end
