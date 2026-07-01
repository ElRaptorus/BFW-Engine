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

  @endpoint EvilEngineWeb.Http.Endpoint

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
      %{"sub" => "starter-user", "lane:Management" => true}
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
      identity = make_identity(%{id: "user", claims: %{"lane:Management" => true}})
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

      identity = make_identity(%{id: "lane-user", claims: %{"lane:Management" => true}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "admin can join any PI" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "admin-user", claims: %{"zeeky_boogie_doog" => true}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})
    end

    test "user with default lane claim can join PI with default lane" do
      process_instance_id = start_default_lane_process()

      identity = make_identity(%{id: "default-lane-user", claims: %{"lane:default" => true}})
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
  # Event filtering
  # -------------------------------------------------------------------------

  describe "event filtering: lane-based dispatch" do
    test "laneless events always delivered" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, socket} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})

      send(socket.channel_pid, {:engine_event, %{"type" => "pi_state_changed", "process_instance_id" => process_instance_id}})

      assert_push "engine_event", %{"type" => "pi_state_changed"}
    end

    test "laned FNI event delivered when subscriber has matching lane" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "lane-user", claims: %{"lane:Management" => true}})
      socket = connect_socket(identity)
      {:ok, _, socket} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})

      send(socket.channel_pid, {:engine_event, %{
        "type" => "FlowNodeInstanceStarted",
        "data" => %{"laneName" => "Management", "flowNodeInstanceId" => "test-fni"},
        "occurredAt" => DateTime.utc_now() |> DateTime.to_iso8601()
      }})

      assert_push "engine_event", %{"type" => "FlowNodeInstanceStarted"}
    end

    test "laned FNI event dropped when subscriber lacks matching lane" do
      process_instance_id = start_laned_process()

      identity = make_identity(%{id: "starter-user", claims: %{}})
      socket = connect_socket(identity)
      {:ok, _, socket} = subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "process_instance:#{process_instance_id}", %{})

      send(socket.channel_pid, {:engine_event, %{
        "type" => "FlowNodeInstanceStarted",
        "data" => %{"laneName" => "Management", "flowNodeInstanceId" => "test-fni"},
        "occurredAt" => DateTime.utc_now() |> DateTime.to_iso8601()
      }})

      refute_push "engine_event", %{"type" => "FlowNodeInstanceStarted"}, 300
    end
  end

  # -------------------------------------------------------------------------
  # engine:events — remains open (no PI-specific filtering)
  # -------------------------------------------------------------------------

  describe "engine:events topic" do
    test "any authenticated user can join" do
      identity = make_identity(%{id: "any-user", claims: %{}})
      socket = connect_socket(identity)

      assert {:ok, _, _socket} =
               subscribe_and_join(socket, EvilEngineWeb.Ws.EngineChannel, "engine:events", %{})
    end
  end
end
