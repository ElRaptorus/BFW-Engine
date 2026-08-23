defmodule EvilEngineWeb.Http.TimerEventController do
  @moduledoc """
  REST controller for timer event manual trigger operations.

  ## Routes

  - `POST /timer-events/:flow_node_instance_id/trigger` — manually fire a waiting timer

  ## Authorization

  Lane access is enforced by `EvilEngine.Api.trigger_timer_event/3`.
  No specific JWT claim is required beyond lane membership (same model as user tasks).
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api

  def trigger(conn, %{"flow_node_instance_id" => flow_node_instance_id}) do
    identity = caller_identity(conn)

    case Api.trigger_timer_event(flow_node_instance_id, identity) do
      :ok ->
        conn |> put_status(200) |> json(%{triggered: true})

      error ->
        render_trigger_error(conn, error)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Failed to trigger timer event")
  end

  @conflict_reasons ~w(
    fni_already_finished fni_already_aborted fni_already_interrupted
    fni_already_fatal fni_not_active fni_not_active_or_found
  )a

  defp render_trigger_error(conn, {:error, :not_found}),
    do: render_error(conn, 404, "not_found", "Flow node instance not found")

  defp render_trigger_error(conn, {:error, :not_a_timer_event}),
    do: render_error(conn, 422, "not_a_timer_event", "Flow node instance is not a timer event")

  defp render_trigger_error(conn, {:error, reason}) when reason in @conflict_reasons,
    do: render_error(conn, 409, "conflict", "Timer event is not in a triggerable state")

  defp render_trigger_error(conn, {:error, :forbidden, details}) do
    render_error(conn, 403, "forbidden", "Insufficient permissions",
      required_claim: details[:required_claim],
      required_value: details[:required_value]
    )
  end

  defp render_trigger_error(conn, {:error, reason}) do
    Logger.error("Timer trigger failed: #{inspect(reason)}")
    render_error(conn, 500, "internal_error", "Failed to trigger timer event")
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
