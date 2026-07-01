defmodule EvilEngine.ExecutionTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(EvilEngine.Execution.ApplicationSupervisor)
  end

  test "DynamicSupervisor started" do
    assert Process.whereis(EvilEngine.Execution.Supervisor)
  end

  test "Registry started" do
    assert Process.whereis(EvilEngine.Execution.Registry)
  end
end
