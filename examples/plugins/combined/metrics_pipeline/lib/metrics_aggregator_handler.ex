defmodule Examples.Plugins.Combined.MetricsPipeline.MetricsAggregatorHandler do
  @moduledoc """
  Reads the shared ETS counter table and returns a grouped summary as task output.

  When `MetricsPipelinePlugin.on_load/1` stores the facade in `FacadeStore`, this
  handler retrieves it at Service Task time and calls into `EngineFacade` closures
  (for example `process_instances.get/1` and an illustrative GraphQL read) so
  the example shows cross-process facade access (plugin load process vs execution
  worker). The same pattern appears in the RabbitMQ combined example: stash the
  facade in `FacadeStore` during `on_load/1`, read it where the worker runs.

  ## Async-only contract

  All Service Task handlers must return `{:async, flow_node_instance_id}` from
  `handle_enter/3` and complete the FNI later via the facade's
  `finish_async`/`fail_async` closures. This handler spawns a Task that
  aggregates counters, enriches with facade data, and calls `finish_async`.

  Tests may set `Process.put(:metrics_pipeline_ets_table, table_name)` before
  `handle_enter/3` for an isolated ETS table. They may also set
  `Process.put(:metrics_pipeline_facade, %EngineFacade{})` to inject a
  facade without starting `FacadeStore` (mirrors how other examples inject stubs
  via the process dictionary).
  """

  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.EngineFacade
  alias BfwEngine.EngineFacade.{Graphql, ProcessInstances}
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token
  alias Examples.Plugins.Combined.MetricsPipeline.FacadeStore

  @process_dictionary_table_key :metrics_pipeline_ets_table

  @process_dictionary_facade_key :metrics_pipeline_facade

  @default_table_name :metrics_pipeline_counters

  @doc "Spawns async aggregation of ETS counter rows, enriches with facade data, and completes via `finish_async`."
  @impl true
  def handle_enter(
        %FlowNode{} = _flow_node,
        %Token{} = _token,
        %HandlerContext{} = handler_context
      ) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    table_name = Process.get(@process_dictionary_table_key) || @default_table_name
    facade = Process.get(@process_dictionary_facade_key)

    {:ok, _pid} =
      Task.start(fn ->
        Process.sleep(50)

        counter_rows = :ets.tab2list(table_name)
        summary_payload = build_summary_payload(counter_rows)

        summary_with_facade_identity =
          enrich_with_facade_data(summary_payload, facade)

        output_payload =
          merge_facade_context(summary_with_facade_identity, handler_context, facade)

        stored_facade = FacadeStore.get()

        if stored_facade do
          stored_facade.service_tasks.finish_async.(flow_node_instance_id, output_payload)
        end
      end)

    {:async, flow_node_instance_id}
  end

  defp build_summary_payload(counter_rows) do
    initial_accumulator = %{process_instance_states: %{}, flow_node_types: %{}}

    summary =
      Enum.reduce(counter_rows, initial_accumulator, fn counter_row, accumulator ->
        accumulate_counter_row(counter_row, accumulator)
      end)

    %{
      process_instance_states: summary.process_instance_states,
      flow_node_types: summary.flow_node_types
    }
  end

  defp enrich_with_facade_data(summary_payload, nil), do: summary_payload

  defp enrich_with_facade_data(summary_payload, %EngineFacade{} = engine_facade) do
    engine_identity = %{
      engine_id: engine_facade.engine_id,
      engine_name: engine_facade.engine_name
    }

    Map.put(summary_payload, :engine_identity, engine_identity)
  end

  defp merge_facade_context(summary_payload, %HandlerContext{} = handler_context, facade) do
    resolved_facade = facade || FacadeStore.get()

    case resolved_facade do
      nil ->
        Map.put(summary_payload, :facade_context, %{
          note: "engine_facade_not_available_in_facade_store"
        })

      %EngineFacade{process_instances: %ProcessInstances{} = process_instances} =
          engine_facade ->
        process_instance_id = handler_context.process_instance_id
        process_instance_snapshot_outcome = process_instances.get.(process_instance_id)

        illustrative_aggregate_query_outcome =
          query_illustrative_process_instance_aggregate(engine_facade)

        Map.put(summary_payload, :facade_context, %{
          process_instance_get: process_instance_snapshot_outcome,
          illustrative_aggregate_query: illustrative_aggregate_query_outcome
        })
    end
  end

  defp query_illustrative_process_instance_aggregate(%EngineFacade{
         graphql: %Graphql{} = graphql_namespace
       }) do
    placeholder_query_string =
      "query MetricsPipelineIllustrativeProcessInstanceCount { __typename }"

    graphql_namespace.query.(placeholder_query_string, %{})
  end

  defp accumulate_counter_row(
         {{:pi_state, process_instance_state}, count},
         accumulator
       ) do
    %{
      accumulator
      | process_instance_states:
          Map.put(
            accumulator.process_instance_states,
            process_instance_state,
            count
          )
    }
  end

  defp accumulate_counter_row({{:fni_type, flow_node_type}, count}, accumulator) do
    %{
      accumulator
      | flow_node_types: Map.put(accumulator.flow_node_types, flow_node_type, count)
    }
  end

  defp accumulate_counter_row(_other, accumulator), do: accumulator
end
