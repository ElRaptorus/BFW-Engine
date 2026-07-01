defmodule EvilEngineWeb.Http.TimerScheduleController do
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

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Timers.StartEventManager
  alias EvilEngine.Types.Wire

  def index(conn, params) do
    identity = caller_identity(conn)

    case check_deploy_claim(identity) do
      :ok ->
        filter_opts = build_filter_opts(params)
        {:ok, schedules} = StartEventManager.list_schedules(filter_opts)
        json(conn, Wire.camelize_keys(%{data: Enum.map(schedules, &sanitize_schedule/1)}))

      {:error, :forbidden} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: "deploy_bpmn"
        )
    end
  end

  def show(conn, %{"id" => schedule_id}) do
    identity = caller_identity(conn)

    case check_deploy_claim(identity) do
      :ok ->
        case StartEventManager.get_schedule(schedule_id) do
          {:ok, schedule} ->
            json(conn, Wire.camelize_keys(%{data: sanitize_schedule(schedule)}))

          {:error, :not_found} ->
            render_error(conn, 404, "not_found", "Timer schedule not found")
        end

      {:error, :forbidden} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: "deploy_bpmn"
        )
    end
  end

  def enable(conn, %{"id" => schedule_id}) do
    identity = caller_identity(conn)

    case check_deploy_claim(identity) do
      :ok ->
        case StartEventManager.enable_schedule(schedule_id) do
          {:ok, updated} ->
            json(conn, Wire.camelize_keys(%{data: sanitize_schedule(updated)}))

          {:error, :not_found} ->
            render_error(conn, 404, "not_found", "Timer schedule not found")

          {:error, :not_a_cycle} ->
            render_error(
              conn,
              422,
              "not_applicable",
              "Enable/disable is only supported for cycle timer schedules"
            )

          {:error, reason} ->
            Logger.error("Failed to enable timer schedule '#{schedule_id}': #{inspect(reason)}")

            render_error(
              conn,
              422,
              "enable_failed",
              "Failed to enable timer schedule '#{schedule_id}'"
            )
        end

      {:error, :forbidden} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: "deploy_bpmn"
        )
    end
  end

  def disable(conn, %{"id" => schedule_id}) do
    identity = caller_identity(conn)

    case check_deploy_claim(identity) do
      :ok ->
        case StartEventManager.disable_schedule(schedule_id) do
          {:ok, updated} ->
            json(conn, Wire.camelize_keys(%{data: sanitize_schedule(updated)}))

          {:error, :not_found} ->
            render_error(conn, 404, "not_found", "Timer schedule not found")

          {:error, :not_a_cycle} ->
            render_error(
              conn,
              422,
              "not_applicable",
              "Enable/disable is only supported for cycle timer schedules"
            )

          {:error, reason} ->
            Logger.error("Failed to disable timer schedule '#{schedule_id}': #{inspect(reason)}")

            render_error(
              conn,
              422,
              "disable_failed",
              "Failed to disable timer schedule '#{schedule_id}'"
            )
        end

      {:error, :forbidden} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: "deploy_bpmn"
        )
    end
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

  defp check_deploy_claim(identity) do
    claim_value = Map.get(identity.claims, "deploy_bpmn", false)

    if claim_value do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
