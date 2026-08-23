defmodule EvilEngine.Integration.Auth.WebsocketAuthorizationTest do
  @moduledoc """
  WebSocket channel authorization tests.

  Verifies:
  - `process_instance:*` join is rejected for invisible process instances
  - `process_instance:*` join is allowed for visible process instances (starter, lane match, admin)
  - Lane-filtered event dispatch: laned FNI events dropped for
    subscribers without matching lane claim; default lane enforcement
  """
  use EvilEngine.ExecutionCase, async: false

  import Phoenix.ChannelTest

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngineWeb.Ws.Sinks.WebSocket, as: WebSocketSink

  @endpoint EvilEngineWeb.Http.Endpoint
  @moduletag :integration

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp make_identity(opts) do
    %EvilEngine.Types.Identity{
      id: opts[:id] || "test-user",
      roles: opts[:roles] || [],
      groups: opts[:groups] || [],
      claims: opts[:claims] || %{}
    }
  end

  defp connect_socket(identity) do
    socket(EvilEngineWeb.Ws.UserSocket, "user:#{identity.id}", %{identity: identity})
  end

  defp start_laned_process do
    {201, _} = http_deploy("user_task_with_lane.bpmn")

    {201, body} = http_start(
      "LanedUserTask",
      %{},
      %{"sub" => "starter-user", "lane:Management" => "write"}
    )

    process_instance_id = body["processInstanceId"]
    Process.sleep(200)
    process_instance_id
  end

  defp start_default_lane_process do
    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, body} = http_start("LinearStartEnd", %{}, %{"sub" => "default-lane-starter"})
    process_instance_id = body["processInstanceId"]
    wait_for_process_instance(process_instance_id)
    process_instance_id
  end

  # -------------------------------------------------------------------------
  # Join authorization
  # -------------------------------------------------------------------------

  describe "process_instance:* join: rejected for invisible PI" do
    test "user without lane claim or starter match is rejected" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "other-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "nonexistent PI is rejected" do
      identity = make_identity(%{id: "user", claims: %{"lane:Management" => "write"}})
      socket = connect_socket(identity)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:00000000-0000-0000-0000-000000000000", %{})
    end
  end

  describe "process_instance:* join: allowed for visible PI" do
    test "starter can join" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "user with matching lane claim can join" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "lane-user", claims: %{"lane:Management" => "write"}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "user with read-only lane claim can join" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "lane-reader", claims: %{"lane:Management" => "read"}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(
                 socket,
                 EvilEngineWeb.Ws.EngineChannel,
                 "process_instance:#{process_instance_id}",
                 %{}
               )
    end

    test "admin can join any PI" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "admin-user", claims: %{"zeeky_boogie_doog" => true}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "observe_all can join a foreign-lane PI" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "observer", claims: %{"observe_all" => true}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(
                 socket,
                 EvilEngineWeb.Ws.EngineChannel,
                 "process_instance:#{process_instance_id}",
                 %{}
               )
    end

    test "user with default lane claim can join PI with default lane" do
      process_instance_id = start_default_lane_process()

      identity = make_identity(%{id: "default-lane-user", claims: %{"lane:default" => "write"}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "user without default lane claim cannot join PI with default lane" do
      process_instance_id = start_default_lane_process()

      identity = make_identity(%{id: "no-lane-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end
  end

  # -------------------------------------------------------------------------
  # Event filtering — synthetic envelopes
  # -------------------------------------------------------------------------

  describe "event filtering: synthetic envelopes" do
    test "laneless FNI envelope is always delivered" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)

      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          EvilEngineWeb.Ws.EngineChannel,
          "process_instance:#{process_instance_id}",
          %{}
        )

      send(socket.channel_pid, {:engine_event, fni_started_envelope(nil)})

      assert_push "engine_event", %{"type" => "FlowNodeInstanceStarted"}
    end

    test "PI-level envelope is always delivered on process_instance:* after a successful join" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)

      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          EvilEngineWeb.Ws.EngineChannel,
          "process_instance:#{process_instance_id}",
          %{}
        )

      send(
        socket.channel_pid,
        {:engine_event,
         pi_state_envelope(process_instance_id, %{
           "startedById" => "starter-user",
           "hasLanelessFlowNode" => false,
           "laneNames" => ["Management"]
         })}
      )

      assert_push "engine_event", %{"type" => "ProcessInstanceStateChanged"}
    end

    test "laned FNI event delivered when subscriber has matching lane" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "lane-user", claims: %{"lane:Management" => "write"}})
      socket = connect_socket(identity)

      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          EvilEngineWeb.Ws.EngineChannel,
          "process_instance:#{process_instance_id}",
          %{}
        )

      send(socket.channel_pid, {:engine_event, fni_started_envelope("Management")})

      assert_push "engine_event", %{"type" => "FlowNodeInstanceStarted"}
    end

    test "laned FNI event dropped when subscriber lacks matching lane" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)

      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          EvilEngineWeb.Ws.EngineChannel,
          "process_instance:#{process_instance_id}",
          %{}
        )

      send(socket.channel_pid, {:engine_event, fni_started_envelope("Management")})

      refute_push "engine_event", %{"type" => "FlowNodeInstanceStarted"}, 300
    end
  end

  describe "engine:events and user_tasks:* join" do
    test "any authenticated user can join engine:events" do
      identity = make_identity(%{id: "any-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})
    end

    test "any authenticated user can join user_tasks:pending" do
      identity = make_identity(%{id: "any-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "user_tasks:pending", %{})
    end

    test "unknown user_tasks subtopic is rejected" do
      identity = make_identity(%{id: "any-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "user_tasks:other", %{})
    end
  end

  # -------------------------------------------------------------------------
  # Live dispatch (WebSocket sink registered)
  # -------------------------------------------------------------------------

  describe "live lane-filtered dispatch" do
    setup do
      :ok = EngineEventBus.register_sink("websocket", WebSocketSink, [])
      :ok
    end

    test "subscriber without Management never receives live Management FlowNodeInstanceStarted on engine:events" do
      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})

      process_instance_id = deploy_and_start_laned()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      assert management_fni_events(events) == []
    end

    test "subscriber without Management never receives live Management FlowNodeInstanceStarted on process_instance:*" do
      process_instance_id = deploy_and_start_laned()
      {:ok, user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)

      {:ok, _, _} =
        subscribe_and_join(
          socket,
          EvilEngineWeb.Ws.EngineChannel,
          "process_instance:#{process_instance_id}",
          %{}
        )

      {204, _} = http_finish_user_task(user_task.id, %{}, %{"lane:Management" => "write"})
      wait_for_process_instance(process_instance_id)
      events = collect_pushes(400)

      assert management_fni_events(events) == []
    end

    test "live laneless FlowNodeInstanceStarted is delivered on engine:events" do
      identity = make_identity(%{id: "stranger-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})

      process_instance_id = deploy_and_start_laneless()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      laneless_started =
        events
        |> filter_type("FlowNodeInstanceStarted")
        |> Enum.filter(fn event -> event["data"]["laneName"] == nil end)

      assert laneless_started != [],
             "Expected a live FlowNodeInstanceStarted with laneName null. Types: #{inspect(Enum.map(events, & &1["type"]))}"

      assert management_fni_events(events) == []
    end

    test "starter without a lane claim receives live ProcessInstanceStateChanged on process_instance:*" do
      process_instance_id = deploy_and_start_laned()
      {:ok, user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)

      {:ok, _, _} =
        subscribe_and_join(
          socket,
          EvilEngineWeb.Ws.EngineChannel,
          "process_instance:#{process_instance_id}",
          %{}
        )

      {204, _} = http_finish_user_task(user_task.id, %{}, %{"lane:Management" => "write"})
      wait_for_process_instance(process_instance_id)
      events = collect_pushes(800)

      pi_events =
        events
        |> filter_type("ProcessInstanceStateChanged")
        |> Enum.filter(fn event -> event["data"]["processInstanceId"] == process_instance_id end)

      assert pi_events != [],
             "Expected live ProcessInstanceStateChanged for the starter. Types: #{inspect(Enum.map(events, & &1["type"]))}"

      assert management_fni_events(events) == []
    end

    test "stranger on engine:events does not receive ProcessInstanceStateChanged for LanedUserTask" do
      identity = make_identity(%{id: "stranger-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})

      process_instance_id = deploy_and_start_laned()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      pi_events =
        events
        |> filter_type("ProcessInstanceStateChanged")
        |> Enum.filter(fn event -> event["data"]["processInstanceId"] == process_instance_id end)

      assert pi_events == []
      assert management_fni_events(events) == []
    end

    test "starter on engine:events receives ProcessInstanceStateChanged via startedById" do
      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})

      process_instance_id = deploy_and_start_laned()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      pi_events =
        events
        |> filter_type("ProcessInstanceStateChanged")
        |> Enum.filter(fn event -> event["data"]["processInstanceId"] == process_instance_id end)

      assert pi_events != [],
             "Expected the starter to receive PI-level events on engine:events. Types: #{inspect(Enum.map(events, & &1["type"]))}"

      assert Enum.any?(pi_events, fn event -> event["data"]["startedById"] == "starter-user" end)
      assert management_fni_events(events) == []
    end

    test "subscriber with Management receives live Management FNI events on engine:events" do
      identity = make_identity(%{id: "lane-observer", claims: %{"lane:Management" => "write"}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})

      process_instance_id = deploy_and_start_laned()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      management_events = management_fni_events(events)
      types = Enum.map(management_events, & &1["type"]) |> Enum.uniq() |> Enum.sort()

      assert "FlowNodeInstanceStarted" in types
      assert "FlowNodeInstanceStateChanged" in types
      assert "UserTaskCreated" in types

      assert Enum.all?(management_events, fn event -> event["data"]["laneName"] == "Management" end),
             "Expected Management FNI events. Types: #{inspect(Enum.map(events, & &1["type"]))}"
    end

    test "user_tasks:pending delivers Management UserTaskCreated with lane:Management" do
      identity = make_identity(%{id: "inbox-lane-user", claims: %{"lane:Management" => "write"}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "user_tasks:pending", %{})

      process_instance_id = deploy_and_start_laned()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      created = filter_type(events, "UserTaskCreated")
      assert created != [], "Expected UserTaskCreated on user_tasks:pending with Management claim"
      assert Enum.all?(created, fn event -> event["data"]["laneName"] == "Management" end)
    end

    test "user_tasks:pending drops Management UserTaskCreated without lane:Management" do
      identity = make_identity(%{id: "inbox-no-lane-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "user_tasks:pending", %{})

      process_instance_id = deploy_and_start_laned()
      {:ok, _user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      events = collect_pushes(400)

      assert filter_type(events, "UserTaskCreated") == []
    end

    test "user_tasks:pending delivers Management UserTaskFinished with lane:Management" do
      identity = make_identity(%{id: "inbox-finish-user", claims: %{"lane:Management" => "write"}})
      process_instance_id = deploy_and_start_laned()
      {:ok, user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      {:ok, _, _} =
        subscribe_and_join(
          connect_socket(identity),
          EvilEngineWeb.Ws.EngineChannel,
          "user_tasks:pending",
          %{}
        )

      {204, _} = http_finish_user_task(user_task.id, %{}, %{"lane:Management" => "write"})
      wait_for_process_instance(process_instance_id)
      events = collect_pushes(800)

      finished = filter_type(events, "UserTaskFinished")
      assert finished != [], "Expected UserTaskFinished on user_tasks:pending with Management claim"
      assert Enum.all?(finished, fn event -> event["data"]["laneName"] == "Management" end)
    end

    test "user_tasks:pending drops Management UserTaskFinished without lane:Management" do
      process_instance_id = deploy_and_start_laned()
      {:ok, user_task} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      identity = make_identity(%{id: "inbox-no-lane-finish", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, _} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "user_tasks:pending", %{})

      {204, _} = http_finish_user_task(user_task.id, %{}, %{"lane:Management" => "write"})
      wait_for_process_instance(process_instance_id)
      events = collect_pushes(800)

      assert filter_type(events, "UserTaskFinished") == []
    end
  end

  defp deploy_and_start_laned do
    deploy_unique("user_task_with_lane.bpmn")

    {201, body} =
      http_start("LanedUserTask", %{}, %{"sub" => "starter-user", "lane:Management" => "write"})

    body["processInstanceId"]
  end

  defp deploy_and_start_laneless do
    deploy_unique("laneless_start_management_task.bpmn")

    {201, body} =
      http_start(
        "LanelessStartManagementTask",
        %{},
        %{"sub" => "starter-user", "lane:Management" => "write"}
      )

    body["processInstanceId"]
  end

  defp deploy_unique(fixture_name) do
    xml = File.read!(Path.join("test/fixtures/bpmns", fixture_name))
    unique_version = "lane-filter-#{System.unique_integer([:positive])}.0.0"
    {201, _} = http_deploy_xml(String.replace(xml, "1.0.0", unique_version))
  end

  defp fni_started_envelope(lane_name) do
    %{
      "type" => "FlowNodeInstanceStarted",
      "data" => %{"laneName" => lane_name, "flowNodeInstanceId" => "test-fni"},
      "occurredAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp pi_state_envelope(process_instance_id, extra) do
    %{
      "type" => "ProcessInstanceStateChanged",
      "data" =>
        Map.merge(
          %{
            "processInstanceId" => process_instance_id,
            "newState" => "running"
          },
          extra
        ),
      "occurredAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp management_fni_events(events) do
    Enum.filter(events, fn event -> event["data"]["laneName"] == "Management" end)
  end

  defp filter_type(events, type), do: Enum.filter(events, &(&1["type"] == type))

  defp collect_pushes(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_pushes([], deadline)
  end

  defp do_collect_pushes(accumulated, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      accumulated
    else
      receive do
        %Phoenix.Socket.Message{event: "engine_event", payload: payload} ->
          do_collect_pushes(accumulated ++ [payload], deadline)
      after
        min(remaining, 100) ->
          do_collect_pushes(accumulated, deadline)
      end
    end
  end
end
