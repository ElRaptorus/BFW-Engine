defmodule EvilEngine.TelemetryTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(EvilEngine.Telemetry.Supervisor)
  end
end
