defmodule BfwEngineWeb.Http.Plugs.PayloadCapPlug do
  @moduledoc """
  Supplementary API-layer fast-fail for the payload cap.

  Checks the `"payload"` field (or a configured field name) of the parsed
  JSON body against `BfwEngine.Execution.PayloadCap.check/2`. On
  violation, halts the conn with HTTP 413 and a structured JSON error
  body per `docs/architecture/api.md` §10.1.1.

  This plug is a convenience — the authoritative enforcement lives in the
  PI Facade (core domain). Inbound requests that pass this plug will be
  checked again by the Facade before any engine state changes.

  ## Usage

      plug PayloadCapPlug, field: "payload"

  ## Options

    * `:field` — the body parameter key to check (default `"payload"`).
  """

  @behaviour Plug

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Execution.PayloadCap

  @impl true
  def init(opts) do
    field_string = Keyword.get(opts, :field, "payload")
    %{field_string: field_string, field_atom: String.to_atom(field_string)}
  end

  @impl true
  def call(%Plug.Conn{body_params: body} = conn, %{field_string: field_string} = opts)
      when is_map(body) do
    case Map.fetch(body, field_string) do
      {:ok, value} ->
        check_and_respond(conn, value, opts)

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp check_and_respond(conn, value, %{field_atom: field_atom}) do
    case PayloadCap.check(value, field: field_atom) do
      :ok ->
        conn

      {:error, :payload_too_large, %{size: size, limit: limit, field: field}} ->
        Logger.warning(
          "Payload cap exceeded: #{conn.method} #{conn.request_path} — " <>
            "field=#{field}, size=#{size}, limit=#{limit}"
        )

        render_error_halt(conn, 413, "payload_too_large", "Payload exceeds size limit",
          field: to_string(field),
          size: size,
          limit: limit
        )
    end
  end
end
