defmodule BfwEngine.Plugins.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BfwEngine.Plugins.Registry,
      BfwEngine.Plugins.Loader
    ]

    opts = [strategy: :one_for_one, name: BfwEngine.Plugins.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
