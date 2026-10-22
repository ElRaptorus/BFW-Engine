defmodule BfwEngine.Auth.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    jwks_url = Application.get_env(:bfw_engine, :jwks_url)

    refresh_ms =
      Application.get_env(:bfw_engine, :jwks_refresh_seconds, 3600)
      |> Kernel.*(1000)

    children = [
      BfwEngine.Auth.ProviderRegistry,
      {BfwEngine.Auth.JwksCache, jwks_url: jwks_url, refresh_ms: refresh_ms}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
