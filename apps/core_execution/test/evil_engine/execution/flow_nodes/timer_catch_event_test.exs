defmodule EvilEngine.Execution.FlowNodes.TimerCatchEventTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes.TimerCatchEvent
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Token

  setup do
    Scheduler.reset_state()
    :ok
  end

  defp build_timer_flow_node(timer_def) do
    %FlowNode{
      id: "TimerCatch_1",
      name: "Wait for Timer",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: timer_def
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }
  end

  defp build_process_model(flow_node) do
    end_event = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    %BpmnProcess{
      id: "test-process",
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [flow_node, end_event],
      sequence_flows: [
        %SequenceFlow{id: "Flow_2", source_ref: "TimerCatch_1", target_ref: "End_1"}
      ]
    }
  end

  defp build_context(flow_node, opts \\ []) do
    process_model = build_process_model(flow_node)

    %HandlerContext{
      flow_node_instance_id: Keyword.get(opts, :flow_node_instance_id, "fni-timer-1"),
      process_instance_id: "pi-test-1",
      process_instance_pid: self(),
      process_model: process_model,
      flow_node_this: %{
        "id" => flow_node.id,
        "name" => flow_node.name,
        "type" => "intermediate_catch_event"
      },
      context: %{},
      identity: %{},
      process: %{"id" => "test-process", "name" => "Test Process", "version" => "1.0.0"},
      process_instance: %{"id" => "pi-test-1", "startedAt" => nil, "startedBy" => nil},
      data_objects: %{}
    }
  end

  defp build_token(payload \\ %{}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-test-1",
      payload: payload,
      originating_flow_node_instance_id: nil,
      created_at: DateTime.utc_now()
    }
  end

  # -------------------------------------------------------------------
  # handle_enter/3 — duration
  # -------------------------------------------------------------------

  describe "handle_enter/3 with time_duration" do
    test "returns {:async, ...} with timer_ref and fire_at in type_properties" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)
      token = build_token(%{"order_id" => "123"})

      assert {:async, fni_id, continuation, type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert fni_id == "fni-timer-1"
      assert is_function(continuation, 0)
      assert is_binary(type_properties.timer_ref)
      assert is_binary(type_properties.fire_at)

      {:ok, fire_at, _offset} = DateTime.from_iso8601(type_properties.fire_at)
      assert DateTime.compare(fire_at, DateTime.utc_now()) == :gt

      assert Scheduler.armed_count() == 1
    end

    test "continuation completes when timer fires" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT0S"})
      context = build_context(flow_node)
      token = build_token(%{"order_id" => "123"})

      assert {:async, _fni_id, continuation, _type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert {:ok, %FlowNodeResult{} = result} = continuation.()

      assert result.output_payload == %{"order_id" => "123"}
      assert result.next_flow_node_ids == ["End_1"]
    end
  end

  # -------------------------------------------------------------------
  # handle_enter/3 — date
  # -------------------------------------------------------------------

  describe "handle_enter/3 with time_date" do
    test "schedules timer for a future date" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_date: future})
      context = build_context(flow_node)
      token = build_token()

      assert {:async, _fni_id, _continuation, type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert is_binary(type_properties.timer_ref)
      assert Scheduler.armed_count() == 1
    end

    test "past date fires immediately — continuation returns at once" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_date: past})
      context = build_context(flow_node)
      token = build_token()

      assert {:async, _fni_id, continuation, _type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert {:ok, %FlowNodeResult{}} = continuation.()
    end
  end

  # -------------------------------------------------------------------
  # handle_enter/3 — error cases
  # -------------------------------------------------------------------

  describe "handle_enter/3 with time_cycle" do
    test "returns error — cycles not supported on intermediate catch events" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_cycle: "R3/PT1H"})
      context = build_context(flow_node)
      token = build_token()

      assert {:error, error} = TimerCatchEvent.handle_enter(flow_node, token, context)
      assert error.reason == :unsupported_timer_type
    end
  end

  describe "handle_enter/3 error cases" do
    test "returns error when no timer spec is set" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{})
      context = build_context(flow_node)
      token = build_token()

      assert {:error, error} = TimerCatchEvent.handle_enter(flow_node, token, context)
      assert error.reason == :missing_timer_spec
    end

    test "returns error for invalid ISO duration" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "not-a-duration"})
      context = build_context(flow_node)
      token = build_token()

      assert {:error, %{reason: :timer_resolution_failed}} =
               TimerCatchEvent.handle_enter(flow_node, token, context)
    end

    test "returns error for invalid ISO date" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_date: "not-a-date"})
      context = build_context(flow_node)
      token = build_token()

      assert {:error, %{reason: :timer_resolution_failed}} =
               TimerCatchEvent.handle_enter(flow_node, token, context)
    end
  end

  # -------------------------------------------------------------------
  # handle_resume/3
  # -------------------------------------------------------------------

  describe "handle_resume/3" do
    test "past fire_at completes immediately without scheduling" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)

      entry = %{
        flow_node_id: "TimerCatch_1",
        type_properties: %{"fire_at" => past, "timer_ref" => "old-ref"},
        token: build_token(%{"data" => "preserved"})
      }

      assert {:ok, %FlowNodeResult{} = result} =
               TimerCatchEvent.handle_resume(flow_node, entry, context)

      assert result.output_payload == %{"data" => "preserved"}
      assert result.next_flow_node_ids == ["End_1"]
      assert Scheduler.armed_count() == 0
    end

    test "future fire_at re-schedules and completes when timer fires" do
      future = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)

      entry = %{
        flow_node_id: "TimerCatch_1",
        type_properties: %{"fire_at" => future, "timer_ref" => "old-ref"},
        token: build_token(%{"data" => "preserved"})
      }

      assert {:ok, %FlowNodeResult{} = result} =
               TimerCatchEvent.handle_resume(flow_node, entry, context)

      assert result.output_payload == %{"data" => "preserved"}
      assert result.next_flow_node_ids == ["End_1"]
    end

    test "returns error for missing fire_at" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)

      entry = %{
        flow_node_id: "TimerCatch_1",
        type_properties: %{},
        token: build_token()
      }

      assert {:error, %{reason: :resume_timer_failed}} =
               TimerCatchEvent.handle_resume(flow_node, entry, context)
    end

    test "returns error for invalid fire_at" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)

      entry = %{
        flow_node_id: "TimerCatch_1",
        type_properties: %{"fire_at" => "not-a-date"},
        token: build_token()
      }

      assert {:error, %{reason: :resume_timer_failed}} =
               TimerCatchEvent.handle_resume(flow_node, entry, context)
    end
  end

  # -------------------------------------------------------------------
  # handle_fatal/1 and handle_aborted/1
  # -------------------------------------------------------------------

  describe "handle_fatal/1" do
    test "cancels the armed timer in the Scheduler" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)
      token = build_token()

      assert {:async, _fni_id, _continuation, type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert Scheduler.armed_count() == 1

      entry = %{type_properties: type_properties}
      assert :ok = TimerCatchEvent.handle_fatal(entry)
      assert Scheduler.armed_count() == 0
    end

    test "tolerates missing timer_ref" do
      entry = %{type_properties: %{}}
      assert :ok = TimerCatchEvent.handle_fatal(entry)
    end

    test "tolerates nil type_properties" do
      entry = %{type_properties: nil}
      assert :ok = TimerCatchEvent.handle_fatal(entry)
    end
  end

  describe "handle_aborted/1" do
    test "cancels the armed timer in the Scheduler" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)
      token = build_token()

      assert {:async, _fni_id, _continuation, type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert Scheduler.armed_count() == 1

      entry = %{type_properties: type_properties}
      assert :ok = TimerCatchEvent.handle_aborted(entry)
      assert Scheduler.armed_count() == 0
    end

    test "handles stringified timer_ref from persistence" do
      flow_node = build_timer_flow_node(%EventDefinition.Timer{time_duration: "PT1H"})
      context = build_context(flow_node)
      token = build_token()

      assert {:async, _fni_id, _continuation, type_properties} =
               TimerCatchEvent.handle_enter(flow_node, token, context)

      assert Scheduler.armed_count() == 1

      stringified = %{"timer_ref" => type_properties.timer_ref}
      entry = %{type_properties: stringified}
      assert :ok = TimerCatchEvent.handle_aborted(entry)
      assert Scheduler.armed_count() == 0
    end

    test "cancels all timers by handler PID when pid is present" do
      task_pid =
        spawn(fn ->
          Process.sleep(:infinity)
        end)

      {:ok, _ref} =
        Scheduler.schedule(%{
          fire_at: DateTime.utc_now() |> DateTime.add(3600, :second),
          target: task_pid,
          metadata: %{}
        })

      assert Scheduler.armed_count() >= 1

      entry = %{
        pid: task_pid,
        type_properties: %{timer_ref: "bogus-ref-should-be-ignored"}
      }

      assert :ok = TimerCatchEvent.handle_aborted(entry)
      assert Scheduler.armed_count() == 0

      Process.exit(task_pid, :kill)
    end
  end

  # -------------------------------------------------------------------
  # resolve_timer_spec/5
  # -------------------------------------------------------------------

  describe "resolve_timer_spec/5" do
    test "falls back to ISO 8601 when spec is not a FEEL expression" do
      context = %HandlerContext{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        process_instance_pid: self(),
        flow_node_this: %{},
        context: %{},
        identity: %{},
        process: %{},
        process_instance: %{},
        data_objects: %{}
      }

      reference_time = ~U[2026-06-01 10:00:00Z]

      assert {:ok, fire_at} =
               TimerCatchEvent.resolve_timer_spec(
                 :duration,
                 "PT2H",
                 %{},
                 context,
                 reference_time
               )

      assert DateTime.compare(fire_at, ~U[2026-06-01 12:00:00Z]) == :eq
    end

    test "resolves ISO date spec directly" do
      context = %HandlerContext{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        process_instance_pid: self(),
        flow_node_this: %{},
        context: %{},
        identity: %{},
        process: %{},
        process_instance: %{},
        data_objects: %{}
      }

      assert {:ok, fire_at} =
               TimerCatchEvent.resolve_timer_spec(
                 :date,
                 "2026-12-25T08:00:00Z",
                 %{},
                 context,
                 DateTime.utc_now()
               )

      assert DateTime.compare(fire_at, ~U[2026-12-25 08:00:00Z]) == :eq
    end
  end
end
