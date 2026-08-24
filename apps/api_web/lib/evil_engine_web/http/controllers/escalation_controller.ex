defmodule EvilEngineWeb.Http.EscalationController do
  @moduledoc """
  REST controller for escalation trigger operations.

  ## Routes

  - `POST /escalations/:escalation_code/trigger` — inject an escalation
    into waiting catchers (Event Subprocess starts and Escalation
    Boundary FNIs) on every running process instance.

  ## Authorization

  Requires the boolean `trigger_escalation` claim via `EvilEngine.Api`.
  `zeeky_boogie_doog` bypasses the claim check.

  ## Payload handling

  Escalations carry no payload. Any `payload` key in the request body is
  silently ignored (consistent with all other engine endpoints, which
  cherry-pick known fields and ignore unknown ones).
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  import EvilEngineWeb.Http.ErrorResponse

  alias EvilEngine.Api
  alias EvilEngine.Types.Wire

  def publish(conn, %{"escalation_code" => escalation_code}) do
    identity = caller_identity(conn)

    case Api.trigger_escalation(escalation_code, identity) do
      {:ok, publish_result} ->
        response = %{
          escalation_code: publish_result.escalation_code,
          deliveries: publish_result.deliveries,
          pending: publish_result.pending
        }

        conn
        |> put_status(200)
        |> json(Wire.camelize_keys(response))

      {:error, :escalation_code_blank} ->
        render_error(
          conn,
          422,
          "escalation_code_blank",
          "Escalation code must not be blank"
        )

      {:error, :escalation_code_too_long} ->
        render_error(
          conn,
          422,
          "escalation_code_too_long",
          "Escalation code must be at most 256 characters"
        )

      {:error, :forbidden, details} ->
        render_error(conn, 403, "forbidden", "Insufficient permissions",
          required_claim: details[:required_claim] || "trigger_escalation",
          resource: "escalation"
        )
    end
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))

      render_error(
        conn,
        500,
        "internal_error",
        "Failed to trigger escalation '#{escalation_code}'"
      )
  end

  defp caller_identity(conn) do
    case conn.assigns[:identity] do
      nil -> %EvilEngine.Types.Identity{id: "anonymous", roles: [], groups: []}
      identity -> identity
    end
  end
end
