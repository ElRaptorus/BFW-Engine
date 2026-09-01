defmodule Examples.BusinessRules.DecisionAuditReporter.AuditSink do
  @moduledoc """
  Event sink that records DMN Business Rule Task completions into `EventTracker`.

  The worker later fetches each tracked flow node instance through the facade
  so the audit report is assembled from persisted `type_properties`.
  """

  @behaviour EvilEngine.Plugin.EventSink

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.DecisionAuditReporter.EventTracker

  @doc "Starts the event tracker agent and stores its registered name in sink state."
  @impl true
  def init(options) do
    tracker_name = Keyword.get(options, :tracker_name, EventTracker)

    case EventTracker.start_link(name: tracker_name) do
      {:ok, _pid} -> {:ok, %{tracker_name: tracker_name}}
      {:error, {:already_started, _pid}} -> {:ok, %{tracker_name: tracker_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns true when the event is a finished DMN Business Rule Task."
  @impl true
  def accepts?(%Event.FlowNodeInstanceFinished{} = event) do
    event.flow_node_type == :business_rule_task and
      dmn_mode?(Map.get(event, :type_properties, %{}))
  end

  @impl true
  def accepts?(_event), do: false

  @doc "Tracks the flow node instance ID for later facade inspection."
  @impl true
  def handle_event(%Event.FlowNodeInstanceFinished{} = event, state) do
    EventTracker.track(
      %{
        flow_node_instance_id: event.flow_node_instance_id,
        process_instance_id: event.process_instance_id,
        flow_node_id: event.flow_node_id
      },
      name: state.tracker_name
    )

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}

  @doc "Returns without flushing; tracked IDs remain until the worker consumes them."
  @impl true
  def handle_shutdown(_state), do: :ok

  defp dmn_mode?(type_properties) when is_map(type_properties) do
    property(type_properties, "mode") == "dmn"
  end

  defp dmn_mode?(_invalid), do: false

  defp property(type_properties, key) when is_binary(key) do
    Map.get(type_properties, key) || Map.get(type_properties, String.to_atom(key))
  end
end
