defmodule BfwEngineWeb.Http.TimerScheduleController do
  @moduledoc """
  REST controller for Timer Start Event schedule management.

  ## Routes

  - `GET /timer-schedules` — List all timer schedules
  - `GET /timer-schedules/:id` — Get a single schedule
  - `PUT /timer-schedules/:id/enable` — Enable a disabled schedule
  - `PUT /timer-schedules/:id/disable` — Disable an enabled schedule

  ## Authorization

  All operations require the `deploy_bpmn` claim (reusing the deploy
  permission since timer schedules are a deployment concern).
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Api
  alias BfwEngine.Types.Wire

  def index(conn, params) do
    case Api.list_timer_schedules(caller_identity(conn), build_filter_opts(params)) do
      {:ok, schedules} ->
        json(conn, Wire.camelize_keys(%{data: Enum.map(schedules, &sanitize_schedule/1)}))

      {:error, :forbidden, _details} ->
        render_forbidden(conn)
    end
  end

  def show(conn, %{"id" => schedule_id}) do
    case Api.get_timer_schedule(schedule_id, caller_identity(conn)) do
      {:ok, schedule} ->
        json(conn, Wire.camelize_keys(%{data: sanitize_schedule(schedule)}))

      {:error, :not_found} ->
        render_error(conn, 404, "not_found", "Timer schedule not found")

      {:error, :forbidden, _details} ->
        render_forbidden(conn)
    end
  end

  def enable(conn, %{"id" => schedule_id}) do
    schedule_id
    |> Api.enable_timer_schedule(caller_identity(conn))
    |> render_update(conn, schedule_id, "enable_failed", "enable")
  end

  def disable(conn, %{"id" => schedule_id}) do
    schedule_id
    |> Api.disable_timer_schedule(caller_identity(conn))
    |> render_update(conn, schedule_id, "disable_failed", "disable")
  end

  defp render_update({:ok, updated}, conn, _schedule_id, _error_code, _verb) do
    json(conn, Wire.camelize_keys(%{data: sanitize_schedule(updated)}))
  end

  defp render_update({:error, :not_found}, conn, _schedule_id, _error_code, _verb) do
    render_error(conn, 404, "not_found", "Timer schedule not found")
  end

  defp render_update({:error, :not_a_cycle}, conn, _schedule_id, _error_code, _verb) do
    render_error(
      conn,
      422,
      "not_applicable",
      "Enable/disable is only supported for cycle timer schedules"
    )
  end

  defp render_update({:error, :forbidden, _details}, conn, _schedule_id, _error_code, _verb) do
    render_forbidden(conn)
  end

  defp render_update({:error, reason}, conn, schedule_id, error_code, verb) do
    Logger.error("Failed to #{verb} timer schedule '#{schedule_id}': #{inspect(reason)}")

    render_error(conn, 422, error_code, "Failed to #{verb} timer schedule '#{schedule_id}'")
  end

  defp render_forbidden(conn) do
    render_error(conn, 403, "forbidden", "Insufficient permissions",
      required_claim: "deploy_bpmn"
    )
  end

  defp build_filter_opts(params) do
    opts = []

    opts =
      if is_binary(params["processVersionId"]) do
        [{:process_version_id, params["processVersionId"]} | opts]
      else
        opts
      end

    if params["enabled"] in ["true", "false"] do
      [{:enabled, params["enabled"] == "true"} | opts]
    else
      opts
    end
  end

  defp sanitize_schedule(schedule) when is_map(schedule) do
    Map.take(schedule, [
      :id,
      :process_model_id,
      :process_version_id,
      :flow_node_id,
      :kind,
      :iso_spec,
      :enabled,
      :next_fire_at,
      :last_triggered_at,
      :cycle_total,
      :cycle_remaining
    ])
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %BfwEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
