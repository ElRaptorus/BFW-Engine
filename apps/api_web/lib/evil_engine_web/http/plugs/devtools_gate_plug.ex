defmodule EvilEngineWeb.Http.Plugs.DevtoolsGatePlug do
  @moduledoc """
  Gates developer-facing UI routes behind the `:devtools_enabled` config flag.

  Returns `404 Not Found` when devtools are disabled (production default).
  Accepts an optional `:allow_if` key that names a secondary config flag —
  when that flag is `true`, the request is allowed even if devtools are off.
  This supports the `EVIL_EXPOSE_OPENAPI_SPEC` opt-in for the spec endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    devtools? = Application.get_env(:api_web, :devtools_enabled, true)
    allow_key = Keyword.get(opts, :allow_if)
    override? = allow_key && Application.get_env(:api_web, allow_key, false)

    if devtools? or override? do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
