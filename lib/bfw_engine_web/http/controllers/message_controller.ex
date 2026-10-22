defmodule BfwEngineWeb.Http.MessageController do
  @moduledoc """
  REST controller for message trigger operations.

  ## Routes

  - `POST /messages/:message_name/trigger` — publish a message

  ## Authorization

  Requires the `trigger_message` claim via `BfwEngine.Api`:
  - `"none"` or absent → 403
  - `"all"` → caller can trigger any message
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Api
  alias BfwEngine.Types.Wire

  def publish(conn, %{"message_name" => message_name}) do
    case validate_body(conn.body_params) do
      :ok -> publish_validated(conn, message_name)
      {:error, message} -> render_error(conn, 400, "bad_request", message)
    end
  end

  defp validate_body(body_params) do
    correlation = Map.get(body_params, "correlation")
    payload = Map.get(body_params, "payload")

    cond do
      not (is_nil(correlation) or is_binary(correlation)) ->
        {:error, "Field 'correlation' must be a string or null, got #{json_type(correlation)}"}

      not (is_nil(payload) or is_map(payload)) ->
        {:error, "Field 'payload' must be an object or null, got #{json_type(payload)}"}

      true ->
        :ok
    end
  end

  defp json_type(value) when is_list(value), do: "an array"
  defp json_type(value) when is_map(value), do: "an object"
  defp json_type(value) when is_number(value), do: "a number"
  defp json_type(value) when is_boolean(value), do: "a boolean"
  defp json_type(value) when is_binary(value), do: "a string"

  defp publish_validated(conn, message_name) do
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
      nil -> %BfwEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
