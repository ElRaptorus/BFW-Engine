defmodule EvilEngine.Plugins.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EvilEngine.Plugins.Registry,
      EvilEngine.Plugins.Loader
    ]

    opts = [strategy: :one_for_one, name: EvilEngine.Plugins.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
