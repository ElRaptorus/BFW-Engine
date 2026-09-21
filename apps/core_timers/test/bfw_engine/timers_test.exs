defmodule BfwEngine.TimersTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(BfwEngine.Timers)
  end

  test "supervision tree started" do
    assert Process.whereis(BfwEngine.Timers.Supervisor)
  end

  test "scheduler GenServer is running under supervisor" do
    assert Process.whereis(BfwEngine.Timers.Scheduler)
    assert Process.alive?(Process.whereis(BfwEngine.Timers.Scheduler))
  end
end
