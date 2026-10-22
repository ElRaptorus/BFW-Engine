defmodule BfwEngine.Api.ListWaitingServiceTasksTest do
  use ExUnit.Case, async: true

  test "rejects an argument that is not a list of strings" do
    assert {:error, :invalid_implementations} =
             BfwEngine.Api.list_waiting_service_tasks(:async_park)

    assert {:error, :invalid_implementations} =
             BfwEngine.Api.list_waiting_service_tasks(["ok", :async_park])
  end
end
