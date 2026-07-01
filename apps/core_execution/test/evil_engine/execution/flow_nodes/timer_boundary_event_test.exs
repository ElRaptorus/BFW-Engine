defmodule EvilEngine.Execution.FlowNodes.TimerBoundaryEventTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.FlowNodes.TimerBoundaryEvent
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Token

  setup do
    Scheduler.reset_state()
    :ok
  end

  defp build_boundary_node(opts \\ []) do
    cancel_activity = Keyword.get(opts, :cancel_activity, true)
    time_duration = Keyword.get(opts, :time_duration, nil)
    time_date = Keyword.get(opts, :time_date, nil)
    time_cycle = Keyword.get(opts, :time_cycle, nil)

    %FlowNode{
      id: "TimerBE_1",
      name: "Timer Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Timer{
          time_date: time_date,
          time_duration: time_duration,
          time_cycle: time_cycle
        }
      },
      outgoing: ["Flow_BE"]
    }
  end

  defp build_context(flow_node) do
    end_timeout = %FlowNode{
      id: "End_Timeout",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    model = %BpmnProcess{
      id: "test-process",
      flow_nodes: [flow_node, end_timeout],
      sequence_flows: [
        %SequenceFlow{id: "Flow_BE", source_ref: "TimerBE_1", target_ref: "End_Timeout"}
      ]
    }

    %HandlerContext{
      flow_node_instance_id: "fni-tbe-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
      process_model: model,
      host_flow_node_instance_id: "fni-host-1",
      identity: %{},
      process: %{},
      process_instance: %{id: "pi-1"},
      data_objects: %{}
    }
  end

  defp build_token do
    %Token{
      id: "t1",
      process_instance_id: "pi-1",
      payload: %{"key" => "value"}
    }
  end

  describe "handle_enter/3" do
    test "returns {:async, ...} with time_duration (interrupting)" do
      flow_node = build_boundary_node(time_duration: "PT1H", cancel_activity: true)
      context = build_context(flow_node)
      token = build_token()

      assert {:async, "fni-tbe-1", continuation, type_properties} =
               TimerBoundaryEvent.handle_enter(flow_node, token, context)

      assert is_function(continuation, 0)
      assert type_properties.host_flow_node_instance_id == "fni-host-1"
      assert type_properties.cancel_activity == true
      assert is_binary(type_properties.fire_at)
      assert is_binary(type_properties.timer_ref)
    end

    test "returns {:async, ...} with time_duration (non-interrupting)" do
      flow_node = build_boundary_node(time_duration: "PT30M", cancel_activity: false)
      context = build_context(flow_node)
      token = build_token()

      assert {:async, "fni-tbe-1", _continuation, type_properties} =
               TimerBoundaryEvent.handle_enter(flow_node, token, context)

      assert type_properties.cancel_activity == false
    end

    test "returns {:async, ...} with time_date" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      flow_node = build_boundary_node(time_date: future, cancel_activity: true)
      context = build_context(flow_node)
      token = build_token()

      assert {:async, "fni-tbe-1", _continuation, type_properties} =
               TimerBoundaryEvent.handle_enter(flow_node, token, context)

      assert type_properties.cancel_activity == true
    end

    test "returns {:async, ...} with time_cycle (interrupting, one-shot)" do
      flow_node = build_boundary_node(time_cycle: "R3/PT1H", cancel_activity: true)
      context = build_context(flow_node)
      token = build_token()

      assert {:async, "fni-tbe-1", continuation, type_properties} =
               TimerBoundaryEvent.handle_enter(flow_node, token, context)

      assert is_function(continuation, 0)
      assert type_properties.cancel_activity == true
      assert is_binary(type_properties.fire_at)
      assert is_binary(type_properties.timer_ref)
      refute Map.has_key?(type_properties, :is_cycle)
    end

    test "returns {:async, ...} with time_cycle (non-interrupting, looping)" do
      flow_node = build_boundary_node(time_cycle: "R3/PT1H", cancel_activity: false)
      context = build_context(flow_node)
      token = build_token()

      assert {:async, "fni-tbe-1", continuation, type_properties} =
               TimerBoundaryEvent.handle_enter(flow_node, token, context)

      assert is_function(continuation, 0)
      assert type_properties.cancel_activity == false
      assert type_properties.is_cycle == true
      assert is_binary(type_properties.fire_at)
      assert is_binary(type_properties.timer_ref)
    end

    test "returns error for missing timer spec" do
      flow_node = build_boundary_node()
      context = build_context(flow_node)
      token = build_token()

      assert {:error, %{reason: :missing_timer_spec}} =
               TimerBoundaryEvent.handle_enter(flow_node, token, context)
    end

    test "continuation returns {:boundary, ...} when timer fires (interrupting)" do
      flow_node = build_boundary_node(time_duration: "PT0S", cancel_activity: true)
      context = build_context(flow_node)
      token = build_token()

      {:async, _fni_id, continuation, _type_props} =
        TimerBoundaryEvent.handle_enter(flow_node, token, context)

      result = continuation.()
      assert {:boundary, "TimerBE_1", %{}, true} = result
    end

    test "continuation returns {:boundary, ...} when timer fires (non-interrupting)" do
      flow_node = build_boundary_node(time_duration: "PT0S", cancel_activity: false)
      context = build_context(flow_node)
      token = build_token()

      {:async, _fni_id, continuation, _type_props} =
        TimerBoundaryEvent.handle_enter(flow_node, token, context)

      result = continuation.()
      assert {:boundary, "TimerBE_1", %{}, false} = result
    end

    test "interrupting cycle fires once and returns {:boundary, ...}" do
      flow_node = build_boundary_node(time_cycle: "R3/PT0S", cancel_activity: true)
      context = build_context(flow_node)
      token = build_token()

      {:async, _fni_id, continuation, _type_props} =
        TimerBoundaryEvent.handle_enter(flow_node, token, context)

      result = continuation.()
      assert {:boundary, "TimerBE_1", %{}, true} = result
    end

    test "non-interrupting cycle with R1 returns {:boundary, ...} on single fire" do
      flow_node = build_boundary_node(time_cycle: "R1/PT0S", cancel_activity: false)
      context = build_context(flow_node)
      token = build_token()

      {:async, _fni_id, continuation, _type_props} =
        TimerBoundaryEvent.handle_enter(flow_node, token, context)

      result = continuation.()
      assert {:boundary, "TimerBE_1", %{}, false} = result
    end

    test "non-interrupting cycle with R2 sends intermediate fire then returns final" do
      flow_node = build_boundary_node(time_cycle: "R2/PT0S", cancel_activity: false)
      context = build_context(flow_node)
      token = build_token()

      {:async, fni_id, continuation, _type_props} =
        TimerBoundaryEvent.handle_enter(flow_node, token, context)

      result = continuation.()

      assert_received {:fni_result, ^fni_id, {:boundary_cycle_fire, "TimerBE_1", %{}, false}}

      assert {:boundary, "TimerBE_1", %{}, false} = result
    end

    test "non-interrupting cycle with R3 sends two intermediate fires then returns final" do
      flow_node = build_boundary_node(time_cycle: "R3/PT0S", cancel_activity: false)
      context = build_context(flow_node)
      token = build_token()

      {:async, fni_id, continuation, _type_props} =
        TimerBoundaryEvent.handle_enter(flow_node, token, context)

      result = continuation.()

      assert_received {:fni_result, ^fni_id, {:boundary_cycle_fire, "TimerBE_1", %{}, false}}

      assert_received {:fni_result, ^fni_id, {:boundary_cycle_fire, "TimerBE_1", %{}, false}}

      assert {:boundary, "TimerBE_1", %{}, false} = result
    end
  end

  describe "handle_fatal/1" do
    test "cancels the armed timer" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: DateTime.utc_now() |> DateTime.add(3600, :second),
          target: self(),
          metadata: %{}
        })

      entry = %{
        type_properties: %{timer_ref: timer_ref, fire_at: "2099-01-01T00:00:00Z"}
      }

      assert :ok = TimerBoundaryEvent.handle_fatal(entry)
      assert {:error, :not_found} = Scheduler.cancel(timer_ref)
    end

    test "handles nil timer_ref gracefully" do
      entry = %{type_properties: %{}}
      assert :ok = TimerBoundaryEvent.handle_fatal(entry)
    end
  end

  describe "handle_aborted/1" do
    test "cancels the armed timer" do
      {:ok, timer_ref} =
        Scheduler.schedule(%{
          fire_at: DateTime.utc_now() |> DateTime.add(3600, :second),
          target: self(),
          metadata: %{}
        })

      entry = %{
        type_properties: %{timer_ref: timer_ref, fire_at: "2099-01-01T00:00:00Z"}
      }

      assert :ok = TimerBoundaryEvent.handle_aborted(entry)
      assert {:error, :not_found} = Scheduler.cancel(timer_ref)
    end

    test "cancels all timers for the handler Task PID even when timer_ref is stale" do
      task_pid =
        spawn(fn ->
          Process.sleep(:infinity)
        end)

      {:ok, _stale_ref} =
        Scheduler.schedule(%{
          fire_at: DateTime.utc_now() |> DateTime.add(3600, :second),
          target: task_pid,
          metadata: %{note: "stale"}
        })

      {:ok, _current_ref} =
        Scheduler.schedule(%{
          fire_at: DateTime.utc_now() |> DateTime.add(7200, :second),
          target: task_pid,
          metadata: %{note: "current"}
        })

      armed_before = Scheduler.armed_count()
      assert armed_before >= 2

      entry = %{
        pid: task_pid,
        type_properties: %{timer_ref: "completely-bogus-ref"}
      }

      assert :ok = TimerBoundaryEvent.handle_aborted(entry)

      armed_after = Scheduler.armed_count()
      assert armed_after == armed_before - 2

      Process.exit(task_pid, :kill)
    end
  end

  describe "handle_resume/3" do
    test "fires immediately when fire_at is in the past" do
      flow_node = build_boundary_node(time_duration: "PT1H", cancel_activity: true)
      context = build_context(flow_node)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      entry = %{
        type_properties: %{
          "fire_at" => past,
          "cancel_activity" => true,
          "host_flow_node_instance_id" => "fni-host-1"
        },
        token: build_token()
      }

      assert {:boundary, "TimerBE_1", %{}, true} =
               TimerBoundaryEvent.handle_resume(flow_node, entry, context)
    end

    test "waits for timer when fire_at is in the future" do
      flow_node = build_boundary_node(time_duration: "PT0S", cancel_activity: false)
      context = build_context(flow_node)

      fire_at = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

      entry = %{
        type_properties: %{
          "fire_at" => fire_at,
          "cancel_activity" => false,
          "host_flow_node_instance_id" => "fni-host-1"
        },
        token: build_token()
      }

      test_pid = self()

      spawn(fn ->
        result = TimerBoundaryEvent.handle_resume(flow_node, entry, context)
        send(test_pid, {:resume_result, result})
      end)

      assert_receive {:resume_result, {:boundary, "TimerBE_1", %{}, false}}, 5_000
    end

    test "returns error when fire_at is missing" do
      flow_node = build_boundary_node(time_duration: "PT1H", cancel_activity: true)
      context = build_context(flow_node)

      entry = %{
        type_properties: %{},
        token: build_token()
      }

      assert {:error, %{reason: :resume_timer_failed}} =
               TimerBoundaryEvent.handle_resume(flow_node, entry, context)
    end
  end
end
