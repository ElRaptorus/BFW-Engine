defmodule BfwEngine.DMN.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [BfwEngine.DMN.ModelCache]
    opts = [strategy: :one_for_one, name: BfwEngine.DMN.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
