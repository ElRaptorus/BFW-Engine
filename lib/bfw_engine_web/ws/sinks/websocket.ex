defmodule BfwEngineWeb.Ws.Sinks.WebSocket do
  @moduledoc """
  WebSocket/Channel push sink. Default ON.

  Broadcasts accepted events to connected Phoenix Channel clients.
  Debug/verbose severities excluded by default.
  """

  @behaviour BfwEngine.Plugin.EventSink

  alias BfwEngine.Types.Wire

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def accepts?(%BfwEngine.Types.Event.SinkFailed{}), do: false
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    pubsub = BfwEngine.Events.pubsub_name()
    payload = event_payload(event)

    _result =
      case Map.get(event, :process_instance_id) || Map.get(event, :scope_process_instance_id) do
        nil ->
          _parent = maybe_broadcast_to_parent_pi_channel(pubsub, event, payload)

          _root =
            maybe_broadcast_to_root_pi_channel(
              pubsub,
              event,
              payload,
              Map.get(event, :parent_process_instance_id)
            )

          Phoenix.PubSub.broadcast(pubsub, "engine:events", {:engine_event, payload})

        process_instance_id ->
          _targeted =
            Phoenix.PubSub.broadcast(
              pubsub,
              "process_instance:#{process_instance_id}",
              {:engine_event, payload}
            )

          _root = maybe_broadcast_to_root_pi_channel(pubsub, event, payload, process_instance_id)
          _pending = maybe_broadcast_pending_user_tasks(pubsub, event, payload)
          Phoenix.PubSub.broadcast(pubsub, "engine:events", {:engine_event, payload})
      end

    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok

  defp maybe_broadcast_to_parent_pi_channel(pubsub, event, payload) do
    case Map.get(event, :parent_process_instance_id) do
      nil ->
        :ok

      parent_process_instance_id ->
        Phoenix.PubSub.broadcast(
          pubsub,
          "process_instance:#{parent_process_instance_id}",
          {:engine_event, payload}
        )
    end
  end

  defp maybe_broadcast_to_root_pi_channel(pubsub, event, payload, process_instance_id) do
    case Map.get(event, :root_process_instance_id) do
      nil ->
        :ok

      root when root == process_instance_id ->
        :ok

      root_process_instance_id ->
        Phoenix.PubSub.broadcast(
          pubsub,
          "process_instance:#{root_process_instance_id}",
          {:engine_event, payload}
        )
    end
  end

  defp maybe_broadcast_pending_user_tasks(pubsub, event, payload) do
    case event do
      %BfwEngine.Types.Event.UserTaskCreated{} ->
        Phoenix.PubSub.broadcast(pubsub, "user_tasks:pending", {:engine_event, payload})

      %BfwEngine.Types.Event.UserTaskFinished{} ->
        Phoenix.PubSub.broadcast(pubsub, "user_tasks:pending", {:engine_event, payload})

      _other ->
        :ok
    end
  end

  defp event_payload(event) do
    %{
      "type" => event.__struct__ |> Module.split() |> List.last(),
      "data" => Wire.struct_to_camel_map(event),
      "occurredAt" => Map.get(event, :occurred_at, DateTime.utc_now())
    }
  end
end
