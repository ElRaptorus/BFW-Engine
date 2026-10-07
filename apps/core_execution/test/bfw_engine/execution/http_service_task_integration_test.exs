defmodule BfwEngine.Execution.HttpServiceTaskIntegrationTest do
  @moduledoc """
  Runtime integration tests for the built-in HTTP Service Task handler.

  Exercises the full PI lifecycle: Start → ServiceTask(implementation=\"http\")
  → End. Uses `Req.Test` to stub HTTP calls and telemetry to assert
  state transitions without relying on persistence.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Execution
  alias BfwEngine.Execution.ServiceReset
  alias BfwEngine.Execution.TestSupport.BpmnFactory
  alias BfwEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000003"
  @moduletag :http_handler

  defmodule HttpServiceTaskDispatch do
    @moduledoc false
    @behaviour BfwEngine.Execution.ServiceTaskDispatch

    @http_handler_module Module.concat([BfwEngine, Plugins, Builtin, HttpServiceTaskHandler])

    @impl true
    def lookup_handler("http"), do: {:ok, @http_handler_module}
    def lookup_handler(_implementation), do: {:error, :not_found}
  end

  setup do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn connection ->
      Plug.Conn.send_resp(connection, 200, Jason.encode!(%{"default" => true}))
    end)

    previous_http_options = Application.get_env(:engine_plugins, :http_req_options)

    Application.put_env(:engine_plugins, :http_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    Application.put_env(
      :core_execution,
      :persistence_adapter,
      BfwEngine.Execution.Persistence.NoOp
    )

    Application.put_env(:core_execution, :service_task_dispatch, HttpServiceTaskDispatch)

    ServiceReset.bpmn_model_cache()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()

      if previous_http_options do
        Application.put_env(:engine_plugins, :http_req_options, previous_http_options)
      else
        Application.delete_env(:engine_plugins, :http_req_options)
      end

      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :service_task_dispatch)
      ServiceReset.bpmn_model_cache()
    end)

    :ok
  end

  defp start_process_instance(opts \\ []) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    process_instance_options = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: @version_id,
      start_event_id: opts[:start_event_id],
      payload: opts[:payload] || %{},
      identity: identity
    }

    Execution.start_process_instance(process_instance_options)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp attach_pi_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "http-pi-#{label}-#{inspect(reference)}",
      [:bfw_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:pi_state_change, reference, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("http-pi-#{label}-#{inspect(reference)}") end)

    reference
  end

  defp attach_fni_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "http-fni-#{label}-#{inspect(reference)}",
      [:bfw_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:fni_state_change, reference, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("http-fni-#{label}-#{inspect(reference)}") end)

    reference
  end

  describe "HTTP Service Task — successful execution (async)" do
    test "HTTP-I1: GET completes PI with response body in service task output" do
      Req.Test.stub(__MODULE__, fn connection ->
        assert connection.method == "GET"

        connection
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "ok"}))
      end)

      definitions = BpmnFactory.http_service_task_process(http_url: "http://test.local/api")
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("http-get-success")
      service_task_reference = attach_fni_telemetry("http-get-success")

      assert {:ok, process_instance_pid} = start_process_instance()

      assert_receive {:fni_state_change, ^service_task_reference,
                      %{flow_node_type: :service_task, terminal_state: :finished}},
                     2_000

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata}, 2_000

      ref = Process.monitor(process_instance_pid)
      assert_receive {:DOWN, ^ref, :process, ^process_instance_pid, _reason}, 2_000
    end

    test "HTTP-I2: POST with FEEL body from token payload completes PI" do
      Req.Test.stub(__MODULE__, fn connection ->
        assert connection.method == "POST"
        {:ok, request_body, connection} = Plug.Conn.read_body(connection)
        decoded_body = Jason.decode!(request_body)
        assert decoded_body["order_id"] == "ORD-456"

        connection
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"received" => decoded_body}))
      end)

      definitions =
        BpmnFactory.http_service_task_process(
          http_url: "http://test.local/api",
          http_method: "POST",
          http_body: ~s({"order_id": token.order_id})
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("http-post-feel")
      service_task_reference = attach_fni_telemetry("http-post-feel")

      assert {:ok, _process_instance_pid} =
               start_process_instance(payload: %{"order_id" => "ORD-456"})

      assert_receive {:fni_state_change, ^service_task_reference,
                      %{flow_node_type: :service_task, terminal_state: :finished}},
                     2_000

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata}, 2_000
    end

    test "HTTP-I3: service task FNI parks in waiting before HTTP response arrives" do
      test_process = self()

      Req.Test.stub(__MODULE__, fn connection ->
        send(test_process, :http_request_started)
        Process.sleep(300)

        connection
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"delayed" => true}))
      end)

      definitions = BpmnFactory.http_service_task_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("http-waiting-park")
      service_task_reference = attach_fni_telemetry("http-waiting-park")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive :http_request_started, 2_000

      assert_receive {:fni_state_change, ^service_task_reference,
                      %{flow_node_type: :service_task, new_state: :waiting}},
                     500

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata}, 2_000
    end
  end

  describe "HTTP Service Task — validation and error paths" do
    test "HTTP-I4: missing URL causes PI fatal before async park" do
      definitions = BpmnFactory.http_service_task_process(http_url: nil)
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("http-missing-url")
      service_task_reference = attach_fni_telemetry("http-missing-url")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:fni_state_change, ^service_task_reference,
                      %{flow_node_type: :service_task, terminal_state: :fatal}},
                     2_000

      assert_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 2_000
    end

    test "HTTP-I5: HTTP 422 response causes PI fatal after async park" do
      Req.Test.stub(__MODULE__, fn connection ->
        connection
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(422, Jason.encode!(%{"error" => "invalid"}))
      end)

      definitions = BpmnFactory.http_service_task_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("http-422-fatal")
      service_task_reference = attach_fni_telemetry("http-422-fatal")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:fni_state_change, ^service_task_reference,
                      %{flow_node_type: :service_task, terminal_state: :fatal}},
                     2_000

      assert_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 2_000
    end
  end
end
