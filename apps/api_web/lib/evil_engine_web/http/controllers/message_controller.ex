defmodule EvilEngineWeb.Http.MessageController do
  @moduledoc """
  REST controller for message trigger operations.

  ## Routes

  - `POST /messages/:message_name/trigger` — publish a message

  ## Authorization

  Requires the `trigger_message` claim via `EvilEngine.Api`:
  - `"none"` or absent → 403
  - `"all"` → caller can trigger any message
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api
  alias EvilEngine.Types.Wire

  def publish(conn, %{"message_name" => message_name}) do
    identity = caller_identity(conn)
    payload = get_in(conn.body_params, ["payload"]) || %{}
    correlation = get_in(conn.body_params, ["correlation"])

    case Api.publish_message(message_name, payload, correlation, identity) do
      {:ok, publish_result} ->
        response = %{
          message_id: publish_result.message_id,
          message_name: publish_result.message_name,
          correlation_value: publish_result.correlation_value,
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
          "Engine is resuming — message subscriptions not ready yet"
        )

      {:error, :forbidden, details} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: details[:required_claim] || "trigger_message",
          required_value: details[:required_value] || "all",
          resource: "message"
        )
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))

      render_error(
        conn,
        500,
        "internal_error",
        "Failed to publish message '#{message_name}'"
      )
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
