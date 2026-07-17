defmodule EvilEngine.Execution.MultiInstanceSubprocessIntegrationTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000003"

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
  end

  defp start_process_instance(version_id \\ @version_id, opts \\ []) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    process_instance_options = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
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
      "pi-#{label}-#{inspect(reference)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:pi_state_change, reference, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pi-#{label}-#{inspect(reference)}") end)

    reference
  end

  defp attach_fni_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "fni-#{label}-#{inspect(reference)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:fni_state_change, reference, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fni-#{label}-#{inspect(reference)}") end)

    reference
  end

  describe "embedded SubProcess — execution" do
    test "PI completes when an embedded subprocess executes its inner graph" do
      definitions = BpmnFactory.embedded_sub_process_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("embedded-sub-process")
      _flow_node_instance_reference = attach_fni_telemetry("embedded-sub-process-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, metadata}, 5_000
      assert metadata.process_instance_id
    end
  end

  describe "multi-instance Task — sequential" do
    test "PI completes when a sequential multi-instance task iterates over the collection" do
      definitions =
        BpmnFactory.multi_instance_task_process(
          is_sequential: true,
          collection_expression: "token.items",
          output_collection: "processedItems"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("multi-instance-sequential")
      _flow_node_instance_reference = attach_fni_telemetry("multi-instance-sequential-fni")

      assert {:ok, _process_instance_pid} =
               start_process_instance(@version_id, payload: %{"items" => [1, 2, 3]})

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, metadata}, 5_000
      assert metadata.process_instance_id
    end
  end

  describe "multi-instance Task — parallel" do
    test "PI stays running when parallel multi-instance user tasks are waiting" do
      definitions =
        BpmnFactory.multi_instance_task_process(
          is_sequential: false,
          collection_expression: "token.items",
          output_collection: "processedItems",
          flow_node_type: :user_task
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("multi-instance-parallel")
      _flow_node_instance_reference = attach_fni_telemetry("multi-instance-parallel-fni")

      assert {:ok, _process_instance_pid} =
               start_process_instance(@version_id, payload: %{"items" => ["alpha", "beta"]})

      assert_receive {:pi_state_change, ^process_instance_reference, :running, _metadata}, 5_000
      refute_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 1_000
    end
  end

end
