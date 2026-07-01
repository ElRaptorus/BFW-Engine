defmodule Examples.BusinessRules.DecisionTracePublisher.Sink do
  @moduledoc """
  Event sink that publishes DMN Business Rule Task audit traces.

  Listens for `FlowNodeInstanceFinished` events where the flow node is a
  Business Rule Task in DMN mode. Builds a structured audit payload and
  delivers it through an injectable `deliver_fn` (defaults to a stubbed
  HTTP POST logger).
  """

  @behaviour EvilEngine.Plugin.EventSink

  require Logger

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.DecisionTracePublisher.AuditMessageBuilder

  @doc "Stores optional `deliver_fn` for audit payload delivery."
  @impl true
  def init(options) do
    deliver_function = Keyword.get(options, :deliver_fn, &default_deliver_audit_message/1)
    {:ok, %{deliver_function: deliver_function}}
  end

  @doc "Returns true when the event is a finished DMN Business Rule Task."
  @impl true
  def accepts?(%Event.FlowNodeInstanceFinished{} = event) do
    event.flow_node_type == :business_rule_task and
      dmn_mode?(Map.get(event, :type_properties, %{}))
  end

  @impl true
  def accepts?(_event), do: false

  @doc "Builds an audit message and passes it to the configured delivery function."
  @impl true
  def handle_event(%Event.FlowNodeInstanceFinished{} = event, state) do
    audit_message = AuditMessageBuilder.build(event)
    state.deliver_function.(audit_message)
    {:ok, state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}

  @doc "Returns without flushing buffered audit messages."
  @impl true
  def handle_shutdown(_state), do: :ok

  defp dmn_mode?(type_properties) when is_map(type_properties) do
    property(type_properties, "mode") == "dmn"
  end

  defp dmn_mode?(_invalid), do: false

  defp property(type_properties, key) when is_binary(key) do
    Map.get(type_properties, key) || Map.get(type_properties, String.to_atom(key))
  end

  defp default_deliver_audit_message(audit_message) do
    Logger.info(
      "[decision_trace_publisher] stub HTTP POST audit payload: #{inspect(audit_message)}"
    )

    :ok
  end
end
