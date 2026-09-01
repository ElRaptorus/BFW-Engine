defmodule Examples.EventSinks.Sse.SsePlug do
  @moduledoc """
  RestApiExtension Plug: `GET <prefix>/stream` returns `text/event-stream`.
  """

  @behaviour Plug
  @behaviour EvilEngine.Plugin.RestApiExtension

  import Plug.Conn

  alias Examples.EventSinks.Sse.ConnectionHub

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["stream"]} = conn, _opts) do
    case conn.assigns[:identity] do
      %{id: _identity_id} ->
        conn = fetch_query_params(conn)
        severity_filter = conn.query_params["severity"]
        max_events = parse_max_events(conn.query_params["maxEvents"])

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        ConnectionHub.subscribe(self())

        try do
          stream_loop(conn, severity_filter, max_events, 0)
        after
          ConnectionHub.unsubscribe(self())
        end

      _missing_identity ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end

  defp stream_loop(conn, severity_filter, max_events, events_sent) do
    receive do
      {:sse_event, json_body, event_severity} ->
        if severity_matches?(severity_filter, event_severity) do
          case chunk(conn, ConnectionHub.frame(json_body)) do
            {:ok, chunked_conn} ->
              next_count = events_sent + 1

              if reached_max_events?(max_events, next_count) do
                chunked_conn
              else
                stream_loop(chunked_conn, severity_filter, max_events, next_count)
              end

            {:error, _reason} ->
              conn
          end
        else
          stream_loop(conn, severity_filter, max_events, events_sent)
        end
    after
      15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, chunked_conn} ->
            stream_loop(chunked_conn, severity_filter, max_events, events_sent)

          {:error, _reason} ->
            conn
        end
    end
  end

  defp severity_matches?(nil, _event_severity), do: true
  defp severity_matches?("", _event_severity), do: true
  defp severity_matches?(filter, event_severity), do: filter == event_severity

  defp parse_max_events(nil), do: nil
  defp parse_max_events(""), do: nil

  defp parse_max_events(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, _} when count > 0 -> count
      _ -> nil
    end
  end

  defp reached_max_events?(nil, _events_sent), do: false
  defp reached_max_events?(max_events, events_sent), do: events_sent >= max_events
end
