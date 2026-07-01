defmodule EvilEngine.Auth.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    jwks_url = Application.get_env(:api_auth, :jwks_url)

    refresh_ms =
      Application.get_env(:api_auth, :jwks_refresh_seconds, 3600)
      |> Kernel.*(1000)

    children = [
      EvilEngine.Auth.ProviderRegistry,
      {EvilEngine.Auth.JwksCache, jwks_url: jwks_url, refresh_ms: refresh_ms}
    ]

    opts = [strategy: :one_for_one, name: EvilEngine.Auth.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
