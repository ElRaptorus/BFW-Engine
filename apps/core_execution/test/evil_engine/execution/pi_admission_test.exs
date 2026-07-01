defmodule EvilEngine.Execution.PiAdmissionTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Execution

  describe "count_active/0" do
    test "returns a non-negative integer" do
      count = Execution.count_active()
      assert is_integer(count) and count >= 0
    end
  end

  describe "configured_limit/0" do
    setup do
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)

      on_exit(fn ->
        if original do
          Application.put_env(:core_execution, :max_concurrent_process_instances, original)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end
      end)

      :ok
    end

    test "defaults to :infinity" do
      Application.delete_env(:core_execution, :max_concurrent_process_instances)
      assert Execution.configured_limit() == :infinity
    end

    test "reads configured limit" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 42)
      assert Execution.configured_limit() == 42
    end
  end
end
