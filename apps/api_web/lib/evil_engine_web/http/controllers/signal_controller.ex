defmodule EvilEngineWeb.Http.SignalController do
  @moduledoc """
  REST controller for signal trigger operations.

  ## Routes

  - `POST /signals/:signal_name/trigger` — broadcast a signal

  ## Authorization

  Requires the `trigger_signal` claim via `EvilEngine.Api`:
  - `"none"` or absent -> 403
  - `"all"` -> caller can trigger any signal

  ## Payload handling

  Signals carry no payload. Any `payload` key in the request body is
  silently ignored (consistent with all other engine endpoints, which
  cherry-pick known fields and ignore unknown ones).
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api
  alias EvilEngine.Types.Wire

  def publish(conn, %{"signal_name" => signal_name}) do
    identity = caller_identity(conn)

    case Api.publish_signal(signal_name, identity) do
      {:ok, publish_result} ->
        response = %{
          signal_id: publish_result.signal_id,
          signal_name: publish_result.signal_name,
          deliveries: publish_result.deliveries,
          started_process_instance_ids: publish_result.started_process_instance_ids,
          pending: publish_result.pending
        }

        conn
        |> put_status(200)
        |> json(Wire.camelize_keys(response))

      {:error, :subscriptions_not_ready} ->
        conn
        |> put_resp_header("retry-after", "5")
        |> render_error(
          503,
          "service_unavailable",
          "Engine is resuming — signal subscriptions not ready yet"
        )

      {:error, :forbidden, details} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: details[:required_claim] || "trigger_signal",
          required_value: details[:required_value] || "all",
          resource: "signal"
        )
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))

      render_error(
        conn,
        500,
        "internal_error",
        "Failed to publish signal '#{signal_name}'"
      )
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
