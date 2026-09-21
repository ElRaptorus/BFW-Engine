defmodule BfwEngineWeb.Http.Plugs.DeprecationPlug do
  @moduledoc """
  Injects RFC 8594 deprecation headers on routes marked as deprecated.

  A route is deprecated when `conn.private[:deprecated]` contains a map
  with `:successor` (path string) and optionally `:sunset` (`DateTime`).
  When present, the plug adds:

    * `deprecation: true`
    * `link: <successor>; rel="successor-version"`
    * `sunset: <HTTP-date>` (only when `:sunset` is non-nil)

  """

  @behaviour Plug

  @doc """
  Initializes plug options.

  Options are passed through unchanged; this plug does not read configuration
  from `opts`.
  """
  @impl true
  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @doc """
  Adds deprecation response headers when `conn.private[:deprecated]` matches
  `%{successor: successor}` for some path string `successor`.

  Otherwise returns `conn` unchanged.
  """
  @impl true
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.private[:deprecated] do
      %{successor: successor} = deprecation_info ->
        conn
        |> Plug.Conn.put_resp_header("deprecation", "true")
        |> Plug.Conn.put_resp_header("link", successor_link(successor))
        |> maybe_sunset(deprecation_info[:sunset])

      _ ->
        conn
    end
  end

  defp successor_link(successor), do: "<#{successor}>; rel=\"successor-version\""

  defp maybe_sunset(conn, nil), do: conn

  defp maybe_sunset(conn, %DateTime{} = date_time) do
    Plug.Conn.put_resp_header(conn, "sunset", format_http_date(date_time))
  end

  defp format_http_date(%DateTime{} = date_time) do
    date_time
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end
end
