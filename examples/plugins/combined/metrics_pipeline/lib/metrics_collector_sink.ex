defmodule Examples.Plugins.Combined.MetricsPipeline.MetricsCollectorSink do
  @moduledoc """
  Increments shared ETS counters for high-volume execution events so Service Task
  handlers can expose aggregated views later.
  """

  @behaviour BfwEngine.Plugin.EventSink

  require Logger

  alias BfwEngine.Types.Event

  @doc "Ensures the named ETS table exists and records its name in sink state."
  @impl true
  def init(options) do
    table_name = Keyword.fetch!(options, :table_name)

    if :ets.whereis(table_name) == :undefined do
      :ets.new(table_name, [:named_table, :public, :set])
    end

    {:ok, %{table: table_name}}
  end

  @doc "Returns true for process instance state and flow node finished events used in the metrics pipeline example."
  @impl true
  def accepts?(%Event.ProcessInstanceStateChanged{}), do: true

  @impl true
  def accepts?(%Event.FlowNodeInstanceFinished{}), do: true

  @impl true
  def accepts?(_event), do: false

  @doc "Updates ETS counters for accepted events or returns state unchanged for unexpected events."
  @impl true
  def handle_event(%Event.ProcessInstanceStateChanged{} = event, state) do
    :ets.update_counter(
      state.table,
      {:pi_state, event.new_state},
      {2, 1},
      {{:pi_state, event.new_state}, 0}
    )

    {:ok, state}
  end

  @impl true
  def handle_event(%Event.FlowNodeInstanceFinished{} = event, state) do
    :ets.update_counter(
      state.table,
      {:fni_type, event.flow_node_type},
      {2, 1},
      {{:fni_type, event.flow_node_type}, 0}
    )

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}

  @doc "Logs the raw ETS rows at shutdown for observability of collected counters."
  @impl true
  def handle_shutdown(state) do
    summary = :ets.tab2list(state.table)

    Logger.info("metrics_collector: shutdown counter_rows=#{inspect(summary)}")
    :ok
  end
end
