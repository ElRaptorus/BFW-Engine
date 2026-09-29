defmodule BfwEngine.Integration.Client.ElixirClientTest do
  @moduledoc """
  End-to-end tests driving the standalone `bfw_engine_client` package
  against a real, loopback Bandit listener fronting the production
  `BfwEngineWeb.Http.Endpoint` (see `BfwEngine.Test.ClientEndpoint`).

  BPMN fixtures are deployed with the existing in-process HTTP helpers
  (`http_deploy/2`) — deployment is boilerplate, not what is under test.
  Every subsequent interaction (start, list/finish tasks, trigger events,
  ad-hoc control, abort, read state, and real-time notifications) goes
  through `BfwEngine.Client` and its resource modules over a real TCP
  connection.
  """

  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  alias BfwEngine.Client
  alias BfwEngine.Client.AdhocSubprocesses
  alias BfwEngine.Client.Error
  alias BfwEngine.Client.Events
  alias BfwEngine.Client.Graphql
  alias BfwEngine.Client.ManualTasks
  alias BfwEngine.Client.Notifications
  alias BfwEngine.Client.ProcessInstances
  alias BfwEngine.Client.Processes
  alias BfwEngine.Client.UserTasks
  alias BfwEngine.Test.ClientEndpoint

  @admin_claims %{"zeeky_boogie_doog" => true}

  setup do
    {http_base_url, _websocket_url} = ClientEndpoint.start!()
    %{http_base_url: http_base_url}
  end

  defp admin_client(http_base_url) do
    token = sign_jwt(@admin_claims)
    Client.new(base_url: http_base_url, token: token)
  end

  defp client_with_claims(http_base_url, claims) do
    token = sign_jwt(claims)
    Client.new(base_url: http_base_url, token: token)
  end

  # ---------------------------------------------------------------------------
  # start / list_waiting / finish / terminal state
  # ---------------------------------------------------------------------------

  describe "start, list_waiting, and finish" do
    test "starts a process, lists the waiting User Task with its form schema, finishes it, and reaches finished",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "UserTaskSimple", payload: %{})

      task = poll_client_waiting_task(client, "UserTask_1")
      assert task["flowNodeType"] == "user_task"
      assert get_in(task, ["typeProperties", "form_schema"]) != nil

      assert {:ok, ""} = UserTasks.finish(client, task["id"], values: %{"approved" => true})

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "finished"}} = ProcessInstances.get(client, process_instance_id)
    end

    test "starts a process, lists the waiting Manual Task requiring confirmation, and confirms it",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("manual_task_confirm.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "ManualTaskConfirm", payload: %{"step" => "pack"})

      task = poll_client_waiting_task(client, "ManualTask_1")
      assert task["flowNodeType"] == "manual_task"

      assert {:ok, ""} = ManualTasks.confirm(client, task["id"])

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "finished"}} = ProcessInstances.get(client, process_instance_id)

      confirmed_task =
        process_instance_id
        |> fetch_flow_node_instances()
        |> Enum.find(&(&1.id == task["id"]))

      assert confirmed_task.output_token == %{"step" => "pack"}
    end

    test "UserTasks.finish answers :not_found for a waiting Manual Task", %{
      http_base_url: http_base_url
    } do
      {201, _} = http_deploy("manual_task_confirm.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => _process_instance_id}} =
        Processes.start(client, "ManualTaskConfirm", payload: %{})

      task = poll_client_waiting_task(client, "ManualTask_1")

      assert {:error, %Error{reason: :not_found}} = UserTasks.finish(client, task["id"])
    end

    test "ManualTasks.confirm answers :not_found for a waiting User Task", %{
      http_base_url: http_base_url
    } do
      {201, _} = http_deploy("user_task_simple.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => _process_instance_id}} =
        Processes.start(client, "UserTaskSimple", payload: %{})

      task = poll_client_waiting_task(client, "UserTask_1")

      assert {:error, %Error{reason: :not_found}} = ManualTasks.confirm(client, task["id"])
    end
  end

  # ---------------------------------------------------------------------------
  # trigger_message / trigger_signal / waiting_catches
  # ---------------------------------------------------------------------------

  describe "trigger_message and waiting_catches" do
    test "trigger_message with a correlation value and payload reaches the waiting catch",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "MessageCatchSimple", payload: %{})

      catches = poll_client_waiting_catches(client, process_instance_id)
      assert [catch_fni] = catches
      assert catch_fni["flowNodeId"] == "Catch_1"
      assert get_in(catch_fni, ["typeProperties", "message_name"]) == "test-message"
      assert Map.has_key?(catch_fni["typeProperties"], "expected_correlation_value")

      # This fixture sets no `bfw:correlationKey`, so the subscription's
      # `expected_correlation_value` is `nil` (catch-all). Passing an empty
      # string as `correlation` would stamp a non-nil `""` on the published
      # message, which does not match a `nil` subscription — omit the
      # option entirely so no correlation value is stamped.
      correlation_opts =
        case catch_fni["typeProperties"]["expected_correlation_value"] do
          nil -> []
          value -> [correlation: value]
        end

      assert {:ok, _body} =
               Events.trigger_message(
                 client,
                 "test-message",
                 [payload: %{"note" => "hello"}] ++ correlation_opts
               )

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "finished"}} = ProcessInstances.get(client, process_instance_id)
    end
  end

  describe "trigger_signal" do
    test "trigger_signal reaches the waiting signal catch", %{http_base_url: http_base_url} do
      {201, _} = http_deploy("signal_catch_simple.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "SignalCatchSimple", payload: %{})

      catches = poll_client_waiting_catches(client, process_instance_id)
      assert [catch_fni] = catches
      assert get_in(catch_fni, ["typeProperties", "signal_name"]) == "test-signal"

      assert {:ok, _body} = Events.trigger_signal(client, "test-signal")

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "finished"}} = ProcessInstances.get(client, process_instance_id)
    end
  end

  # ---------------------------------------------------------------------------
  # trigger_timer
  # ---------------------------------------------------------------------------

  describe "trigger_timer" do
    test "waiting_catches reports the timer_ref / fire_at keys and trigger_timer fires it",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("timer_catch_manual_trigger.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "TimerCatchManualTrigger", payload: %{})

      catches = poll_client_waiting_catches(client, process_instance_id)
      assert [catch_fni] = catches
      assert catch_fni["flowNodeId"] == "TimerCatch_1"
      assert Map.has_key?(catch_fni["typeProperties"], "timer_ref")
      assert Map.has_key?(catch_fni["typeProperties"], "fire_at")

      assert {:ok, _body} = Events.trigger_timer(client, catch_fni["id"])

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "finished"}} = ProcessInstances.get(client, process_instance_id)
    end
  end

  # ---------------------------------------------------------------------------
  # trigger_escalation
  # ---------------------------------------------------------------------------

  describe "trigger_escalation" do
    test "trigger_escalation is caught by the boundary and the process reaches finished",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("escalation_trigger_user_task_interrupting.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "EscalationTriggerInterrupting", payload: %{})

      _task = poll_client_waiting_task(client, "UserTask_1")

      assert {:ok, _body} = Events.trigger_escalation(client, "ESC_API")

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "finished"}} = ProcessInstances.get(client, process_instance_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Ad-hoc subprocess: activities / activate / status / complete
  # ---------------------------------------------------------------------------

  describe "ad-hoc subprocess control" do
    test "activities, activate, status, and complete drive a plugin-managed ad-hoc subprocess to completion",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("adhoc_plugin_managed.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => parent_process_instance_id}} =
        Processes.start(client, "AdHocPluginManaged", payload: %{})

      child_process_instance_id = poll_child_process_instance_id(parent_process_instance_id)

      assert {:ok, activities} = AdhocSubprocesses.activities(client, child_process_instance_id)
      activity_ids = Enum.map(activities, & &1["id"])
      assert "ScriptTask_Plugin_A" in activity_ids
      assert "ScriptTask_Plugin_B" in activity_ids

      assert {:ok, _} =
               AdhocSubprocesses.activate(
                 client,
                 child_process_instance_id,
                 "ScriptTask_Plugin_A"
               )

      poll_adhoc_idle(client, child_process_instance_id)

      assert {:ok, _} =
               AdhocSubprocesses.activate(
                 client,
                 child_process_instance_id,
                 "ScriptTask_Plugin_B"
               )

      status = poll_adhoc_idle(client, child_process_instance_id)
      assert is_map(status)

      assert {:ok, _} = AdhocSubprocesses.complete(client, child_process_instance_id)

      wait_for_process_instance(parent_process_instance_id)

      assert {:ok, %{"state" => "finished"}} =
               ProcessInstances.get(client, parent_process_instance_id)
    end
  end

  # ---------------------------------------------------------------------------
  # abort / ProcessInstances.get reaching aborted
  # ---------------------------------------------------------------------------

  describe "abort" do
    test "abort stops the process instance and ProcessInstances.get reports aborted",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "UserTaskSimple", payload: %{})

      _task = poll_client_waiting_task(client, "UserTask_1")

      assert {:ok, ""} =
               ProcessInstances.abort(client, process_instance_id, reason: "client test")

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "aborted"}} = ProcessInstances.get(client, process_instance_id)
    end

    test "UserTasks.cancel aborts the process instance", %{http_base_url: http_base_url} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "UserTaskSimple", payload: %{})

      task = poll_client_waiting_task(client, "UserTask_1")
      assert {:ok, ""} = UserTasks.cancel(client, task["id"], reason: "client cancel")

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "aborted"}} = ProcessInstances.get(client, process_instance_id)
    end

    test "ManualTasks.cancel aborts the process instance", %{http_base_url: http_base_url} do
      {201, _} = http_deploy("manual_task_confirm.bpmn")
      client = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "ManualTaskConfirm", payload: %{})

      task = poll_client_waiting_task(client, "ManualTask_1")
      assert {:ok, ""} = ManualTasks.cancel(client, task["id"], reason: "client cancel")

      wait_for_process_instance(process_instance_id)
      assert {:ok, %{"state" => "aborted"}} = ProcessInstances.get(client, process_instance_id)
    end
  end

  describe "process catalog" do
    test "Processes.list returns a process after it is deployed", %{http_base_url: http_base_url} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      client = admin_client(http_base_url)

      assert {:ok, processes} = Processes.list(client)
      assert Enum.any?(processes, &(&1["id"] == "UserTaskSimple"))
    end
  end

  # ---------------------------------------------------------------------------
  # Notifications: real-time inbox + lifecycle events
  # ---------------------------------------------------------------------------

  describe "Notifications over a real WebSocket" do
    test "receives UserTaskCreated (flowNodeType manual_task) on user_tasks:pending and lifecycle events on engine:events",
         %{http_base_url: http_base_url} do
      :ok =
        BfwEngine.Events.EngineEventBus.register_sink(
          "websocket",
          BfwEngineWeb.Ws.Sinks.WebSocket,
          []
        )

      {201, _} = http_deploy("manual_task_confirm.bpmn")
      client = admin_client(http_base_url)

      {:ok, notifications} = Notifications.start_link(client: client)
      :ok = Notifications.subscribe(notifications, "engine:events")
      :ok = Notifications.subscribe(notifications, "user_tasks:pending")

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(client, "ManualTaskConfirm", payload: %{})

      assert_receive {:bfw_engine_event, "user_tasks:pending",
                      %{
                        "type" => "UserTaskCreated",
                        "data" => %{"flowNodeType" => "manual_task"} = manual_task_data
                      }},
                     5_000

      assert manual_task_data["processInstanceId"] == process_instance_id

      assert_receive {:bfw_engine_event, "engine:events",
                      %{
                        "type" => "ProcessInstanceStateChanged",
                        "data" => %{"processInstanceId" => ^process_instance_id}
                      }},
                     5_000

      task = poll_client_waiting_task(client, "ManualTask_1")
      assert {:ok, ""} = ManualTasks.confirm(client, task["id"])

      assert_receive {:bfw_engine_event, "user_tasks:pending",
                      %{
                        "type" => "UserTaskFinished",
                        "data" => %{
                          "flowNodeType" => "manual_task",
                          "outcome" => "completed",
                          "processInstanceId" => ^process_instance_id
                        }
                      }},
                     5_000

      wait_for_process_instance(process_instance_id)
    end

    test "a user without lane access receives no UserTaskCreated inbox event",
         %{http_base_url: http_base_url} do
      :ok =
        BfwEngine.Events.EngineEventBus.register_sink(
          "websocket",
          BfwEngineWeb.Ws.Sinks.WebSocket,
          []
        )

      {201, _} = http_deploy("user_task_with_lane.bpmn")
      admin = admin_client(http_base_url)

      outsider_claims = %{"sub" => "outsider", "lane:Engineering" => "write"}
      outsider = client_with_claims(http_base_url, outsider_claims)

      {:ok, notifications} = Notifications.start_link(client: outsider)
      :ok = Notifications.subscribe(notifications, "user_tasks:pending")

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(admin, "LanedUserTask", payload: %{})

      _task = poll_client_waiting_task(admin, "UserTask_1")

      refute_receive {:bfw_engine_event, "user_tasks:pending", _envelope}, 1_000

      assert {:ok, ""} = ProcessInstances.abort(admin, process_instance_id)
      wait_for_process_instance(process_instance_id)
    end

    test "a socket connect with a bad token fails and is retried without crashing the owner",
         %{http_base_url: http_base_url} do
      bad_client = Client.new(base_url: http_base_url, token: "not-a-real-token")

      {:ok, notifications} = Notifications.start_link(client: bad_client)
      monitor_reference = Process.monitor(notifications)

      refute_receive {:DOWN, ^monitor_reference, :process, _process, _reason}, 300

      assert Process.alive?(notifications)
      assert Process.alive?(self())

      # `notifications` is linked to this test process (via `start_link/1`);
      # it is torn down automatically when the test process exits. Exiting
      # it explicitly here would propagate the exit signal back to this
      # linked test process and crash the test itself.
    end
  end

  describe "GraphQL errors" do
    test "maps a real GraphQL error from the Engine", %{http_base_url: http_base_url} do
      client = admin_client(http_base_url)

      assert {:error, %Error{status: nil} = error} =
               Graphql.query(client, "{ processes { results { thisFieldDoesNotExist } } }")

      assert is_binary(error.code)
      assert is_atom(error.reason)
      assert error.message =~ "thisFieldDoesNotExist"
    end
  end

  # ---------------------------------------------------------------------------
  # Security: authentication and authorization failures
  # ---------------------------------------------------------------------------

  describe "security: authentication failures" do
    test "missing token returns :unauthorized", %{http_base_url: http_base_url} do
      client = Client.new(base_url: http_base_url)

      assert {:error, %Error{reason: :unauthorized}} = Processes.list(client)
    end

    test "expired token returns :unauthorized", %{http_base_url: http_base_url} do
      expired_token =
        sign_jwt(%{"exp" => DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()})

      client = Client.new(base_url: http_base_url, token: expired_token)

      assert {:error, %Error{reason: :unauthorized}} = Processes.list(client)
    end

    test "a wrongly signed token returns :unauthorized", %{http_base_url: http_base_url} do
      wrong_secret_jwk = JOSE.JWK.from_oct("a_completely_different_secret_at_least_32_bytes!")

      claims = %{
        "sub" => "forger",
        "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
        "iat" => DateTime.utc_now() |> DateTime.to_unix()
      }

      {_, wrongly_signed_token} =
        JOSE.JWT.sign(wrong_secret_jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

      client = Client.new(base_url: http_base_url, token: wrongly_signed_token)

      assert {:error, %Error{reason: :unauthorized}} = Processes.list(client)
    end
  end

  describe "security: authorization failures" do
    test "a lane claim without write access returns :forbidden when finishing a User Task",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("user_task_with_lane.bpmn")
      admin = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(admin, "LanedUserTask", payload: %{})

      task = poll_client_waiting_task(admin, "UserTask_1")

      read_only_client =
        client_with_claims(http_base_url, %{"sub" => "reader", "lane:Management" => "read"})

      assert {:error, %Error{reason: :forbidden}} = UserTasks.finish(read_only_client, task["id"])

      assert {:ok, ""} = ProcessInstances.abort(admin, process_instance_id)
      wait_for_process_instance(process_instance_id)
    end

    test "an FNI invisible to the caller's lane returns :not_found when finishing a User Task",
         %{http_base_url: http_base_url} do
      {201, _} = http_deploy("user_task_with_lane.bpmn")
      admin = admin_client(http_base_url)

      {:ok, %{"processInstanceId" => process_instance_id}} =
        Processes.start(admin, "LanedUserTask", payload: %{})

      task = poll_client_waiting_task(admin, "UserTask_1")

      no_access_client =
        client_with_claims(http_base_url, %{"sub" => "outsider", "lane:Engineering" => "write"})

      assert {:error, %Error{reason: :not_found}} = UserTasks.finish(no_access_client, task["id"])

      assert {:ok, ""} = ProcessInstances.abort(admin, process_instance_id)
      wait_for_process_instance(process_instance_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Polling helpers (client-side, over the network)
  # ---------------------------------------------------------------------------

  @poll_timeout_ms 5_000
  @poll_interval_ms 50

  defp poll_client_waiting_task(client, flow_node_id) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll_client_waiting_task(client, flow_node_id, deadline)
  end

  defp do_poll_client_waiting_task(client, flow_node_id, deadline) do
    case UserTasks.list_waiting(client) do
      {:ok, tasks} ->
        case Enum.find(tasks, &(&1["flowNodeId"] == flow_node_id)) do
          nil -> retry_or_raise(client, flow_node_id, deadline, &do_poll_client_waiting_task/3)
          task -> task
        end

      {:error, _reason} ->
        retry_or_raise(client, flow_node_id, deadline, &do_poll_client_waiting_task/3)
    end
  end

  defp retry_or_raise(client, key, deadline, retry_fun) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "Waiting flow node '#{key}' never appeared within #{@poll_timeout_ms}ms"
    else
      Process.sleep(@poll_interval_ms)
      retry_fun.(client, key, deadline)
    end
  end

  defp poll_client_waiting_catches(client, process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll_client_waiting_catches(client, process_instance_id, deadline)
  end

  defp do_poll_client_waiting_catches(client, process_instance_id, deadline) do
    case ProcessInstances.waiting_catches(client, process_instance_id) do
      {:ok, [_ | _] = catches} ->
        catches

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "No waiting catches appeared for PI #{process_instance_id} within #{@poll_timeout_ms}ms"
        else
          Process.sleep(@poll_interval_ms)
          do_poll_client_waiting_catches(client, process_instance_id, deadline)
        end
    end
  end

  defp poll_adhoc_idle(client, child_process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll_adhoc_idle(client, child_process_instance_id, deadline)
  end

  defp do_poll_adhoc_idle(client, child_process_instance_id, deadline) do
    case AdhocSubprocesses.status(client, child_process_instance_id) do
      {:ok, %{"activeCount" => 0} = status} ->
        status

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "Ad-hoc PI #{child_process_instance_id} still had active activities after #{@poll_timeout_ms}ms"
        else
          Process.sleep(@poll_interval_ms)
          do_poll_adhoc_idle(client, child_process_instance_id, deadline)
        end
    end
  end

  defp poll_child_process_instance_id(parent_process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll_child_process_instance_id(parent_process_instance_id, deadline)
  end

  defp do_poll_child_process_instance_id(parent_process_instance_id, deadline) do
    case BfwEngine.Test.DbAssertions.list_child_process_instance_ids(parent_process_instance_id) do
      [child_id | _] ->
        child_id

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "No child PI appeared for parent #{parent_process_instance_id} within #{@poll_timeout_ms}ms"
        else
          Process.sleep(@poll_interval_ms)
          do_poll_child_process_instance_id(parent_process_instance_id, deadline)
        end
    end
  end
end
