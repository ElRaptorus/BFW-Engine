defmodule EvilEngine.AuthTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(EvilEngine.Auth.Supervisor)
  end
end
