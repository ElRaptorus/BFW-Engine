defmodule EvilEngine.Integration.Websocket.GlobalChannelEventDeliveryTest do
  @moduledoc """
  End-to-end WebSocket event delivery tests on the `engine:events` channel.

  Every test subscribes to `engine:events` BEFORE triggering the action,
  eliminating the subscribe-before-start race condition that affects
  `process_instance:*` channels.

  Verifies that real engine events flow from EngineEventBus through
  WebSocketSink into Phoenix PubSub and arrive at the test process
  with correct camelCase envelope shape.
  """
  use EvilEngine.ExecutionCase, async: false

  import Phoenix.ChannelTest

  @endpoint EvilEngineWeb.Http.Endpoint
  @moduletag :integration

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Types.Identity
  alias EvilEngineWeb.Ws.EngineChannel
  alias EvilEngineWeb.Ws.Sinks.WebSocket, as: WebSocketSink
  alias EvilEngineWeb.Ws.UserSocket

  setup context do
    :ok = EngineEventBus.register_sink("websocket", WebSocketSink, [])

    identity = %Identity{
      id: "ws-test-user",
      roles: [],
      groups: [],
      claims: %{"lane:default" => "write", "zeeky_boogie_doog" => true}
    }

    socket = socket(UserSocket, "user:#{identity.id}", %{identity: identity})
    {:ok, _, channel_socket} = subscribe_and_join(socket, EngineChannel, "engine:events", %{})

    Map.merge(context, %{channel_socket: channel_socket})
  end

  # ---------------------------------------------------------------------------
  # 1.1 PI lifecycle on global channel
  # ---------------------------------------------------------------------------

  describe "1.1 PI lifecycle on global channel" do
    test "delivers ProcessInstanceStateChanged and FNI events for a linear process" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, start_body} = http_start("LinearStartEnd")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)
      events = collect_events_until(fn events -> count_of_type(events, "ProcessInstanceStateChanged") >= 2 end)

      pi_state_events = filter_type(events, "ProcessInstanceStateChanged")
      fni_started_events = filter_type(events, "FlowNodeInstanceStarted")
      fni_finished_events = filter_type(events, "FlowNodeInstanceFinished")

      assert length(pi_state_events) >= 2,
             "Expected at least 2 PI state changes, got #{length(pi_state_events)}"

      assert length(fni_started_events) >= 1,
             "Expected FNI started events. All types: #{inspect(Enum.map(events, & &1["type"]))}"

      assert length(fni_finished_events) >= 1

      for event <- pi_state_events do
        assert event["data"]["processInstanceId"] == process_instance_id
        assert_d52_envelope(event)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 1.2 User task events
  # ---------------------------------------------------------------------------

  describe "1.2 user task events" do
    test "delivers UserTaskCreated and UserTaskFinished on global channel" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, start_body} = http_start("UserTaskSimple")
      process_instance_id = start_body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task")

      pre_events = collect_events_until(fn events -> has_type?(events, "UserTaskCreated") end)
      created_events = filter_type(pre_events, "UserTaskCreated")

      assert length(created_events) >= 1
      created = hd(created_events)
      assert created["data"]["flowNodeInstanceId"] == user_task_fni.id
      assert_d52_envelope(created)

      {204, _} = http_finish_user_task(user_task_fni.id)
      wait_for_process_instance(process_instance_id)

      post_events = collect_events_until(fn events -> has_type?(events, "UserTaskFinished") end)
      finished_events = filter_type(post_events, "UserTaskFinished")

      assert length(finished_events) >= 1
      finished = hd(finished_events)
      assert to_string(finished["data"]["outcome"]) == "completed"
      assert_d52_envelope(finished)
    end
  end

  # ---------------------------------------------------------------------------
  # 1.3 Embedded subprocess fan-out
  # ---------------------------------------------------------------------------

  describe "1.3 embedded subprocess fan-out" do
    test "delivers SubProcessChildStarted and child FNI events on global channel" do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")
      {201, start_body} = http_start("EmbeddedSubprocessHappyPath")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)
      events = collect_events_until(fn events -> has_type?(events, "SubProcessChildStarted") end)

      subprocess_started = filter_type(events, "SubProcessChildStarted")

      assert length(subprocess_started) >= 1,
             "Expected SubProcessChildStarted. Types: #{inspect(Enum.map(events, & &1["type"]))}"

      fni_events = Enum.filter(events, &(&1["type"] in ["FlowNodeInstanceStarted", "FlowNodeInstanceFinished"]))
      assert length(fni_events) >= 2, "Expected child FNI events on global channel"
    end
  end

  # ---------------------------------------------------------------------------
  # 1.4 Call activity child events
  # ---------------------------------------------------------------------------

  describe "1.4 call activity child events" do
    test "delivers CallActivityChildStarted on global channel" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy("call_activity_basic.bpmn")
      {201, start_body} = http_start("CallActivityBasic")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)
      events = collect_events_until(fn events -> has_type?(events, "CallActivityChildStarted") end)

      ca_child_started = filter_type(events, "CallActivityChildStarted")

      assert length(ca_child_started) >= 1,
             "Expected CallActivityChildStarted. Types: #{inspect(Enum.map(events, & &1["type"]))}"

      event = hd(ca_child_started)
      assert event["data"]["parentProcessInstanceId"] == process_instance_id
      assert is_binary(event["data"]["childProcessInstanceId"])
      assert_d52_envelope(event)
    end
  end

  # ---------------------------------------------------------------------------
  # 1.5 Error/fatal events
  # ---------------------------------------------------------------------------

  describe "1.5 error/fatal events" do
    test "delivers fatal state changes on global channel" do
      {201, _} = http_deploy("embedded_subprocess_unhandled_error_both_fatal.bpmn")
      {201, start_body} = http_start("EmbeddedSubprocessUnhandledError")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      events =
        collect_events_until(fn events ->
          events
          |> filter_type("ProcessInstanceStateChanged")
          |> Enum.any?(fn e -> to_string(e["data"]["newState"]) == "fatal" end)
        end)

      pi_fatal_events =
        events
        |> filter_type("ProcessInstanceStateChanged")
        |> Enum.filter(fn e -> to_string(e["data"]["newState"]) == "fatal" end)

      assert length(pi_fatal_events) >= 1, "Expected at least one PI → fatal transition"

      fni_fatal_events =
        events
        |> filter_type("FlowNodeInstanceFinished")
        |> Enum.filter(fn e -> to_string(e["data"]["terminalState"]) == "fatal" end)

      assert length(fni_fatal_events) >= 1,
             "Expected at least one FNI terminalState=fatal"
    end
  end

  # ---------------------------------------------------------------------------
  # 1.6 Timer boundary event
  # ---------------------------------------------------------------------------

  describe "1.6 timer boundary event" do
    test "delivers events after timer fires on global channel" do
      {201, _} = http_deploy("embedded_subprocess_timer_boundary.bpmn")
      {201, start_body} = http_start("EmbeddedSubprocessTimerBoundary")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 15_000)

      events =
        collect_events_until(
          fn events ->
            events
            |> filter_type("ProcessInstanceStateChanged")
            |> Enum.any?(fn e ->
              state = to_string(e["data"]["newState"])
              state in ["finished", "aborted"]
            end)
          end,
          10_000
        )

      pi_terminal =
        events
        |> filter_type("ProcessInstanceStateChanged")
        |> Enum.filter(fn e ->
          to_string(e["data"]["newState"]) in ["finished", "aborted"]
        end)

      assert length(pi_terminal) >= 1,
             "Expected process to reach terminal state after timer boundary"
    end
  end

  # ---------------------------------------------------------------------------
  # 1.7 Envelope shape verification
  # ---------------------------------------------------------------------------

  describe "1.7 envelope shape verification" do
    test "all events on global channel have correct camelCase envelope shape" do
      {201, _} = http_deploy("linear_three_node.bpmn")
      {201, start_body} = http_start("LinearThreeNode")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      events =
        collect_events_until(fn events -> count_of_type(events, "ProcessInstanceStateChanged") >= 2 end)

      assert length(events) >= 1, "Expected at least one event"

      for event <- events do
        assert_d52_envelope(event)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 1.8 DMN evaluation events
  # ---------------------------------------------------------------------------

  describe "1.8 DMN evaluation events" do
    test "delivers DecisionEvaluated on global channel after ad-hoc evaluation" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, _eval_result} =
        http_evaluate_decision("definitions_discount", %{"age" => 25})

      events = collect_events_until(fn events -> has_type?(events, "DecisionEvaluated") end)
      dmn_events = filter_type(events, "DecisionEvaluated")

      assert length(dmn_events) >= 1,
             "Expected DecisionEvaluated. Types: #{inspect(Enum.map(events, & &1["type"]))}"

      event = hd(dmn_events)
      assert is_binary(event["data"]["decisionDefinitionId"])
      assert_d52_envelope(event)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collect_events_until(condition_fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_until(condition_fun, deadline, [])
  end

  defp do_collect_until(condition_fun, deadline, accumulated) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      %Phoenix.Socket.Message{event: "engine_event", payload: payload} ->
        new_accumulated = accumulated ++ [payload]

        if condition_fun.(new_accumulated) do
          drain_remaining(new_accumulated)
        else
          do_collect_until(condition_fun, deadline, new_accumulated)
        end
    after
      min(remaining, 200) ->
        if condition_fun.(accumulated) or remaining <= 0 do
          accumulated
        else
          do_collect_until(condition_fun, deadline, accumulated)
        end
    end
  end

  defp drain_remaining(accumulated) do
    receive do
      %Phoenix.Socket.Message{event: "engine_event", payload: payload} ->
        drain_remaining(accumulated ++ [payload])
    after
      200 ->
        accumulated
    end
  end

  defp filter_type(events, type), do: Enum.filter(events, &(&1["type"] == type))
  defp count_of_type(events, type), do: events |> filter_type(type) |> length()
  defp has_type?(events, type), do: count_of_type(events, type) >= 1

  defp assert_d52_envelope(event) do
    assert is_binary(event["type"]),
           "Event missing 'type' string: #{inspect(event)}"

    assert is_map(event["data"]),
           "Event missing 'data' map: #{inspect(event)}"

    occurred_at = event["occurredAt"]

    assert occurred_at != nil,
           "Event missing 'occurredAt': #{inspect(event)}"

    assert is_binary(occurred_at) or match?(%DateTime{}, occurred_at),
           "Event 'occurredAt' must be ISO 8601 string or DateTime: #{inspect(occurred_at)}"

    snake_keys =
      event["data"]
      |> Map.keys()
      |> Enum.filter(&String.contains?(&1, "_"))

    assert snake_keys == [],
           "Event data contains snake_case keys (camelCase violation): #{inspect(snake_keys)}"
  end
end
