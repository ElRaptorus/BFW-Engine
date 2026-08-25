defmodule EvilEngineWeb.Ws.RootFanOutTest do
  @moduledoc """
  Verifies SP-13 root-PI PubSub fan-out for events that now carry
  `root_process_instance_id`.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.Types.Event
  alias EvilEngineWeb.Ws.Sinks.WebSocket

  setup do
    {:ok, sink_state} = WebSocket.init([])
    %{sink_state: sink_state}
  end

  test "TimerFired with a distinct root broadcasts to child and root PI topics", %{
    sink_state: sink_state
  } do
    pubsub = EvilEngine.Events.pubsub_name()
    child_process_instance_id = "child-pi-#{System.unique_integer([:positive])}"
    root_process_instance_id = "root-pi-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{child_process_instance_id}")
    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{root_process_instance_id}")

    event = %Event.TimerFired{
      timer_ref: "timer-ref-1",
      process_instance_id: child_process_instance_id,
      flow_node_instance_id: "fni-1",
      flow_node_id: "Catch_timer",
      kind: :catch,
      root_process_instance_id: root_process_instance_id,
      occurred_at: DateTime.utc_now()
    }

    assert {:ok, ^sink_state} = WebSocket.handle_event(event, sink_state)

    assert_receive {:engine_event, %{"type" => "TimerFired"} = child_payload}
    assert_receive {:engine_event, %{"type" => "TimerFired"} = root_payload}

    assert child_payload["data"]["processInstanceId"] == child_process_instance_id
    assert child_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
    assert root_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
  end

  test "CallActivityChildStarted with a nested parent fans out to the root PI topic", %{
    sink_state: sink_state
  } do
    pubsub = EvilEngine.Events.pubsub_name()
    parent_process_instance_id = "parent-pi-#{System.unique_integer([:positive])}"
    root_process_instance_id = "root-pi-#{System.unique_integer([:positive])}"
    child_process_instance_id = "child-pi-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{parent_process_instance_id}")
    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{root_process_instance_id}")

    event = %Event.CallActivityChildStarted{
      call_activity_flow_node_instance_id: "fni-ca-1",
      parent_process_instance_id: parent_process_instance_id,
      child_process_instance_id: child_process_instance_id,
      child_process_model_id: "called-process",
      child_version: "1.0.0",
      root_process_instance_id: root_process_instance_id,
      occurred_at: DateTime.utc_now()
    }

    assert {:ok, ^sink_state} = WebSocket.handle_event(event, sink_state)

    assert_receive {:engine_event, %{"type" => "CallActivityChildStarted"} = parent_payload}
    assert_receive {:engine_event, %{"type" => "CallActivityChildStarted"} = root_payload}

    assert parent_payload["data"]["parentProcessInstanceId"] == parent_process_instance_id
    assert parent_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
    assert root_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
  end

  test "MessageArrived with a distinct root broadcasts to child and root PI topics", %{
    sink_state: sink_state
  } do
    pubsub = EvilEngine.Events.pubsub_name()
    child_process_instance_id = "child-pi-#{System.unique_integer([:positive])}"
    root_process_instance_id = "root-pi-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{child_process_instance_id}")
    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{root_process_instance_id}")

    event = %Event.MessageArrived{
      message_id: "msg-1",
      message_name: "order-paid",
      process_instance_id: child_process_instance_id,
      flow_node_instance_id: "fni-catch-1",
      root_process_instance_id: root_process_instance_id,
      occurred_at: DateTime.utc_now()
    }

    assert {:ok, ^sink_state} = WebSocket.handle_event(event, sink_state)

    assert_receive {:engine_event, %{"type" => "MessageArrived"} = child_payload}
    assert_receive {:engine_event, %{"type" => "MessageArrived"} = root_payload}

    assert child_payload["data"]["processInstanceId"] == child_process_instance_id
    assert child_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
    assert root_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
  end

  test "SignalArrived with a distinct root broadcasts to child and root PI topics", %{
    sink_state: sink_state
  } do
    pubsub = EvilEngine.Events.pubsub_name()
    child_process_instance_id = "child-pi-#{System.unique_integer([:positive])}"
    root_process_instance_id = "root-pi-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{child_process_instance_id}")
    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{root_process_instance_id}")

    event = %Event.SignalArrived{
      signal_id: "sig-1",
      signal_name: "stock-updated",
      process_instance_id: child_process_instance_id,
      flow_node_instance_id: "fni-signal-1",
      root_process_instance_id: root_process_instance_id,
      occurred_at: DateTime.utc_now()
    }

    assert {:ok, ^sink_state} = WebSocket.handle_event(event, sink_state)

    assert_receive {:engine_event, %{"type" => "SignalArrived"} = child_payload}
    assert_receive {:engine_event, %{"type" => "SignalArrived"} = root_payload}

    assert child_payload["data"]["processInstanceId"] == child_process_instance_id
    assert child_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
    assert root_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
  end

  test "SubProcessChildStarted with a nested parent fans out to the root PI topic", %{
    sink_state: sink_state
  } do
    pubsub = EvilEngine.Events.pubsub_name()
    parent_process_instance_id = "parent-pi-#{System.unique_integer([:positive])}"
    root_process_instance_id = "root-pi-#{System.unique_integer([:positive])}"
    child_process_instance_id = "child-pi-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{parent_process_instance_id}")
    Phoenix.PubSub.subscribe(pubsub, "process_instance:#{root_process_instance_id}")

    event = %Event.SubProcessChildStarted{
      subprocess_flow_node_instance_id: "fni-sp-1",
      parent_process_instance_id: parent_process_instance_id,
      child_process_instance_id: child_process_instance_id,
      subprocess_node_id: "SubProcess_1",
      child_process_model_id: "parent__subprocess__SubProcess_1",
      child_version: "1.0.0",
      is_event_subprocess: false,
      root_process_instance_id: root_process_instance_id,
      occurred_at: DateTime.utc_now()
    }

    assert {:ok, ^sink_state} = WebSocket.handle_event(event, sink_state)

    assert_receive {:engine_event, %{"type" => "SubProcessChildStarted"} = parent_payload}
    assert_receive {:engine_event, %{"type" => "SubProcessChildStarted"} = root_payload}

    assert parent_payload["data"]["parentProcessInstanceId"] == parent_process_instance_id
    assert parent_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
    assert root_payload["data"]["rootProcessInstanceId"] == root_process_instance_id
  end
end
