defmodule BfwEngine.Execution.ServiceTaskDispatchTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Execution.ServiceTaskDispatch

  defmodule ConfiguredAdapter do
    @moduledoc false
    @behaviour ServiceTaskDispatch

    @impl true
    def lookup_handler("resolved"), do: {:ok, __MODULE__}
    def lookup_handler(_implementation), do: {:error, :not_found}
  end

  describe "NoOp" do
    test "lookup_handler returns :not_found for any type key" do
      assert {:error, :not_found} = ServiceTaskDispatch.NoOp.lookup_handler("http")
      assert {:error, :not_found} = ServiceTaskDispatch.NoOp.lookup_handler("")
      assert {:error, :not_found} = ServiceTaskDispatch.NoOp.lookup_handler("any-key")
    end
  end

  describe "adapter/0" do
    setup do
      previous = Application.get_env(:core_execution, :service_task_dispatch)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:core_execution, :service_task_dispatch)
        else
          Application.put_env(:core_execution, :service_task_dispatch, previous)
        end
      end)

      :ok
    end

    test "returns configured module from application env" do
      Application.put_env(:core_execution, :service_task_dispatch, ConfiguredAdapter)
      assert ServiceTaskDispatch.adapter() == ConfiguredAdapter
      assert {:ok, ConfiguredAdapter} == ConfiguredAdapter.lookup_handler("resolved")
    end

    test "defaults to NoOp when config is absent" do
      Application.delete_env(:core_execution, :service_task_dispatch)
      assert ServiceTaskDispatch.adapter() == ServiceTaskDispatch.NoOp
    end
  end
end
