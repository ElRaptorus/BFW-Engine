defmodule BfwEngineWeb.Http.AdhocSubprocessController do
  @moduledoc """
  REST controller for ad-hoc subprocess operations.

  ## Routes

  - `GET  /adhoc-subprocesses/:id/activities` — list enabled/performed inner activities
  - `POST /adhoc-subprocesses/:id/activities/:activity_id/activate` — activate an inner activity
  - `POST /adhoc-subprocesses/:id/complete` — signal completion
  - `GET  /adhoc-subprocesses/:id/status` — query runtime status

  ## Authorization

  All endpoints require the `manage_adhoc_subprocess` JWT claim (or the
  `zeeky_boogie_doog` admin override). Plugins call the same facade
  functions with `skip_claims: true`.

  The `:id` path parameter is the **child process instance ID** of the
  ad-hoc subprocess — the PI spawned by the ad-hoc subprocess handler,
  not the parent PI.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Api
  alias BfwEngine.Types.Wire

  def list_activities(conn, %{"id" => process_instance_id}) do
    identity = caller_identity(conn)

    case Api.get_adhoc_enabled_activities(process_instance_id, identity) do
      {:ok, activities} ->
        json(conn, Wire.camelize_keys(%{data: activities}))

      error ->
        render_adhoc_error(conn, error)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Failed to list ad-hoc activities")
  end

  def activate_activity(conn, %{"id" => process_instance_id, "activity_id" => flow_node_id}) do
    identity = caller_identity(conn)

    case Api.activate_adhoc_activity(process_instance_id, flow_node_id, identity) do
      {:ok, result} ->
        conn |> put_status(200) |> json(Wire.camelize_keys(result))

      error ->
        render_adhoc_error(conn, error)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Failed to activate ad-hoc activity")
  end

  def complete(conn, %{"id" => process_instance_id}) do
    identity = caller_identity(conn)

    case Api.complete_adhoc_subprocess(process_instance_id, identity) do
      :ok ->
        conn |> put_status(200) |> json(%{completed: true})

      error ->
        render_adhoc_error(conn, error)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Failed to complete ad-hoc subprocess")
  end

  def status(conn, %{"id" => process_instance_id}) do
    identity = caller_identity(conn)

    case Api.get_adhoc_status(process_instance_id, identity) do
      {:ok, status_map} ->
        json(conn, Wire.camelize_keys(status_map))

      error ->
        render_adhoc_error(conn, error)
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      render_error(conn, 500, "internal_error", "Failed to get ad-hoc status")
  end

  # -------------------------------------------------------------------
  # Error rendering
  # -------------------------------------------------------------------

  defp render_adhoc_error(conn, {:error, :not_found}),
    do: render_error(conn, 404, "not_found", "Process instance not found")

  defp render_adhoc_error(conn, {:error, :not_adhoc_subprocess}),
    do:
      render_error(
        conn,
        422,
        "not_adhoc_subprocess",
        "Process instance is not an ad-hoc subprocess"
      )

  defp render_adhoc_error(conn, {:error, :adhoc_activity_not_found}),
    do: render_error(conn, 404, "adhoc_activity_not_found", "Activity not found in ad-hoc scope")

  defp render_adhoc_error(conn, {:error, :adhoc_already_completing}),
    do:
      render_error(
        conn,
        409,
        "adhoc_already_completing",
        "Ad-hoc subprocess completion already signaled"
      )

  defp render_adhoc_error(conn, {:error, :adhoc_not_active}),
    do:
      render_error(
        conn,
        409,
        "adhoc_not_active",
        "Ad-hoc subprocess is no longer active"
      )

  defp render_adhoc_error(conn, {:error, :adhoc_sequential_busy}),
    do:
      render_error(
        conn,
        422,
        "adhoc_sequential_busy",
        "Sequential ad-hoc subprocess is busy — an activity is already running"
      )

  defp render_adhoc_error(conn, {:error, :dispatch_failed}),
    do:
      render_error(
        conn,
        500,
        "dispatch_failed",
        "Failed to dispatch ad-hoc activity"
      )

  defp render_adhoc_error(conn, {:error, :forbidden, details}),
    do:
      render_error(conn, 403, "forbidden", "Insufficient permissions",
        required_claim: details[:required_claim] || "manage_adhoc_subprocess"
      )

  defp render_adhoc_error(conn, {:error, reason}) do
    Logger.error("Ad-hoc subprocess operation failed: #{inspect(reason)}")
    render_error(conn, 500, "internal_error", "Ad-hoc subprocess operation failed")
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %BfwEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
