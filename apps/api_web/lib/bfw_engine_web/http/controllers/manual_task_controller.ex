defmodule BfwEngineWeb.Http.ManualTaskController do
  @moduledoc """
  REST controller for confirming Manual Tasks (`bfw:requireConfirmation`).

  ## Routes

  - `PUT /manual-tasks/:flow_node_instance_id/confirm` — confirm a waiting Manual Task; any
    request body is ignored and the token the task entered with continues unchanged
  - `PUT /manual-tasks/:flow_node_instance_id/cancel` — cancel a waiting Manual Task, which
    aborts the whole process instance tree

  ## Authorization

  Both actions enforce lane-based visibility via `BfwEngine.Api`.
  Invisible tasks and flow node instances that are not Manual Tasks return
  404. Visible but not writable (`\"read\"` or `observe_all`) return 403.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Api

  @terminal_fni_reasons ~w(
    fni_already_finished fni_already_aborted fni_already_interrupted
    fni_already_fatal fni_not_waiting fni_not_active
  )a

  # ---------------------------------------------------------------------------
  # PUT /manual-tasks/:flow_node_instance_id/confirm
  # ---------------------------------------------------------------------------

  def confirm(conn, %{"flow_node_instance_id" => flow_node_instance_id}) do
    identity = caller_identity(conn)

    case Api.confirm_manual_task(flow_node_instance_id, identity) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :forbidden, details} ->
        render_manual_task_error(conn, {:forbidden, details}, "confirm")

      {:error, reason} ->
        render_manual_task_error(conn, reason, "confirm")
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Manual task operation failed")
  end

  # ---------------------------------------------------------------------------
  # PUT /manual-tasks/:flow_node_instance_id/cancel
  # ---------------------------------------------------------------------------

  def cancel(conn, %{"flow_node_instance_id" => flow_node_instance_id}) do
    reason = get_in(conn.body_params, ["reason"])
    identity = caller_identity(conn)

    case Api.cancel_manual_task(flow_node_instance_id, reason, identity) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :forbidden, details} ->
        render_manual_task_error(conn, {:forbidden, details}, "cancel")

      {:error, reason} ->
        render_manual_task_error(conn, reason, "cancel")
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Manual task operation failed")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_manual_task_error(conn, :not_found, _operation), do: render_fni_not_found(conn)

  defp render_manual_task_error(conn, :not_a_manual_task, _operation),
    do: render_fni_not_found(conn)

  defp render_manual_task_error(conn, {:forbidden, details}, _operation) do
    render_error(conn, 403, "forbidden", "Insufficient permissions",
      required_claim: details[:required_claim],
      required_value: details[:required_value]
    )
  end

  defp render_manual_task_error(conn, reason, operation) when reason in @terminal_fni_reasons do
    render_error(conn, 422, to_string(reason), "Manual task #{operation} failed")
  end

  defp render_manual_task_error(conn, reason, operation) do
    Logger.error("Manual task #{operation} failed: #{inspect(reason)}")
    render_error(conn, 500, "internal_error", "Manual task #{operation} failed")
  end

  defp render_fni_not_found(conn) do
    render_error(conn, 404, "not_found", "Flow node instance not found")
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %BfwEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
