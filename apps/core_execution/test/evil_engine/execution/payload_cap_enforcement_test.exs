defmodule EvilEngine.Execution.PayloadCapEnforcementTest do
  @moduledoc """
  Tests PayloadCap enforcement at the PI runtime boundaries:
  - Async handler output (handle_complete via finish_async_service_task)
  - Start payload in init
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ServiceTaskDispatch
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000002"
  @small_cap 2048

  defmodule LargeOutputHandler do
    @moduledoc false
    @behaviour EvilEngine.Plugin.ServiceTaskHandler

    @impl true
    def handle_enter(_flow_node, _token, context) do
      flow_node_instance_id = context.flow_node_instance_id

      spawn(fn ->
        Process.sleep(50)
        large_payload = %{"data" => String.duplicate("x", 10_000)}
        Execution.finish_async_service_task(flow_node_instance_id, large_payload)
      end)

      {:async, flow_node_instance_id}
    end
  end

  defmodule SmallOutputHandler do
    @moduledoc false
    @behaviour EvilEngine.Plugin.ServiceTaskHandler

    @impl true
    def handle_enter(_flow_node, _token, context) do
      flow_node_instance_id = context.flow_node_instance_id

      spawn(fn ->
        Process.sleep(50)
        Execution.finish_async_service_task(flow_node_instance_id, %{"result" => "ok"})
      end)

      {:async, flow_node_instance_id}
    end
  end

  defmodule TestDispatch do
    @moduledoc false
    @behaviour ServiceTaskDispatch

    @impl true
    def lookup_handler("large_output"), do: {:ok, LargeOutputHandler}
    def lookup_handler("small_output"), do: {:ok, SmallOutputHandler}
    def lookup_handler(_), do: {:error, :not_found}
  end

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    Application.put_env(:core_execution, :service_task_dispatch, TestDispatch)
    Application.put_env(:core_execution, :token_max_bytes, @small_cap)
    ModelCache.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :service_task_dispatch)
      Application.delete_env(:core_execution, :token_max_bytes)
      ModelCache.reset_state()
    end)
  end

  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp start_process_instance(opts \\ []) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    pi_opts =
      %{
        process_instance_id: opts[:process_instance_id] || random_id(),
        process_version_id: @version_id,
        payload: opts[:payload] || %{"input" => "data"},
        identity: identity
      }
      |> then(fn map ->
        if Keyword.has_key?(opts, :context),
          do: Map.put(map, :context, opts[:context]),
          else: map
      end)

    Execution.start_process_instance(pi_opts)
  end

  # -------------------------------------------------------------------
  # 16.1: Async handler output exceeding cap → FNI fatal (via handle_complete)
  # -------------------------------------------------------------------

  describe "async handler output PayloadCap (16.1)" do
    test "FNI transitions to fatal when handler output exceeds cap" do
      definitions = BpmnFactory.service_task_process("large_output")
      ModelCache.put_new(@version_id, definitions)

      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "cap-fni-fatal-#{inspect(ref)}",
        [:evil_engine, :flow_node_instance, :state_change],
        fn _event, _measurements, metadata, _config ->
          if Map.get(metadata, :terminal_state) == :fatal and metadata.flow_node_type == :service_task do
            send(test_pid, {:fni_fatal, ref, metadata})
          end
        end,
        nil
      )

      :telemetry.attach(
        "cap-pi-fatal-#{inspect(ref)}",
        [:evil_engine, :process_instance, :state_change],
        fn _event, _measurements, metadata, _config ->
          if metadata.new_state == :fatal do
            send(test_pid, {:pi_fatal, ref, metadata})
          end
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("cap-fni-fatal-#{inspect(ref)}")
        :telemetry.detach("cap-pi-fatal-#{inspect(ref)}")
      end)

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:fni_fatal, ^ref, fni_meta}, 2_000
      assert fni_meta.flow_node_type == :service_task
      assert fni_meta.terminal_state == :fatal

      assert_receive {:pi_fatal, ^ref, _pi_meta}, 2_000
    end

    test "FNI proceeds normally when handler output is within cap" do
      definitions = BpmnFactory.service_task_process("small_output")
      ModelCache.put_new(@version_id, definitions)

      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "cap-pi-finish-#{inspect(ref)}",
        [:evil_engine, :process_instance, :state_change],
        fn _event, _measurements, metadata, _config ->
          if metadata.new_state == :finished do
            send(test_pid, {:pi_finished, ref})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("cap-pi-finish-#{inspect(ref)}") end)

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_finished, ^ref}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # 16.2: Start payload exceeding cap → init fails
  # -------------------------------------------------------------------

  describe "start payload PayloadCap (16.2)" do
    test "init fails when start payload exceeds cap" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      large_payload = %{"data" => String.duplicate("x", @small_cap + 1000)}

      assert {:error, {:payload_too_large, details}} =
               start_process_instance(payload: large_payload)

      assert details.field == :start_payload
      assert details.size > @small_cap
    end

    test "init succeeds when start payload is within cap" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      small_payload = %{"msg" => "hello"}

      assert {:ok, process_instance_pid} = start_process_instance(payload: small_payload)
      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end

    test "init succeeds with nil payload" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, process_instance_pid} = start_process_instance(payload: nil)
      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end

    test "init fails at exactly cap+1 byte" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      payload_str = String.duplicate("a", @small_cap)
      json_size = byte_size(Jason.encode!(payload_str))

      Application.put_env(:core_execution, :token_max_bytes, json_size - 1)

      assert {:error, {:payload_too_large, _details}} =
               start_process_instance(payload: payload_str)
    end

    test "init succeeds at exactly cap bytes" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      payload_str = String.duplicate("a", @small_cap)
      json_size = byte_size(Jason.encode!(payload_str))

      Application.put_env(:core_execution, :token_max_bytes, json_size)

      assert {:ok, _pid} = start_process_instance(payload: payload_str)
    end
  end

  # -------------------------------------------------------------------
  # 16.3: Start context exceeding cap → init fails
  # -------------------------------------------------------------------

  describe "start context PayloadCap (16.3)" do
    test "init fails when start context exceeds cap" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      large_context = %{"data" => String.duplicate("x", @small_cap + 1000)}

      assert {:error, {:payload_too_large, details}} =
               start_process_instance(context: large_context)

      assert details.field == :start_context
      assert details.size > @small_cap
    end

    test "init succeeds when start context is within cap" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      small_context = %{"env" => "test"}

      assert {:ok, process_instance_pid} = start_process_instance(context: small_context)
      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end

    test "init succeeds with nil context" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, process_instance_pid} = start_process_instance(context: nil)
      Process.sleep(100)
      refute Process.alive?(process_instance_pid)
    end

    test "init fails at exactly cap+1 byte for context" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      context_str = String.duplicate("a", @small_cap)
      json_size = byte_size(Jason.encode!(context_str))

      Application.put_env(:core_execution, :token_max_bytes, json_size - 1)

      assert {:error, {:payload_too_large, details}} =
               start_process_instance(context: context_str)

      assert details.field == :start_context
    end

    test "init succeeds at exactly cap bytes for context" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      context_str = String.duplicate("a", @small_cap)
      json_size = byte_size(Jason.encode!(context_str))

      Application.put_env(:core_execution, :token_max_bytes, json_size)

      assert {:ok, _pid} = start_process_instance(context: context_str)
    end

    test "both payload and context are checked independently" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      small_payload = %{"msg" => "ok"}
      large_context = %{"data" => String.duplicate("x", @small_cap + 1000)}

      assert {:error, {:payload_too_large, details}} =
               start_process_instance(payload: small_payload, context: large_context)

      assert details.field == :start_context
    end

    test "oversized payload is caught even when context is valid" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      large_payload = %{"data" => String.duplicate("x", @small_cap + 1000)}
      small_context = %{"env" => "test"}

      assert {:error, {:payload_too_large, details}} =
               start_process_instance(payload: large_payload, context: small_context)

      assert details.field == :start_payload
    end

    test "context omitted entirely does not trigger cap check" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, _pid} = start_process_instance(payload: %{"msg" => "ok"})
    end
  end
end
