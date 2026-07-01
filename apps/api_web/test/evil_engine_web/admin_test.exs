defmodule EvilEngineWeb.AdminTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(EvilEngineWeb.Admin)
  end
end
