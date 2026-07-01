defmodule Examples.EventSinks.DatadogMetrics.DatadogSink do
  @moduledoc """
  Batches high-volume engine events into metric entries for DataDog (stubbed flush).

  Registration: `facade.register_event_sink.("datadog", DatadogSink, api_key: ..., batch_size: ...)`
  """

  @behaviour EvilEngine.Plugin.EventSink

  require Logger

  alias EvilEngine.Types.Event

  @doc "Initializes batching state from registration options, rejecting invalid batch sizes."
  @impl true
  def init(options) do
    api_key = Keyword.fetch!(options, :api_key)
    batch_size = Keyword.get(options, :batch_size, 10)
    on_flush = Keyword.get(options, :on_flush, &default_on_flush/2)

    if batch_size < 1 do
      {:error, :invalid_batch_size}
    else
      {:ok,
       %{
         api_key: api_key,
         batch_size: batch_size,
         buffer: [],
         on_flush: on_flush
       }}
    end
  end

  @doc "Returns true for process instance, flow node, and engine overload events that feed this metrics batcher."
  @impl true
  def accepts?(%Event.ProcessInstanceStateChanged{}), do: true
  def accepts?(%Event.FlowNodeInstanceStarted{}), do: true
  def accepts?(%Event.FlowNodeInstanceFinished{}), do: true
  def accepts?(%Event.EngineOverloaded{}), do: true
  def accepts?(_event), do: false

  @doc "Appends a metric row and flushes when the batch reaches the configured size."
  @impl true
  def handle_event(event, state) do
    entry = metric_entry_for_event(event)
    updated_buffer = state.buffer ++ [entry]
    updated_state = %{state | buffer: updated_buffer}

    if length(updated_state.buffer) >= updated_state.batch_size do
      {:ok, flush_to_datadog(updated_state)}
    else
      {:ok, updated_state}
    end
  end

  @doc "Flushes any buffered metrics when the sink worker shuts down."
  @impl true
  def handle_shutdown(state) do
    flush_to_datadog(state)
    :ok
  end

  defp metric_entry_for_event(%Event.ProcessInstanceStateChanged{} = event) do
    %{
      metric: "evil.process_instance.state_changed",
      tags: [
        "process_instance_id:#{event.process_instance_id}",
        "new_state:#{event.new_state}"
      ],
      value: 1,
      timestamp: event.occurred_at
    }
  end

  defp metric_entry_for_event(%Event.FlowNodeInstanceStarted{} = event) do
    %{
      metric: "evil.flow_node.started",
      tags: [
        "process_instance_id:#{event.process_instance_id}",
        "flow_node_id:#{event.flow_node_id}",
        "flow_node_type:#{event.flow_node_type}"
      ],
      value: 1,
      timestamp: event.occurred_at
    }
  end

  defp metric_entry_for_event(%Event.FlowNodeInstanceFinished{} = event) do
    %{
      metric: "evil.flow_node.finished",
      tags: [
        "process_instance_id:#{event.process_instance_id}",
        "flow_node_id:#{event.flow_node_id}",
        "terminal_state:#{event.terminal_state}"
      ],
      value: 1,
      timestamp: event.occurred_at
    }
  end

  defp metric_entry_for_event(%Event.EngineOverloaded{} = event) do
    %{
      metric: "evil.engine.overload",
      tags: [
        "level:#{event.level}",
        "active_process_instances:#{event.active_process_instances}",
        "limit:#{event.limit}"
      ],
      value: 1,
      timestamp: event.occurred_at
    }
  end

  defp flush_to_datadog(%{buffer: []} = state), do: state

  defp flush_to_datadog(state) do
    state.on_flush.(state.api_key, state.buffer)
    %{state | buffer: []}
  end

  defp default_on_flush(api_key, buffer) do
    Logger.info(
      "Datadog metrics flush (stub, api_key_present=#{api_key != ""}, points=#{length(buffer)}): #{inspect(buffer)}"
    )

    # TODO: replace with Req.post!("https://api.datadoghq.com/api/v1/series", ...)
  end
end
