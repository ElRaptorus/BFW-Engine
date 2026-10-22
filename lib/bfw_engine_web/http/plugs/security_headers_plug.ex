defmodule BfwEngineWeb.Http.Plugs.SecurityHeadersPlug do
  @moduledoc """
  Injects defensive HTTP response headers on every JSON / REST / GraphQL
  response (`:api` and `:authenticated` pipelines).

  Headers emitted on every request:

  | Header | Value | Rationale |
  |--------|-------|-----------|
  | `x-content-type-options` | `nosniff` | Prevents MIME-type sniffing. |
  | `x-frame-options` | `DENY` | Disallows embedding in iframes. |
  | `referrer-policy` | `strict-origin-when-cross-origin` | Limits referrer leakage. |
  | `permissions-policy` | `geolocation=(), camera=(), microphone=()` | Opts out of unused browser APIs. |

  Additionally, when the request scheme is `:https`:

  | Header | Value | Rationale |
  |--------|-------|-----------|
  | `strict-transport-security` | `max-age=63072000; includeSubDomains` | 2-year HSTS declaration. The `preload` directive is intentionally omitted: the engine is commonly deployed behind a reverse proxy that terminates TLS, and `preload` requires the engine itself to be the public TLS terminator. |

  The `:swagger_ui` pipeline is handled separately by Phoenix's
  `put_secure_browser_headers/2` and is not affected by this plug.
  """

  @behaviour Plug

  import Plug.Conn

  @static_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "strict-origin-when-cross-origin"},
    {"permissions-policy", "geolocation=(), camera=(), microphone=()"}
  ]

  @hsts_value "max-age=63072000; includeSubDomains"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_static_headers()
    |> maybe_hsts()
  end

  defp put_static_headers(conn) do
    Enum.reduce(@static_headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end

  defp maybe_hsts(%{scheme: :https} = conn) do
    put_resp_header(conn, "strict-transport-security", @hsts_value)
  end

  defp maybe_hsts(conn), do: conn
end
