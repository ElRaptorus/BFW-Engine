defmodule EvilEngine.TypesTest do
  use ExUnit.Case, async: true

  doctest EvilEngine.Types

  test "module exists" do
    assert Code.ensure_loaded?(EvilEngine.Types)
  end
end
