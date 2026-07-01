defmodule EvilEngine.Auth.Plug do
  @moduledoc """
  Plug pipeline that extracts and verifies JWT tokens from the
  `Authorization: Bearer <token>` header.

  When `EVIL_AUTH_DISABLED=true`, injects a synthetic anonymous
  `%EvilEngine.Types.Identity{}` with least-privilege defaults.

  ## Conn assigns

  On success, sets:
  - `conn.assigns.identity` — `%EvilEngine.Types.Identity{}`
  - `conn.assigns.auth_method` — `:jwt` | `:anonymous`
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.Types.Identity
  alias EvilEngine.Types.Wire

  @anonymous_identity %Identity{
    id: "anonymous",
    roles: [],
    groups: [],
    claims: %{}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if auth_disabled?() do
      conn
      |> assign(:identity, @anonymous_identity)
      |> assign(:auth_method, :anonymous)
    else
      authenticate(conn)
    end
  end

  defp authenticate(conn) do
    with {:ok, token} <- extract_bearer(conn),
         {:ok, %Identity{} = identity} <- ProviderRegistry.verify_and_resolve(token) do
      conn
      |> assign(:identity, identity)
      |> assign(:auth_method, :jwt)
    else
      {:error, :no_bearer} ->
        Logger.warning("Auth rejected: missing Authorization header",
          path: conn.request_path,
          method: conn.method
        )

        conn |> unauthorized("Missing Authorization header")

      {:error, :no_key_configured} ->
        Logger.warning("Auth rejected: no JWT key material configured",
          path: conn.request_path,
          method: conn.method
        )

        conn |> service_unavailable("No JWT key material configured")

      {:error, reason} ->
        Logger.warning("Auth rejected: JWT verification failed — #{reason}",
          path: conn.request_path,
          method: conn.method
        )

        conn |> unauthorized()
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> {:error, :no_bearer}
    end
  end

  defp unauthorized(conn) do
    body = Wire.camelize_keys(%{error: "unauthorized", message: "Authentication required"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
    |> halt()
  end

  defp unauthorized(conn, message) do
    body = Wire.camelize_keys(%{error: "unauthorized", message: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
    |> halt()
  end

  defp service_unavailable(conn, message) do
    body = Wire.camelize_keys(%{error: "service_unavailable", message: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(body))
    |> halt()
  end

  defp auth_disabled? do
    Application.get_env(:api_auth, :auth_disabled, false)
  end
end
