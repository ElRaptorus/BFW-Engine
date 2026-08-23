defmodule EvilEngineWeb.Ws.EngineChannel do
  @moduledoc """
  Phoenix Channel for receiving engine events.

  ## Topics

  - `engine:events` — engine-level events plus PI-scoped events filtered by §5.1 visibility and lane
  - `process_instance:<process_instance_id>` — events scoped to a specific process instance
  - `user_tasks:pending` — `UserTaskCreated` / `UserTaskFinished` inbox, lane-filtered

  Events arrive via the `WebSocket` EventSink, which broadcasts
  `{:engine_event, payload}` to the corresponding PubSub topic.
  This channel intercepts those broadcasts and pushes them to
  connected clients.

  ## Authorization

  - `process_instance:*` join requires process-instance visibility (starter match, `read`/`write` lane, `observe_all`, or admin override)
  - Dispatch filtering is delegated to `EvilEngineWeb.Ws.EventDelivery`
  - `admin_override` is zeeky-only; `observe_all` is a separate unbounded-read assign
  """

  use Phoenix.Channel

  alias EvilEngine.Api
  alias EvilEngine.Api.Validation
  alias EvilEngineWeb.Ws.EventDelivery

  @impl true
  def join("engine:" <> _subtopic, _payload, socket) do
    {:ok, assign_identity_filters(socket)}
  end

  def join("process_instance:" <> process_instance_id, _payload, socket) do
    identity = socket.assigns[:identity]

    case check_process_instance_visibility(process_instance_id, identity) do
      :ok ->
        {:ok, assign_identity_filters(socket)}

      :not_visible ->
        {:error, %{reason: "not_found"}}
    end
  end

  def join("user_tasks:pending", _payload, socket) do
    {:ok, assign_identity_filters(socket)}
  end

  def join("user_tasks:" <> _other, _payload, _socket) do
    {:error, %{reason: "not_found"}}
  end

  @impl true
  def handle_info({:engine_event, payload}, socket) do
    assigns = Map.put(socket.assigns, :topic, socket.topic)

    if EventDelivery.should_deliver?(payload, assigns) do
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
      Validation.observe_all?(identity) -> :ok
      starter_match?(process_instance, identity) -> :ok
      Api.check_lane_access(process_instance.id, Validation.accessible_lanes(identity)) -> :ok
      true -> :not_visible
    end
  end

  defp starter_match?(process_instance, identity) do
    get_in(process_instance.started_by, ["id"]) == identity.id
  end

  # ---------------------------------------------------------------------------
  # Identity helpers
  # ---------------------------------------------------------------------------

  defp assign_identity_filters(socket) do
    identity = socket.assigns[:identity]

    socket
    |> assign(:accessible_lanes, Validation.accessible_lanes(identity || %{}))
    |> assign(:writable_lanes, Validation.writable_lanes(identity || %{}))
    |> assign(:admin_override, admin_override?(identity))
    |> assign(:observe_all, Validation.observe_all?(identity || %{}))
    |> assign(:identity_id, identity && identity.id)
  end

  defp admin_override?(identity) do
    identity && identity.claims["zeeky_boogie_doog"] == true
  end
end
