defmodule EvilEngineWeb.Http.ErrorResponse do
  @moduledoc """
  Centralized error response helper for all REST controllers and plugs.

  Every error response produced by the HTTP layer should go through this
  module to guarantee:

    1. All structural keys are camelCased via `Wire.camelize_keys/1`
    2. Every response contains at least `error` (snake_case code) and `message`
    3. Field names match the SDK's `ErrorMapper` expectations
    4. Every error response is logged for the audit trail

  ## Audit-trail logging

  Both `render_error/5` and `render_error_halt/5` automatically log the
  error before sending the response:

    - **5xx** → `Logger.error`
    - **4xx** → `Logger.warning`

  Log lines include HTTP method, path, status, error code, message, and
  the acting identity (from `conn.assigns.identity`, if set).

  ## Usage

      import EvilEngineWeb.Http.ErrorResponse

      render_error(conn, 404, "not_found", "Resource not found")
      render_error(conn, 422, "contract_violation", "Result contract failed",
        violations: violations)

  Plugs that need to halt the conn before Phoenix.Controller is available
  should use `render_error_halt/4` or `render_error_halt/5` instead —
  these call `send_resp/3` + `halt/0` directly.
  """

  require Logger

  import Plug.Conn
  alias EvilEngine.Types.Wire

  @doc """
  Renders a JSON error response through `Phoenix.Controller.json/2`.

  Sets the status code and sends a camelCased JSON body with at least
  `error` and `message` keys, plus any extra fields merged in.
  Logs the error before sending.
  """
  @spec render_error(Plug.Conn.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          Plug.Conn.t()
  def render_error(conn, status, error_code, message, extras \\ []) do
    log_error_response(conn, status, error_code, message)
    body = build_body(error_code, message, extras)

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(Wire.camelize_keys(body))
  end

  @doc """
  Renders a JSON error response and halts the connection.

  For use in Plugs where `Phoenix.Controller.json/2` is not available.
  Calls `send_resp/3` directly with a pre-encoded JSON body.
  Logs the error before sending.
  """
  @spec render_error_halt(Plug.Conn.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          Plug.Conn.t()
  def render_error_halt(conn, status, error_code, message, extras \\ []) do
    log_error_response(conn, status, error_code, message)
    body = build_body(error_code, message, extras)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(Wire.camelize_keys(body)))
    |> halt()
  end

  defp build_body(error_code, message, extras) do
    base = %{error: error_code, message: message}
    Enum.into(extras, base)
  end

  defp log_error_response(conn, status, error_code, message) do
    level = if status >= 500, do: :error, else: :warning
    method = conn.method
    path = conn.request_path
    actor = actor_label(conn)

    Logger.log(level, "API #{status}: #{method} #{path} — #{error_code}: #{message}",
      http_status: status,
      error_code: error_code,
      actor: actor
    )
  end

  defp actor_label(conn) do
    case conn.assigns[:identity] do
      %{id: identity_id} -> identity_id
      _ -> "unauthenticated"
    end
  end
end
