defmodule BfwEngineWeb.AdminTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(BfwEngineWeb.Admin)
  end
end
