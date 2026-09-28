defmodule BfwEngine.Execution.ScriptDispatchTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Execution.ScriptDispatch

  defmodule ConfiguredAdapter do
    @moduledoc false
    @behaviour ScriptDispatch

    @impl true
    def lookup_script("resolved"), do: {:ok, __MODULE__}
    def lookup_script(_script_ref), do: {:error, :not_found}
  end

  describe "ScriptDispatch.NoOp" do
    test "lookup_script always returns {:error, :not_found}" do
      assert {:error, :not_found} = ScriptDispatch.NoOp.lookup_script("any_key")
    end
  end

  describe "adapter/0" do
    setup do
      previous = Application.get_env(:core_execution, :script_dispatch)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:core_execution, :script_dispatch)
        else
          Application.put_env(:core_execution, :script_dispatch, previous)
        end
      end)

      :ok
    end

    test "returns configured adapter module" do
      Application.put_env(:core_execution, :script_dispatch, ConfiguredAdapter)

      assert ScriptDispatch.adapter() == ConfiguredAdapter
    end

    test "defaults to NoOp when not configured" do
      Application.delete_env(:core_execution, :script_dispatch)

      assert ScriptDispatch.adapter() == ScriptDispatch.NoOp
    end
  end
end
