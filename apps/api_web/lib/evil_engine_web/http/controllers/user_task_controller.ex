defmodule EvilEngineWeb.Http.UserTaskController do
  @moduledoc """
  REST controller for User Task and Manual Task interactions.

  ## Routes

  - `PUT /user-tasks/:flow_node_instance_id/finish` — complete a waiting task with a result payload
  - `PUT /user-tasks/:flow_node_instance_id/cancel` — cancel a waiting task

  ## Authorization

  Both actions enforce lane-based visibility via `EvilEngine.Api` — tasks
  invisible to the caller return 404 (not 403) to prevent existence probing.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api

  @terminal_fni_reasons ~w(
    fni_already_finished fni_already_aborted fni_already_interrupted
    fni_already_fatal fni_not_waiting fni_not_active
  )a

  # ---------------------------------------------------------------------------
  # PUT /user-tasks/:flow_node_instance_id/finish
  # ---------------------------------------------------------------------------

  def finish(conn, %{"flow_node_instance_id" => flow_node_instance_id}) do
    result = get_in(conn.body_params, ["result"]) || %{}
    identity = caller_identity(conn)

    case Api.finish_user_task(flow_node_instance_id, result, identity) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :payload_too_large, details} ->
        render_finish_error(conn, {:payload_too_large, details})

      {:error, reason} ->
        render_finish_error(conn, reason)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "User task operation failed")
  end

  # ---------------------------------------------------------------------------
  # PUT /user-tasks/:flow_node_instance_id/cancel
  # ---------------------------------------------------------------------------

  def cancel(conn, %{"flow_node_instance_id" => flow_node_instance_id}) do
    reason = get_in(conn.body_params, ["reason"])
    identity = caller_identity(conn)

    case Api.cancel_user_task(flow_node_instance_id, reason, identity) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, reason} ->
        render_cancel_error(conn, reason)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "User task operation failed")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_finish_error(conn, :not_found), do: render_fni_not_found(conn)
  defp render_finish_error(conn, :not_a_user_task), do: render_fni_not_found(conn)

  defp render_finish_error(conn, {:payload_too_large, details}) do
    render_error(conn, 413, "payload_too_large", "Result payload exceeds size limit",
      field: to_string(details[:field] || "result"),
      size: details[:size],
      limit: details[:limit]
    )
  end

  defp render_finish_error(conn, {:contract_violation, violations}) do
    render_error(conn, 422, "contract_violation", "Result contract validation failed",
      violations: format_violations(violations)
    )
  end

  defp render_finish_error(conn, reason) when reason in @terminal_fni_reasons do
    render_error(conn, 422, to_string(reason), "User task completion failed")
  end

  defp render_finish_error(conn, reason) do
    Logger.error("User task finish failed: #{inspect(reason)}")
    render_error(conn, 500, "internal_error", "User task completion failed")
  end

  defp render_cancel_error(conn, :not_found), do: render_fni_not_found(conn)
  defp render_cancel_error(conn, :not_a_user_task), do: render_fni_not_found(conn)

  defp render_cancel_error(conn, reason) when reason in @terminal_fni_reasons do
    render_error(conn, 422, to_string(reason), "User task cancellation failed")
  end

  defp render_cancel_error(conn, reason) do
    Logger.error("User task cancel failed: #{inspect(reason)}")
    render_error(conn, 500, "internal_error", "User task cancellation failed")
  end

  defp render_fni_not_found(conn) do
    render_error(conn, 404, "not_found", "Flow node instance not found")
  end

  defp format_violations(violations) do
    Enum.map(violations, fn
      {message, path} -> %{message: message, path: path}
      other when is_binary(other) -> %{message: other}
      _other -> %{message: "Validation constraint violated"}
    end)
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
