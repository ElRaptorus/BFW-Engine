defmodule Examples.Plugins.Combined.MetricsPipeline.MetricsPipelinePlugin do
  @moduledoc """
  Registers a metrics collector sink and an aggregator Service Task handler that
  share an ETS-backed counter table.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.Plugins.Combined.MetricsPipeline.{
    FacadeStore,
    MetricsAggregatorHandler,
    MetricsCollectorSink
  }

  @ets_table_name :metrics_pipeline_counters

  @doc "Ensures the shared counter table exists, registers the sink and handler, and stores the facade for the aggregator task."
  @impl true
  def on_load(engine_facade) do
    if :ets.whereis(@ets_table_name) == :undefined do
      :ets.new(@ets_table_name, [:named_table, :public, :set])
    end

    with :ok <-
           register_sink_outcome_to_ok(
             engine_facade.register_event_sink.(
               "metrics_collector",
               MetricsCollectorSink,
               table_name: @ets_table_name
             )
           ),
         :ok <-
           register_handler_outcome_to_ok(
             engine_facade.register_service_task_handler.(
               "aggregate_metrics",
               MetricsAggregatorHandler
             )
           ) do
      :ok = FacadeStore.put(engine_facade)
      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_engine_facade), do: :ok

  defp register_sink_outcome_to_ok(:ok), do: :ok

  defp register_sink_outcome_to_ok({:error, reason}),
    do: {:error, {:register_event_sink_failed, reason}}

  defp register_handler_outcome_to_ok(:ok), do: :ok

  defp register_handler_outcome_to_ok({:error, :conflict, incumbent}),
    do: {:error, {:register_service_task_handler_conflict, incumbent}}

  defp register_handler_outcome_to_ok({:error, :invalid_handler, message}),
    do: {:error, {:register_service_task_handler_invalid, message}}

  defp register_handler_outcome_to_ok({:error, :module_not_loaded, message}),
    do: {:error, {:register_service_task_handler_not_loaded, message}}

  defp register_handler_outcome_to_ok({:error, other}), do: {:error, other}
end
