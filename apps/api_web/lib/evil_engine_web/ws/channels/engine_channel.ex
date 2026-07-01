defmodule EvilEngineWeb.Ws.EngineChannel do
  @moduledoc """
  Phoenix Channel for receiving engine events.

  ## Topics

  - `engine:events` — broadcasts all engine-level events
  - `process_instance:<process_instance_id>` — broadcasts events scoped to a specific process instance

  Events arrive via the `WebSocket` EventSink, which broadcasts
  `{:engine_event, payload}` to the corresponding PubSub topic.
  This channel intercepts those broadcasts and pushes them to
  connected clients.

  ## Authorization

  - `process_instance:*` join requires process-instance visibility (starter match, lane match, or admin override)
  - Flow node instance events are lane-filtered: events on inaccessible lanes are silently dropped
  - Process-instance-level events (`pi_state_changed`, etc.) always delivered if the join succeeded
  """

  use Phoenix.Channel

  alias EvilEngine.Api

  @impl true
  def join("engine:" <> _subtopic, _payload, socket) do
    identity = socket.assigns[:identity]
    lanes = extract_lane_names(identity)
    is_admin = admin_override?(identity)
    socket = assign(socket, :accessible_lanes, lanes)
    socket = assign(socket, :admin_override, is_admin)
    {:ok, socket}
  end

  def join("process_instance:" <> process_instance_id, _payload, socket) do
    identity = socket.assigns[:identity]

    case check_process_instance_visibility(process_instance_id, identity) do
      :ok ->
        lanes = extract_lane_names(identity)
        is_admin = admin_override?(identity)
        socket = assign(socket, :accessible_lanes, lanes)
        socket = assign(socket, :admin_override, is_admin)
        {:ok, socket}

      :not_visible ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info({:engine_event, payload}, socket) do
    if should_deliver?(payload, socket) do
      push(socket, "engine_event", payload)
    end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Process instance visibility
  # ---------------------------------------------------------------------------

  defp check_process_instance_visibility(process_instance_id, identity) do
    if admin_override?(identity) do
      :ok
    else
      case Api.get_process_instance(process_instance_id) do
        {:ok, process_instance} ->
          evaluate_process_instance_visibility(process_instance, identity)

        {:error, _} ->
          :not_visible
      end
    end
  rescue
    _ -> :not_visible
  end

  defp evaluate_process_instance_visibility(process_instance, identity) do
    cond do
      starter_match?(process_instance, identity) -> :ok
      Api.check_lane_access(process_instance.id, extract_lane_names(identity)) -> :ok
      true -> :not_visible
    end
  end

  defp starter_match?(process_instance, identity) do
    get_in(process_instance.started_by, ["id"]) == identity.id
  end

  # ---------------------------------------------------------------------------
  # Event filtering
  # ---------------------------------------------------------------------------

  defp should_deliver?(payload, socket) do
    if socket.assigns[:admin_override] do
      true
    else
      lane_name = get_in(payload, ["data", "laneName"])

      case lane_name do
        nil -> true
        name -> name in (socket.assigns[:accessible_lanes] || [])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Identity helpers
  # ---------------------------------------------------------------------------

  defp admin_override?(identity) do
    identity && identity.claims["zeeky_boogie_doog"] == true
  end

  defp extract_lane_names(nil), do: []

  defp extract_lane_names(identity) do
    (identity.claims || %{})
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, "lane:") and value == true
    end)
    |> Enum.map(fn {key, _} -> String.trim_leading(key, "lane:") end)
  end
end
