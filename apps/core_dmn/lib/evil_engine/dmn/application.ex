defmodule EvilEngine.DMN.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [EvilEngine.DMN.ModelCache]
    opts = [strategy: :one_for_one, name: EvilEngine.DMN.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
