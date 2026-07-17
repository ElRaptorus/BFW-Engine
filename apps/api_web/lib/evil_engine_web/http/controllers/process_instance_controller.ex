defmodule EvilEngineWeb.Http.ProcessInstanceController do
  @moduledoc """
  REST controller for process instance administrative operations.

  ## Routes

  - `PUT /process-instances/:id/abort` — abort a running process instance
  - `PUT /process-instances/:id/retry` — retry a terminal process instance
  - `DELETE /process-instances/:id` — delete a terminal process instance

  ## Authorization

  Abort requires the `abort_process_instance` enum claim:
  - `"none"` or absent → 403
  - `"own"` → caller can abort PIs where `started_by.id == caller.sub`
  - `"all"` → caller can abort any PI

  Retry requires the `retry_process_instance` enum claim (same scoping).

  Delete requires the `delete_process_instance` enum claim (same scoping).
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api

  # ---------------------------------------------------------------------------
  # PUT /process-instances/:id/abort
  # ---------------------------------------------------------------------------

  def abort(conn, %{"id" => process_instance_id}) do
    reason = get_in(conn.body_params, ["reason"])
    identity = caller_identity(conn)

    case Api.abort_process_instance(process_instance_id, reason, identity) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Process instance not found")

      {:error, :forbidden, details} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: details[:required_claim] || "abort_process_instance",
          required_value: details[:required_value],
          resource: "process_instance"
        )

      {:error, :process_finished} ->
        render_error(
          conn,
          422,
          "process_already_terminal",
          "Process instance is already in a terminal state",
          current_state: "finished"
        )

      {:error, :process_fatal} ->
        render_error(
          conn,
          422,
          "process_already_terminal",
          "Process instance is already in a terminal state",
          current_state: "fatal"
        )

      {:error, :process_aborted} ->
        render_error(
          conn,
          422,
          "process_already_terminal",
          "Process instance is already in a terminal state",
          current_state: "aborted"
        )

      {:error, abort_reason} ->
        render_error(
          conn,
          422,
          to_string(abort_reason),
          "Cannot abort process instance: #{abort_reason}"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /process-instances/:id/retry
  # ---------------------------------------------------------------------------

  def retry(conn, %{"id" => process_instance_id}) do
    identity = caller_identity(conn)

    retry_opts = %{
      "version" => get_in(conn.body_params, ["version"]),
      "resetToFlowNodeInstanceId" => get_in(conn.body_params, ["resetToFlowNodeInstanceId"])
    }

    case Api.retry_process_instance(process_instance_id, retry_opts, identity) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :forbidden, details} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: details[:required_claim] || "retry_process_instance",
          required_value: details[:required_value],
          resource: "process_instance"
        )

      error ->
        render_retry_error(conn, process_instance_id, error)
    end
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :not_found}) do
    render_error(conn, 404, "not_found", "Process instance not found")
  end

  defp render_retry_error(
         conn,
         _process_instance_id,
         {:error, :process_instance_not_retriable, current_state}
       ) do
    render_error(
      conn,
      422,
      "process_instance_not_retriable",
      "Process instance cannot be retried in its current state",
      current_state: current_state
    )
  end

  defp render_retry_error(
         conn,
         _process_instance_id,
         {:error, :root_process_instance_not_terminal, root_state, root_id}
       ) do
    render_error(
      conn,
      422,
      "root_process_instance_not_terminal",
      "Root process instance is not in a terminal state",
      root_process_instance_id: root_id,
      root_state: root_state
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :version_not_found, version}) do
    render_error(conn, 404, "version_not_found", "Target version not found", version: version)
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :version_not_found}) do
    render_error(conn, 404, "version_not_found", "Target version not found")
  end

  defp render_retry_error(conn, process_instance_id, {:error, :target_version_not_cached, reason}) do
    Logger.error(
      "Retry target version not cached for process instance '#{process_instance_id}': #{inspect(reason)}"
    )

    render_error(
      conn,
      422,
      "target_version_not_cached",
      "Target version BPMN could not be loaded for compatibility check"
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :version_disabled, version}) do
    render_error(conn, 422, "version_disabled", "Target process is disabled", version: version)
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :version_disabled}) do
    render_error(conn, 422, "version_disabled", "Target process is disabled")
  end

  defp render_retry_error(
         conn,
         _process_instance_id,
         {:error, :version_migration_incompatible, conflicts}
       ) do
    render_error(
      conn,
      422,
      "version_migration_incompatible",
      "FNI chain is incompatible with target version",
      conflicts: conflicts
    )
  end

  defp render_retry_error(
         conn,
         _process_instance_id,
         {:error, :flow_node_instance_not_found, flow_node_instance_id}
       ) do
    render_error(
      conn,
      404,
      "flow_node_instance_not_found",
      "Checkpoint flow node instance not found on this process instance",
      flow_node_instance_id: flow_node_instance_id
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :flow_node_instance_not_found}) do
    render_error(
      conn,
      404,
      "flow_node_instance_not_found",
      "Checkpoint flow node instance not found on this process instance"
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :retry_checkpoint_is_ebg_loser}) do
    render_error(
      conn,
      422,
      "retry_checkpoint_is_ebg_loser",
      "Cannot retry at this flow node — it was cancelled by an Event-Based Gateway race. " <>
        "Retry at the gateway itself or at a node upstream of it."
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :retry_checkpoint_is_join_gateway}) do
    render_error(
      conn,
      422,
      "retry_checkpoint_is_join_gateway",
      "Cannot retry at a parallel join gateway. " <>
        "Retry at the fork gateway or at a node upstream of it."
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :retry_checkpoint_is_mi_iteration}) do
    render_error(
      conn,
      422,
      "retry_checkpoint_is_mi_iteration",
      "Cannot retry at a multi-instance iteration. " <>
        "Retry at the multi-instance shell activity or at a node upstream of it."
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :retry_checkpoint_is_non_retryable}) do
    render_error(
      conn,
      422,
      "retry_checkpoint_is_non_retryable",
      "Cannot retry at this flow node — it was interrupted by a BPMN flow mechanism " <>
        "(boundary cancellation, Event-Based Gateway, or Terminate/Error End Event). " <>
        "Retry without a checkpoint or select a different flow node."
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :engine_at_capacity, details}) do
    conn
    |> put_resp_header("retry-after", "5")
    |> render_error(503, "engine_at_capacity", "Engine at capacity",
      active: details.active,
      limit: details.limit
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :ancestor_not_found, ancestor_id}) do
    render_error(
      conn,
      422,
      "root_process_instance_not_terminal",
      "Ancestor process instance not found during tree walk",
      ancestor_process_instance_id: ancestor_id
    )
  end

  defp render_retry_error(conn, _process_instance_id, {:error, :retry_inside_transaction_scope}) do
    render_error(
      conn,
      422,
      "retry_inside_transaction_scope",
      "Cannot retry a process instance that is nested inside a Transaction subprocess. " <>
        "Retry from the Transaction subprocess shell or from a node upstream of it."
    )
  end

  defp render_retry_error(
         conn,
         _process_instance_id,
         {:error, :retry_checkpoint_inside_transaction}
       ) do
    render_error(
      conn,
      422,
      "retry_checkpoint_inside_transaction",
      "Cannot checkpoint-retry at a flow node that was cancelled by a Cancel End Event " <>
        "inside a Transaction subprocess. Select a checkpoint upstream of the transaction."
    )
  end

  defp render_retry_error(conn, process_instance_id, {:error, :retry_start_failed, reason}) do
    Logger.error("Retry failed for process instance '#{process_instance_id}': #{inspect(reason)}")

    render_error(
      conn,
      500,
      "internal_error",
      "Retry failed for process instance '#{process_instance_id}'"
    )
  end

  defp render_retry_error(conn, process_instance_id, {:error, reason}) do
    Logger.error("Retry failed for process instance '#{process_instance_id}': #{inspect(reason)}")

    render_error(
      conn,
      500,
      "internal_error",
      "Retry failed for process instance '#{process_instance_id}'"
    )
  end

  # ---------------------------------------------------------------------------
  # DELETE /process-instances/:id
  # ---------------------------------------------------------------------------

  def soft_delete(conn, %{"id" => process_instance_id}) do
    identity = caller_identity(conn)

    case Api.delete_process_instance(process_instance_id, identity) do
      {:ok, _updated_process_instance} ->
        send_resp(conn, 204, "")

      {:error, :forbidden, details} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: details[:required_claim] || "delete_process_instance",
          required_value: details[:required_value],
          resource: "process_instance"
        )

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Process instance not found")

      {:error, :process_instance_not_terminal, state} ->
        render_error(
          conn,
          422,
          "process_instance_not_terminal",
          "Process instance must be in a terminal state before deletion",
          current_state: state
        )

      {:error, reason} ->
        Logger.error(
          "Delete failed for process instance '#{process_instance_id}': #{inspect(reason)}"
        )

        render_error(
          conn,
          500,
          "internal_error",
          "Delete failed for process instance '#{process_instance_id}'"
        )
    end
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
