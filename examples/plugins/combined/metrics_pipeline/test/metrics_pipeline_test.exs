defmodule Examples.Plugins.Combined.MetricsPipeline.MetricsPipelineTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias EvilEngine.EngineFacade
  alias EvilEngine.EngineFacade.{Graphql, ProcessInstances, ServiceTasks}
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.{Event, Token}

  alias Examples.Plugins.Combined.MetricsPipeline.{
    FacadeStore,
    MetricsAggregatorHandler,
    MetricsCollectorSink
  }

  setup do
    test_pid = self()

    mock_facade = %EngineFacade{
      engine_id: "test-engine",
      engine_name: "test-engine-name",
      version: "0.0.0",
      service_tasks: %ServiceTasks{
        finish_async: fn flow_node_instance_id, output_payload ->
          send(test_pid, {:finish_async, flow_node_instance_id, output_payload})
          :ok
        end,
        fail_async: fn flow_node_instance_id, error_code, error_message ->
          send(test_pid, {:fail_async, flow_node_instance_id, error_code, error_message})
          :ok
        end
      }
    }

    case FacadeStore.start_link(name: FacadeStore) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    FacadeStore.put(mock_facade)

    on_exit(fn ->
      case Process.whereis(FacadeStore) do
        nil -> :ok
        facade_store_pid -> if Process.alive?(facade_store_pid), do: Agent.stop(facade_store_pid)
      end
    end)

    table_name =
      String.to_atom("metrics_pipeline_isolated_#{:erlang.unique_integer([:positive])}")

    :ets.new(table_name, [:named_table, :public, :set])

    on_exit(fn ->
      if :ets.whereis(table_name) != :undefined, do: :ets.delete(table_name)
    end)

    {:ok, metrics_table_name: table_name, mock_facade: mock_facade}
  end

  test "sink increments ETS counters for process instance state change events", %{
    metrics_table_name: table_name
  } do
    {:ok, state} = MetricsCollectorSink.init(table_name: table_name)

    event = %Event.ProcessInstanceStateChanged{
      process_instance_id: "pi-1",
      process_model_id: "model-1",
      version: "1.0.0",
      parent_process_instance_id: nil,
      old_state: nil,
      new_state: :running,
      occurred_at: ~U[2026-05-14T12:00:00Z]
    }

    assert {:ok, ^state} = MetricsCollectorSink.handle_event(event, state)
    assert [{{:pi_state, :running}, 1}] = :ets.lookup(table_name, {:pi_state, :running})
  end

  test "sink increments ETS counters for flow node instance finished events", %{
    metrics_table_name: table_name
  } do
    {:ok, state} = MetricsCollectorSink.init(table_name: table_name)

    event = %Event.FlowNodeInstanceFinished{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      flow_node_id: "Task_1",
      flow_node_type: :service_task,
      event_type: nil,
      terminal_state: :finished,
      occurred_at: ~U[2026-05-14T12:00:00Z]
    }

    assert {:ok, ^state} = MetricsCollectorSink.handle_event(event, state)

    assert [{{:fni_type, :service_task}, 1}] =
             :ets.lookup(table_name, {:fni_type, :service_task})
  end

  test "handler returns {:async, fni_id} and completes via finish_async (no facade in process dict)",
       %{metrics_table_name: table_name} do
    :ets.insert(table_name, {{:pi_state, :running}, 2})
    :ets.insert(table_name, {{:fni_type, :service_task}, 3})

    Process.put(:metrics_pipeline_ets_table, table_name)

    flow_node = %FlowNode{
      id: "Task_aggregate",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "aggregate_metrics"}
    }

    token = %Token{id: "token-1", process_instance_id: "pi-1", payload: %{}}

    handler_context = %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1"
    }

    assert {:async, "fni-1"} =
             MetricsAggregatorHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:finish_async, "fni-1", output_payload}, 2_000
    assert output_payload.process_instance_states == %{running: 2}
    assert output_payload.flow_node_types == %{service_task: 3}
    assert is_map(output_payload.facade_context)
  after
    Process.delete(:metrics_pipeline_ets_table)
  end

  test "handler includes process_instances.get outcome when facade is in process dict", %{
    metrics_table_name: table_name
  } do
    :ets.insert(table_name, {{:pi_state, :running}, 1})

    Process.put(:metrics_pipeline_ets_table, table_name)

    engine_facade_for_process_dict = %EngineFacade{
      engine_id: "example-test-engine",
      engine_name: "example-test-engine-name",
      version: "0.0.0",
      process_instances: %ProcessInstances{
        get: fn process_instance_id ->
          {:ok, %{process_instance_id: process_instance_id, stub_snapshot: true}}
        end
      }
    }

    Process.put(:metrics_pipeline_facade, engine_facade_for_process_dict)

    flow_node = %FlowNode{
      id: "Task_aggregate",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "aggregate_metrics"}
    }

    token = %Token{id: "token-2", process_instance_id: "pi-facade-test", payload: %{}}

    handler_context = %HandlerContext{
      flow_node_instance_id: "fni-2",
      process_instance_id: "pi-facade-test"
    }

    assert {:async, "fni-2"} =
             MetricsAggregatorHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:finish_async, "fni-2", output_payload}, 2_000

    assert {:ok, %{process_instance_id: "pi-facade-test", stub_snapshot: true}} =
             output_payload.facade_context.process_instance_get
  after
    Process.delete(:metrics_pipeline_ets_table)
    Process.delete(:metrics_pipeline_facade)
  end

  test "handler resolves engine facade from process dictionary with graphql", %{
    metrics_table_name: table_name
  } do
    :ets.insert(table_name, {{:pi_state, :running}, 1})

    Process.put(:metrics_pipeline_ets_table, table_name)

    engine_facade_from_process_dictionary = %EngineFacade{
      engine_id: "example-test-engine-process-dictionary",
      engine_name: "example-test-engine-name-process-dictionary",
      version: "0.0.0",
      process_instances: %ProcessInstances{
        get: fn process_instance_id ->
          {:ok,
           %{process_instance_id: process_instance_id, stub_snapshot_process_dictionary: true}}
        end
      },
      graphql: %Graphql{
        query: fn _query_string, _variables ->
          {:ok, %{"data" => %{"listProcessInstances" => %{"count" => 12}}}}
        end
      }
    }

    Process.put(:metrics_pipeline_facade, engine_facade_from_process_dictionary)

    flow_node = %FlowNode{
      id: "Task_aggregate",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "aggregate_metrics"}
    }

    token = %Token{id: "token-3", process_instance_id: "pi-process-dictionary-test", payload: %{}}

    handler_context = %HandlerContext{
      flow_node_instance_id: "fni-3",
      process_instance_id: "pi-process-dictionary-test"
    }

    assert {:async, "fni-3"} =
             MetricsAggregatorHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:finish_async, "fni-3", output_payload}, 2_000

    assert {:ok,
            %{
              process_instance_id: "pi-process-dictionary-test",
              stub_snapshot_process_dictionary: true
            }} = output_payload.facade_context.process_instance_get

    assert {:ok, %{"data" => %{"listProcessInstances" => %{"count" => 12}}}} =
             output_payload.facade_context.illustrative_aggregate_query

    assert output_payload.engine_identity == %{
             engine_id: "example-test-engine-process-dictionary",
             engine_name: "example-test-engine-name-process-dictionary"
           }
  after
    Process.delete(:metrics_pipeline_ets_table)
    Process.delete(:metrics_pipeline_facade)
  end
end
