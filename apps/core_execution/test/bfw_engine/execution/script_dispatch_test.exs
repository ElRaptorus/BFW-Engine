defmodule BfwEngine.Execution.ScriptDispatchTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Execution.ScriptDispatch

  describe "ScriptDispatch.NoOp" do
    test "lookup_script always returns {:error, :not_found}" do
      assert {:error, :not_found} = ScriptDispatch.NoOp.lookup_script("any_key")
    end
  end

  describe "adapter/0" do
    test "returns configured adapter module" do
      previous = Application.get_env(:core_execution, :script_dispatch)
      Application.put_env(:core_execution, :script_dispatch, SomeFakeModule)

      assert ScriptDispatch.adapter() == SomeFakeModule

      if previous do
        Application.put_env(:core_execution, :script_dispatch, previous)
      else
        Application.delete_env(:core_execution, :script_dispatch)
      end
    end

    test "defaults to NoOp when not configured" do
      previous = Application.get_env(:core_execution, :script_dispatch)
      Application.delete_env(:core_execution, :script_dispatch)

      assert ScriptDispatch.adapter() == ScriptDispatch.NoOp

      if previous do
        Application.put_env(:core_execution, :script_dispatch, previous)
      end
    end
  end
end
