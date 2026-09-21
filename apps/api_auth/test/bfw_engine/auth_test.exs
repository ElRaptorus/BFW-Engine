defmodule BfwEngine.AuthTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(BfwEngine.Auth.Supervisor)
  end
end
