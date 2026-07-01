defmodule EvilEngine.TimersTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(EvilEngine.Timers)
  end

  test "supervision tree started" do
    assert Process.whereis(EvilEngine.Timers.Supervisor)
  end

  test "scheduler GenServer is running under supervisor" do
    assert Process.whereis(EvilEngine.Timers.Scheduler)
    assert Process.alive?(Process.whereis(EvilEngine.Timers.Scheduler))
  end
end
