defmodule BfwEngine.TelemetryTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(BfwEngine.Telemetry.Supervisor)
  end
end
