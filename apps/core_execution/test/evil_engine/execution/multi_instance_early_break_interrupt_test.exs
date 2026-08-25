defmodule EvilEngine.Execution.MultiInstanceEarlyBreakInterruptTest do
  @moduledoc """
  Parallel MI early-break must interrupt remaining iteration FNIs so the
  process instance can finish.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
    end)

    :ok
  end

  test "parallel MI remaining iterations reach interrupted before the PI finishes" do
    version_id = random_id()

    definitions =
      BpmnFactory.multi_instance_task_process(
        is_sequential: false,
        flow_node_type: :user_task,
        completion_condition: "loop.completed >= 1",
        process_id: "mi-early-break-states"
      )

    ModelCache.put_new(version_id, definitions)

    process_instance_id = random_id()
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "mi-early-break-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state, ref, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("mi-early-break-#{inspect(ref)}") end)

    assert {:ok, process_instance_pid} =
             Execution.start_process_instance(%{
               process_instance_id: process_instance_id,
               process_version_id: version_id,
               payload: %{"items" => [1, 2, 3]},
               identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
             })

    waiting_ids = await_waiting_user_tasks(process_instance_pid, 3)
    [first_id | remaining_ids] = waiting_ids

    assert :ok =
             ProcessInstance.finish_user_task(
               process_instance_pid,
               first_id,
               %{},
               %Identity{id: "finisher"}
             )

    Enum.each(remaining_ids, fn remaining_id ->
      assert_receive {:fni_state, ^ref,
                      %{
                        flow_node_instance_id: ^remaining_id,
                        terminal_state: :interrupted
                      }},
                     2_000
    end)

    await_process_death(process_instance_pid)
  end

  defp await_waiting_user_tasks(process_instance_pid, count) do
    Enum.reduce_while(1..100, [], fn _attempt, _acc ->
      {:running, state} = :sys.get_state(process_instance_pid)

      waiting_ids =
        state.flow_node_instance_states
        |> Enum.filter(fn {_id, entry} ->
          entry.flow_node_type == :user_task and entry.state == :waiting and
            is_binary(Map.get(entry, :multi_instance_id))
        end)
        |> Enum.map(fn {id, _entry} -> id end)

      if length(waiting_ids) >= count do
        {:halt, waiting_ids}
      else
        Process.sleep(20)
        {:cont, waiting_ids}
      end
    end)
  end

  defp await_process_death(pid) do
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 2_000
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
